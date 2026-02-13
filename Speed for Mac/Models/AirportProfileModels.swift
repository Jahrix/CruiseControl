import Foundation

struct AirportGovernorProfile: Identifiable, Codable, Hashable {
    let id: UUID
    var icao: String
    var name: String
    var groundMaxAGLFeet: Double
    var cruiseMinAGLFeet: Double
    var targetLODGround: Double
    var targetLODTransition: Double
    var targetLODCruise: Double
    var clampMinLOD: Double
    var clampMaxLOD: Double

    init(
        id: UUID = UUID(),
        icao: String,
        name: String,
        groundMaxAGLFeet: Double,
        cruiseMinAGLFeet: Double,
        targetLODGround: Double,
        targetLODTransition: Double,
        targetLODCruise: Double,
        clampMinLOD: Double,
        clampMaxLOD: Double
    ) {
        self.id = id
        self.icao = AirportGovernorProfile.normalizeICAO(icao)
        self.name = name
        self.groundMaxAGLFeet = groundMaxAGLFeet
        self.cruiseMinAGLFeet = cruiseMinAGLFeet
        self.targetLODGround = targetLODGround
        self.targetLODTransition = targetLODTransition
        self.targetLODCruise = targetLODCruise
        self.clampMinLOD = clampMinLOD
        self.clampMaxLOD = clampMaxLOD
    }

    static func normalizeICAO(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
    }

    static let examples: [AirportGovernorProfile] = [
        AirportGovernorProfile(
            icao: "KATL",
            name: "Heavy hub",
            groundMaxAGLFeet: 2_000,
            cruiseMinAGLFeet: 11_000,
            targetLODGround: 1.55,
            targetLODTransition: 1.20,
            targetLODCruise: 0.95,
            clampMinLOD: 0.30,
            clampMaxLOD: 2.60
        ),
        AirportGovernorProfile(
            icao: "KDEN",
            name: "Medium",
            groundMaxAGLFeet: 1_600,
            cruiseMinAGLFeet: 10_000,
            targetLODGround: 1.35,
            targetLODTransition: 1.10,
            targetLODCruise: 0.90,
            clampMinLOD: 0.25,
            clampMaxLOD: 2.40
        ),
        AirportGovernorProfile(
            icao: "KOSH",
            name: "GA field",
            groundMaxAGLFeet: 1_200,
            cruiseMinAGLFeet: 8_000,
            targetLODGround: 1.20,
            targetLODTransition: 1.00,
            targetLODCruise: 0.85,
            clampMinLOD: 0.20,
            clampMaxLOD: 2.20
        )
    ]
}
