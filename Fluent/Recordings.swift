@preconcurrency import AVFoundation
import Foundation

/// Keeps the most recent dictation recordings on this Mac (never uploaded), so accuracy can be
/// checked against the owner's real voice with --compare-models. Oldest are deleted past 30.
enum Recordings {
    static let keep = 30

    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fluent/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ samples: [Float]) {
        guard UserDefaults.standard.object(forKey: "keepRecordings") as? Bool ?? true else { return }
        Task.detached(priority: .utility) {
            let name = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            let url = folder.appendingPathComponent("\(name).wav")
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false]
            if let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) {
                try? file.write(from: buffer)
            }
            prune()
        }
    }

    private static func prune() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }
}
