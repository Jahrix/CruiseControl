import Foundation
import CryptoKit
import Security
import Combine

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) throws -> Data {
        let remainder = string.count % 4
        let padding = remainder == 0 ? "" : String(repeating: "=", count: 4 - remainder)
        let base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding

        guard let data = Data(base64Encoded: base64) else {
            throw LicenseValidationError.invalidBase64
        }
        return data
    }
}

struct LicensePayload: Codable, Equatable {
    let v: Int
    let product: String
    let issuedAt: Date
    let email: String?
    let name: String?
    let expiresAt: Date?
    let features: [String]
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case v
        case product
        case issuedAt = "issued_at"
        case email
        case name
        case expiresAt = "expires_at"
        case features
        case nonce
    }

    var licensedTo: String? {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedEmail, !trimmedEmail.isEmpty {
            return trimmedEmail
        }

        return nil
    }
}

enum LicenseStatus: Equatable {
    case locked
    case unlocked(licensedTo: String?)
    case expired
    case invalid
    case missing

    var badgeText: String {
        switch self {
        case .locked, .missing:
            return "Locked"
        case .unlocked:
            return "Pro ✅"
        case .expired:
            return "Expired"
        case .invalid:
            return "Invalid"
        }
    }
}

enum LicenseValidationError: LocalizedError {
    case malformed
    case invalidBase64
    case invalidSignature
    case unsupportedVersion
    case wrongProduct
    case missingProFeature
    case invalidNonce
    case invalidPublicKey
    case expired

    var errorDescription: String? {
        switch self {
        case .malformed:
            return "License key format is invalid."
        case .invalidBase64:
            return "License key contains invalid Base64URL data."
        case .invalidSignature:
            return "License signature verification failed."
        case .unsupportedVersion:
            return "This license version is not supported."
        case .wrongProduct:
            return "This key is not for CruiseControl Pro."
        case .missingProFeature:
            return "This key does not unlock CruiseControl Pro."
        case .invalidNonce:
            return "License payload is missing a valid nonce."
        case .invalidPublicKey:
            return "Embedded license public key is invalid."
        case .expired:
            return "This license has expired."
        }
    }
}

enum LicenseKeychainStore {
    static let service = "com.jahrix.CruiseControl"
    static let account = "license"

    static func loadLicense() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    static func saveLicense(_ value: String) throws {
        let valueData = Data(value.utf8)
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(updateStatus),
                userInfo: [NSLocalizedDescriptionKey: "Unable to update the stored license (OSStatus \(updateStatus))."]
            )
        }

        var addQuery = lookup
        addQuery.merge(attributes) { _, newValue in newValue }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(addStatus),
                userInfo: [NSLocalizedDescriptionKey: "Unable to save the license in Keychain (OSStatus \(addStatus))."]
            )
        }
    }

    static func deleteLicense() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Unable to remove the stored license (OSStatus \(status))."]
            )
        }
    }
}

private enum LicenseConfiguration {
    static let prefix = "CC1"
    static let product = "CruiseControlPro"
    static let publicKeyBase64URL = "Iu6Q3x6NrwyezA0j6ZU2seS9nJBTXMv9RneqWLL13gI"
}

private struct ParsedLicense {
    let payload: LicensePayload
    let rawLicense: String
}

@MainActor
final class ProGate: ObservableObject {
    @Published private(set) var licenseStatus: LicenseStatus = .missing
    @Published private(set) var lastValidationError: String?
    @Published private(set) var installedLicense: String?

    var isProUnlocked: Bool {
        if isDebugDeveloperOverrideEnabled {
            return true
        }
        if case .unlocked = licenseStatus {
            return true
        }
        return false
    }

    init() {
        refreshStoredLicense()
    }

    func refreshStoredLicense() {
        if isDebugDeveloperOverrideEnabled {
            installedLicense = nil
            licenseStatus = .unlocked(licensedTo: "Developer")
            lastValidationError = nil
            return
        }

        guard let stored = LicenseKeychainStore.loadLicense(),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            installedLicense = nil
            licenseStatus = .missing
            lastValidationError = nil
            return
        }

        installedLicense = stored

