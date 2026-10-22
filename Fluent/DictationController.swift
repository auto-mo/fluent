import AppKit
import FluidAudio
import Observation
import os

/// The dictation loop: record while the key says so, transcribe on device, type the text in.
/// Recordings never wait on each other: a new one can start while the last is still being
/// transcribed, and results are inserted in the order they were spoken.
@MainActor
@Observable
final class DictationController {
    /// Hold: talk while the key is down. Toggle: tap to start, tap to stop.
    /// Both: a press longer than 0.3 s is hold, a quick tap starts hands-free.
    enum Mode: String, CaseIterable, Identifiable {
        case hold, toggle, both
        var id: String { rawValue }
        var label: String { switch self { case .hold: "Hold"; case .toggle: "Toggle"; case .both: "Both" } }
        var help: String {
            switch self {
            case .hold: "Talk while the key is held down"
            case .toggle: "Tap to start, tap again to stop"
            case .both: "Hold to talk, or tap once for hands-free"
            }
        }
    }

    enum Language: String, CaseIterable, Identifiable {
        case english, multilingual
        var id: String { rawValue }
        var short: String { self == .english ? "EN" : "Auto" }
        var help: String {
            self == .english ? "English (Parakeet v2, most accurate for English)"
                : "Detects 25 European languages (Parakeet Ultra)"
        }
        var model: AsrModelVersion { self == .english ? .v2 : .ultra }   // v3 spells numbers out; Ultra formats them (research/model-comparison.md)
    }

    enum ModelState: Equatable { case loading(Double), ready, failed(String) }

    struct Result: Equatable {
        let text: String
        let app: String
        let audioSeconds: Double
        let transcribeSeconds: Double
        let keyUpToPastedSeconds: Double
        let method: String
        let raw: String
        let cleanupSeconds: Double
    }

    private(set) var modelState: ModelState = CommandLine.arguments.contains("--pretend-ready") ? .ready : .loading(0)   // screenshots only
    private(set) var isRecording = false
    private(set) var pending = 0
    private(set) var last: Result?
    private(set) var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .both
    private(set) var language: Language =
        Language(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .english

    let hotkey = HotkeyMonitor()
    let history = HistoryStore()
    let dictionary = WordDictionary()
    let snippets = Snippets()
    let learner = EditLearner()
    private let widget = WidgetPanel()
    private let recorder = AudioRecorder()
    private let cleaner = Cleaner()
    var cleanupOn: Bool { UserDefaults.standard.object(forKey: "cleanup") as? Bool ?? true }
    private var transcriber: any Transcriber = ParakeetTranscriber(version: .v2)
    /// The speech model in use (ModelCatalog id).
    private(set) var modelID: String = ModelCatalog.selectedID
    private var chain: Task<Void, Never>?
    private var keyDownAt = Date.distantPast
    private var latched = false          // recording continues after the key is released
    private var ignoreNextRelease = false
    private let log = Logger(subsystem: "org.fluentdictation.fluent", category: "dictation")

    var menuSymbol: String {
        if case .failed = modelState { return "mic.slash" }
        if case .loading = modelState { return "arrow.down.circle" }
        if isRecording { return "mic.fill" }
        return pending > 0 ? "ellipsis" : "mic"
    }

    var statusText: String {
        switch modelState {
        case .failed(let message): return message
        case .loading(let p): return p > 0 && p < 1 ? "Downloading the speech model, \(Int(p * 100))%" : "Loading the speech model"
        case .ready:
            if isRecording { return latched ? "Listening, tap \(hotkey.key.label) to stop" : "Listening" }
            if pending > 0 { return "Transcribing" }
            return switch mode {
            case .hold: "Ready. Hold \(hotkey.key.label) and speak."
            case .toggle: "Ready. Tap \(hotkey.key.label) to start and again to stop."
            case .both: "Ready. Hold \(hotkey.key.label), or tap it for hands-free."
            }
        }
    }

    func start() {
        // Well-known names from Wikidata: refreshed when more than a week old, checked once a day.
        dictionary.refreshWorldNames()
        Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.dictionary.refreshWorldNames() }
        }
        widget.model.levelSource = { [recorder] in recorder.level.withLock { $0 } }
        widget.model.actions = .init(
            start: { [weak self] in self?.startRecording(latched: true) },
            stop: { [weak self] in self?.stopRecording() },
            cancel: { [weak self] in self?.cancelRecording() },
            setMode: { [weak self] in self?.setMode($0) },
            drop: { [weak self] in self?.dropHeld() },
            undo: { [weak self] in self?.undoLast() },
            copyHeld: { [weak self] in self?.copyHeld() },
            discardHeld: { [weak self] in self?.discardHeld() },
            toggleCleanup: { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(!self.cleanupOn, forKey: "cleanup")
                self.syncWidgetSettings()
            },
            toggleLanguage: { [weak self] in
                guard let self else { return }
                self.setLanguage(self.language == .english ? .multilingual : .english)
            })
        syncWidgetSettings()
        widget.rest()

