import SwiftUI

/// The window's controls, drawn to match the pill (WidgetView): monochrome, bold SF Symbols in
/// round tiles, a soft fill on hover, a small press. Everything clickable reacts to the pointer.

/// A bold symbol in a round tile, the same glyphs and weight the pill uses.
struct Glyph: View {
    let symbol: String
    var size: CGFloat = 26
    var strong = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(strong ? Color(nsColor: .windowBackgroundColor) : .primary)
            .frame(width: size, height: size)
            .background(Circle().fill(strong ? Color.primary : Color.primary.opacity(0.08)))
    }
}

/// Round icon button, like the pill's buttons.
struct HoverIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(Press())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Ink-filled button with the window colour as text, so it inverts correctly in dark mode.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(!enabled ? 0.35 : hovering ? 0.78 : 0.92)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Quiet text button: no fill until you point at it.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

struct Press: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Black and white switch: ink track when on, so nothing in the window is blue.
struct MonoSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            HStack(spacing: 10) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Color.primary.opacity(0.9) : Color.primary.opacity(hovering ? 0.2 : 0.14))
                    .frame(width: 34, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? Color(nsColor: .windowBackgroundColor) : .white)
                            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                            .padding(2.5)
                    }
                    .opacity(enabled ? 1 : 0.4)
                    .contentShape(Capsule())
                    .onTapGesture { if enabled { configuration.isOn.toggle() } }
                    .onHover { hovering = $0 }
                    .animation(.spring(response: 0.22, dampingFraction: 0.85), value: configuration.isOn)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(configuration.isOn ? "On" : "Off")
            }
        }
    }
}

/// Segmented choice drawn like the pill's Hold / Toggle / Both switch, with a sliding selection.
struct MonoSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var ns
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? .primary : .secondary)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background {
                            if on {
                                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                    .matchedGeometryEffect(id: "sel", in: ns)
                            } else if hovered == value {
                                Capsule().fill(Color.primary.opacity(0.06))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(Press())
                .onHover { hovered = $0 ? value : (hovered == value ? nil : hovered) }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: selection)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .fixedSize()
    }
}

extension View {
    /// Soft rounded highlight under a clickable row while the pointer is on it.
    func hoverHighlight(cornerRadius: CGFloat = 8) -> some View { modifier(HoverHighlight(cornerRadius: cornerRadius)) }
}

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
