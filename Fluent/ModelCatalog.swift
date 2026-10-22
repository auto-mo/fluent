import FluidAudio
import Foundation
import Security

/// The speech models Fluent can use: the models FluidAudio runs on this Mac (NVIDIA Parakeet and
/// Canary, Alibaba SenseVoice), Apple's own on-device transcriber, plus any server you add that
/// speaks the OpenAI-style transcription API (POST /v1/audio/transcriptions).
struct ModelInfo: Codable, Identifiable, Hashable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        case parakeet(String)                     // FluidAudio version name
        case server(url: String, model: String)   // OpenAI-compatible endpoint
        case canary                               // NVIDIA Canary 1B v2, int4
        case senseVoice                           // Alibaba SenseVoice Small
        case apple                                // macOS SpeechTranscriber
    }
    let id: String
    let name: String
    let detail: String
    let kind: Kind

    /// Section in the Models list.
    var group: String {
        switch kind {
        case .parakeet("ja"), .senseVoice: "Asian languages"
        case .parakeet("ultra"), .parakeet("v3"), .canary: "Many languages"
        case .parakeet: "English"
        case .apple: "Built into macOS"
        case .server: "Yours"
        }
    }

    var isServer: Bool { if case .server = kind { true } else { false } }

    var folder: String? {
        switch kind {
        case .parakeet(let v):
            return ["v2": "parakeet-tdt-0.6b-v2", "v3": "parakeet-tdt-0.6b-v3", "ultra": "parakeet-ultra",
                    "phonon2": "phonon-2", "redux": "parakeet-redux",
                    "mini": Repo.parakeetTdtCtc110m.folderName, "ja": Repo.parakeetJa.folderName][v]
        case .canary: return Repo.canary1bV2.folderName
        case .senseVoice: return Repo.senseVoiceSmall.folderName
        case .server, .apple: return nil
        }
    }

    var isDownloaded: Bool {
        guard let folder else { return true }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/\(folder)")
        return FileManager.default.fileExists(atPath: dir.path)
    }
}

enum ModelCatalog {
    static let english = "parakeet-v2"
    static let multilingual = "parakeet-ultra"

    /// Apple's transcriber needs macOS 26; older systems don't list it.
    static let builtIn: [ModelInfo] = allBuiltIn.filter { m in
        if case .apple = m.kind, #unavailable(macOS 26) { return false }
        return true
    }

    private static let allBuiltIn: [ModelInfo] = [
        ModelInfo(id: "parakeet-v2", name: "Parakeet v2", detail: "English. Most accurate for English; writes numbers well.", kind: .parakeet("v2")),
        ModelInfo(id: "parakeet-ultra", name: "Parakeet Ultra", detail: "25 European languages, detected automatically; writes numbers well.", kind: .parakeet("ultra")),
        ModelInfo(id: "parakeet-v3", name: "Parakeet v3", detail: "What SpeakType uses. 25 languages; tends to spell numbers out.", kind: .parakeet("v3")),
        ModelInfo(id: "parakeet-phonon2", name: "Phonon-2", detail: "English re-training of v3. Spells numbers out in tests.", kind: .parakeet("phonon2")),
        ModelInfo(id: "parakeet-redux", name: "Parakeet Redux", detail: "Small download (about 220 MB). Mostly right in tests, with small glitches.", kind: .parakeet("redux")),
        ModelInfo(id: "parakeet-mini", name: "Parakeet Mini", detail: "English, 110M parameters: the lightest, for Macs with 8 GB or less. A little less accurate.", kind: .parakeet("mini")),
        ModelInfo(id: "canary-1b", name: "Canary 1B", detail: "NVIDIA. 25 European languages. Accurate but slow (several seconds per dictation): best for transcribing files.", kind: .canary),
        ModelInfo(id: "parakeet-ja", name: "Parakeet Japanese", detail: "Japanese.", kind: .parakeet("ja")),
        ModelInfo(id: "sensevoice", name: "SenseVoice Small", detail: "Alibaba. Chinese, Cantonese, Japanese and Korean; very fast. Its English has no capitals or punctuation.", kind: .senseVoice),
        ModelInfo(id: "apple", name: "Apple on-device", detail: "Apple's own transcriber, built into macOS: nothing to download from Fluent, your Mac's language.", kind: .apple),
    ]