        learner.onLearned = { [weak self] heard, correct, app in self?.learned(heard: heard, correct: correct, app: app) }
        hotkey.onPress = { [weak self] in self?.keyDown() }
        hotkey.onRelease = { [weak self] in self?.keyUp() }
        hotkey.onCancel = { [weak self] in
            guard let self else { return }
            if self.isRecording { self.cancelRecording() } else { self.discardHeld() }
        }
        hotkey.onReturn = { [weak self] in self?.dropHeld() }
        hotkey.onCombo = { [weak self] code, flags in
            guard let self, let s = self.snippets.snippet(forKey: code, flags: flags) else { return false }
            Task { _ = await Inserter.insert(s.text) }
            return true
        }
        hotkey.onCapturedCombo = { [weak self] id, code, flags, label in
            self?.snippets.setShortcut(id, keyCode: code, flags: flags, label: label)
        }
        if !hotkey.start() { log.error("Input Monitoring not granted; hotkey off") }
        transcriber = ModelCatalog.makeTranscriber(ModelCatalog.model(modelID))
        Task { await loadModel(transcriber) }
        // Apple's model takes about 2 s on first use; load it now so the first dictation isn't slow.
        if cleanupOn { cleaner.prewarm() }
        recorder.prepare()
        // Restart only between dictations, never mid-sentence or with text waiting.
        MemoryWatch.start { [weak self] in
            guard let self else { return false }
            return !self.isRecording && self.pending == 0 && self.held == nil
        }
    }

    // MARK: Idle

    private var idleUnload: Task<Void, Never>?
    static let idleMinutes = 5.0

    /// After a few quiet minutes, free the speech model's memory; pressing the key reloads it.
    private func scheduleIdleUnload() {
        idleUnload?.cancel()
        let model = transcriber
        idleUnload = Task {
            try? await Task.sleep(for: .seconds(Self.idleMinutes * 60))
            guard !Task.isCancelled, !isRecording, pending == 0 else { return }
            await model.unload()
            log.info("Speech model unloaded after idle")
        }
    }

    // MARK: Settings

    func setMode(_ newMode: Mode) {
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: "mode")
        syncWidgetSettings()
    }

    func setLanguage(_ newLanguage: Language) {
        setModel(newLanguage == .english ? ModelCatalog.english : ModelCatalog.multilingual)
    }

    /// Switches the speech model; it downloads the first time it's chosen.
    func setModel(_ id: String) {
        guard id != modelID else { return }
        modelID = id
        ModelCatalog.selectedID = id
        language = id == ModelCatalog.multilingual ? .multilingual : .english
        UserDefaults.standard.set(language.rawValue, forKey: "language")
        syncWidgetSettings()
        let next = ModelCatalog.makeTranscriber(ModelCatalog.model(id))
        transcriber = next   // queued dictations keep the model they started with
        Task { await loadModel(next) }
    }

    func refreshWidgetSettings() { syncWidgetSettings() }

    private func syncWidgetSettings() {
        widget.model.recordingMode = mode
        widget.model.language = language
        widget.model.cleanupOn = cleanupOn
    }

    private func loadModel(_ t: any Transcriber) async {
        modelState = .loading(0)
        do {
            try await t.prepare { p in
                Task { @MainActor [weak self] in
                    if case .loading = self?.modelState { self?.modelState = .loading(p) }
                }
            }
            if t === transcriber { modelState = .ready }
            log.info("Speech model ready")
        } catch {
            modelState = .failed("Couldn't load the speech model: \(error.localizedDescription)")
            log.error("Model load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Delivering text

    /// Types the text into the focused box, records it, starts learning from edits, shows the result.
    private func deliver(_ final: String, raw: String, app: String, before: String?, stoppedAt: Date,
                         audioSeconds: Double, transcribeSeconds: Double, cleanupSeconds: Double) async {
        let text = raw.isEmpty ? "" : CaretContext.join(final, after: before)
        let inserted = await Inserter.insert(text)
        let seconds = (inserted?.date ?? .now).timeIntervalSince(stoppedAt)
        last = Result(text: text, app: app, audioSeconds: audioSeconds, transcribeSeconds: transcribeSeconds,
                      keyUpToPastedSeconds: seconds, method: inserted?.method.rawValue ?? "Nothing to insert",
                      raw: raw, cleanupSeconds: cleanupSeconds)
        if !text.isEmpty {
            history.add(.init(date: stoppedAt, text: text.trimmingCharacters(in: .whitespaces), raw: raw, app: app,
                              method: inserted?.method.rawValue ?? "", seconds: seconds, audioSeconds: audioSeconds))
        }
        if inserted != nil {
            learner.watch(text, app: app)
            lastInsert = (text, app, Date.now)
        }
        log.info("Dictated \(audioSeconds, format: .fixed(precision: 1))s in \(app, privacy: .public)")
        if !isRecording {
            if text.isEmpty { widget.flash(.message("Didn't hear anything"), for: 1.5) }
            else { widget.flash(.done(app: app), for: 1.5) }
        }
    }

    struct Held: Equatable {
        let text: String
        let raw: String
        let stoppedAt: Date
        let audioSeconds: Double
    }

    /// Text waiting for a text box (no box had focus when you stopped).
    private(set) var held: Held?
    private var holdTimer: Timer?
    private var dropApp: String?
    /// The last text typed, for undo.
    private(set) var lastInsert: (text: String, app: String, at: Date)?

    private func hold(_ h: Held) {
        if let old = held { history.add(.init(date: old.stoppedAt, text: old.text, raw: old.raw, app: "Not inserted",
                                              method: "Held, replaced by a newer dictation", seconds: 0, audioSeconds: old.audioSeconds)) }
        held = h
        dropApp = nil
        hotkey.cancelActive = true
        widget.show(.holding(h.text))
        holdTimer?.invalidate()
        // Watch for a text box to get focus, in any app, on any screen.
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForTextBox() }
        }
    }

    private func checkForTextBox() async {
        guard held != nil, !isRecording, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        ChromiumAccess.enable(for: front, element: AXUIElementCreateApplication(front.processIdentifier))
        let pid = front.processIdentifier
        let state = await Task.detached { FocusProbe.state(pid: pid) }.value
        guard let held else { return }
        let name = front.localizedName ?? "this app"
        if state != .notText {   // a text box, or something that may be one: offer the drop (Return confirms)
            if dropApp != name {
                dropApp = name
                hotkey.returnActive = true
                widget.show(.dropPrompt(app: name))
            }
        } else if dropApp != nil {
            dropApp = nil
            hotkey.returnActive = false
            widget.show(.holding(held.text))
        }
    }

    private func endHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        held = nil
        dropApp = nil
        hotkey.returnActive = false
        hotkey.cancelActive = isRecording && latched
    }

    /// Undo for the last dictation: ⌘Z in the app it went into, which removes it there as one edit.
    func undoLast() {
        guard let last = lastInsert, Date.now.timeIntervalSince(last.at) < 60,
              NSWorkspace.shared.frontmostApplication?.localizedName == last.app else { return }
        lastInsert = nil
        learner.stop()
        Inserter.postKey(6, command: true)   // ⌘Z
        widget.flash(.message("Undone"), for: 1.0)
    }

    /// Drops held text into the box that has focus now.
    func dropHeld() {
        guard let h = held else { return }
        endHold()
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.localizedName ?? "?"
        Task {
            let pid = front?.processIdentifier
            let before: String? = if let pid { await Task.detached { CaretContext.textBefore(pid: pid) }.value } else { nil }
            await deliver(h.text, raw: h.raw, app: app, before: before, stoppedAt: h.stoppedAt,
                          audioSeconds: h.audioSeconds, transcribeSeconds: 0, cleanupSeconds: 0)
        }
    }

    func copyHeld() {
        guard let h = held else { return }
        endHold()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(h.text, forType: .string)
        history.add(.init(date: h.stoppedAt, text: h.text, raw: h.raw, app: "Clipboard", method: "Copied", seconds: 0, audioSeconds: h.audioSeconds))
        widget.flash(.message("Copied"), for: 1.2)
    }

    /// Discarded text is still kept in History.
    func discardHeld() {
        guard let h = held else { return }
        endHold()
        history.add(.init(date: h.stoppedAt, text: h.text, raw: h.raw, app: "Not inserted", method: "Discarded", seconds: 0, audioSeconds: h.audioSeconds))
        widget.flash(.message("Discarded. It's in History."), for: 1.5)
    }

    // MARK: Files

    /// Transcribes a whole audio or video file with the current model, then applies the fixed
    /// rules (fillers, numbers, temperatures, dictionary). No AI cleanup: files can be long.
    func transcribeFile(_ url: URL) async throws -> String {
        let model = transcriber
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let raw: String
        if let parakeet = model as? ParakeetTranscriber {
            try await parakeet.prepare { _ in }
            raw = try await parakeet.transcribe(file: url)
        } else {
            let samples = try AudioConverter().resampleAudioFile(path: url.path)
            raw = try await model.transcribe(samples)
        }
        let fixed = ClockTimes.normalize(Temperatures.normalize(SpokenDigits.normalize(Fillers.remove(raw))))
        return dictionary.apply(to: fixed, app: nil).0
    }

    // MARK: Learning

    /// A correction you made after Fluent typed. Ordinary word swaps ("The" to "Then") are edits,
    /// not names: when both sides are dictionary words, nothing is learned.
    private func learned(heard: String, correct: String, app: String) {
        let checker = NSSpellChecker.shared
        func isWord(_ w: String) -> Bool {
            w.split(separator: " ").allSatisfy {
                checker.checkSpelling(of: $0.lowercased(), startingAt: 0).location == NSNotFound
            }
        }
        if EditLearner.isPlainWordSwap(heard: heard, correct: correct), isWord(heard), isWord(correct) { return }
        // A misheard ordinary word ("leaner" for "Lena") is not kept as something to replace,
        // or every "project" would change. The name itself is still remembered.
        let replaceable = !(heard.split(separator: " ").count == 1 && isWord(heard))
        guard dictionary.learn(heard: replaceable ? heard : nil, correct: correct, app: app) != nil else { return }
        log.info("Learned \(correct, privacy: .public)")
        if !isRecording { widget.flash(.message("Learned \(correct)"), for: 2.0) }
    }

    // MARK: Key handling

    private func keyDown() {
        if isRecording {
            // Second press in hands-free mode stops it.
            if latched { ignoreNextRelease = true; stopRecording() }
            return
        }
        keyDownAt = .now
        startRecording(latched: mode == .toggle)
    }

    private func keyUp() {
        if ignoreNextRelease { ignoreNextRelease = false; return }
        guard isRecording, !latched else { return }
        let held = Date.now.timeIntervalSince(keyDownAt)
        if mode == .both, held < 0.3 {
            latched = true                 // a quick tap: keep listening until the next tap
            hotkey.cancelActive = true
            widget.model.latched = true
            return
        }
        stopRecording()
    }

    // MARK: Recording

    private func startRecording(latched: Bool) {
        guard modelState == .ready, !isRecording else { return }
        do {
            // Show the pill first so it appears the moment you press; the mic starts right after.
            widget.model.latched = latched
            widget.show(.recording(started: .now), follow: true)
            try recorder.start()
            isRecording = true
            idleUnload?.cancel()
            let model = transcriber
            Task { if !(await model.isLoaded) { try? await model.prepare { _ in } } }   // reload while you talk
            originApp = NSWorkspace.shared.frontmostApplication?.localizedName
            widget.model.dropTarget = nil
            targetTimer?.invalidate()
            // Hands-free: if you move to another app, the pill names where the text will go.
            targetTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRecording, self.latched else { return }
                    let now = NSWorkspace.shared.frontmostApplication?.localizedName
                    self.widget.model.dropTarget = now == self.originApp ? nil : now
                }
            }
            self.latched = latched
            hotkey.cancelActive = latched
            if cleanupOn { DispatchQueue.main.async { self.cleaner.prewarm() } }
        } catch {
            widget.flash(.message("Couldn't start the microphone"), for: 2.5)
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        _ = recorder.stop()
        endRecordingState()
        widget.flash(.message("Cancelled"), for: 1.0)
    }

    private var originApp: String?
    private var targetTimer: Timer?

    private func endRecordingState() {
        targetTimer?.invalidate()
        widget.model.dropTarget = nil
        isRecording = false
        latched = false
        hotkey.cancelActive = false
        widget.model.latched = false
    }

    private func stopRecording() {
        guard isRecording else { return }
        let stoppedAt = Date.now
        let samples = recorder.stop()
        endRecordingState()
        let seconds = Double(samples.count) / 16_000
        guard seconds >= 0.3 else { widget.rest(); return }

        Recordings.save(samples)
        // The text goes wherever the cursor is now, when you stop.
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.localizedName ?? "?"
        let model = transcriber
        let previous = chain
        pending += 1
        widget.show(.transcribing)
        chain = Task {
            await previous?.value   // keep insertions in the order they were spoken
            do {
                let t0 = Date.now
                let raw = try await model.transcribe(samples)
                let t1 = Date.now
                // What's already before the cursor, read now (the box may have changed since you stopped).
                let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let before: String? = if let pid { await Task.detached { CaretContext.textBefore(pid: pid) }.value } else { nil }
                let literal = Cleaner.literalApps.contains(front?.bundleIdentifier ?? "")
                let digitsFixed = literal ? raw : ClockTimes.normalize(Temperatures.normalize(SpokenDigits.normalize(Fillers.remove(raw))))
                // Your names first, so cleanup sees them right; again after, in case it changed one.
                let named = dictionary.apply(to: digitsFixed, app: app).0
                // Email and documents get lists; chat stays one paragraph.
                let title: String? = if let pid { await Task.detached { AppStyle.windowTitle(pid: pid) }.value } else { nil }
                let style = UserDefaults.standard.object(forKey: "formatLists") as? Bool ?? true
                    ? AppStyle.detect(bundleID: front?.bundleIdentifier, appName: app, windowTitle: title) : .plain
                let cleaned = cleanupOn
                    ? await cleaner.clean(named, before: before, appBundleID: front?.bundleIdentifier, terms: dictionary.hintTerms, style: style)
                    : Cleaner.Output(text: named, cleaned: false, seconds: 0)
                let final = snippets.expand(dictionary.apply(to: cleaned.text, app: app).0)
                // Is there somewhere to type? If definitely not, hold the text until you click into a box.
                let target = NSWorkspace.shared.frontmostApplication
                let isSelf = target?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                let chromium = target.map { ChromiumAccess.isChromium($0) } ?? false
                let state: FocusProbe.State = if let pid = target?.processIdentifier, !isSelf {
                    await Task.detached { FocusProbe.state(pid: pid, chromium: chromium) }.value
                } else { .notText }
                if !raw.isEmpty, state == .notText {
                    hold(Held(text: final, raw: raw, stoppedAt: stoppedAt, audioSeconds: seconds))
                } else {
                    await deliver(final, raw: raw, app: app, before: before, stoppedAt: stoppedAt, audioSeconds: seconds,
                                  transcribeSeconds: t1.timeIntervalSince(t0), cleanupSeconds: cleaned.seconds)
                }
            } catch {
                log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                if !isRecording { widget.flash(.message("Couldn't transcribe that"), for: 2.5) }
            }
            pending -= 1
            scheduleIdleUnload()
            // Learning watches the text for 60 s; release the apps' accessibility mode after that.
            ChromiumAccess.scheduleRelease()
        }
    }
}
