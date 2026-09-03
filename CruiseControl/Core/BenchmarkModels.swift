import Foundation

public struct BenchmarkRun: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let flightContext: FlightContext
    public let settingsSnapshot: [String: String]
    public let sampleCount: Int
    public let averageFPS: Double
    public let lowestFPS: Double
    public let medianFrameTimeMilliseconds: Double
    public let p95FrameTimeMilliseconds: Double?
    public let spikeFraction: Double
    public let stutterCount: Int

    public init(
        startedAt: Date,
        endedAt: Date,
        flightContext: FlightContext,
        settingsSnapshot: [String: String],
        sampleCount: Int,
        averageFPS: Double,
        lowestFPS: Double,
        medianFrameTimeMilliseconds: Double,
        p95FrameTimeMilliseconds: Double?,
        spikeFraction: Double,
        stutterCount: Int
    ) {
        self.startedAt = startedAt
        self.endedAt = max(endedAt, startedAt)
        self.flightContext = flightContext
        self.settingsSnapshot = settingsSnapshot
        self.sampleCount = max(sampleCount, 0)
        self.averageFPS = averageFPS
        self.lowestFPS = lowestFPS
        self.medianFrameTimeMilliseconds = medianFrameTimeMilliseconds
        self.p95FrameTimeMilliseconds = p95FrameTimeMilliseconds
        self.spikeFraction = spikeFraction
        self.stutterCount = max(stutterCount, 0)
    }

    public var durationSeconds: TimeInterval { max(endedAt.timeIntervalSince(startedAt), 0) }
}

public struct BenchmarkPair: Codable, Equatable, Identifiable, Sendable {
    public enum Compatibility: Equatable, Sendable {
        case comparable
        case questionable([String])

        public var summary: String {
            switch self {
            case .comparable:
                return "Contexts match closely enough for a useful comparison."
            case .questionable(let reasons):
                return reasons.joined(separator: " ")
            }
        }
    }

    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let baseline: BenchmarkRun
    public let comparison: BenchmarkRun

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), baseline: BenchmarkRun, comparison: BenchmarkRun) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Benchmark" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.baseline = baseline
        self.comparison = comparison
    }

    public var compatibility: Compatibility { Self.compatibility(baseline: baseline.flightContext, comparison: comparison.flightContext) }
    public var averageFPSDelta: Double { comparison.averageFPS - baseline.averageFPS }
    public var medianFrameTimeDelta: Double { comparison.medianFrameTimeMilliseconds - baseline.medianFrameTimeMilliseconds }
    public var stutterDelta: Int { comparison.stutterCount - baseline.stutterCount }

    public static func compatibility(baseline: FlightContext, comparison: FlightContext) -> Compatibility {
        var reasons: [String] = []
        if baseline.simulatorVersion != .unknown,
           comparison.simulatorVersion != .unknown,
           baseline.simulatorVersion != comparison.simulatorVersion {
            reasons.append("X-Plane versions differ.")
        }
        if let baselineAircraft = baseline.aircraftIdentifier,
           let comparisonAircraft = comparison.aircraftIdentifier,
           baselineAircraft != comparisonAircraft {
            reasons.append("Aircraft identifiers differ.")
        }
        if let baselineAirport = baseline.nearestAirportICAO,
           let comparisonAirport = comparison.nearestAirportICAO,
           baselineAirport != comparisonAirport {
            reasons.append("Airport ICAO codes differ.")
        }
        return reasons.isEmpty ? .comparable : .questionable(reasons)
    }
}

public struct BenchmarkHistoryDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let pairs: [BenchmarkPair]

    public init(schemaVersion: Int = Self.currentSchemaVersion, pairs: [BenchmarkPair]) {
        self.schemaVersion = schemaVersion
        self.pairs = pairs.sorted { $0.createdAt > $1.createdAt }
    }
}

public enum BenchmarkHistoryPersistence {
    public enum Error: Swift.Error, Equatable { case unsupportedSchema(Int), unreadable }

    public static func encode(_ document: BenchmarkHistoryDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> BenchmarkHistoryDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(BenchmarkHistoryDocument.self, from: data) else {
            throw Error.unreadable
        }
        guard document.schemaVersion <= BenchmarkHistoryDocument.currentSchemaVersion else {
            throw Error.unsupportedSchema(document.schemaVersion)
        }
        return BenchmarkHistoryDocument(pairs: document.pairs)
    }
}
