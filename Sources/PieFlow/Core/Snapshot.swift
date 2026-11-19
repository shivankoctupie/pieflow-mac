import AppKit
import SwiftUI

/// `PIEFLOW_HOME=/tmp/x PieFlow --snapshot <dir>` renders every screen to PNG for visual QA.
/// Demo data is seeded only into the throwaway PIEFLOW_HOME, never into real user data.
enum Snapshot {
    static var outDir: URL? {
        guard let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    }

    static func seed(_ store: Store) {
        guard ProcessInfo.processInfo.environment["PIEFLOW_HOME"] != nil else { return }
        let cal = Calendar.current
        let samples: [(String, String, String)] = [
            ("Whenever the trial ends or they hit a limit, we should show a dialog with all the plans they can pick, plus an option to skip and keep using the free tier. What do you think?", "Claude", "com.anthropic.claudefordesktop"),
            ("What screen do the users see when their trial has ended?", "Claude", "com.anthropic.claudefordesktop"),
            ("hey are you free for lunch tomorrow? let's do 12 if that works", "WhatsApp", "net.whatsapp.WhatsApp"),
            ("Can we move the design review to Thursday afternoon? I need one more day on the onboarding flow.", "Slack", "com.tinyspeck.slackmacgap"),
            ("Hi Priya, thanks for the quick turnaround. The numbers look right to me, let's lock the plan for next week.", "Mail", "com.apple.mail"),
            ("Refactor the settings store so every field decodes with a default, then add a test for an old settings file.", "Cursor", "com.todesktop.cursor"),
            ("Notes for the launch: pricing page, demo video, and a short FAQ about local models.", "Notes", "com.apple.Notes"),
        ]
        var history: [DictationEntry] = []
        for d in 0..<24 where d % 5 != 3 {
            for k in 0..<(1 + d % 3) {
                let s = samples[(d + k) % samples.count]
                let date = cal.date(byAdding: .minute, value: -(d * 1440 + k * 37 + 20), to: Date())!
                history.append(DictationEntry(rawText: s.0, text: s.0, appName: s.1, bundleID: s.2,
                                              category: AppCategory.from(bundleID: s.2, appName: s.1),
                                              durationSec: Double(s.0.split(separator: " ").count) / 2.6, engine: ["Grok", "Groq", "Local"][k % 3]))
            }
        }
        store.history = history.sorted { $0.date > $1.date }
        store.fixesCount = 214
        store.dictionary = [DictionaryWord(word: "PieFlow", misheard: ["pie flow"]), DictionaryWord(word: "Octupie", misheard: ["octopie"]),
                            DictionaryWord(word: "Groq"), DictionaryWord(word: "SwiftUI")]
        store.snippets = [Snippet(trigger: "my email address", expansion: "me@example.com"),
                          Snippet(trigger: "my calendar link", expansion: "https://cal.com/your-name/30min"),
                          Snippet(trigger: "organize thoughts prompt", expansion: "Organize these unstructured thoughts into a clear, polished version without losing any detail.")]
        var launch = Note(title: "Launch checklist", body: "Pricing page\nDemo video\nFAQ on local models")
        if let icon = NSImage(named: NSImage.applicationIconName), let name = NoteImages.save(icon) { launch.images = [name] }
        store.notes = [launch, Note(title: "Hiring thoughts", body: "Need one designer who can also write.")]
        var m = Meeting(title: "Weekly product sync")
        m.started = cal.date(byAdding: .day, value: -1, to: Date())!
        m.durationSec = 1860
        m.status = .ready
        m.segments = [TranscriptSegment(start: 3, end: 9, speaker: "You", text: "Let's start with the onboarding numbers."),
                      TranscriptSegment(start: 10, end: 21, speaker: "Others", text: "Completion went up to 64 percent after we cut the permissions step."),
                      TranscriptSegment(start: 22, end: 30, speaker: "You", text: "Great. Next is the pricing page, I want it live by Friday.")]
        m.summary = "## Summary\nThe team reviewed onboarding and pricing. Onboarding completion rose to 64 percent after the permissions step was simplified. Pricing page goes live Friday.\n\n## Action items\n- [ ] You: ship the pricing page by Friday\n- [ ] Others: share the onboarding funnel dashboard\n\n## Key points\n- Fewer setup steps lifted completion\n- Pricing copy needs one more review"
        store.meetings = [m]
        store.settings.onboarded = true
        store.settings.userName = "Shivank"
    }

    static func capture(_ window: NSWindow, _ name: String, to dir: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        print("snapshot \(name)")
    }