        do {
            let parsed = try validate(licenseString: stored)
            licenseStatus = .unlocked(licensedTo: parsed.payload.licensedTo)
            lastValidationError = nil
        } catch LicenseValidationError.expired {
            licenseStatus = .expired
            lastValidationError = LicenseValidationError.expired.localizedDescription
        } catch {
            licenseStatus = .invalid
            lastValidationError = error.localizedDescription
        }
    }

    @discardableResult
    func activate(licenseString: String) -> Bool {
        let trimmed = licenseString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if installedLicense == nil {
                licenseStatus = .locked
            }
            lastValidationError = "Paste a CruiseControl Pro license key first."
            return false
        }

        do {
            let parsed = try validate(licenseString: trimmed)
            try LicenseKeychainStore.saveLicense(trimmed)
            installedLicense = trimmed
            licenseStatus = .unlocked(licensedTo: parsed.payload.licensedTo)
            lastValidationError = nil
            return true
        } catch LicenseValidationError.expired {
            if installedLicense == nil {
                licenseStatus = .expired
            }
            lastValidationError = LicenseValidationError.expired.localizedDescription
            return false
        } catch {
            if installedLicense == nil {
                licenseStatus = .invalid
            }
            lastValidationError = error.localizedDescription
            return false
        }
    }

    func removeLicense() {
        do {
            try LicenseKeychainStore.deleteLicense()
            installedLicense = nil
            refreshStoredLicense()
        } catch {
            lastValidationError = error.localizedDescription
        }
    }

    func statusLine() -> String {
        switch licenseStatus {
        case .locked, .missing:
            return "CruiseControl Pro is locked."
        case .unlocked(let licensedTo):
            if let licensedTo, !licensedTo.isEmpty {
                return "CruiseControl Pro is unlocked for \(licensedTo)."
            }
            return "CruiseControl Pro is unlocked."
        case .expired:
            return "Stored license found, but it has expired."
        case .invalid:
            return "Stored license found, but it is invalid."
        }
    }

    private func validate(licenseString: String) throws -> ParsedLicense {
        let components = licenseString.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components[0] == LicenseConfiguration.prefix else {
            throw LicenseValidationError.malformed
        }

        let payloadData = try Base64URL.decode(String(components[1]))
        let signature = try Base64URL.decode(String(components[2]))

        guard let publicKeyData = try? Base64URL.decode(LicenseConfiguration.publicKeyBase64URL),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw LicenseValidationError.invalidPublicKey
        }

        guard publicKey.isValidSignature(signature, for: payloadData) else {
            throw LicenseValidationError.invalidSignature
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(LicensePayload.self, from: payloadData)

        guard payload.v == 1 else {
            throw LicenseValidationError.unsupportedVersion
        }
        guard payload.product == LicenseConfiguration.product else {
            throw LicenseValidationError.wrongProduct
        }
        guard payload.features.contains("pro") else {
            throw LicenseValidationError.missingProFeature
        }
        guard !payload.nonce.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LicenseValidationError.invalidNonce
        }
        if let expiresAt = payload.expiresAt, expiresAt < Date() {
            throw LicenseValidationError.expired
        }

        return ParsedLicense(payload: payload, rawLicense: licenseString)
    }

    private var isDebugDeveloperOverrideEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CRUISECONTROL_DEV_PRO"] == "1"
        #else
        return false
        #endif
    }
}

#if DEBUG
enum LicenseDebugSelfTests {
    static func run() {
        let roundtripData = Data("CruiseControl Pro".utf8)
        assert((try? Base64URL.decode(Base64URL.encode(roundtripData))) == roundtripData, "Base64URL roundtrip failed.")

        let payload = try! Base64URL.decode("eyJ2IjoxLCJwcm9kdWN0IjoiQ3J1aXNlQ29udHJvbFBybyIsImlzc3VlZF9hdCI6IjIwMjYtMDMtMDVUMDA6MDA6MDBaIiwiZW1haWwiOiJ0ZXN0QGV4YW1wbGUuY29tIiwibmFtZSI6IlRlc3QgUGlsb3QiLCJleHBpcmVzX2F0IjpudWxsLCJmZWF0dXJlcyI6WyJwcm8iXSwibm9uY2UiOiJkZWJ1Zy1zZWxmLXRlc3QifQ")
        let signature = try! Base64URL.decode("T7e88iizdrvHXHCbIIvMcodfboFXkERHQg4YAvkkqqFucg0-eFpVHoblj4JtRXOWZhcgaOOI1V4bgj7AZRXwCQ")
        let publicKeyData = try! Base64URL.decode("hlxy28Br26JezrQ9x-oidq8kAn-aeGNgQKitbXSQZUc")
        let publicKey = try! Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)

        assert(publicKey.isValidSignature(signature, for: payload), "Expected test signature to verify.")

        var tamperedPayload = payload
        tamperedPayload[0] ^= 0x01
        assert(!publicKey.isValidSignature(signature, for: tamperedPayload), "Tampered payload should fail signature verification.")
    }
}
#endif
