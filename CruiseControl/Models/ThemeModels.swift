import SwiftUI

struct CruiseTheme: Identifiable {
    let id: String
    let name: String
    let accent: Color
    let accentSoft: Color
    let backgroundTop: Color
    let backgroundBottom: Color
    let cardFill: Color
    let cardStroke: Color
    let textPrimary: Color
    let textSecondary: Color

    static let all: [CruiseTheme] = [
        CruiseTheme(id: "cobalt", name: "Cobalt", accent: Color(red: 0.38, green: 0.66, blue: 1.00), accentSoft: Color(red: 0.52, green: 0.80, blue: 1.00), backgroundTop: Color(red: 0.02, green: 0.05, blue: 0.11), backgroundBottom: Color(red: 0.01, green: 0.03, blue: 0.08), cardFill: Color(red: 0.05, green: 0.09, blue: 0.17), cardStroke: Color.white.opacity(0.10), textPrimary: .white, textSecondary: Color.white.opacity(0.68)),
        CruiseTheme(id: "emerald", name: "Emerald", accent: Color(red: 0.28, green: 0.88, blue: 0.66), accentSoft: Color(red: 0.53, green: 0.95, blue: 0.78), backgroundTop: Color(red: 0.02, green: 0.07, blue: 0.08), backgroundBottom: Color(red: 0.01, green: 0.04, blue: 0.05), cardFill: Color(red: 0.04, green: 0.10, blue: 0.12), cardStroke: Color.white.opacity(0.10), textPrimary: .white, textSecondary: Color.white.opacity(0.67)),
        CruiseTheme(id: "amethyst", name: "Amethyst", accent: Color(red: 0.72, green: 0.58, blue: 1.00), accentSoft: Color(red: 0.84, green: 0.74, blue: 1.00), backgroundTop: Color(red: 0.05, green: 0.04, blue: 0.11), backgroundBottom: Color(red: 0.02, green: 0.02, blue: 0.08), cardFill: Color(red: 0.08, green: 0.07, blue: 0.16), cardStroke: Color.white.opacity(0.10), textPrimary: .white, textSecondary: Color.white.opacity(0.68)),
        CruiseTheme(id: "sapphire", name: "Sapphire", accent: Color(red: 0.32, green: 0.54, blue: 0.96), accentSoft: Color(red: 0.56, green: 0.72, blue: 1.00), backgroundTop: Color(red: 0.02, green: 0.04, blue: 0.12), backgroundBottom: Color(red: 0.01, green: 0.03, blue: 0.07), cardFill: Color(red: 0.05, green: 0.08, blue: 0.17), cardStroke: Color.white.opacity(0.10), textPrimary: .white, textSecondary: Color.white.opacity(0.68)),
        CruiseTheme(id: "ruby", name: "Ruby", accent: Color(red: 0.95, green: 0.34, blue: 0.48), accentSoft: Color(red: 1.00, green: 0.57, blue: 0.67), backgroundTop: Color(red: 0.10, green: 0.03, blue: 0.07), backgroundBottom: Color(red: 0.05, green: 0.02, blue: 0.05), cardFill: Color(red: 0.14, green: 0.05, blue: 0.10), cardStroke: Color.white.opacity(0.09), textPrimary: .white, textSecondary: Color.white.opacity(0.68)),
        CruiseTheme(id: "onyx", name: "Onyx", accent: Color(red: 0.74, green: 0.78, blue: 0.88), accentSoft: Color(red: 0.88, green: 0.90, blue: 0.96), backgroundTop: Color(red: 0.03, green: 0.04, blue: 0.06), backgroundBottom: Color(red: 0.01, green: 0.02, blue: 0.03), cardFill: Color(red: 0.07, green: 0.08, blue: 0.10), cardStroke: Color.white.opacity(0.09), textPrimary: .white, textSecondary: Color.white.opacity(0.65)),
        CruiseTheme(id: "gold", name: "Gold", accent: Color(red: 0.96, green: 0.79, blue: 0.34), accentSoft: Color(red: 1.00, green: 0.87, blue: 0.55), backgroundTop: Color(red: 0.09, green: 0.07, blue: 0.03), backgroundBottom: Color(red: 0.05, green: 0.04, blue: 0.02), cardFill: Color(red: 0.13, green: 0.10, blue: 0.05), cardStroke: Color.white.opacity(0.09), textPrimary: .white, textSecondary: Color.white.opacity(0.66)),
        CruiseTheme(id: "azure", name: "Azure", accent: Color(red: 0.28, green: 0.77, blue: 0.95), accentSoft: Color(red: 0.49, green: 0.86, blue: 1.00), backgroundTop: Color(red: 0.02, green: 0.07, blue: 0.11), backgroundBottom: Color(red: 0.01, green: 0.04, blue: 0.07), cardFill: Color(red: 0.04, green: 0.10, blue: 0.15), cardStroke: Color.white.opacity(0.10), textPrimary: .white, textSecondary: Color.white.opacity(0.68)),
        CruiseTheme(id: "violet", name: "Violet", accent: Color(red: 0.62, green: 0.48, blue: 0.98), accentSoft: Color(red: 0.79, green: 0.68, blue: 1.00), backgroundTop: Color(red: 0.05, green: 0.04, blue: 0.12), backgroundBottom: Color(red: 0.02, green: 0.02, blue: 0.08), cardFill: Color(red: 0.08, green: 0.07, blue: 0.18), cardStroke: Color.white.opacity(0.10), textPrimary: .white, textSecondary: Color.white.opacity(0.68)),
        CruiseTheme(id: "teal", name: "Teal", accent: Color(red: 0.22, green: 0.80, blue: 0.78), accentSoft: Color(red: 0.47, green: 0.91, blue: 0.88), backgroundTop: Color(red: 0.02, green: 0.08, blue: 0.10), backgroundBottom: Color(red: 0.01, green: 0.04, blue: 0.06), cardFill: Color(red: 0.04, green: 0.11, blue: 0.13), cardStroke: Color.white.opacity(0.10), textPrimary: .white, textSecondary: Color.white.opacity(0.67)),
        CruiseTheme(id: "crimson", name: "Crimson", accent: Color(red: 0.88, green: 0.30, blue: 0.38), accentSoft: Color(red: 0.96, green: 0.50, blue: 0.58), backgroundTop: Color(red: 0.09, green: 0.03, blue: 0.05), backgroundBottom: Color(red: 0.05, green: 0.02, blue: 0.04), cardFill: Color(red: 0.13, green: 0.05, blue: 0.08), cardStroke: Color.white.opacity(0.09), textPrimary: .white, textSecondary: Color.white.opacity(0.68)),
        CruiseTheme(id: "indigo", name: "Indigo", accent: Color(red: 0.43, green: 0.48, blue: 0.98), accentSoft: Color(red: 0.61, green: 0.67, blue: 1.00), backgroundTop: Color(red: 0.03, green: 0.04, blue: 0.12), backgroundBottom: Color(red: 0.01, green: 0.02, blue: 0.08), cardFill: Color(red: 0.06, green: 0.08, blue: 0.18), cardStroke: Color.white.opacity(0.10), textPrimary: .white, textSecondary: Color.white.opacity(0.68)),
        CruiseTheme(id: "obsidian", name: "Obsidian", accent: Color(red: 0.78, green: 0.82, blue: 0.92), accentSoft: Color(red: 0.90, green: 0.92, blue: 0.98), backgroundTop: Color(red: 0.02, green: 0.03, blue: 0.05), backgroundBottom: Color(red: 0.01, green: 0.01, blue: 0.02), cardFill: Color(red: 0.06, green: 0.07, blue: 0.09), cardStroke: Color.white.opacity(0.08), textPrimary: .white, textSecondary: Color.white.opacity(0.64)),
        CruiseTheme(id: "pearl", name: "Pearl", accent: Color(red: 0.73, green: 0.78, blue: 0.86), accentSoft: Color(red: 0.88, green: 0.90, blue: 0.96), backgroundTop: Color(red: 0.10, green: 0.12, blue: 0.16), backgroundBottom: Color(red: 0.06, green: 0.07, blue: 0.11), cardFill: Color(red: 0.15, green: 0.17, blue: 0.22), cardStroke: Color.white.opacity(0.08), textPrimary: .white, textSecondary: Color.white.opacity(0.66)),
        CruiseTheme(id: "royal-mint", name: "Royal Mint", accent: Color(red: 0.44, green: 0.93, blue: 0.78), accentSoft: Color(red: 0.63, green: 0.97, blue: 0.86), backgroundTop: Color(red: 0.02, green: 0.08, blue: 0.09), backgroundBottom: Color(red: 0.01, green: 0.04, blue: 0.05), cardFill: Color(red: 0.04, green: 0.12, blue: 0.13), cardStroke: Color.white.opacity(0.10), textPrimary: .white, textSecondary: Color.white.opacity(0.67)),
        CruiseTheme(id: "midnight", name: "Midnight", accent: Color(red: 0.34, green: 0.60, blue: 0.92), accentSoft: Color(red: 0.48, green: 0.73, blue: 1.00), backgroundTop: Color(red: 0.01, green: 0.03, blue: 0.08), backgroundBottom: Color(red: 0.00, green: 0.01, blue: 0.04), cardFill: Color(red: 0.04, green: 0.07, blue: 0.13), cardStroke: Color.white.opacity(0.10), textPrimary: .white, textSecondary: Color.white.opacity(0.67))
    ]
}

enum ThemeManager {
    static let defaultThemeID = "cobalt"

    static func theme(id: String) -> CruiseTheme {
        CruiseTheme.all.first(where: { $0.id == id }) ?? CruiseTheme.all[0]
    }
}
