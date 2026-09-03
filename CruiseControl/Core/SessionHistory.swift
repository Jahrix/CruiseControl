import Foundation

/// A compact, durable record of one completed telemetry session. It contains
/// aggregates only; raw telemetry remains in memory and is never written here.
public struct FlightSessionRecord: Codable, Equatable, Identifiable, Sendable {
    public struct StabilitySummary: Codable, Equatable, Sendable {
        public let sampleCount: Int
        public let averageFrameTimeMilliseconds: Double?
        public let lowestFPS: Double?
        public let spikeCount: Int

        public init(
            sampleCount: Int,
            averageFrameTimeMilliseconds: Double?,
            lowestFPS: Double?,
            spikeCount: Int
        ) {
            self.sampleCount = max(sampleCount, 0)
            self.averageFrameTimeMilliseconds = averageFrameTimeMilliseconds?.isFinite == true
                ? averageFrameTimeMilliseconds
                : nil
            self.lowestFPS = lowestFPS?.isFinite == true ? lowestFPS : nil
            self.spikeCount = max(spikeCount, 0)
        }

        public var spikeFraction: Double? {
            guard sampleCount > 0 else { return nil }
            return Double(spikeCount) / Double(sampleCount)
        }
    }

    public struct ActionSummary: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let kind: String
        public let succeeded: Bool
        public let message: String

        public init(id: UUID = UUID(), timestamp: Date, kind: String, succeeded: Bool, message: String) {
            self.id = id
            self.timestamp = timestamp
            self.kind = kind
            self.succeeded = succeeded
            self.message = message
        }
    }

    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let flightContext: FlightContext
    public let averageFPS: Double?
    public let stability: StabilitySummary
    public let stutterCount: Int
    public let actions: [ActionSummary]

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        flightContext: FlightContext,
        averageFPS: Double?,
        stability: StabilitySummary,
        stutterCount: Int,
        actions: [ActionSummary]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = max(endedAt, startedAt)
        self.flightContext = flightContext
        self.averageFPS = averageFPS?.isFinite == true ? averageFPS : nil
        self.stability = stability
        self.stutterCount = max(stutterCount, 0)
        self.actions = Array(actions.sorted { $0.timestamp < $1.timestamp }.suffix(12))
    }

    public var durationSeconds: TimeInterval {
        max(endedAt.timeIntervalSince(startedAt), 0)
    }
}

public struct SessionHistoryDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let records: [FlightSessionRecord]

    public init(schemaVersion: Int = Self.currentSchemaVersion, records: [FlightSessionRecord]) {
        self.schemaVersion = schemaVersion
        self.records = records.sorted { $0.endedAt > $1.endedAt }
    }
}

public enum SessionHistoryPersistence {
    public enum Error: Swift.Error, Equatable {
        case unsupportedSchema(Int)
        case unreadable
    }

    public static func decode(_ data: Data) throws -> SessionHistoryDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let document = try? decoder.decode(SessionHistoryDocument.self, from: data) {
            guard document.schemaVersion <= SessionHistoryDocument.currentSchemaVersion else {
                throw Error.unsupportedSchema(document.schemaVersion)
            }
            return SessionHistoryDocument(records: document.records)
        }

        // Schema 0 stored a bare records array. Keep the migration local and
        // deterministic so an early build does not strand user history.
        if let legacyRecords = try? decoder.decode([FlightSessionRecord].self, from: data) {
            return SessionHistoryDocument(records: legacyRecords)
        }

        throw Error.unreadable
    }

    public static func encode(_ document: SessionHistoryDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }
}
