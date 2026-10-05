import SwiftUI
import AppKit
import AVFoundation

enum Page: String, CaseIterable, Identifiable {
    case dictation, notetaker, insights, dictionary, snippets, style, transforms, scratchpad
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .notetaker: return "Notetaker"
        case .insights: return "Insights"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .style: return "Style"
        case .transforms: return "Transforms"
        case .scratchpad: return "Scratchpad"
        }
    }
    var icon: String {
        switch self {
        case .dictation: return "mic"
        case .notetaker: return "record.circle"
        case .insights: return "chart.bar"
        case .dictionary: return "character.book.closed"
        case .snippets: return "scissors"
        case .style: return "textformat.size"
        case .transforms: return "wand.and.stars"
        case .scratchpad: return "square.and.pencil"
        }
    }
}

final class Router: ObservableObject {
    @Published var page: Page = .dictation
    @Published var showSettings = false
    @Published var settingsTab: SettingsTab = .general
    @Published var showHelp = false
    @Published var openMeeting: UUID?
    @Published var insightsTab = 0
    @Published var sidebarCollapsed = false
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var dictation: DictationController

    var body: some View {
        HStack(spacing: 0) {
            if !router.sidebarCollapsed {
                Sidebar().frame(width: 228)
                    .transition(.move(edge: .leading))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Theme.page)
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line, lineWidth: 1))
                pageView.clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .padding(.trailing, 10).padding(.bottom, 10).padding(.leading, router.sidebarCollapsed ? 10 : 0)
        }
        .padding(.top, 44)
        .background(Theme.window)
        .overlay(alignment: .top) { TopBar() }
        .sheet(isPresented: $router.showSettings) { SettingsView().environmentObject(store).environmentObject(router) }
        .sheet(isPresented: $router.showHelp) { HelpView() }
        .animation(.easeOut(duration: 0.2), value: router.sidebarCollapsed)
        .ignoresSafeArea()
    }

    @ViewBuilder private var pageView: some View {
        switch router.page {
        case .dictation: HomePage()
        case .notetaker: NotetakerPage()
        case .insights: InsightsPage()
        case .dictionary: DictionaryPage()
        case .snippets: SnippetsPage()
        case .style: StylePage()
        case .transforms: TransformsPage()
        case .scratchpad: ScratchpadPage()
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var router: Router
    @EnvironmentObject var dictation: DictationController
    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 76)
            IconButton(symbol: "sidebar.left", help: "Toggle sidebar") { router.sidebarCollapsed.toggle() }
            Spacer()
            statusChip
            IconButton(symbol: "questionmark.circle", help: "Help") { router.showHelp = true }
            IconButton(symbol: "gearshape", help: "Settings") { router.showSettings = true }
                .padding(.trailing, 12)
        }
        .frame(height: 44)
    }

    @ViewBuilder private var statusChip: some View {
        if !Permissions.accessibility || !dictation.hotkeys.isListening {
            Button { router.settingsTab = .system; router.showSettings = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(Theme.red).frame(width: 6, height: 6)
                    Text(dictation.hotkeys.isListening ? "Allow Accessibility to paste" : "Hotkey inactive, check permissions")
                        .font(.sans(12.5, .medium)).foregroundStyle(Theme.ink2)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Theme.cardStrong))
            }.buttonStyle(.plain)
        }
    }
}

struct LogoMark: View {
    var size: CGFloat = 22
    var body: some View {
        HStack(alignment: .center, spacing: size * 0.09) {
            ForEach([0.55, 0.9, 0.62, 1.0, 0.7], id: \.self) { h in
                RoundedRectangle(cornerRadius: size * 0.05).fill(Theme.ink).frame(width: size * 0.11, height: size * h)
            }
        }.frame(height: size)
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var models: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                LogoMark()
                Text("PieFlow").font(.sans(24, .semibold)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 22)

            ForEach(Page.allCases) { p in
                SidebarRow(icon: p.icon, title: p.title, selected: router.page == p) { router.page = p }
            }

            if !setupDone {
                SetupCard().padding(.top, 14)
            }
            Spacer(minLength: 10)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 8).padding(.bottom, 6)
            SidebarRow(icon: "gearshape", title: "Settings", selected: false) { router.showSettings = true }
            SidebarRow(icon: "questionmark.circle", title: "Help", selected: false) { router.showHelp = true }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    private var setupDone: Bool {
        Permissions.accessibility && Permissions.microphone && hasEngine && !store.history.isEmpty && !store.meetings.isEmpty
    }
    private var hasEngine: Bool { !store.keys.xai.isEmpty || !store.keys.groq.isEmpty || !models.installed.isEmpty }
}