    static var custom: [ModelInfo] {
        get { (UserDefaults.standard.data(forKey: "customModels")).flatMap { try? JSONDecoder().decode([ModelInfo].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "customModels") }
    }

    static var all: [ModelInfo] { builtIn + custom }

    static var selectedID: String {
        get { UserDefaults.standard.string(forKey: "modelId") ?? english }
        set { UserDefaults.standard.set(newValue, forKey: "modelId") }
    }

    static func model(_ id: String) -> ModelInfo { all.first { $0.id == id } ?? builtIn[0] }

    static func makeTranscriber(_ m: ModelInfo) -> any Transcriber {
        switch m.kind {
        case .parakeet(let v):
            let version: AsrModelVersion = switch v {
            case "v3": .v3
            case "ultra": .ultra
            case "phonon2": .phonon2
            case "redux": .redux
            case "mini": .tdtCtc110m
            case "ja": .tdtJa
            default: .v2
            }
            return ParakeetTranscriber(version: version)
        case .server(let url, let model):
            return ServerTranscriber(baseURL: url, model: model)
        case .canary: return CanaryTranscriber()
        case .senseVoice: return SenseVoiceTranscriber()
        case .apple:
            if #available(macOS 26, *) { return AppleTranscriber() }
            return ParakeetTranscriber(version: .tdtCtc110m)
        }
    }

    // MARK: Picking a model for this Mac

    /// What this Mac is, for the recommendation.
    struct Device: Sendable {
        let chip: String
        let memoryGB: Int
        let appleSilicon: Bool
        let language: String   // first preferred language, e.g. "en", "ja"
    }

    static let device: Device = {
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
            return String(cString: buf)
        }
        var arm: Int32 = 0, armSize = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &arm, &armSize, nil, 0)
        let lang = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        return Device(chip: sysctl("machdep.cpu.brand_string") ?? "This Mac",
                      memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
                      appleSilicon: arm == 1, language: lang)
    }()

    /// The model that should work best here, and why, in one line.
    static func recommendation(for d: Device = device) -> (id: String, why: String) {
        let summary = "\(d.chip), \(d.memoryGB) GB"
        guard d.appleSilicon else {
            if #unavailable(macOS 26) { return ("parakeet-mini", "\(summary): the lightest model runs best without a Neural Engine.") }
            return ("apple", "\(summary): Intel Macs have no Neural Engine, so Apple's built-in transcriber runs best.")
        }
        switch d.language {
        case "ja": return ("parakeet-ja", "\(summary), Japanese as your first language.")
        case "zh", "yue", "ko": return ("sensevoice", "\(summary), \(Locale.current.localizedString(forLanguageCode: d.language) ?? d.language) as your first language.")
        case "en":
            if d.memoryGB <= 8 { return ("parakeet-mini", "\(summary): the lightest English model leaves memory for your other apps.") }
            return ("parakeet-v2", "\(summary): the most accurate English model, fast on the Neural Engine.")
        default:
            return ("parakeet-ultra", "\(summary), \(Locale.current.localizedString(forLanguageCode: d.language) ?? d.language) as your first language: 25 European languages.")
        }
    }

    // MARK: Adding a model from a link

    enum Check: Sendable {
        case known(ModelInfo)
        case server(ModelInfo)
        case unsupported(String)
    }

    /// Hugging Face repos FluidAudio runs, mapped to the built-in entries.
    private static let knownRepos: [String: String] = [
        "fluidinference/parakeet-tdt-0.6b-v2-coreml": "parakeet-v2", "fluidinference/parakeet-tdt-0.6b-v3-coreml": "parakeet-v3",
        "fluidinference/parakeet-ultra-coreml": "parakeet-ultra", "fluidinference/phonon-2-coreml": "parakeet-phonon2",
        "fluidinference/parakeet-redux-coreml": "parakeet-redux", "fluidinference/parakeet-tdt-ctc-110m-coreml": "parakeet-mini",
        "fluidinference/canary-1b-v2-coreml": "canary-1b", "fluidinference/parakeet-0.6b-ja-coreml": "parakeet-ja",
        "fluidinference/sensevoice-small-coreml": "sensevoice",
    ]

    /// Works out what a pasted link is and whether Fluent can run it. Never downloads model files.
    static func check(_ input: String, model: String, apiKey: String) async -> Check {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.hasPrefix("http") ? text : "https://" + text), let host = url.host else {
            return .unsupported("That doesn't look like a link.")
        }
        if host.hasSuffix("huggingface.co") {
            let parts = url.path.split(separator: "/").prefix(2).map(String.init)
            guard parts.count == 2 else { return .unsupported("Paste a model page, like huggingface.co/org/model.") }
            let repo = parts.joined(separator: "/")
            if let id = knownRepos[repo.lowercased()] { return .known(ModelCatalog.model(id)) }
            return .unsupported(await describe(repo: repo))
        }
        // Anything else: treat it as an OpenAI-compatible server and test it with a short silent clip.
        let base = text.replacingOccurrences(of: "/v1/audio/transcriptions", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !apiKey.isEmpty { Keychain.set(apiKey, for: base) }
        let probe = ServerTranscriber(baseURL: base, model: model.isEmpty ? "whisper-1" : model)
        do {
            _ = try await probe.transcribe([Float](repeating: 0, count: 8000))
            let name = URL(string: base)?.host ?? base
            return .server(ModelInfo(id: "server-\(base)", name: "Server: \(name)", detail: "\(model.isEmpty ? "whisper-1" : model) at \(base)",
                                     kind: .server(url: base, model: model.isEmpty ? "whisper-1" : model)))
        } catch {
            return .unsupported("Couldn't reach a transcription server there: \(error.localizedDescription)")
        }
    }

    /// Reads a Hugging Face repo's file list and says plainly what it is.
    private static func describe(repo: String) async -> String {
        guard let api = URL(string: "https://huggingface.co/api/models/\(repo)"),
              let (data, response) = try? await URLSession.shared.data(from: api),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Couldn't read that model on Hugging Face (private, gated or misspelled?)."
        }
        let files = ((json["siblings"] as? [[String: Any]]) ?? []).compactMap { $0["rfilename"] as? String }
        func has(_ ext: String) -> Bool { files.contains { $0.lowercased().contains(ext) } }
        if has(".pt") || has(".nemo") || has(".ckpt") || files.contains(where: { $0.hasSuffix("pytorch_model.bin") }) {
            return "This model is stored in a format that can run code when loaded, so Fluent won't load it."
        }
        if has(".gguf") || has("ggml") { return "A whisper.cpp model. Support is planned, not built yet. Running it on a server and adding the server works today." }
        if has(".onnx") { return "An ONNX model. Support for these (through sherpa-onnx) is planned, not built yet." }
        if has(".mlmodelc") || has(".mlpackage") { return "A Core ML model, but not one Fluent knows how to run yet." }
        if has(".safetensors") { return "Raw model weights (MLX or PyTorch). Fluent can't run these directly; serve it with an OpenAI-compatible server and add that instead." }
        return "Fluent didn't recognise this model's format."
    }
}

/// Any server that speaks the OpenAI transcription API: a server on your own machine, speaches, vLLM, LocalAI, Groq.
actor ServerTranscriber: Transcriber {
    let baseURL: String
    let model: String
    init(baseURL: String, model: String) { self.baseURL = baseURL; self.model = model }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }
    func unload() {}
    var isLoaded: Bool { true }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let url = URL(string: baseURL + "/v1/audio/transcriptions") else { throw URLError(.badURL) }
        let boundary = "fluent-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "json")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(Self.wav(samples))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let key = Keychain.get(baseURL) { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let text = json?["text"] as? String else { throw URLError(.cannotParseResponse) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 16 kHz mono 16-bit WAV.
    static func wav(_ samples: [Float]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples { var v = Int16(max(-1, min(1, s)) * 32767).littleEndian; pcm.append(Data(bytes: &v, count: 2)) }
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}

/// API keys for servers, in the macOS Keychain (never in files or settings).
enum Keychain {
    private static let service = "org.fluentdictation.fluent.server"

    static func set(_ secret: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(secret.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
