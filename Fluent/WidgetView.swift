import SwiftUI

/// What the widget shows (design/widget.html). Recording is waveform and timer only; the
/// controls appear when you hover.
@MainActor
@Observable
final class WidgetModel {
    enum Mode: Equatable {
        case idle
        case recording(started: Date)
        case transcribing
        case done(app: String)
        case message(String)
        /// No text box when you stopped: the text waits here.
        case holding(String)
        /// You clicked into a text box: one key or click drops it in.
        case dropPrompt(app: String)
    }
    struct Actions {
        var start: () -> Void = {}
        var stop: () -> Void = {}
        var cancel: () -> Void = {}
        var setMode: (DictationController.Mode) -> Void = { _ in }
        var drop: () -> Void = {}
        var undo: () -> Void = {}
        var copyHeld: () -> Void = {}
        var pasteHeld: () -> Void = {}
        var discardHeld: () -> Void = {}
        var toggleCleanup: () -> Void = {}
        var toggleLanguage: () -> Void = {}
    }

    var mode: Mode = .idle
    var hovered = false
    var latched = false
    var recordingMode: DictationController.Mode = .both
    var language: DictationController.Language = .english
    var cleanupOn = true
    /// While hands-free, the app the text will go to if you stop now (shown only when you've moved).
    var dropTarget: String?
    /// What the button under the pointer does, shown above the pill. The panel never becomes the
    /// active window, so macOS's own tooltips don't appear on it.
    var hint: String?
    @ObservationIgnored var actions = Actions()
    /// Reads the live microphone level, 0...1.
    @ObservationIgnored var levelSource: () -> Float = { 0 }

    /// Called when the pill's size should change, so the panel can re-anchor.
    @ObservationIgnored var onLayoutChange: () -> Void = {}
}

struct WidgetView: View {
    static let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let model: WidgetModel
    @State private var wave = CombWave()