    /// Scrolls every scroll view in the window to its end. False when nothing had further to go.
    static func scrollToEnd(_ window: NSWindow) -> Bool {
        var moved = false
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, let doc = scroll.documentView {
                let room = doc.frame.height - scroll.contentView.bounds.height
                if room > 1 {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? room : 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    moved = true
                }
            }
            view.subviews.forEach(visit)
        }
        if let root = window.contentView { visit(root) }
        return moved
    }

    static func run(_ app: AppDelegate, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var steps: [(String, () -> Void)] = []
        for p in Page.allCases {
            steps.append(("page-\(p.rawValue)", { app.router.page = p; app.router.openMeeting = nil }))
        }
        steps.append(("meeting-detail", { app.router.page = .notetaker; app.router.openMeeting = app.store.meetings.first?.id }))
        steps.append(("note-with-image", {
            app.router.openMeeting = nil; app.router.page = .scratchpad
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NotificationCenter.default.post(name: .openFirstNote, object: nil) }
        }))
        steps.append(("insights-voice", { app.router.openMeeting = nil; app.router.page = .insights; app.router.insightsTab = 1 }))
        for t in SettingsTab.allCases {
            steps.append(("settings-\(t.rawValue)", { app.router.insightsTab = 0; app.router.settingsTab = t; app.router.showSettings = true }))
        }
        var i = 0
        func next() {
            guard i < steps.count else {
                app.router.showSettings = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { snapOnboarding(app, dir: dir) }
                return
            }
            let (name, action) = steps[i]
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if name.hasPrefix("settings"), let sheet = app.window?.attachedSheet {
                    capture(sheet, name, to: dir)
                    // A settings tab can be taller than the sheet: take its lower end too, or the rows
                    // past the fold are never looked at.
                    if scrollToEnd(sheet) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            capture(sheet, name + "-end", to: dir)
                            i += 1
                            next()
                        }
                        return
                    }
                } else if let w = app.window { capture(w, name, to: dir) }
                i += 1
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { next() }
    }

    static func snapOnboarding(_ app: AppDelegate, dir: URL) {
        app.window?.orderOut(nil)
        app.showOnboarding()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let w = app.onboarding { capture(w, "onboarding-1", to: dir) }
            print("SNAPSHOT DONE")
            exit(0)
        }
    }
}

/// `PIEFLOW_HOME=/tmp/x PIEFLOW_ONBOARD_STEP=3 PieFlow --focus-test`
/// Regression test for "cannot paste API key": focuses the Groq key field, waits 3 s, checks it kept
/// focus, then pastes from the clipboard and checks the key was stored.
enum FocusTest {
    static func secureFields(in view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        for v in view.subviews {
            if let f = v as? NSSecureTextField { out.append(f) }
            out += secureFields(in: v)
        }
        return out
    }

    static func run(_ app: AppDelegate) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let w = app.onboarding, let root = w.contentView else { print("FAIL no onboarding window"); exit(1) }
            let fields = secureFields(in: root)
            print("secure fields found: \(fields.count)")
            guard fields.count >= 2 else { print("FAIL key fields not found"); exit(1) }
            let groq = fields[1]
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            w.makeFirstResponder(groq)
            func editingGroq() -> Bool {
                guard let editor = w.firstResponder as? NSText else { return false }
                return (editor.delegate as? NSTextField) === groq && groq.window != nil
            }
            print("focused right after click: \(editingGroq())")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let still = editingGroq()
                print("still focused after 3 s: \(still)")
                print("app active: \(NSApp.isActive), window key: \(w.isKeyWindow)")
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let stored = app.store.keys.groq
                    let expected = NSPasteboard.general.string(forType: .string) ?? ""
                    print("stored key matches clipboard: \(stored == expected && !stored.isEmpty)")
                    print(still && stored == expected && !stored.isEmpty ? "FOCUS TEST PASS" : "FOCUS TEST FAIL")
                    exit(still ? 0 : 1)
                }
            }
        }
    }
}

/// `PIEFLOW_FAKE_VERSION=0.9.0 PieFlow --update-test`: runs the real update path against the live
/// GitHub release (check, download, checksum, swap, relaunch) and logs each step to pieflow.log.
enum UpdateTest {
    static func run(_ app: AppDelegate) {
        Log.write("update-test start, pretending to be \(Updater.currentVersion) at \(Bundle.main.bundlePath)")
        app.updater.check(userInitiated: true)
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
            ticks += 1
            switch app.updater.state {
            case .available(let r):
                Log.write("update-test found \(r.version), installing")
                app.updater.installAvailable()
            case .upToDate:
                Log.write("update-test RESULT: already up to date, nothing to install"); t.invalidate(); exit(0)
            case .failed(let m):
                Log.write("update-test RESULT: FAIL \(m)"); t.invalidate(); exit(1)
            default:
                if ticks > 600 { Log.write("update-test RESULT: FAIL timeout"); exit(1) }
            }
        }
    }
}

