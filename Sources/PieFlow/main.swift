import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store.shared
    lazy var transcriber = Transcriber(store: store)
    lazy var llm = LLM(store: store)
    lazy var engine = TextEngine(store: store, llm: llm)
    lazy var dictation = DictationController(store: store, transcriber: transcriber, engine: engine)
    lazy var notetaker = Notetaker(store: store, transcriber: transcriber, llm: llm)
    lazy var models = ModelManager()
    lazy var llmBox = LLMBox(llm: llm, engine: engine)
    lazy var updater = Updater(store: store)
    let router = Router()
    lazy var flowBar = FlowBarController(dictation: dictation, store: store)

    var window: NSWindow?
    var onboarding: NSWindow?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        Theme.registerFonts()
        Log.write("launch v\(AppInfo.version) build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        Log.write("permissions at launch: \(Permissions.summary)")
        _ = PermissionState.shared
        NSApp.setActivationPolicy(store.settings.showInDock ? .regular : .accessory)
        buildMenu()
        setupStatusItem()
        flowBar.show()
        dictation.startListening()
        store.pruneAudio()
        transcriber.warmUpLocal()
        updater.startSchedule()
        NotificationCenter.default.addObserver(forName: .showOnboarding, object: nil, queue: .main) { [weak self] _ in self?.showOnboarding() }
        if CommandLine.arguments.contains("--update-test") {
            UpdateTest.run(self)
            return
        }
        if CommandLine.arguments.contains("--focus-test") {
            showOnboarding()
            FocusTest.run(self)
            return
        }
        if let dir = Snapshot.outDir {
            Snapshot.seed(store)
            showMain()
            Snapshot.run(self, dir: dir)
            return
        }
        if store.settings.onboarded { showMain() } else { showOnboarding() }
        // Keep retrying the hotkey listener until permissions arrive.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, !self.dictation.hotkeys.isListening, Permissions.accessibility else { return }
            self.dictation.startListening()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMain() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        store.flush()
    }

    private func environment<V: View>(_ v: V) -> some View {
        v.environmentObject(store).environmentObject(router).environmentObject(dictation)
            .environmentObject(notetaker).environmentObject(models).environmentObject(llmBox).environmentObject(updater)
    }

    @objc func showMain() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.minSize = NSSize(width: 980, height: 640)
            w.backgroundColor = NSColor(Theme.window)
            w.contentView = NSHostingView(rootView: environment(MainView()))
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("PieFlowMain")
            w.appearance = NSAppearance(named: .aqua)
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOnboarding() {
        if onboarding == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .aqua)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: environment(OnboardingView { [weak self] in
                self?.onboarding?.close()
                self?.onboarding = nil
                self?.showMain()
            }))
            w.center()
            onboarding = w
        }
        onboarding?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "PieFlow")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About PieFlow", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide PieFlow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit PieFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.mainMenu = main
    }

    @objc func openSettings() { showMain(); router.showSettings = true }
    @objc func toggleNotetaker() {
        Task { @MainActor in
            if notetaker.isRecording { await notetaker.stop() } else { await notetaker.start() }
        }
    }
    @objc func toggleHandsFree() { dictation.toggleFromUI() }
    @objc func openNotes() { showMain(); router.page = .notetaker }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Open PieFlow", action: #selector(showMain), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: dictation.isRecording ? "Stop dictation" : "Start hands-free dictation", action: #selector(toggleHandsFree), keyEquivalent: "").target = self
        menu.addItem(withTitle: notetaker.isRecording ? "Stop Notetaker (\(Meeting.clock(notetaker.elapsed)))" : "Start Notetaker",
                     action: #selector(toggleNotetaker), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Meeting notes", action: #selector(openNotes), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let status = NSMenuItem(title: dictation.hotkeys.isListening ? "Hold \(store.settings.hotkey.label) to dictate" : "Shortcut inactive: check permissions", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let r = updater.availableRelease {
            menu.addItem(withTitle: "Update to PieFlow \(r.version)…", action: #selector(installUpdate), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit PieFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func checkUpdates() { updater.check(userInitiated: true); showMain(); router.settingsTab = .about; router.showSettings = true }
    @objc func installUpdate() { showMain(); updater.installAvailable() }
}

// MARK: entry

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}
if CommandLine.arguments.contains("--aec-probe") {
    exit(SelfTest.aecProbe())
}
if CommandLine.arguments.contains("--aec-test") {
    exit(SelfTest.aecTest())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