struct SidebarRow: View {
    let icon: String
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 20)
                Text(title).font(.sans(15.5, .medium))
                Spacer()
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.cardStrong : (hover ? Theme.cardStrong.opacity(0.5) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SetupCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var models: ModelManager

    var body: some View {
        let items: [(String, Bool, () -> Void)] = [
            ("Allow permissions", Permissions.accessibility && Permissions.microphone, { router.settingsTab = .system; router.showSettings = true }),
            ("Set up transcription", !store.keys.xai.isEmpty || !store.keys.groq.isEmpty || !models.installed.isEmpty,
             { router.settingsTab = .transcription; router.showSettings = true }),
            ("Dictate once", !store.history.isEmpty, { router.page = .dictation }),
            ("Record a meeting", !store.meetings.isEmpty, { router.page = .notetaker }),
        ]
        let done = items.filter(\.1).count
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up PieFlow").font(.sans(13.5, .semibold)).foregroundStyle(Theme.ink)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardStrong)
                    Capsule().fill(Theme.ink).frame(width: g.size.width * CGFloat(done) / CGFloat(items.count))
                }
            }.frame(height: 4)
            ForEach(items.indices, id: \.self) { i in
                Button(action: items[i].2) {
                    HStack(spacing: 10) {
                        Image(systemName: items[i].1 ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17, weight: .light)).foregroundStyle(items[i].1 ? Theme.teal : Theme.ink2)
                        Text(items[i].0).font(.sans(13)).foregroundStyle(items[i].1 ? Theme.ink3 : Theme.ink)
                            .strikethrough(items[i].1, color: Theme.ink3)
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
}

// MARK: Home (Dictation)

struct HomePage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var dictation: DictationController
    @EnvironmentObject var updater: Updater
    @State private var search = ""
    @State private var searching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Welcome back, \(store.settings.userName)").font(.sans(28, .semibold)).foregroundStyle(Theme.ink)
                UpdateBanner()
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 28) {
                        if !store.settings.dismissedHero.contains("home") {
                            HeroBanner(onClose: { store.settings.dismissedHero.append("home") }) {
                                VStack(alignment: .leading, spacing: 12) {
                                    (Text("Make PieFlow sound like ").font(.serif(36)) + Text("you").font(.serif(36, italic: true)))
                                        .foregroundStyle(.white)
                                    Text("Set up different writing styles for different apps.").font(.sans(16)).foregroundStyle(.white.opacity(0.92))
                                    Button("Start now") { router.page = .style }.buttonStyle(HeroButton()).padding(.top, 14)
                                }
                            }.frame(height: 220)
                        }
                        history
                    }
                    .frame(maxWidth: .infinity)
                    sideColumn.frame(width: 300)
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 36)
        }
    }

    private var sideColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                stat(Self.compact(store.totalWords), "total words")
                stat("\(store.averageWPM)", "wpm")
                stat("\(store.currentStreak)", "day streak")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
            if !store.settings.dismissedHero.contains("voice") && store.history.count >= 5 {
                Rectangle().fill(Theme.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Voice Profile Unlocked!").font(.sans(17, .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                        Button { store.settings.dismissedHero.append("voice") } label: {
                            Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                        }.buttonStyle(.plain)
                    }
                    Text("Discover your unique insights").font(.sans(14.5)).foregroundStyle(Theme.ink2)
                    Button("Create report") { router.insightsTab = 1; router.page = .insights }
                        .buttonStyle(AccentButton()).padding(.top, 14)
                }.padding(24)
            }
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
    }

    private func stat(_ big: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(big).font(.serif(34)).foregroundStyle(Theme.ink)
            Text(label).font(.sans(16)).foregroundStyle(Theme.ink)
        }
    }

    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.1fK", Double(n) / 1000) }
        return NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }

    private var filtered: [DictationEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? store.history : store.history.filter { $0.text.lowercased().contains(q) || ($0.appName ?? "").lowercased().contains(q) }
    }

    private var grouped: [(Date, [DictationEntry])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: filtered.prefix(400)) { cal.startOfDay(for: $0.date) }
        return dict.keys.sorted(by: >).map { ($0, dict[$0]!.sorted { $0.date > $1.date }) }
    }

    @ViewBuilder private var history: some View {
        if store.history.isEmpty {
            EmptyHistory()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                if searching {
                    HStack {
                        TextField("Search your dictations", text: $search).pieField()
                        IconButton(symbol: "xmark") { search = ""; searching = false }
                    }
                }
                ForEach(Array(grouped.enumerated()), id: \.element.0) { idx, group in
                    HStack {
                        SectionLabel(text: Self.dayFormatter.string(from: group.0))
                        Spacer()
                        if idx == 0 && !searching { IconButton(symbol: "magnifyingglass", help: "Search") { searching = true } }
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(group.1.enumerated()), id: \.element.id) { i, e in
                            HistoryRow(entry: e)
                            if i < group.1.count - 1 { Rectangle().fill(Theme.line).frame(height: 1) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"; return f }()
}

struct EmptyHistory: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Your dictations")
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Hold").font(.sans(15)).foregroundStyle(Theme.ink2)
                    KeyCap(text: store.settings.hotkey.label)
                    Text("anywhere and speak. Let go and your words appear where your cursor is.").font(.sans(15)).foregroundStyle(Theme.ink2)
                }
                HStack(spacing: 6) {
                    Text("Double tap").font(.sans(15)).foregroundStyle(Theme.ink2)
                    KeyCap(text: store.settings.hotkey.label)
                    Text("for hands-free. Press it again to finish, or Esc to cancel.").font(.sans(15)).foregroundStyle(Theme.ink2)
                }
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.card.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
        }
    }
}

