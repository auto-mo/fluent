@preconcurrency import AVFoundation
import FluidAudio
import os

/// Records the default microphone while the dictation key is down and hands back
/// 16 kHz mono samples, the format Parakeet expects. The engine runs only while
/// recording, so the mic indicator is on only then.
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter = AudioConverter()
    // Buffers are only touched under this lock, so the non-Sendable buffer type is safe here.
    private let buffers = OSAllocatedUnfairLock<[AVAudioPCMBuffer]>(uncheckedState: [])
    /// Loudness of the latest buffer, 0...1, for the waveform later.
    let level = OSAllocatedUnfairLock(initialState: Float(0))

    /// Prepares the audio graph ahead of time so starting to record is quick.
    func prepare() {
        _ = engine.inputNode.outputFormat(forBus: 0)
        engine.prepare()
    }

    func start() throws {
        buffers.withLock { $0.removeAll() }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [buffers, level] buffer, _ in
            guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            buffers.withLock { $0.append(copy) }
            level.withLock { $0 = Self.rms(buffer) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops recording and returns the audio as 16 kHz mono samples.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        level.withLock { $0 = 0 }
        let recorded = buffers.withLock { b -> [AVAudioPCMBuffer] in defer { b.removeAll() }; return b }
        return recorded.flatMap { (try? converter.resampleBuffer($0)) ?? [] }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let db = 20 * log10(sqrt(sum / Float(buffer.frameLength)) + 1e-7)
        return min(1, max(0, (db + 58) / 42))
    }
}