    var body: some View {
        VStack(spacing: 6) {
            if let hint = model.hint {
                Text(hint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color(white: 0.05).opacity(0.92))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 0.5)))
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
            content
        }
        .environment(\.pillHint, { model.hint = $0 })
        .animation(Self.reduceMotion ? nil : .easeOut(duration: 0.14), value: model.hint)
        .onChange(of: model.hint) { model.onLayoutChange() }
        .onChange(of: model.mode) { model.hint = nil }
        .onChange(of: model.hovered) { if !model.hovered { model.hint = nil } }
    }

    private var content: some View {
        Group {
            switch model.mode {
            case .idle:
                if model.hovered { expandedIdle } else { restingPill }
            case .recording(let started):
                recording(started).onAppear { wave.style = .current }
            case .transcribing:
                TimelineView(.animation) { context in
                    Canvas { ctx, size in CombWave.drawBusy(in: ctx, size: size, now: context.date) }
                        .frame(width: 132, height: 24)
                }
                .pill()
            case .done(let app):
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                    Text(app).lineLimit(1)
                    PillButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z in \(app))") { model.actions.undo() }
                }
                .pill(horizontal: 16, trailing: 6)
            case .message(let text):
                Text(text).lineLimit(1).pill()
            case .holding(let text):
                VStack(alignment: .leading, spacing: 0) {
                    Text(text).lineLimit(3).frame(width: 300, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
                    Divider().overlay(.white.opacity(0.08))
                    HStack(spacing: 6) {
                        Text("Click a text box").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        PillButton(symbol: "arrow.down.doc", help: "Paste anyway, where you are now (on the desktop it makes a text file)") { model.actions.pasteHeld() }
                        PillButton(symbol: "doc.on.doc", help: "Copy") { model.actions.copyHeld() }
                        PillButton(symbol: "trash", help: "Discard (Esc)") { model.actions.discardHeld() }
                    }
                    .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 7)
                }
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.05).opacity(0.94))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.09), lineWidth: 0.5)))
            case .dropPrompt(let app):
                HStack(spacing: 10) {
                    Text("Drop into \(app)").lineLimit(1)
                    Button { model.actions.drop() } label: {
                        HStack(spacing: 5) {
                            Text("Drop").font(.system(size: 12, weight: .semibold))
                            Image(systemName: "return").font(.system(size: 10, weight: .bold)).opacity(0.6)
                        }
                        .foregroundStyle(.black).padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(0.92)))
                    }
                    .buttonStyle(.plain).modifier(HintOnHover(text: "Drop the text here (Return)"))
                    PillButton(symbol: "xmark", help: "Discard (Esc)") { model.actions.discardHeld() }
                }
                .pill(horizontal: 16, trailing: 6)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.white.opacity(0.92))
        .fixedSize()
        .animation(Self.reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.88), value: model.hovered)
        .animation(Self.reduceMotion ? nil : .easeOut(duration: 0.18), value: model.latched)
        .onChange(of: model.hovered) { model.onLayoutChange() }
        .onChange(of: model.mode) { model.onLayoutChange() }
        .onChange(of: model.latched) { model.onLayoutChange() }
        .onChange(of: model.dropTarget) { model.onLayoutChange() }
    }

    /// At rest: a small dark pill with a few idle comb lines, easy to find, easy to ignore.
    private var restingPill: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<7, id: \.self) { i in
                Capsule().fill(.white.opacity(0.45))
                    .frame(width: 1.2, height: [3, 5, 7, 9, 7, 5, 3][i])
            }
        }
        .frame(width: 54, height: 16)
        .background(Capsule().fill(Color(white: 0.05).opacity(0.85))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)))
        .help("Fluent: hover for options")
    }

    /// Hovered at rest: start button, mode switch, language.
    private var expandedIdle: some View {
        HStack(spacing: 10) {
            PillButton(symbol: "mic.fill", help: "Start dictating (hands-free)", prominent: true) { model.actions.start() }
            HStack(spacing: 2) {
                ForEach(DictationController.Mode.allCases) { m in
                    Button { model.actions.setMode(m) } label: {
                        Text(m.label)
                            .font(.system(size: 12, weight: model.recordingMode == m ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(model.recordingMode == m ? 0.95 : 0.55))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(model.recordingMode == m ? 0.16 : 0)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .modifier(HintOnHover(text: m.help))
                }
            }
            .padding(2)
            .background(Capsule().fill(.white.opacity(0.06)))
            Button { model.actions.toggleLanguage() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.system(size: 11))
                    Text(model.language.short).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.06)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .modifier(HintOnHover(text: model.language.help + ". Click to switch."))
            PillButton(symbol: "wand.and.stars", help: model.cleanupOn ? "Clean up is on: removes ums, fixes numbers. Click to turn off."
                                                                         : "Clean up is off: types exactly what you say. Click to turn on.",
                       dimmed: !model.cleanupOn) { model.actions.toggleCleanup() }
        }
        .pill(horizontal: 6)
    }

    private func recording(_ started: Date) -> some View {
        HStack(spacing: 12) {
            TimelineView(.animation) { context in
                HStack(spacing: 12) {
                    Canvas { ctx, size in
                        wave.step(level: model.levelSource(), now: context.date)
                        wave.draw(in: ctx, size: size)
                    }
                    .frame(width: 132, height: 24)
                    Text(elapsed(since: started, now: context.date))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.55))
                    if let target = model.dropTarget {
                        Label(target, systemImage: "arrow.right").labelStyle(.titleAndIcon)
                            .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.7)).lineLimit(1)
                            .modifier(HintOnHover(text: "If you stop now, the text goes to \(target)"))
                    }
                }
            }
            // Hands-free shows a stop button; hovering also offers cancel.
            if model.latched || model.hovered {
                if model.hovered {
                    Group {
                    PillButton(symbol: model.cleanupOn ? "wand.and.stars" : "wand.and.stars.inverse",
                               help: model.cleanupOn ? "Clean up is on: removes ums, fixes numbers. Click to turn off."
                                                     : "Clean up is off: types exactly what you say. Click to turn on.",
                               dimmed: !model.cleanupOn) { model.actions.toggleCleanup() }
                    PillButton(symbol: "xmark", help: "Cancel (Esc)") { model.actions.cancel() }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
                PillButton(symbol: "stop.fill", help: "Stop and type it in", prominent: model.latched) { model.actions.stop() }
            }
        }
        .pill(trailing: model.latched || model.hovered ? 6 : 16)
    }

    private func elapsed(since start: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

private struct PillButton: View {
    let symbol: String
    let help: String
    var prominent = false
    var dimmed = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.pillHint) private var setHint

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(prominent ? Color.black : .white)
                .frame(width: 26, height: 26)
                .opacity(dimmed ? 0.45 : 1)
                .background(Circle().fill(prominent ? .white.opacity(hovering ? 1 : 0.88) : .white.opacity(hovering ? 0.22 : 0.12)))
                .scaleEffect(hovering && !WidgetView.reduceMotion ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0; setHint($0 ? help : nil) }
        .onDisappear { if hovering { setHint(nil) } }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(help)
    }
}

private struct PillHintKey: EnvironmentKey {
    static let defaultValue: @MainActor (String?) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Lets a control inside the pill show what it does above the pill.
    var pillHint: @MainActor (String?) -> Void {
        get { self[PillHintKey.self] }
        set { self[PillHintKey.self] = newValue }
    }
}