final class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()
    @Published var playing: UUID?
    private var player: AVAudioPlayer?
    private var delegate: Delegate?
    final class Delegate: NSObject, AVAudioPlayerDelegate {
        let done: () -> Void
        init(_ d: @escaping () -> Void) { done = d }
        func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) { DispatchQueue.main.async(execute: done) }
    }
    func toggle(_ id: UUID, url: URL) {
        if playing == id { player?.stop(); playing = nil; return }
        player = try? AVAudioPlayer(contentsOf: url)
        delegate = Delegate { [weak self] in self?.playing = nil }
        player?.delegate = delegate
        player?.play()
        playing = player == nil ? nil : id
    }
}

struct HistoryRow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var dictation: DictationController
    @ObservedObject var player = AudioPlayer.shared
    let entry: DictationEntry
    @State private var hover = false
    @State private var editing = false
    @State private var draft = ""
    @State private var copied = false
    @State private var busy = false

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Text(Self.time.string(from: entry.date).lowercased())
                .font(.sans(14)).foregroundStyle(Theme.ink3).frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if editing {
                    TextEditor(text: $draft).font(.sans(15.5)).scrollContentBackground(.hidden)
                        .frame(minHeight: 60).padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                    HStack {
                        Button("Save") { saveEdit() }.buttonStyle(PrimaryButton())
                        Button("Cancel") { editing = false }.buttonStyle(GhostButton())
                    }
                } else if entry.engine == "failed" {
                    Text("Transcription failed. Retry from the menu.").font(.sans(15.5)).foregroundStyle(Theme.red)
                } else {
                    Text(entry.text).font(.sans(15.5)).foregroundStyle(Theme.ink).lineSpacing(4).textSelection(.enabled)
                }
                if hover && !editing {
                    Text([entry.appName, entry.engine, "\(entry.wordCount) words"].compactMap { $0 }.joined(separator: "  ·  "))
                        .font(.sans(12)).foregroundStyle(Theme.ink3)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                if busy { ProgressView().controlSize(.small) }
                if let f = entry.audioFile {
                    IconButton(symbol: player.playing == entry.id ? "stop.fill" : "play", help: "Play audio") {
                        player.toggle(entry.id, url: Paths.audio.appendingPathComponent(f))
                    }
                }
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.text, forType: .string)
                    copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                IconButton(symbol: entry.flagged ? "flag.fill" : "flag", help: "Flag") { mutate { $0.flagged.toggle() } }
                Menu {
                    Button("Edit text") { draft = entry.text; editing = true }
                    Menu("Retry transcription") {
                        ForEach(STTProvider.allCases) { p in Button(p.label) { retry(p) } }
                    }
                    Button("Paste again") { Inserter.paste(entry.text) }
                    Divider()
                    Button("Delete", role: .destructive) { delete() }
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).foregroundStyle(Theme.ink2).frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
            }
            .opacity(hover || player.playing == entry.id || busy ? 1 : 0)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(hover ? Theme.card : Color.clear)
        .onHover { hover = $0 }
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mma"; return f }()

    private func mutate(_ f: (inout DictationEntry) -> Void) {
        guard let i = store.history.firstIndex(where: { $0.id == entry.id }) else { return }
        f(&store.history[i])
    }

    private func saveEdit() {
        let old = entry.text
        mutate { $0.text = draft }
        editing = false
        learn(from: old, to: draft)
    }

    /// Single-word corrections become dictionary entries, so the next dictation gets them right.
    private func learn(from old: String, to new: String) {
        let a = old.split(separator: " ").map(String.init), b = new.split(separator: " ").map(String.init)
        guard a.count == b.count else { return }
        let strip: (String) -> String = { $0.trimmingCharacters(in: .punctuationCharacters) }
        for (x, y) in zip(a, b) where strip(x).lowercased() != strip(y).lowercased() && !strip(y).isEmpty {
            let word = strip(y), heard = strip(x)
            if let i = store.dictionary.firstIndex(where: { $0.word.lowercased() == word.lowercased() }) {
                if !store.dictionary[i].misheard.contains(heard) { store.dictionary[i].misheard.append(heard) }
            } else {
                store.dictionary.append(DictionaryWord(word: word, misheard: [heard]))
            }
        }
    }

    private func retry(_ p: STTProvider) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { let e = try await dictation.retry(entry, with: p); mutate { $0 = e } }
            catch { dictation.flash(error.localizedDescription.components(separatedBy: "\n").first ?? "Retry failed", error: true) }
        }
    }

    private func delete() {
        if let f = entry.audioFile { try? FileManager.default.removeItem(at: Paths.audio.appendingPathComponent(f)) }
        store.history.removeAll { $0.id == entry.id }
    }
}


