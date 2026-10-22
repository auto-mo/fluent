import SwiftUI
import UniformTypeIdentifiers

/// Drop an audio or video file, get its text. Runs on this Mac with the current model, then the
/// same fixed rules as dictation (fillers, numbers, your dictionary). Not counted as dictation.
struct TranscribePane: View {
    let dictation: DictationController
    @State private var file: URL?
    @State private var text = ""
    @State private var state: Phase = .waiting
    @State private var dropping = false

    enum Phase: Equatable { case waiting, working(String), done(seconds: Double), failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcribe").font(.system(size: 20, weight: .semibold))
                Spacer()
                if case .done = state {
                    HoverIconButton(symbol: "doc.on.doc", help: "Copy the text") { copy() }
                    HoverIconButton(symbol: "square.and.arrow.down", help: "Save as a text file") { save() }
                    Button("New file") { reset() }.buttonStyle(PrimaryButtonStyle())
                }
            }
            switch state {
            case .waiting:
                dropZone
            case .working(let name):
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Transcribing \(name)…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            case .done(let seconds):
                Text("\(file?.lastPathComponent ?? "File") · \(text.split(whereSeparator: \.isWhitespace).count) words · took \(String(format: "%.1f", seconds)) s")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            case .failed(let why):
                VStack(alignment: .leading, spacing: 10) {
                    Label(why, systemImage: "exclamationmark.circle")
                    Button("Try another file") { reset() }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Glyph(symbol: "waveform.badge.plus", size: 48)
            Text("Drop an audio or video file here").font(.system(size: 15, weight: .medium))
            Text("Voice memos, meeting recordings, podcasts: m4a, mp3, wav, aiff, caf, mp4, mov. Stays on this Mac.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose a file…") { choose() }.buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .background(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(dropping ? Color.primary : Color.secondary.opacity(0.5)))
        .background(RoundedRectangle(cornerRadius: 14).fill(dropping ? Color.primary.opacity(0.05) : .clear))
        .animation(.easeOut(duration: 0.12), value: dropping)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            run(url)
            return true
        } isTargeted: { dropping = $0 }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Audio, .mp3, .wav, .aiff]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { run(url) }
    }

    private func run(_ url: URL) {
        file = url
        state = .working(url.lastPathComponent)
        let started = Date.now
        Task {
            do {
                text = try await dictation.transcribeFile(url)
                state = text.isEmpty ? .failed("No speech found in that file.") : .done(seconds: Date.now.timeIntervalSince(started))
            } catch {
                state = .failed("Couldn't read that file: \(error.localizedDescription)")
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (file?.deletingPathExtension().lastPathComponent ?? "Transcript") + ".txt"
        if panel.runModal() == .OK, let url = panel.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    private func reset() { file = nil; text = ""; state = .waiting }
}
