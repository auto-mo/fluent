import AppKit
import FluidAudio
import ApplicationServices
import AVFoundation

/// Non-interactive modes for scripts/verify.sh. Launch through `open -n --args ...` so that
/// macOS treats Fluent, not the terminal, as the process asking about permissions.
@MainActor
enum DiagnosticModes {
    static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fluent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// True when launched for a check. Such runs never watch the key, record or type, so they
    /// can't act alongside the real Fluent (a stuck check once typed every dictation twice).
    static var isDiagnosticRun: Bool { CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") } }

    static func runIfRequested() {
        let args = CommandLine.arguments
        // `--appearance dark|light`: for screenshots in either theme.
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            NSApplication.shared.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
        }
        if let i = args.firstIndex(of: "--probe-apps"), i + 1 < args.count {
            probeApps(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--report-permissions"), i + 1 < args.count {
            writePermissionReport(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--transcribe"), i + 2 < args.count {
            let input = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            Task { await transcribeFile(input, to: out); exit(0) }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--compare-models"), i + 2 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            let ids = i + 3 < args.count && !args[i + 3].hasPrefix("--") ? args[i + 3].split(separator: ",").map(String.init) : nil
            Task { await compareModels(dir, to: out, ids: ids); exit(0) }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--cleanup-test"), i + 2 < args.count {
            let input = URL(fileURLWithPath: args[i + 1]), out = URL(fileURLWithPath: args[i + 2])
            Task { await cleanupTest(input, to: out); exit(0) }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--caret-probe"), i + 1 < args.count {
            // Prints only the code points just before the cursor in the named app (no full text).
            let name = args[i + 1]
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
                ChromiumAccess.enable(for: app, element: AXUIElementCreateApplication(app.processIdentifier))
                RunLoop.main.run(until: .now + 1)
                let before = CaretContext.textBefore(pid: app.processIdentifier) ?? "(unreadable)"
                let tail = before.unicodeScalars.suffix(6).map { String(format: "U+%04X", $0.value) }
                print("length \(before.count), last code points: \(tail.joined(separator: " "))")
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--sync-names"), i + 1 < args.count {
            // Runs the Wikidata sync and copies the result out (used to make the bundled copy).
            let out = URL(fileURLWithPath: args[i + 1])
            Task {
                do {
                    let store = try await WorldNames.refresh()
                    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try e.encode(store).write(to: out)
                } catch { try? "failed: \(error)".write(to: out, atomically: true, encoding: .utf8) }
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--dictionary-test"), i + 1 < args.count {
            dictionaryTest(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--soak"), i + 3 < args.count {
            let minutes = Double(args[i + 1]) ?? 30
            let audio = URL(fileURLWithPath: args[i + 2]), out = URL(fileURLWithPath: args[i + 3])
            Task { await soak(minutes: minutes, audio: audio, out: out); exit(0) }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--menu-icons"), i + 1 < args.count {
            // Draws every menu bar icon (at rest and recording) at 4x on one strip.
            let out = NSImage(size: NSSize(width: 8 * 80, height: 80))
            out.lockFocus()
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 640, height: 80).fill()
            for (n, icon) in MenuBarIcon.allCases.enumerated() {
                for (m, rec) in [false, true].enumerated() {
                    icon.image(recording: rec).draw(in: NSRect(x: (n * 2 + m) * 80 + 4, y: 4, width: 72, height: 72))
                }
            }
            out.unlockFocus()
            if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--list-test"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            Task { await listTest(to: out); exit(0) }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--model-check"), i + 2 < args.count {
            let links = args[i + 1].components(separatedBy: ","), out = URL(fileURLWithPath: args[i + 2])
            Task {
                var md = "| Link | Result |\n|---|---|\n"
                for link in links {
                    let r = await ModelCatalog.check(link, model: "", apiKey: "")
                    let text: String = switch r {
                    case .known(let m): "known: \(m.name)"
                    case .server(let m): "server OK: \(m.detail)"
                    case .unsupported(let why): "not added: \(why)"
                    }
                    md += "| \(link) | \(text) |\n"
                }
                if let server = links.first(where: { $0.contains("127.0.0.1") }) {
                    let t = ServerTranscriber(baseURL: server, model: "whisper-1")
                    let reply = (try? await t.transcribe([Float](repeating: 0.1, count: 16000))) ?? "(failed)"
                    md += "| transcribe via \(server) | \(reply) |\n"
                }
                try? md.write(to: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--file-test"), i + 2 < args.count {
            let files = args[i + 1].components(separatedBy: ","), out = URL(fileURLWithPath: args[i + 2])
            Task {
                let controller = DictationController()
                var md = "| File | Seconds | Text |\n|---|---|---|\n"
                for f in files {
                    let t0 = Date.now
                    let text = (try? await controller.transcribeFile(URL(fileURLWithPath: f))) ?? "(error)"
                    md += "| \((f as NSString).lastPathComponent) | \(String(format: "%.2f", Date.now.timeIntervalSince(t0))) | \(text) |\n"
                }
                try? md.write(to: out, atomically: true, encoding: .utf8)
                exit(0)
            }
            RunLoop.main.run()
        }
        if let i = args.firstIndex(of: "--widget-test"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.async { Task { await widgetTest(in: dir); exit(0) } }
        }
        if let i = args.firstIndex(of: "--insert-test"), i + 1 < args.count {
            let out = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.async { Task { await insertTest(to: out); exit(0) } }
        }
    }

    /// `--widget-test <dir>`: show the real widget with a simulated voice, save each state as a
    /// PNG, and record where it was placed relative to the focused text box.
    private static func widgetTest(in dir: URL) async {
        let widget = WidgetPanel()
        let start = Date.now
        widget.model.levelSource = { Float(0.55 + 0.4 * sin(Date.now.timeIntervalSince(start) * 9)) }
        widget.show(.recording(started: start.addingTimeInterval(-12)), follow: true)
        try? await Task.sleep(for: .milliseconds(1500))
        let snap = FocusInspector.snapshot()
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: widget.frame.midX, y: widget.frame.midY)) }
        try? widget.snapshotPNG()?.write(to: dir.appendingPathComponent("widget-recording.png"))
        let ownersChoice = UserDefaults.standard.string(forKey: "waveStyle")   // shared with the real app
        for style in CombWave.Style.allCases where style != .comb {
            UserDefaults.standard.set(style.rawValue, forKey: "waveStyle")
            widget.show(.transcribing); try? await Task.sleep(for: .milliseconds(100))
            widget.show(.recording(started: start.addingTimeInterval(-12)))
            try? await Task.sleep(for: .milliseconds(700))
            try? widget.snapshotPNG()?.write(to: dir.appendingPathComponent("widget-\(style.rawValue).png"))
        }
        if let ownersChoice { UserDefaults.standard.set(ownersChoice, forKey: "waveStyle") }
        else { UserDefaults.standard.removeObject(forKey: "waveStyle") }
        widget.show(.transcribing)
        try? await Task.sleep(for: .milliseconds(600))
        try? widget.snapshotPNG()?.write(to: dir.appendingPathComponent("widget-transcribing.png"))
        for i in 1...4 {   // a few frames across the cleanup loop, to check it never restarts visibly
            try? await Task.sleep(for: .milliseconds(400))
            try? widget.snapshotPNG()?.write(to: dir.appendingPathComponent("widget-transcribing-\(i).png"))
        }
        widget.show(.done(app: "Mail"))
        try? await Task.sleep(for: .milliseconds(300))
        try? widget.snapshotPNG()?.write(to: dir.appendingPathComponent("widget-done.png"))
        widget.showIdle()
        try? await Task.sleep(for: .milliseconds(300))
        try? widget.snapshotPNG()?.write(to: dir.appendingPathComponent("widget-idle.png"))
        widget.model.hovered = true
        try? await Task.sleep(for: .milliseconds(400))
        try? widget.snapshotPNG()?.write(to: dir.appendingPathComponent("widget-hover.png"))
        widget.model.hint = "Clean up is on: removes ums, fixes numbers. Click to turn off."
        try? await Task.sleep(for: .milliseconds(400))
        try? widget.snapshotPNG()?.write(to: dir.appendingPathComponent("widget-hint.png"))
        widget.model.hint = nil
        widget.model.hovered = false
        widget.model.latched = true
        widget.model.dropTarget = "Gmail"
        widget.show(.recording(started: .now))
        try? await Task.sleep(for: .milliseconds(400))
        try? widget.snapshotPNG()?.write(to: dir.appendingPathComponent("widget-handsfree.png"))
        widget.model.dropTarget = nil
        widget.model.latched = false
        widget.show(.holding("Can we push the review to Thursday? I want to fold in the survey results first, and the last batch lands Wednesday night."))
        try? await Task.sleep(for: .milliseconds(400))
        try? widget.snapshotPNG()?.write(to: dir.appendingPathComponent("widget-holding.png"))
        widget.show(.dropPrompt(app: "Messages"))
        try? await Task.sleep(for: .milliseconds(400))
        try? widget.snapshotPNG()?.write(to: dir.appendingPathComponent("widget-drop.png"))
        writeJSON(["frontApp": snap?.app ?? "?", "focusedRole": snap?.role ?? "?", "isTextBox": snap?.isTextInput ?? false,
                   "focusScreen": snap?.screen ?? "?", "widgetScreen": screen?.localizedName ?? "?",
                   "widgetFrame": NSStringFromRect(widget.frame),
                   "caret": snap?.caretBounds.map { NSStringFromRect($0) } ?? "none",
                   "box": snap?.frame.map { NSStringFromRect($0) } ?? "none"],
                  to: dir.appendingPathComponent("widget-test.json"))
    }

    /// `--compare-models <folder of .wav> <out.md>`: transcribe every recording with each Parakeet
    /// version and write a side-by-side table (downloads each model the first time).
    private static func compareModels(_ dir: URL, to out: URL, ids: [String]? = nil) async {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let models = (ids ?? ModelCatalog.builtIn.filter { if case .parakeet = $0.kind { true } else { false } }.map(\.id))
            .map(ModelCatalog.model)
        var md = "| Clip | " + models.map(\.name).joined(separator: " | ") + " |\n|---|" + models.map { _ in "---|" }.joined() + "\n"
        var columns: [[String]] = []
        for m in models {
            let t = ModelCatalog.makeTranscriber(m)
            do {
                let loadStart = Date.now
                try await t.prepare { _ in }
                let load = Date.now.timeIntervalSince(loadStart)
                var col: [String] = []
                for f in files {
                    let started = Date.now
                    let samples = (try? AudioConverter().resampleAudioFile(path: f.path)) ?? []
                    let text = (try? await t.transcribe(samples)) ?? "(error)"
                    col.append(text + String(format: " *(%.2f s)*", Date.now.timeIntervalSince(started)))
                }
                col[0] = String(format: "[load %.1f s] ", load) + col[0]
                columns.append(col)
            } catch {
                columns.append(files.map { _ in "(model failed: \(error.localizedDescription))" })
            }
            await t.unload()
        }
        for (i, f) in files.enumerated() {
            md += "| \(f.deletingPathExtension().lastPathComponent) | " + columns.map { $0[i].replacingOccurrences(of: "|", with: "/") }.joined(separator: " | ") + " |\n"
        }
        try? md.write(to: out, atomically: true, encoding: .utf8)
    }

    /// `--cleanup-test <lines.txt> <out.md>`: each line is "raw" or "text before cursor ||| raw".
    /// Runs the cleanup and spacing exactly as dictation does and tabulates the results.
    private static func cleanupTest(_ input: URL, to out: URL) async {
        let lines = ((try? String(contentsOf: input, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        let cleaner = Cleaner()
        cleaner.prewarm()                                   // as the app does at launch
        try? await Task.sleep(for: .seconds(3))
        var md = "Apple on-device model available: \(Cleaner.isAvailable)\n\n| Before cursor | Heard | Inserted | Cleaned | Model said (if rejected) | Seconds |\n|---|---|---|---|---|---|\n"
        for line in lines where !line.isEmpty {
            let parts = line.components(separatedBy: " ||| ")
            let before = parts.count > 1 ? parts[0] : nil
            let raw = parts.last!
            cleaner.prewarm()
            try? await Task.sleep(for: .milliseconds(300))   // roughly the time you'd still be talking
            let r = await cleaner.clean(ClockTimes.normalize(Temperatures.normalize(SpokenDigits.normalize(Fillers.remove(raw)))), before: before, appBundleID: "com.apple.mail")
            let final = CaretContext.join(r.text, after: before)
            md += "| \(before.map { "«\($0)»" } ?? "") | \(raw) | «\(final)» | \(r.cleaned ? "yes" : "no") | \(r.cleaned ? "" : (r.modelText ?? "")) | \(String(format: "%.2f", r.seconds)) |\n"
        }
        try? md.write(to: out, atomically: true, encoding: .utf8)
    }

    /// `--dictionary-test <out.md>`: replacement and learning decisions on fixed cases, using the
    /// starter and common-name lists (not the owner's saved dictionary).
    private static func dictionaryTest(to out: URL) {
        typealias C = WordDictionary.Candidate
        var candidates: [C] = []
        for (t, h) in WordDictionary.starter { candidates.append(C(term: t, form: t, fuzzy: true)); h.forEach { candidates.append(C(term: t, form: $0)) } }
        for (t, h) in WordDictionary.commonNames { candidates.append(C(term: t, form: t)); h.forEach { candidates.append(C(term: t, form: $0)) } }
        let world = WorldNames.load()?.names ?? []
        for n in world { candidates.append(C(term: n, form: n, guarded: true)) }
        var md = "Synced names loaded: \(world.count)\n\n## Replacement\n\n| Heard | Written |\n|---|---|\n"
        for line in [
            "The fluid audio's release notes are out.", "The fluid audio repo has a new release.",
            "Restart the N8N container, then check fluid audio.", "Send it on linked in or what's app.",
            "This project is due Friday.", "Can you zoom in on the outlook slide?", "I used chat gpt and open ai today.",
            "Check fluid audio's new release.", "My iphone and mac book died.",
            "I paid with pay pal on e bay.", "Give me my space please.", "I use duolingo and spotify every day.",
            "Did you see the space x launch?", "The blogger wrote about the uber driver.",
        ] {
            md += "| \(line) | \(WordDictionary.replace(in: line, candidates: candidates).0) |\n"
        }
        md += "\n## Learning from edits\n\n| Typed | After your edit | Learned |\n|---|---|---|\n"
        let checker = NSSpellChecker.shared
        func isWord(_ w: String) -> Bool { w.split(separator: " ").allSatisfy { checker.checkSpelling(of: $0.lowercased(), startingAt: 0).location == NSNotFound } }
        for (typed, edited) in [
            ("Open the figma file.", "Open the Figma file."),
            ("I spoke to leaner about it.", "I spoke to Lena about it."),
            ("Let's meet on Thursday.", "Let's meet on Friday."),
            ("Put it over their.", "Put it over there."),
            ("The I feel like it's slow.", "Then I feel like it's slow."),
            ("It costs 40 dollars.", "It costs 45 dollars."),
            ("Check fluid audio now.", "Check FluidAudio now."),
            ("Ask nate n about it.", "Ask n8n about it."),
            ("Send it to Sam.", "Send it to Sam tonight, thanks."),
        ] {
            let swaps = EditLearner.corrections(from: typed, to: edited).filter { !(EditLearner.isPlainWordSwap(heard: $0.heard, correct: $0.correct) && isWord($0.heard) && isWord($0.correct)) }
            md += "| \(typed) | \(edited) | \(swaps.isEmpty ? "nothing" : swaps.map { "\($0.heard) → \($0.correct)" }.joined(separator: "; ")) |\n"
        }
        try? md.write(to: out, atomically: true, encoding: .utf8)
    }

    /// `--soak <minutes> <audio.wav> <out.md>`: the long-running check. Every 20 s, transcribe,
    /// clean up and apply the dictionary as a dictation would; record memory every minute.
    private static func soak(minutes: Double, audio: URL, out: URL) async {
        let t = ParakeetTranscriber(), cleaner = Cleaner(), dictionary = WordDictionary()
        try? await t.prepare { _ in }
        var md = "| Minute | Footprint MB | Dictations |\n|---|---|---|\n"
        let start = Date.now
        var count = 0, nextSample = 0.0
        while Date.now.timeIntervalSince(start) < minutes * 60 {
            let elapsed = Date.now.timeIntervalSince(start)
            if elapsed >= nextSample {
                md += "| \(Int(elapsed / 60)) | \(MemoryWatch.footprint() / 1_000_000) | \(count) |\n"
                try? md.write(to: out, atomically: true, encoding: .utf8)
                nextSample += 60
            }
            if let raw = try? await t.transcribe(file: audio) {
                cleaner.prewarm()
                let text = dictionary.apply(to: SpokenDigits.normalize(Fillers.remove(raw + " Um, like, seventy five Main Street.")), app: "Mail").0
                _ = await cleaner.clean(text, before: nil, appBundleID: "com.apple.mail")
                count += 1
            }
            try? await Task.sleep(for: .seconds(20))
        }
        md += "| end | \(MemoryWatch.footprint() / 1_000_000) | \(count) |\n"
        try? md.write(to: out, atomically: true, encoding: .utf8)
    }

    /// `--list-test <out.md>`: the same speech formatted for an email app and a chat app, plus
    /// snippet expansion (with a temporary in-memory snippet, not the owner's).
    private static func listTest(to out: URL) async {
        let cleaner = Cleaner()
        cleaner.prewarm()
        try? await Task.sleep(for: .seconds(3))
        var md = "| Spoken | Mail | Claude |\n|---|---|---|\n"
        for raw in [
            "For the offsite I need three things. First, book the room. Second, order lunch. Third, send the agenda.",
            "The plan is one, finish the deck, two, send it to Sam, three, book the call.",
            "Can you check the numbers and send them over tonight?",
        ] {
            let mail = await cleaner.clean(raw, before: nil, appBundleID: "com.apple.mail", style: .document)
            cleaner.prewarm()
            let chat = await cleaner.clean(raw, before: nil, appBundleID: "com.anthropic.claudefordesktop", style: .chat)
            cleaner.prewarm()
            func cell(_ t: String) -> String { t.replacingOccurrences(of: "\n", with: "<br>") }
            md += "| \(raw) | \(cell(mail.text)) | \(cell(chat.text)) |\n"
        }
        md += "\n| Snippet test | Result |\n|---|---|\n"
        let snippets = Snippets()
        let trial = Snippets.Snippet(trigger: "my email", text: "you@example.com")
        for line in ["Send it to my email please.", "Check my emails tonight.", "My email."] {
            md += "| \(line) | \(snippets.expandWith([trial], line)) |\n"
        }
        try? md.write(to: out, atomically: true, encoding: .utf8)
    }

    private static func writeJSON(_ dict: [String: Any], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    /// `--transcribe <audio> <out.json>`: load the model (downloading it the first time) and
    /// transcribe a file, recording how long each step took.
    private static func transcribeFile(_ input: URL, to out: URL) async {
        let t = ParakeetTranscriber()
        do {
            let t0 = Date.now
            try await t.prepare { _ in }
            let t1 = Date.now
            let text = try await t.transcribe(file: input)
            let t2 = Date.now
            let again = try await t.transcribe(file: input)   // warm run
            writeJSON(["text": text, "loadSeconds": t1.timeIntervalSince(t0),
                       "coldTranscribeSeconds": t2.timeIntervalSince(t1),
                       "warmTranscribeSeconds": Date.now.timeIntervalSince(t2), "warmText": again], to: out)
        } catch {
            writeJSON(["error": error.localizedDescription], to: out)
        }
    }

    /// `--insert-test <out.json>`: paste into a text box in Fluent's own window and check that
    /// the text arrived and the clipboard came back unchanged. Refuses to paste if another app
    /// is in front, so it can never type into the owner's apps.
    private static func insertTest(to out: URL) async {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Fluent insert test"
        let textView = NSTextView(frame: window.contentLayoutRect)
        window.contentView = textView
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        try? await Task.sleep(for: .milliseconds(800))

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              window.isKeyWindow else {
            writeJSON(["error": "Fluent could not come to the front; nothing was pasted"], to: out)
            return
        }
        let pb = NSPasteboard.general
        func clipboardFingerprint() -> [[String]] {
            pb.pasteboardItems?.map { item in item.types.map { "\($0.rawValue):\(item.data(forType: $0)?.hashValue ?? 0)" } } ?? []
        }
        let before = clipboardFingerprint()
        let changeBefore = pb.changeCount

        // 1. Direct insertion: must not touch the clipboard at all.
        let direct = "Typed directly, 1 2 3."
        let result = await Inserter.insert(direct)
        try? await Task.sleep(for: .milliseconds(300))
        let directOK = textView.string == direct
        let clipboardUntouched = pb.changeCount == changeBefore

        // 2. Clipboard fallback on its own: text arrives and the clipboard content comes back.
        textView.string = ""
        let pasted = "Pasted, 4 5 6."
        _ = await Inserter.paste(pasted)
        try? await Task.sleep(for: .milliseconds(300))
        let pasteOK = textView.string == pasted
        let after = clipboardFingerprint().map { $0.filter { !$0.hasPrefix("org.nspasteboard.") } }
        let beforeClean = before.map { $0.filter { !$0.hasPrefix("org.nspasteboard.") } }
        writeJSON(["directInserted": directOK, "directMethod": result?.method.rawValue ?? "none",
                   "directLeftClipboardUntouched": clipboardUntouched,
                   "pasteInserted": pasteOK, "pasteRestoredClipboardContent": beforeClean == after,
                   "clipboardBefore": beforeClean.map { $0.map { String($0.prefix(40)) } }, "clipboardAfter": after.map { $0.map { String($0.prefix(40)) } },
                   "textViewNow": textView.string], to: out)
    }

    /// `--capture-window <path>`: once the setup window is on screen, draw it to a PNG and quit.
    /// An app may render its own windows without screen-recording permission.
    static func captureWindowIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--capture-window"), i + 1 < args.count else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Fluent" }),
               let view = window.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                // Draw in the window's own light or dark appearance, or text comes out the wrong colour.
                window.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            exit(0)
        }
    }

    /// `--probe-apps <path>`: for every running app with a window, switch on its accessibility
    /// tree, wait, and record what it reports as focused. Read-only apart from that switch.
    private static func probeApps(to url: URL) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        for _ in 0..<2 {   // second pass lets the fallback switch take effect
            for app in apps { _ = FocusInspector.snapshot(of: app) }
            RunLoop.main.run(until: .now + 2)   // give Chromium time to build its tree
        }
        let rows = apps.map { app -> String in
            let state: String = switch FocusProbe.state(pid: app.processIdentifier) {
            case .textBox: "type"; case .notText: "HOLD"; case .unknown: "type (unknown)"
            }
            return FocusInspector.snapshot(of: app).markdownRow + " \(state) |"
        }
        let header = FocusSnapshot.markdownHeader.replacingOccurrences(of: "| Screen |", with: "| Screen | Fluent would |")
            .replacingOccurrences(of: "|---|---|---|---|---|---|---|---|---|", with: "|---|---|---|---|---|---|---|---|---|---|")
        let body = ([header] + rows).joined(separator: "\n") + "\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    static func saveReport(_ markdown: String) -> URL? {
        let url = supportDir.appendingPathComponent("text-box-check.md")
        let body = "# Text box check, \(Date.now.formatted())\n\n\(markdown)\n"
        return (try? body.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    private static func writePermissionReport(to url: URL) {
        let mic: String = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "granted"
        case .notDetermined: "notAsked"
        default: "denied"
        }
        let report: [String: String] = [
            "microphone": mic,
            "accessibility": AXIsProcessTrusted() ? "granted" : "denied",
            "inputMonitoring": CGPreflightListenEventAccess() ? "granted" : "denied",
            "bundlePath": Bundle.main.bundlePath,
            "time": ISO8601DateFormatter().string(from: .now),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}