/// Shown on the home page when a newer release exists or an update is in progress.
struct UpdateBanner: View {
    @EnvironmentObject var updater: Updater
    var body: some View {
        switch updater.state {
        case .available(let r):
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle").font(.system(size: 20, weight: .light)).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PieFlow \(r.version) is available").font(.sans(15.5, .semibold)).foregroundStyle(Theme.ink)
                    Text("You have \(Updater.currentVersion). Updating keeps your permissions, key and history.").font(.sans(13.5)).foregroundStyle(Theme.ink2)
                }
                Spacer()
                Button("What's new") { NSWorkspace.shared.open(r.pageURL) }.buttonStyle(.plain).font(.sans(14)).foregroundStyle(Theme.ink2)
                Button("Skip") { updater.skip(r) }.buttonStyle(GhostButton())
                Button("Update now") { updater.installAvailable() }.buttonStyle(PrimaryButton())
            }
            .padding(18).background(RoundedRectangle(cornerRadius: 14).fill(Theme.accentSoft))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accentLine))
        case .downloading(let p):
            HStack(spacing: 14) {
                ProgressView(value: p).frame(width: 180)
                Text("Downloading update, \(Int(p * 100))%").font(.sans(14)).foregroundStyle(Theme.ink2)
                Spacer()
            }
            .padding(18).background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        case .installing:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Installing. PieFlow will relaunch in a moment.").font(.sans(14)).foregroundStyle(Theme.ink2)
                Spacer()
            }
            .padding(18).background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        case .failed(let msg):
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.red)
                Text("Update failed: \(msg)").font(.sans(13.5)).foregroundStyle(Theme.ink2).lineLimit(2)
                Spacer()
                Button("Dismiss") { updater.dismiss() }.buttonStyle(GhostButton())
            }
            .padding(18).background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
        default:
            EmptyView()
        }
    }
}
