import SwiftUI

struct GlassCardModifier: ViewModifier {
    let variant: GlassSurface.Variant
    let padding: CGFloat
    let cornerRadius: CGFloat
    let hoverEnabled: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("useGlassEffects") private var useGlassEffects: Bool = true
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                GlassSurface(
                    variant: variant,
                    cornerRadius: cornerRadius,
                    isHovering: hoverEnabled ? isHovering : false,
                    reduceTransparency: reduceTransparency,
                    useGlassEffects: useGlassEffects
                )
            )
            .onHover { hovering in
                guard hoverEnabled else { return }
                isHovering = hovering
            }
    }
}


struct HoverOpacityModifier: ViewModifier {
    let hoverOpacity: Double
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .opacity(hovering ? hoverOpacity : 1.0)
            .onHover { hovering = $0 }
    }
}

extension View {
    func glassCard() -> some View {
        modifier(GlassCardModifier(variant: .card, padding: 16, cornerRadius: 18, hoverEnabled: false))
    }

    func glassPanel() -> some View {
        modifier(GlassCardModifier(variant: .card, padding: 12, cornerRadius: 16, hoverEnabled: false))
    }

    func glassPill(hoverEnabled: Bool = false) -> some View {
        modifier(GlassCardModifier(variant: .pill, padding: 8, cornerRadius: 999, hoverEnabled: hoverEnabled))
    }

    func glassSidebar() -> some View {
        modifier(GlassCardModifier(variant: .sidebar, padding: 12, cornerRadius: 18, hoverEnabled: false))
    }

    func glassHover(opacity: Double = 0.97) -> some View {
        modifier(HoverOpacityModifier(hoverOpacity: opacity))
    }
}
