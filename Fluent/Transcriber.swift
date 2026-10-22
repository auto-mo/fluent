@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import Speech

/// Every speech model sits behind this, so models can be swapped (see PLAN.md, model layer).
protocol Transcriber: AnyObject, Sendable {
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(_ samples: [Float]) async throws -> String
    /// Frees memory after idle; the next transcription reloads.
    func unload() async
    var isLoaded: Bool { get async }
}

/// NVIDIA Parakeet TDT through FluidAudio, on the Neural Engine. English v2 by default.
actor ParakeetTranscriber: Transcriber {
    private let version: AsrModelVersion
    private var manager: AsrManager?

    init(version: AsrModelVersion = .v2) { self.version = version }

    nonisolated var versionName: String { "\(version)" }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        // Downloads once (to FluidAudio's cache in Application Support), then loads from disk.
        let models = try await AsrModels.downloadAndLoad(version: version) { p in
            progress(p.fractionCompleted)
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        if manager == nil { try await prepare { _ in } }   // reload after an idle unload
        guard let manager else { throw FluentError.modelNotReady }
        var state = TdtDecoderState.make()
        do {
            let result = try await manager.transcribe(samples, decoderState: &state)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // Parakeet Mini throws on near-silence; nothing said is an empty result, not a failure.
            if (samples.map(abs).max() ?? 0) < 0.03 { return "" }
            throw error
        }
    }

    /// Frees the model's memory; the next transcription loads it again (about 0.2 s once cached).
    func unload() { manager = nil }

    var isLoaded: Bool { manager != nil }

    func transcribe(file url: URL) async throws -> String {
        guard let manager else { throw FluentError.modelNotReady }
        var state = TdtDecoderState.make()
        return try await manager.transcribe(url, decoderState: &state).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// NVIDIA Canary 1B v2 through FluidAudio (int4 weights). 25 European languages.
actor CanaryTranscriber: Transcriber {
    private var manager: CanaryManager?

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        manager = try await CanaryManager.load(precision: .int4) { p in progress(p.fractionCompleted) }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        if manager == nil { try await prepare { _ in } }
        guard let manager else { throw FluentError.modelNotReady }
        return try await manager.transcribe(audio: samples).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() { manager = nil }
    var isLoaded: Bool { manager != nil }
}

/// Alibaba SenseVoice Small through FluidAudio. Chinese, Cantonese, English, Japanese, Korean.
actor SenseVoiceTranscriber: Transcriber {
    private var manager: SenseVoiceManager?

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        manager = try await SenseVoiceManager.load { p in progress(p.fractionCompleted) }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        if manager == nil { try await prepare { _ in } }
        guard let manager else { throw FluentError.modelNotReady }
        // Its larger input sizes failed in testing, so feed it pieces of 15 s or less.
        var parts: [String] = []
        for piece in AudioPieces.split(samples, maxSeconds: 15) {
            parts.append(try await manager.transcribe(audio: piece).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    func unload() { manager = nil }
    var isLoaded: Bool { manager != nil }
}

/// Cuts long audio at the quietest moment near each limit, so no word is split in two.
enum AudioPieces {
    static func split(_ samples: [Float], maxSeconds: Double, rate: Int = 16_000) -> [[Float]] {
        let maxLen = Int(maxSeconds * Double(rate))
        guard samples.count > maxLen else { return [samples] }
        var pieces: [[Float]] = []
        var start = 0
        let window = rate / 10   // 100 ms
        while samples.count - start > maxLen {
            // Look for the quietest 100 ms in the last third of the allowed length.
            var best = start + maxLen, bestEnergy = Float.greatestFiniteMagnitude
            var w = start + maxLen * 2 / 3
            while w + window <= start + maxLen {
                var e: Float = 0
                for i in w..<(w + window) { e += samples[i] * samples[i] }
                if e < bestEnergy { bestEnergy = e; best = w + window / 2 }
                w += window / 2
            }
            pieces.append(Array(samples[start..<best]))
            start = best
        }
        pieces.append(Array(samples[start...]))
        return pieces
    }
}

/// Apple's on-device SpeechTranscriber, in the Mac's own language. macOS keeps the model; the
/// first use may ask macOS to fetch it, after that nothing is downloaded. macOS 26 and later.
@available(macOS 26, *)
actor AppleTranscriber: Transcriber {
    private var locale: Locale?

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard locale == nil else { return }
        let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        let module = SpeechTranscriber(locale: l, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        locale = l
        progress(1)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        if locale == nil { try await prepare { _ in } }
        guard let locale else { throw FluentError.modelNotReady }
        // SpeechAnalyzer reads audio files; a short temporary WAV is the simplest hand-off.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fluent-\(UUID().uuidString).wav")
        try ServerTranscriber.wav(samples).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [module])
        async let text: String = {
            var out = ""
            for try await result in module.results { out += String(result.text.characters) }
            return out
        }()
        let file = try AVAudioFile(forReading: url)
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {}
    var isLoaded: Bool { locale != nil }
}

enum FluentError: LocalizedError {
    case modelNotReady
    var errorDescription: String? { "The speech model is still loading." }
}
