import SwiftUI
import AppKit

struct GlassSurface: View {
    enum Variant {
        case windowBackdrop
        case sidebar
        case card
        case pill
    }

    let variant: Variant
    var cornerRadius: CGFloat = 16
    var isHovering: Bool = false
    var reduceTransparency: Bool
    var useGlassEffects: Bool

    private struct Style {
        let material: NSVisualEffectView.Material
        let borderOpacity: Double
        let highlightOpacity: Double
        let shadowOpacity: Double
        let shadowRadius: CGFloat
    }

    private var style: Style {
        switch variant {
        case .windowBackdrop:
            return Style(
                material: .underWindowBackground,
                borderOpacity: 0,
                highlightOpacity: 0.06,
                shadowOpacity: 0,
                shadowRadius: 0
            )
        case .sidebar:
            return Style(
                material: .sidebar,
                borderOpacity: 0.14,
                highlightOpacity: 0.08,
                shadowOpacity: 0.12,
                shadowRadius: 10
            )
        case .card:
            return Style(
                material: .hudWindow,
                borderOpacity: 0.16,
                highlightOpacity: 0.12,
                shadowOpacity: 0.22,
                shadowRadius: 16
            )
        case .pill:
            return Style(
                material: .menu,
                borderOpacity: 0.18,
                highlightOpacity: 0.10,
                shadowOpacity: 0.18,
                shadowRadius: 8
            )
        }
    }

    var body: some View {
        let activeHighlight = style.highlightOpacity + (isHovering ? 0.05 : 0)
        ZStack {
            if reduceTransparency || !useGlassEffects {
                Color.black.opacity(0.85)
            } else {
                VisualEffectView(material: style.material)
            }

            LinearGradient(
                colors: [
                    Color.white.opacity(activeHighlight),
                    Color.white.opacity(0.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(style.borderOpacity + (isHovering ? 0.08 : 0)), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(style.shadowOpacity), radius: style.shadowRadius, x: 0, y: 6)
    }
}