/// Shows `text` above the pill while the pointer is on this view.
private struct HintOnHover: ViewModifier {
    let text: String
    @Environment(\.pillHint) private var setHint
    func body(content: Content) -> some View {
        content.onHover { setHint($0 ? text : nil) }
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    /// The black glass capsule every state sits in.
    func pill(horizontal: CGFloat = 16, trailing: CGFloat? = nil) -> some View {
        padding(.leading, horizontal).padding(.trailing, trailing ?? horizontal)
            .frame(height: 40)
            .background(Capsule().fill(Color(white: 0.05).opacity(0.92))
                .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 0.5)))
    }
}

/// The Comb waveform: a soft ribbon glow with hairline vertical lines carrying its shape.
/// Same maths as design/waveform.html: summed tapered sines, fast rise and slow fall.
final class CombWave {
    private struct Ribbon { let c, w, f, sp, a, alpha, twist: Double }
    private let ribbons = [
        Ribbon(c: -0.38, w: 0.30, f: 2.3, sp: 1.00, a: 1.00, alpha: 0.22, twist: 0.9),
        Ribbon(c: 0.06, w: 0.40, f: 3.2, sp: 1.35, a: 0.85, alpha: 0.19, twist: 1.3),
        Ribbon(c: 0.42, w: 0.28, f: 4.1, sp: 1.70, a: 0.75, alpha: 0.17, twist: 0.7),
        Ribbon(c: -0.08, w: 0.55, f: 1.7, sp: 0.75, a: 0.60, alpha: 0.14, twist: 1.6),
    ]
    private var level = 0.0
    private var phase = 0.0
    /// Recent loudness peak, so the wave scales to your mic and voice rather than a fixed level.
    private var peak = 0.3
    private var last: Date?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    func step(level target: Float, now: Date) {
        let dt = min(0.05, last.map { now.timeIntervalSince($0) } ?? 0)
        last = now
        let incoming = Double(target)
        peak = max(incoming, peak * exp(-dt / 2.5), 0.25)   // decays over a few seconds, never below a floor
        let t = min(1, pow(incoming / peak, 0.8))
        let k = t > level ? 1 - exp(-dt / 0.035) : 1 - exp(-dt / 0.22)
        level += (t - level) * k
        phase += dt * (reduceMotion ? 0.6 : 1.4 + level * 7)
    }

    private static func taper(_ x: Double) -> Double { pow(max(0, 1 - x * x), 2.2) }

    private func y(_ r: Ribbon, _ x: Double, _ extra: Double) -> Double {
        let drift = sin(phase * 0.11 * r.sp + r.f) * 0.18
        let g = exp(-pow(x - (r.c + drift), 2) / (2 * r.w * r.w))
        return g * Self.taper(x) * sin(r.f * .pi * x - phase * r.sp + extra) * r.a * (0.035 + level * 1.4)
    }

    enum Style: String, CaseIterable, Identifiable {
        case comb, ribbons, lattice, strands
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        static var current: Style { Style(rawValue: UserDefaults.standard.string(forKey: "waveStyle") ?? "") ?? .comb }
    }

    var style: Style = .current

    func draw(in ctx: GraphicsContext, size: CGSize) {
        switch style {
        case .comb: drawComb(ctx, size)
        case .ribbons: drawRibbons(ctx, size, opacity: 1); drawCore(ctx, size)
        case .lattice: drawLattice(ctx, size)
        case .strands: drawStrands(ctx, size)
        }
    }

    /// See-through bands that twist as you talk.
    private func drawRibbons(_ ctx: GraphicsContext, _ size: CGSize, opacity: Double) {
        let w = size.width, mid = size.height / 2, H = size.height * 0.46
        var glow = ctx
        glow.opacity = opacity
        glow.blendMode = .plusLighter
        for r in ribbons {
            var p = Path()
            var px = 0.0
            while px <= w { let x = px / w * 2 - 1; let v = mid - y(r, x, 0) * H
                px == 0 ? p.move(to: CGPoint(x: px, y: v)) : p.addLine(to: CGPoint(x: px, y: v)); px += 2 }
            px = w
            while px >= 0 { let x = px / w * 2 - 1; p.addLine(to: CGPoint(x: px, y: mid - y(r, x, r.twist) * H * 0.75)); px -= 2 }
            p.closeSubpath()
            glow.fill(p, with: .color(.white.opacity(r.alpha * 1.3)))
        }
    }

