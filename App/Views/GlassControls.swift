import SwiftUI

/// Keep navigation and input controls on the system's glass layer, with native
/// bordered controls on older systems. Message content keeps its own surface.
extension View {
    @ViewBuilder
    func chatGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
    }

    @ViewBuilder
    func chatGlassSurface(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5))
        }
    }
}

struct ChatGlassGroup<Content: View>: View {
    var spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
