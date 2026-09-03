import Foundation

/// Read-only flight context assembled from fresh X-Plane telemetry and the
/// optional CruiseControl companion bridge. Values are deliberately absent when
/// neither source can provide them reliably.
public struct FlightContext: Equatable, Sendable {
    public enum SimulatorVersion: String, Equatable, Sendable {
        case xp11
        case xp12
        case unknown

        public var displayName: String {
            switch self {
            case .xp11: return "X-Plane 11"
            case .xp12: return "X-Plane 12"
            case .unknown: return "Not available yet"
            }
        }
    }

    public let simulatorVersion: SimulatorVersion
    public let aircraftIdentifier: String?
    public let aircraftName: String?
    public let nearestAirportICAO: String?
    public let altitudeAGLFeet: Double?
    public let altitudeMSLFeet: Double?
    public let isOnGround: Bool?

    public static let unknown = FlightContext(
        simulatorVersion: .unknown,
        aircraftIdentifier: nil,
        aircraftName: nil,
        nearestAirportICAO: nil,
        altitudeAGLFeet: nil,
        altitudeMSLFeet: nil,
        isOnGround: nil
    )

    public init(
        simulatorVersion: SimulatorVersion,
        aircraftIdentifier: String?,
        aircraftName: String?,
        nearestAirportICAO: String?,
        altitudeAGLFeet: Double?,
        altitudeMSLFeet: Double?,
        isOnGround: Bool?
    ) {
        self.simulatorVersion = simulatorVersion
        self.aircraftIdentifier = Self.nonEmpty(aircraftIdentifier)
        self.aircraftName = Self.nonEmpty(aircraftName)
        self.nearestAirportICAO = Self.normalizedICAO(nearestAirportICAO)
        self.altitudeAGLFeet = Self.validAltitude(altitudeAGLFeet, minimum: -200, maximum: 50_000)
        self.altitudeMSLFeet = Self.validAltitude(altitudeMSLFeet, minimum: -1_500, maximum: 80_000)
        self.isOnGround = isOnGround
    }

    public static func normalized(
        simulatorVersionRaw: String?,
        aircraftIdentifier: String?,
        aircraftName: String?,
        nearestAirportICAO: String?,
        altitudeAGLFeet: Double?,
        altitudeMSLFeet: Double?,
        isOnGround: Bool?
    ) -> FlightContext {
        FlightContext(
            simulatorVersion: simulatorVersion(from: simulatorVersionRaw),
            aircraftIdentifier: aircraftIdentifier,
            aircraftName: aircraftName,
            nearestAirportICAO: nearestAirportICAO,
            altitudeAGLFeet: altitudeAGLFeet,
            altitudeMSLFeet: altitudeMSLFeet,
            isOnGround: isOnGround
        )
    }

    public var aircraftDisplayName: String {
        aircraftName ?? aircraftIdentifier ?? "Not available yet"
    }

    public var phaseOfFlightDetail: String {
        var values: [String] = []
        if let altitudeAGLFeet {
            values.append(String(format: "%.0f ft AGL", altitudeAGLFeet))
        }
        if let isOnGround {
            values.append(isOnGround ? "On ground" : "Airborne")
        }
        return values.isEmpty ? "Not available yet" : values.joined(separator: " · ")
    }

    private static func simulatorVersion(from raw: String?) -> SimulatorVersion {
        let value = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? ""

        if value == "11" || value.hasPrefix("XP11") || value.hasPrefix("X-PLANE 11") {
            return .xp11
        }
        if value == "12" || value.hasPrefix("XP12") || value.hasPrefix("X-PLANE 12") {
            return .xp12
        }
        return .unknown
    }

    private static func normalizedICAO(_ raw: String?) -> String? {
        guard let value = nonEmpty(raw)?.uppercased(),
              (3...4).contains(value.count),
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
              value != "N/A",
              value != "UNKNOWN" else {
            return nil
        }
        return value
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func validAltitude(_ value: Double?, minimum: Double, maximum: Double) -> Double? {
        guard let value, value.isFinite, (minimum...maximum).contains(value) else {
            return nil
        }
        return value
    }
}