    /// A bright thin line through the middle, fading at both ends.
    private func drawCore(_ ctx: GraphicsContext, _ size: CGSize) {
        var line = Path()
        line.move(to: CGPoint(x: 0, y: size.height / 2)); line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        let g = Gradient(stops: [.init(color: .white.opacity(0), location: 0), .init(color: .white.opacity(0.95), location: 0.5),
                                 .init(color: .white.opacity(0), location: 1)])
        ctx.stroke(line, with: .linearGradient(g, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 1)
    }

    /// Hairline vertical lines under a soft ribbon glow (the default).
    private func drawComb(_ ctx: GraphicsContext, _ size: CGSize) {
        drawRibbons(ctx, size, opacity: 0.45)
        let w = size.width, mid = size.height / 2, H = size.height * 0.46
        var comb = Path()
        var px = 1.5
        while px <= w {
            let x = px / w * 2 - 1
            let e = ribbons.map { abs(y($0, x, 0)) }.max() ?? 0
            let hh = max(0.5, e * H)
            comb.move(to: CGPoint(x: px, y: mid - hh)); comb.addLine(to: CGPoint(x: px, y: mid + hh))
            px += 3
        }
        ctx.stroke(comb, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
    }

    /// The bands drawn as fine vertical lines, with a dotted axis.
    private func drawLattice(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, mid = size.height / 2, H = size.height * 0.46
        for r in ribbons {
            var lines = Path()
            var px = 0.0
            while px <= w {
                let x = px / w * 2 - 1
                let a = mid - y(r, x, 0) * H, b = mid - y(r, x, r.twist) * H * 0.75
                if abs(a - b) > 0.4 { lines.move(to: CGPoint(x: px, y: a)); lines.addLine(to: CGPoint(x: px, y: b)) }
                px += 2.5
            }
            ctx.stroke(lines, with: .color(.white.opacity(min(1, r.alpha * 2.2))), lineWidth: 0.6)
        }
        var dots = Path()
        var px = 0.0
        while px <= w { dots.addRect(CGRect(x: px, y: mid - 0.5, width: 1, height: 1)); px += 3 }
        ctx.fill(dots, with: .color(.white.opacity(0.5)))
    }

    /// Six hairline waves that fan apart with your voice and meet at the ends.
    private func drawStrands(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = size.width, mid = size.height / 2, H = size.height * 0.42
        let amp = 0.035 + level * 1.4
        for i in 0..<6 {
            let f = 1.6 + Double(i) * 0.45, sp = 0.8 + Double(i) * 0.22, a = 1 - Double(i) * 0.11
            var p = Path()
            var px = 0.0
            while px <= w {
                let x = px / w * 2 - 1
                let v = mid - Self.taper(x) * sin(f * .pi * x - phase * sp + Double(i) * 0.7) * amp * a * H
                px == 0 ? p.move(to: CGPoint(x: px, y: v)) : p.addLine(to: CGPoint(x: px, y: v))
                px += 2
            }
            ctx.stroke(p, with: .color(.white.opacity(0.78 - Double(i) * 0.1)), lineWidth: 0.85)
        }
    }

    /// After you stop, while the text is finished: the comb stays, calm, and soft swells drift
    /// across it left to right without end. Two swells half a cycle apart, each fading out past the
    /// right edge as the next comes in on the left, so the loop never visibly restarts.
    static func drawBusy(in ctx: GraphicsContext, size: CGSize, now: Date) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let t = now.timeIntervalSinceReferenceDate
        let cycle = 1.6
        let p = (t / cycle).truncatingRemainder(dividingBy: 1)
        // Constant speed over -0.3...1.3; at either end a swell sits past the tapered edge, out of sight.
        let positions = [p, (p + 0.5).truncatingRemainder(dividingBy: 1)].map { -0.3 + 1.6 * $0 }
        let mid = size.height / 2, w = size.width
        var bars = Path(), bright = Path()
        var px = 1.5
        while px <= w {
            let x = px / w
            let edge = pow(max(0, 1 - pow(x * 2 - 1, 2)), 1.5)                 // taper at both ends
            let swell = reduce ? 0.35 : positions.map { exp(-pow(x - $0, 2) / (2 * 0.12 * 0.12)) }.max()!
            let breathe = 0.5 + 0.5 * sin(t * 4 + x * 14)
            let h = max(0.8, edge * (2.4 + 2.2 * breathe + 7 * swell))
            let line = Path { p in p.move(to: CGPoint(x: px, y: mid - h)); p.addLine(to: CGPoint(x: px, y: mid + h)) }
            if swell > 0.3 { bright.addPath(line) } else { bars.addPath(line) }
            px += 3
        }
        let style = StrokeStyle(lineWidth: 0.8, lineCap: .round)
        ctx.stroke(bars, with: .color(.white.opacity(0.5)), style: style)
        ctx.stroke(bright, with: .color(.white.opacity(0.92)), style: style)
    }
}