/// `PieFlow --bar-test [dir]`: the Flow Bar must stay on screen when the app is hidden and when its
/// window is closed, the Dock icon must follow the window, and dictation must start without a Dock icon.
/// With a directory, it also saves pictures of the pill in each state.
enum BarTest {
    /// Asks the window server, not AppKit, whether the bar is really on screen.
    static func barOnScreen() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == me && ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)) }
    }

    static func run(_ app: AppDelegate, dir: URL?) {
        var ok = true
        func check(_ name: String, _ pass: Bool) {
            let line = "bar-test \(pass ? "PASS" : "FAIL") \(name)"
            print(line); Log.write(line); ok = ok && pass
        }
        func after(_ seconds: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }
        func shot(_ name: String) {
            guard let dir, let frame = app.flowBar.frame, let screen = NSScreen.screens.first,
                  let full = CGDisplayCreateImage(CGMainDisplayID()) else { return }
            let scale = CGFloat(full.width) / screen.frame.width
            let rect = CGRect(x: frame.minX * scale, y: (screen.frame.height - frame.maxY) * scale, width: frame.width * scale, height: frame.height * scale)
            guard let crop = full.cropping(to: rect) else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        app.showMain()
        after(1.2) {
            check("window open: PieFlow is in the Dock", NSApp.activationPolicy() == .regular)
            check("Flow Bar on screen", barOnScreen())
            NSApp.hide(nil)
            after(1.0) {
                check("app is hidden", NSApp.isHidden)
                check("Flow Bar still on screen while the app is hidden", barOnScreen())
                NSApp.unhide(nil)
                after(0.6) {
                    app.window?.performClose(nil)
                    after(0.8) {
                        check("window closed: PieFlow left the Dock", NSApp.activationPolicy() == .accessory)
                        check("Flow Bar on screen with no Dock icon", barOnScreen())
                        shot("pill-idle")
                        app.dictation.begin(handsFree: false)
                        after(1.0) {
                            check("dictation starts with no Dock icon, pill on screen", app.dictation.isRecording && barOnScreen())
                            shot("pill-hold")
                            app.dictation.level.pinned = 0.6
                            after(0.5) {
                              shot("pill-speaking")
                              app.dictation.level.pinned = nil
                              app.dictation.cancel(silent: true)
                              after(0.5) {
                                app.dictation.begin(handsFree: true)
                                after(1.0) {
                                    shot("pill-handsfree")
                                    app.dictation.cancel(silent: false)
                                    after(0.5) {
                                        shot("pill-message")
                                        app.showMain()
                                        after(0.8) {
                                            check("window reopened: back in the Dock", NSApp.activationPolicy() == .regular)
                                            let verdict = ok ? "BAR TEST PASS" : "BAR TEST FAIL"
                                            print(verdict); Log.write("bar-test " + verdict)
                                            after(0.3) { exit(ok ? 0 : 1) }
                                        }
                                    }
                                }
                              }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// `PieFlow --bar-drag-test [dir]`: the Flow Bar can be dragged anywhere, stays put, and a plain click
/// still works. Runs without the app itself (no hotkey, no microphone, no second instance), sends the
/// panel its own mouse events and scripts the mouse position, so the real pointer never moves. Nothing
/// is saved. With a directory, it also saves a picture of the pill at the dragged spot.
enum BarDragTest {
    static func run() -> Int32 {
        Store.writesToDisk = false
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Theme.registerFonts()
        let store = Store.shared
        var clean = store.settings
        clean.flowBarX = nil; clean.flowBarY = nil; clean.showFlowBar = true
        store.settings = clean
        let llm = LLM(store: store)
        let dictation = DictationController(store: store, transcriber: Transcriber(store: store), engine: TextEngine(store: store, llm: llm))
        guard let screen = NSScreen.main else { print("bar-drag-test FAIL no screen"); return 1 }
        let vf = screen.visibleFrame
        var mouse = NSPoint(x: vf.midX, y: vf.minY + 20)
        var taps = 0
        let bar = FlowBarController(dictation: dictation, store: store)
        bar.mouseLocation = { mouse }
        bar.onTap = { taps += 1 }
        var ok = true
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            print("bar-drag-test \(pass ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : "  [\(detail)]")"); ok = ok && pass
        }
        func spin(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func near(_ a: NSPoint, _ b: NSPoint, _ tolerance: CGFloat = 1.5) -> Bool { abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance }
        func show(_ p: NSPoint) -> String { String(format: "%.0f, %.0f", p.x, p.y) }
        func anchor(_ b: FlowBarController = bar) -> NSPoint { FlowBarLayout.anchor(of: b.frame ?? .zero) }
        func window(_ b: FlowBarController = bar) -> NSWindow? {
            NSApp.windows.first { $0.frame == b.frame && $0 is FlowBarPanel }
        }
        /// A mouse event at the scripted pointer position, delivered straight to the panel.
        func send(_ type: NSEvent.EventType, clicks: Int = 1) {
            guard let w = window(), let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: mouse.x - w.frame.minX, y: mouse.y - w.frame.minY),
                                                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                                               context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) else { return }
            w.sendEvent(e)
            spin(0.03)
        }
        /// Press on the pill, travel to `target` in steps, let go.
        func dragPill(to target: NSPoint, steps: Int = 12) {
            let start = NSPoint(x: anchor().x, y: anchor().y + 14)
            mouse = start
            send(.leftMouseDown)
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                mouse = NSPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t)
                send(.leftMouseDragged)
            }
            send(.leftMouseUp)
            spin(0.3)
        }

        bar.show()
        spin(0.8)
        let home = FlowBarLayout.defaultAnchor(in: vf)
        check("starts at the bottom centre", near(anchor(), home), show(anchor()))

        // 1. A plain click still reaches the pill.
        mouse = NSPoint(x: home.x, y: home.y + 14)
        send(.leftMouseDown); send(.leftMouseUp); spin(0.4)
        check("a click on the pill still counts as a click", taps == 1, "clicks \(taps)")
        check("a click does not move it", near(anchor(), home), show(anchor()))

        // 2. Drag it up and to the right.
        let target = NSPoint(x: vf.minX + vf.width * 0.72, y: vf.minY + vf.height * 0.55)
        dragPill(to: target)
        let dropped = anchor()
        check("the pill follows the drag", near(dropped, NSPoint(x: target.x, y: target.y - 14), 3), "at \(show(dropped)), pointer let go at \(show(target))")
        check("a drag is not taken for a click", taps == 1, "clicks \(taps)")
        check("the spot is remembered", store.settings.flowBarX != nil && store.settings.flowBarY != nil,
              String(format: "%.3f, %.3f", store.settings.flowBarX ?? -1, store.settings.flowBarY ?? -1))
        if let dir = CommandLine.arguments.firstIndex(of: "--bar-drag-test").flatMap({ $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }),
           let frame = bar.frame, let full = CGDisplayCreateImage(CGMainDisplayID()) {
            let scale = CGFloat(full.width) / screen.frame.width
            let area = frame.insetBy(dx: -120, dy: -60)
            let rect = CGRect(x: area.minX * scale, y: (screen.frame.height - area.maxY) * scale, width: area.width * scale, height: area.height * scale)
            if let crop = full.cropping(to: rect) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("pill-dragged.png"))
            }
        }

        // 3. It stays there: when a dictation starts, and after a restart.
        mouse = NSPoint(x: vf.midX, y: vf.midY)
        bar.position()
        check("stays put when a dictation starts", near(anchor(), dropped), show(anchor()))
        let again = FlowBarController(dictation: dictation, store: store)
        again.mouseLocation = { mouse }
        again.show(); spin(0.3)
        check("comes back to the same spot after a restart", near(anchor(again), dropped), show(anchor(again)))

        // 4. It cannot be dragged off the screen.
        dragPill(to: NSPoint(x: vf.maxX + 600, y: vf.maxY + 600))
        let corner = anchor()
        check("stops at the screen edge", near(corner, NSPoint(x: vf.maxX - FlowBarLayout.sideMargin, y: vf.maxY - FlowBarLayout.topMargin)), show(corner))
        check("whole pill still on screen", vf.contains(NSRect(x: corner.x - 60, y: corner.y, width: 120, height: 48)))

        // 5. Dropped next to the bottom centre, it goes home and the saved spot is cleared.
        dragPill(to: NSPoint(x: home.x + 12, y: home.y + 14 + 10))
        check("dropped near the bottom centre, it snaps back", near(anchor(), home) && store.settings.flowBarX == nil, show(anchor()))

        // 6. Reset in Settings.
        dragPill(to: target)
        check("moved again", !near(anchor(), home, 50), show(anchor()))
        var reset = store.settings
        reset.flowBarX = nil; reset.flowBarY = nil
        store.settings = reset
        spin(0.4)
        check("Reset in Settings puts it back", near(anchor(), home), show(anchor()))

        print(ok ? "BAR DRAG TEST PASS" : "BAR DRAG TEST FAIL")
        return ok ? 0 : 1
    }
}
