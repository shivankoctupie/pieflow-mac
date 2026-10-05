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
        store.notes = [Note(title: "Launch checklist", body: "Pricing page\nDemo video\nFAQ on local models"),
                       Note(title: "Hiring thoughts", body: "Need one designer who can also write.")]
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

    static func run(_ app: AppDelegate, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var steps: [(String, () -> Void)] = []
        for p in Page.allCases {
            steps.append(("page-\(p.rawValue)", { app.router.page = p; app.router.openMeeting = nil }))
        }
        steps.append(("meeting-detail", { app.router.page = .notetaker; app.router.openMeeting = app.store.meetings.first?.id }))
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
                if name.hasPrefix("settings"), let sheet = app.window?.attachedSheet { capture(sheet, name, to: dir) }
                else if let w = app.window { capture(w, name, to: dir) }
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
