import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Notetaker

struct NotetakerPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var notetaker: Notetaker
    @State private var tab = 0
    @State private var search = ""

    var body: some View {
        if let id = router.openMeeting, store.meetings.contains(where: { $0.id == id }) {
            MeetingDetail(id: id)
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    PageTitle(text: "Notetaker")
                    Spacer()
                    IconButton(symbol: "gearshape", help: "Notetaker settings") { router.settingsTab = .notetaker; router.showSettings = true }
                    if notetaker.isRecording {
                        Button { Task { await notetaker.stop() } } label: {
                            HStack(spacing: 8) { Image(systemName: "stop.fill"); Text("Stop Notetaker") }
                        }.buttonStyle(PrimaryButton())
                    } else {
                        Button { Task { await notetaker.start() } } label: {
                            HStack(spacing: 8) { Image(systemName: "record.circle"); Text("Start Notetaker") }
                                .font(.sans(15, .medium)).foregroundStyle(Theme.ink)
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accentSoft))
                        }.buttonStyle(.plain)
                    }
                }
                VStack(alignment: .leading, spacing: 18) {
                    SectionLabel(text: "Today")
                    if notetaker.isRecording { LiveMeetingCard() }
                    else {
                        HStack(spacing: 16) {
                            Image(systemName: "waveform.circle").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.ink2)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Record any meeting").font(.sans(17, .semibold))
                                Text("Zoom, Meet, Teams, Slack huddles or in person. PieFlow captures your mic and the other side's audio, then writes the notes.")
                                    .font(.sans(14)).foregroundStyle(Theme.ink2)
                            }
                            Spacer()
                            Button("Start") { Task { await notetaker.start() } }.buttonStyle(PrimaryButton())
                        }
                        .padding(22)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accentSoft))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accentLine))
                    }
                    if !notetaker.statusLine.isEmpty {
                        Text(notetaker.statusLine).font(.sans(13)).foregroundStyle(Theme.ink2)
                    }
                }
                .padding(28)
                .background(RoundedRectangle(cornerRadius: 18).fill(Theme.card))

                HStack(spacing: 28) {
                    tabButton("Past notes", 0)
                    Spacer()
                    TextField("Search", text: $search).textFieldStyle(.plain).font(.sans(14)).frame(width: 180)
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.ink2)
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1).offset(y: 10) }

                let past = store.meetings.filter { $0.id != notetaker.activeID }
                    .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search) }
                if past.isEmpty {
                    HStack(spacing: 16) {
                        Image(systemName: "doc.text").foregroundStyle(Theme.ink2)
                            .frame(width: 44, height: 44).background(Circle().fill(Color.white))
                        Text("Your meetings will appear here").font(.sans(16)).foregroundStyle(Theme.ink)
                        Spacer()
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
                    .padding(.top, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(past) { m in
                            MeetingRow(meeting: m).onTapGesture { router.openMeeting = m.id }
                            Rectangle().fill(Theme.line).frame(height: 1)
                        }
                    }.padding(.top, 6)
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 36)
        }
    }

    private func tabButton(_ t: String, _ i: Int) -> some View {
        Text(t).font(.sans(16, .medium)).foregroundStyle(tab == i ? Theme.ink : Theme.ink2)
            .overlay(alignment: .bottom) { if tab == i { Rectangle().fill(Theme.ink).frame(height: 2).offset(y: 10) } }
            .onTapGesture { tab = i }
    }
}

struct LiveMeetingCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var notetaker: Notetaker
    var body: some View {
        let m = store.meetings.first { $0.id == notetaker.activeID }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle().fill(Theme.red).frame(width: 9, height: 9)
                Text(m?.title ?? "Recording").font(.sans(17, .semibold))
                Spacer()
                Text(Meeting.clock(notetaker.elapsed)).font(.sans(15, .medium)).monospacedDigit().foregroundStyle(Theme.ink2)
                LevelMeter(level: notetaker.micLevel)
            }
            let tail = (m?.segments ?? []).suffix(4)
            if tail.isEmpty {
                Text("Listening. The transcript fills in every 45 seconds.").font(.sans(14)).foregroundStyle(Theme.ink3)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(tail.enumerated()), id: \.offset) { _, s in
                        (Text(s.speaker + "  ").font(.sans(13.5, .semibold)) + Text(s.text).font(.sans(14)))
                            .foregroundStyle(Theme.ink).lineLimit(2)
                    }
                }
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.accentLine))
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8) { i in
                RoundedRectangle(cornerRadius: 1).fill(Float(i) / 8 < level ? Theme.teal : Theme.cardStrong).frame(width: 3, height: 14)
            }
        }
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    @State private var hover = false
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "doc.text").foregroundStyle(Theme.ink2)
                .frame(width: 40, height: 40).background(Circle().fill(Color.white)).overlay(Circle().stroke(Theme.line))
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title).font(.sans(15.5, .medium)).foregroundStyle(Theme.ink)
                Text("\(Self.fmt.string(from: meeting.started))  ·  \(Meeting.clock(meeting.durationSec))")
                    .font(.sans(13)).foregroundStyle(Theme.ink3)
            }
            Spacer()
            switch meeting.status {
            case .processing: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Processing").font(.sans(13)).foregroundStyle(Theme.ink2) }
            case .failed: Text("Failed").font(.sans(13)).foregroundStyle(Theme.red)
            default: Image(systemName: "chevron.right").foregroundStyle(Theme.ink3)
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.card : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
    static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE, MMM d  h:mm a"; return f }()
}

struct MeetingDetail: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var notetaker: Notetaker
    let id: UUID
    @State private var tab = 0

    private var idx: Int? { store.meetings.firstIndex { $0.id == id } }

    var body: some View {
        if let i = idx {
            let m = store.meetings[i]
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Button { router.openMeeting = nil } label: {
                        HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("All notes") }.font(.sans(14)).foregroundStyle(Theme.ink2)
                    }.buttonStyle(.plain)
                    TextField("Title", text: Binding(get: { store.meetings[i].title }, set: { store.meetings[i].title = $0 }))
                        .textFieldStyle(.plain).font(.serif(34))
                    HStack(spacing: 10) {
                        Text("\(MeetingRow.fmt.string(from: m.started))  ·  \(Meeting.clock(m.durationSec))  ·  \(m.segments.count) segments")
                            .font(.sans(13.5)).foregroundStyle(Theme.ink3)
                        Spacer()
                        Button("Copy notes") { copy(m) }.buttonStyle(GhostButton())
                        Button("Export") { export(m) }.buttonStyle(GhostButton())
                        Menu {
                            Button("Regenerate summary") { Task { await notetaker.summarize(id) } }
                            Button("Re-transcribe from audio") { Task { await notetaker.reprocess(id) } }
                            if let f = m.audioFolder {
                                Button("Show audio in Finder") { NSWorkspace.shared.open(Paths.meetings.appendingPathComponent(f)) }
                            }
                            Divider()
                            Button("Delete meeting", role: .destructive) { delete(m) }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30)
                    }
                    if m.status == .processing {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Writing your notes").font(.sans(14)).foregroundStyle(Theme.ink2) }
                    }
                    if let err = m.errorMessage { Text(err).font(.sans(13.5)).foregroundStyle(Theme.red) }
                    HStack(spacing: 28) {
                        tabButton("Summary", 0); tabButton("Transcript", 1); Spacer()
                    }
                    .padding(.bottom, 4)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1).offset(y: 6) }
                    if tab == 0 {
                        MarkdownView(text: m.summary.isEmpty ? "_No summary yet._" : m.summary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(m.segments.enumerated()), id: \.offset) { _, s in
                                HStack(alignment: .top, spacing: 14) {
                                    Text(Meeting.clock(s.start)).font(.sans(12.5)).monospacedDigit().foregroundStyle(Theme.ink3).frame(width: 48, alignment: .leading)
                                    Text(s.speaker).font(.sans(13.5, .semibold)).foregroundStyle(s.speaker == "You" ? Theme.teal : Theme.ink).frame(width: 56, alignment: .leading)
                                    Text(s.text).font(.sans(14.5)).foregroundStyle(Theme.ink).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 48).padding(.vertical, 36)
            }
        }
    }

    private func tabButton(_ t: String, _ i: Int) -> some View {
        Text(t).font(.sans(16, .medium)).foregroundStyle(tab == i ? Theme.ink : Theme.ink2)
            .overlay(alignment: .bottom) { if tab == i { Rectangle().fill(Theme.ink).frame(height: 2).offset(y: 6) } }
            .onTapGesture { tab = i }
    }

    private func markdown(_ m: Meeting) -> String {
        "# \(m.title)\n\n\(MeetingRow.fmt.string(from: m.started))\n\n\(m.summary)\n\n## Transcript\n\n\(m.transcriptText)\n"
    }

    private func copy(_ m: Meeting) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(m), forType: .string)
    }

    private func export(_ m: Meeting) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = m.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        if panel.runModal() == .OK, let url = panel.url { try? markdown(m).write(to: url, atomically: true, encoding: .utf8) }
    }

    private func delete(_ m: Meeting) {
        if let f = m.audioFolder { try? FileManager.default.removeItem(at: Paths.meetings.appendingPathComponent(f)) }
        router.openMeeting = nil
        store.meetings.removeAll { $0.id == m.id }
    }
}

/// Small Markdown renderer for headings, checkboxes, bullets and inline styles.
struct MarkdownView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("## ") || line.hasPrefix("# ") {
                    Text(inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
                        .font(.sans(18, .semibold)).padding(.top, 12)
                } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: line.hasPrefix("- [x]") ? "checkmark.square" : "square").foregroundStyle(Theme.ink2).padding(.top, 2)
                        Text(inline(String(line.dropFirst(6)))).font(.sans(15))
                    }
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 10) {
                        Text("•").font(.sans(15)).foregroundStyle(Theme.ink2)
                        Text(inline(String(line.dropFirst(2)))).font(.sans(15))
                    }
                } else if !line.isEmpty {
                    Text(inline(line)).font(.sans(15)).lineSpacing(4)
                }
            }
        }
        .foregroundStyle(Theme.ink)
        .textSelection(.enabled)
    }
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: Insights

struct InsightsPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageTitle(text: "Insights")
                HStack(spacing: 34) {
                    tab("Your usage", 0); tab("Your voice", 1); Spacer()
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1).offset(y: 12) }
                .padding(.bottom, 14)
                if router.insightsTab == 0 { UsageInsights() } else { VoiceInsights() }
            }
            .padding(.horizontal, 40).padding(.vertical, 36)
        }
    }
    private func tab(_ t: String, _ i: Int) -> some View {
        Text(t).font(.sans(17, .medium)).foregroundStyle(router.insightsTab == i ? Theme.ink : Theme.ink2)
            .overlay(alignment: .bottom) { if router.insightsTab == i { Rectangle().fill(Theme.ink).frame(height: 2).offset(y: 12) } }
            .onTapGesture { router.insightsTab = i }
    }
}

struct InsightCard<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(26)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
}

struct UsageInsights: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                InsightCard {
                    Text("\(store.averageWPM)").font(.sans(40, .semibold))
                    SectionLabel(text: "Words per minute").padding(.top, 6)
                    Gauge(value: min(1, Double(store.averageWPM) / 200))
                        .frame(height: 120).padding(.top, 22)
                        .overlay {
                            VStack(spacing: 2) {
                                Text("vs typing").font(.sans(15)).foregroundStyle(Theme.ink2)
                                Text(String(format: "%.1fx", Double(store.averageWPM) / 40)).font(.sans(24, .medium))
                            }.offset(y: 22)
                        }
                }
                InsightCard {
                    Text(NumberFormatter.localizedString(from: NSNumber(value: store.fixesCount), number: .decimal)).font(.sans(40, .semibold))
                    SectionLabel(text: "Fixes made by PieFlow").padding(.top, 6)
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 18)
                    Text("\(store.dictionary.count) dictionary words").font(.sans(16))
                    Text("\(store.dictionary.reduce(0) { $0 + $1.misheard.count }) learned corrections").font(.sans(16)).padding(.top, 10)
                }
                InsightCard {
                    HStack(alignment: .top) {
                        Text(NumberFormatter.localizedString(from: NSNumber(value: store.totalWords), number: .decimal)).font(.sans(40, .semibold))
                        Spacer()
                        if let ch = store.wordsThisMonthChange {
                            Text("\(ch >= 0 ? "↗" : "↘") \(abs(ch))% this month").font(.sans(13.5))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
                        }
                    }
                    SectionLabel(text: "Total words dictated").padding(.top, 6)
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 18)
                    HStack(spacing: 6) { Image(systemName: "desktopcomputer"); Text("Desktop") }.font(.sans(16))
                    Text("\(store.history.count) dictations").font(.sans(16)).padding(.top, 4)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 24) {
                InsightCard { CategoryUsage() }
                InsightCard { StreakGrid() }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct Gauge: View {
    let value: Double
    var body: some View {
        GeometryReader { g in
            let w = min(g.size.width, g.size.height * 2)
            ZStack {
                Arc(fraction: 1).stroke(Theme.cardStrong, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                Arc(fraction: value).stroke(Theme.teal, style: StrokeStyle(lineWidth: 16, lineCap: .round))
            }
            .frame(width: w, height: w / 2)
            .frame(maxWidth: .infinity)
        }
    }
    struct Arc: Shape {
        var fraction: Double
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.addArc(center: CGPoint(x: r.midX, y: r.maxY), radius: r.width / 2 - 8,
                     startAngle: .degrees(180), endAngle: .degrees(180 + 180 * fraction), clockwise: false)
            return p
        }
    }
}

struct CategoryUsage: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let total = max(1, store.history.count)
        let counts = Dictionary(grouping: store.history, by: \.category).mapValues(\.count)
        let apps = Set(store.history.compactMap(\.appName)).count
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Desktop usage").font(.sans(30, .semibold))
                Spacer()
                SectionLabel(text: "Total apps used | \(apps)").fixedSize()
            }.padding(.bottom, 6)
            ForEach(AppCategory.allCases.sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }) { c in
                let n = counts[c] ?? 0
                let frac = Double(n) / Double(total)
                HStack(spacing: 14) {
                    Image(systemName: c.icon).font(.system(size: 16)).frame(width: 24)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6).fill(frac > 0.5 ? Theme.teal : Theme.teal2.opacity(0.6 + frac))
                                .frame(width: max(56, g.size.width * frac))
                            Text("\(Int((frac * 100).rounded()))%").font(.sans(14, .semibold)).foregroundStyle(.white).padding(.leading, 14)
                        }
                    }
                    .frame(width: frac > 0.5 ? nil : 56, height: 40)
                    .frame(maxWidth: frac > 0.5 ? 380 : 56, alignment: .leading)
                    Text("\(n) \(c.label)".uppercased()).font(.sans(14, .semibold)).kerning(1.2)
                    Spacer()
                }
            }
        }
    }
}

struct StreakGrid: View {
    @EnvironmentObject var store: Store
    @State private var weekOffset = 0

    var body: some View {
        let cal = Calendar.current
        let weeks = 17
        let today = cal.startOfDay(for: Date())
        let endWeekStart = cal.date(byAdding: .weekOfYear, value: -weekOffset, to: cal.dateInterval(of: .weekOfYear, for: today)!.start)!
        let start = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: endWeekStart)!
        let perDay = Dictionary(grouping: store.history) { cal.startOfDay(for: $0.date) }.mapValues { $0.reduce(0) { $0 + $1.wordCount } }
        let maxWords = max(1, perDay.values.max() ?? 1)
        let streakDays = currentStreakDays(cal)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(store.currentStreak) day streak").font(.sans(30, .semibold))
                Spacer()
                SectionLabel(text: "Longest streak | \(store.longestStreak) days")
            }
            HStack {
                Button { weekOffset += weeks } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Spacer()
                ForEach(monthLabels(start: start, weeks: weeks, cal: cal), id: \.self) { Text($0).font(.sans(13)).foregroundStyle(Theme.ink2); Spacer() }
                Button { weekOffset = max(0, weekOffset - weeks) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
                    .opacity(weekOffset == 0 ? 0.3 : 1)
            }
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"], id: \.self) {
                        Text($0).font(.sans(12)).foregroundStyle(Theme.ink2).frame(height: 22)
                    }
                }.frame(width: 34)
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 6) {
                        ForEach(0..<7, id: \.self) { d in
                            let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                            let words = perDay[day] ?? 0
                            RoundedRectangle(cornerRadius: 4)
                                .fill(day > today ? Theme.card : color(words, maxWords))
                                .frame(width: 22, height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(streakDays.contains(day) ? Theme.ink : .clear, lineWidth: 1.2))
                                .help("\(HomePage.dayFormatter.string(from: day)): \(words) words")
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Text("More").font(.sans(13)).foregroundStyle(Theme.ink2)
                ForEach([Theme.teal, Theme.teal2, Theme.teal3, Theme.teal4], id: \.self) { RoundedRectangle(cornerRadius: 3).fill($0).frame(width: 18, height: 18) }
                Text("Less").font(.sans(13)).foregroundStyle(Theme.ink2)
                Spacer()
                RoundedRectangle(cornerRadius: 3).stroke(Theme.ink, lineWidth: 1.2).frame(width: 18, height: 18)
                Text("Current streak").font(.sans(13)).foregroundStyle(Theme.ink2)
            }
        }
    }

    private func color(_ words: Int, _ maxWords: Int) -> Color {
        guard words > 0 else { return Theme.cardStrong }
        let f = Double(words) / Double(maxWords)
        return f > 0.66 ? Theme.teal : f > 0.33 ? Theme.teal2 : f > 0.1 ? Theme.teal3 : Theme.teal4
    }

    private func currentStreakDays(_ cal: Calendar) -> Set<Date> {
        var out = Set<Date>()
        var day = cal.startOfDay(for: Date())
        let days = store.activeDays
        if !days.contains(day) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        while days.contains(day) { out.insert(day); day = cal.date(byAdding: .day, value: -1, to: day)! }
        return out
    }

    private func monthLabels(start: Date, weeks: Int, cal: Calendar) -> [String] {
        let f = DateFormatter(); f.dateFormat = "MMM"
        var seen: [String] = []
        for w in stride(from: 0, to: weeks, by: 1) {
            let m = f.string(from: cal.date(byAdding: .weekOfYear, value: w, to: start)!)
            if !seen.contains(m) { seen.append(m) }
        }
        return seen
    }
}

struct VoiceInsights: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var llmBox: LLMBox
    @AppStorage("voiceReport") private var report = ""
    @State private var busy = false
    @State private var error = ""

    private static let stop: Set<String> = ["the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "is", "it", "that", "this", "i", "you", "we", "be", "with", "as", "at", "so", "if", "are", "was", "do", "have", "my", "me", "your", "can", "not", "just", "they", "what", "will", "from", "about", "there", "then", "would", "should", "like", "all", "our", "their", "them", "he", "she", "has", "had", "how", "which", "also", "some", "these", "those", "by", "an", "up", "out", "into", "more", "than", "very", "really", "get", "need", "want", "think"]

    var body: some View {
        let words = store.history.flatMap { $0.text.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init) }
        let freq = Dictionary(words.filter { $0.count > 2 && !Self.stop.contains($0) }.map { ($0, 1) }, uniquingKeysWith: +)
        let top = freq.sorted { $0.value > $1.value }.prefix(12)
        let hours = Dictionary(grouping: store.history) { Calendar.current.component(.hour, from: $0.date) }.mapValues(\.count)
        let peak = hours.max { $0.value < $1.value }?.key
        let questions = store.history.filter { $0.text.contains("?") }.count
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                InsightCard {
                    SectionLabel(text: "Words you say most")
                    FlowWrap(items: top.map { "\($0.key)  \($0.value)" }).padding(.top, 16)
                }
                InsightCard {
                    SectionLabel(text: "Your rhythm")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Peak hour: \(peak.map { Self.hour($0) } ?? "not enough data")").font(.sans(16))
                        Text("Average dictation: \(store.history.isEmpty ? 0 : store.totalWords / store.history.count) words").font(.sans(16))
                        Text("Questions asked: \(questions)").font(.sans(16))
                        Text("Top app: \(topApp ?? "none yet")").font(.sans(16))
                    }.padding(.top, 16)
                }
            }.fixedSize(horizontal: false, vertical: true)
            InsightCard {
                HStack {
                    Text("Voice profile").font(.sans(24, .semibold))
                    Spacer()
                    Button(busy ? "Analysing" : (report.isEmpty ? "Create report" : "Refresh report")) { create() }
                        .buttonStyle(PrimaryButton()).disabled(busy || store.history.count < 5)
                }
                if store.history.count < 5 {
                    Text("Dictate at least 5 times to unlock your voice profile.").font(.sans(15)).foregroundStyle(Theme.ink2).padding(.top, 12)
                }
                if !error.isEmpty { Text(error).font(.sans(13.5)).foregroundStyle(Theme.red).padding(.top, 10) }
                if !report.isEmpty { MarkdownView(text: report).padding(.top, 12) }
            }
        }
    }

    private var topApp: String? {
        Dictionary(grouping: store.history.compactMap(\.appName), by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    static func hour(_ h: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "h a"
        return f.string(from: Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!)
    }

    private func create() {
        busy = true; error = ""
        let sample = store.history.prefix(150).map { "[\($0.category.label)] \($0.text)" }.joined(separator: "\n")
        Task { @MainActor in
            defer { busy = false }
            do {
                report = try await llmBox.llm.complete(system: """
                You analyse how a person speaks, from their dictations. Write a short, warm, specific voice profile in Markdown with sections:
                ## How you sound
                ## Habits worth knowing
                ## Words and phrases you lean on
                ## Tips to dictate even faster
                Quote short real phrases from the data. Keep it under 300 words. Never use em dashes or en dashes.
                """, user: sample, timeout: 90, allowCLI: true)
            } catch { self.error = error.localizedDescription }
        }
    }
}

final class LLMBox: ObservableObject {
    let llm: LLM
    let engine: TextEngine
    init(llm: LLM, engine: TextEngine) { self.llm = llm; self.engine = engine }
}

struct FlowWrap: View {
    let items: [String]
    var body: some View {
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rows[r], id: \.self) { t in
                        Text(t).font(.sans(14)).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
                    }
                }
            }
            if items.isEmpty { Text("Nothing yet").font(.sans(14)).foregroundStyle(Theme.ink3) }
        }
    }
}

// MARK: Dictionary

struct DictionaryPage: View {
    @EnvironmentObject var store: Store
    @State private var editing: DictionaryWord?
    @State private var search = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    PageTitle(text: "Dictionary")
                    Spacer()
                    Button("Add new") { editing = DictionaryWord(word: "") }.buttonStyle(PrimaryButton())
                }
                if !store.settings.dismissedHero.contains("dictionary") {
                    HeroBanner(tint: [Color(hex: 0x1D2B3A), Color(hex: 0x3B5A6E), Color(hex: 0x9C7A55)],
                               onClose: { store.settings.dismissedHero.append("dictionary") }) {
                        VStack(alignment: .leading, spacing: 12) {
                            (Text("PieFlow speaks ").font(.serif(36)) + Text("your").font(.serif(36, italic: true)) + Text(" language").font(.serif(36)))
                                .foregroundStyle(.white)
                            Text("Add names, brands and jargon. PieFlow biases transcription toward them and fixes them when it mishears. Edits you make in history are learned here automatically.")
                                .font(.sans(15)).foregroundStyle(.white.opacity(0.92)).frame(maxWidth: 560, alignment: .leading)
                            Button("Add new word") { editing = DictionaryWord(word: "") }.buttonStyle(HeroButton()).padding(.top, 10)
                        }
                    }.frame(height: 230)
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.ink3)
                    TextField("Search", text: $search).textFieldStyle(.plain).font(.sans(14))
                }
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                let list = store.dictionary.filter { search.isEmpty || $0.word.localizedCaseInsensitiveContains(search) }
                if list.isEmpty {
                    Text("No words yet.").font(.sans(15)).foregroundStyle(Theme.ink3)
                } else {
                    ListCard(items: list) { w in
                        HStack {
                            Text(w.word).font(.sans(15.5, .medium))
                            if !w.misheard.isEmpty {
                                Text("fixes " + w.misheard.map { "\"\($0)\"" }.joined(separator: ", ")).font(.sans(13.5)).foregroundStyle(Theme.ink3)
                            }
                            Spacer()
                        }
                    } onEdit: { editing = $0 } onDelete: { w in store.dictionary.removeAll { $0.id == w.id } }
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 36)
        }
        .sheet(item: $editing) { w in
            DictionaryEditor(word: w) { saved in
                if let i = store.dictionary.firstIndex(where: { $0.id == saved.id }) { store.dictionary[i] = saved }
                else { store.dictionary.append(saved) }
            }
        }
    }
}

struct ListCard<T: Identifiable & Hashable, Row: View>: View {
    let items: [T]
    @ViewBuilder let row: (T) -> Row
    let onEdit: (T) -> Void
    let onDelete: (T) -> Void
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                HoverRow(onEdit: { onEdit(item) }, onDelete: { onDelete(item) }) { row(item) }
                if i < items.count - 1 { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct HoverRow<C: View>: View {
    let onEdit: () -> Void
    let onDelete: () -> Void
    @ViewBuilder let content: C
    @State private var hover = false
    var body: some View {
        HStack {
            content
            if hover {
                IconButton(symbol: "pencil", help: "Edit", action: onEdit)
                IconButton(symbol: "trash", help: "Delete", action: onDelete)
            }
        }
        .padding(.horizontal, 24).frame(minHeight: 58)
        .background(hover ? Theme.card.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: onEdit)
    }
}

struct DictionaryEditor: View {
    @Environment(\.dismiss) var dismiss
    @State var word: DictionaryWord
    @State private var misheard = ""
    let save: (DictionaryWord) -> Void
    init(word: DictionaryWord, save: @escaping (DictionaryWord) -> Void) {
        _word = State(initialValue: word)
        _misheard = State(initialValue: word.misheard.joined(separator: ", "))
        self.save = save
    }
    var body: some View {
        EditorSheet(title: word.word.isEmpty ? "Add word" : "Edit word", canSave: !word.word.trimmingCharacters(in: .whitespaces).isEmpty) {
            Text("Word or phrase").font(.sans(13, .medium)).foregroundStyle(Theme.ink2)
            TextField("e.g. Octupie", text: $word.word).pieField()
            Text("Often misheard as (optional, comma separated)").font(.sans(13, .medium)).foregroundStyle(Theme.ink2).padding(.top, 8)
            TextField("e.g. octopie, octo pie", text: $misheard).pieField()
        } onSave: {
            word.word = word.word.trimmingCharacters(in: .whitespaces)
            word.misheard = misheard.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            save(word); dismiss()
        }
    }
}

struct EditorSheet<C: View>: View {
    @Environment(\.dismiss) var dismiss
    let title: String
    var canSave = true
    @ViewBuilder let content: C
    let onSave: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.serif(30)).padding(.bottom, 8)
            content
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(GhostButton()).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave).buttonStyle(PrimaryButton()).disabled(!canSave).keyboardShortcut(.defaultAction)
            }.padding(.top, 16)
        }
        .padding(32).frame(width: 520)
        .background(Theme.page)
    }
}

// MARK: Snippets

struct SnippetsPage: View {
    @EnvironmentObject var store: Store
    @State private var editing: Snippet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack {
                    PageTitle(text: "Snippets")
                    Spacer()
                    Button("Add new") { editing = Snippet(trigger: "", expansion: "") }.buttonStyle(PrimaryButton())
                }
                if !store.settings.dismissedHero.contains("snippets") {
                    HeroBanner(tint: [Color(hex: 0x1E3A4C), Color(hex: 0x5C4632), Color(hex: 0xA8743F)],
                               onClose: { store.settings.dismissedHero.append("snippets") }) {
                        VStack(alignment: .leading, spacing: 14) {
                            (Text("The stuff ").font(.serif(38)) + Text("you").font(.serif(38, italic: true)) + Text(" shouldn't have to re-type.").font(.serif(38)))
                                .foregroundStyle(.white)
                            Text("Save text you type often, an email, intro, or prompt, then say a word to drop it in instantly.")
                                .font(.sans(15.5)).foregroundStyle(.white.opacity(0.92))
                            VStack(alignment: .leading, spacing: 8) {
                                example("\"my LinkedIn\"", "https://www.linkedin.com/in/your-name/")
                                example("\"rewrite prompt\"", "Rewrite this to be more concise...")
                                example("\"intro email\"", "Hey, would love to find some time to chat later...")
                            }.padding(.top, 4)
                            Button("Add new snippet") { editing = Snippet(trigger: "", expansion: "") }.buttonStyle(HeroButton()).padding(.top, 8)
                        }
                    }.frame(height: 400)
                }
                if store.snippets.isEmpty {
                    Text("No snippets yet.").font(.sans(15)).foregroundStyle(Theme.ink3)
                } else {
                    ListCard(items: store.snippets) { s in
                        HStack(spacing: 8) {
                            Text(s.trigger).font(.sans(15.5, .medium))
                            Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                            Text(s.expansion.replacingOccurrences(of: "\n", with: " ")).font(.sans(15.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                            Spacer()
                        }
                    } onEdit: { editing = $0 } onDelete: { s in store.snippets.removeAll { $0.id == s.id } }
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 36)
        }
        .sheet(item: $editing) { s in
            SnippetEditor(snippet: s) { saved in
                if let i = store.snippets.firstIndex(where: { $0.id == saved.id }) { store.snippets[i] = saved }
                else { store.snippets.append(saved) }
            }
        }
    }

    private func example(_ a: String, _ b: String) -> some View {
        HStack(spacing: 10) {
            Text(a).font(.sans(15, .medium)).italic().foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.22)))
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.white)
            Text(b).font(.sans(15, .medium)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.22)))
        }
    }
}

struct SnippetEditor: View {
    @Environment(\.dismiss) var dismiss
    @State var snippet: Snippet
    let save: (Snippet) -> Void
    var body: some View {
        EditorSheet(title: snippet.trigger.isEmpty ? "New snippet" : "Edit snippet",
                    canSave: !snippet.trigger.isEmpty && !snippet.expansion.isEmpty) {
            Text("When I say").font(.sans(13, .medium)).foregroundStyle(Theme.ink2)
            TextField("e.g. my email address", text: $snippet.trigger).pieField()
            Text("Insert").font(.sans(13, .medium)).foregroundStyle(Theme.ink2).padding(.top, 8)
            TextEditor(text: $snippet.expansion).font(.sans(14)).scrollContentBackground(.hidden).padding(8)
                .frame(height: 140).background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
        } onSave: { save(snippet); dismiss() }
    }
}

// MARK: Style

struct StylePage: View {
    @EnvironmentObject var store: Store
    @State private var cat: AppCategory = .personal
    private let cats: [AppCategory] = [.personal, .work, .email, .other]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageTitle(text: "Style")
                HStack(spacing: 30) {
                    ForEach(cats) { c in
                        Text(c == .other ? "Other" : c == .email ? "Email" : c.label)
                            .font(.sans(16, .medium)).foregroundStyle(cat == c ? Theme.ink : Theme.ink2)
                            .overlay(alignment: .bottom) { if cat == c { Rectangle().fill(Theme.ink).frame(height: 2).offset(y: 10) } }
                            .onTapGesture { cat = c }
                    }
                    Spacer()
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1).offset(y: 10) }
                .padding(.bottom, 8)
                HStack(spacing: 12) {
                    Text("This style applies in").font(.sans(15)).foregroundStyle(Theme.ink2)
                    Text(appsFor(cat)).font(.sans(15, .medium))
                }
                HStack(spacing: 20) {
                    ForEach(StyleTone.allCases) { tone in
                        let selected = (store.settings.styles[cat.rawValue] ?? .formal) == tone
                        VStack(alignment: .leading, spacing: 10) {
                            Text(tone.label).font(.serif(32))
                            Text(tone == .formal ? "Caps + Punctuation" : tone == .casual ? "Caps + Less punctuation" : "No Caps + Less punctuation")
                                .font(.sans(14)).foregroundStyle(Theme.ink2)
                            Spacer(minLength: 20)
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(Theme.cardStrong).frame(width: 30, height: 30)
                                    .overlay(Text(String(store.settings.userName.prefix(1))).font(.sans(13, .semibold)))
                                Text(tone.example).font(.sans(14.5)).padding(12)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Theme.ink : Theme.line, lineWidth: selected ? 2 : 1))
                        .contentShape(Rectangle())
                        .onTapGesture { store.settings.styles[cat.rawValue] = tone }
                    }
                }
                Text(store.settings.aiCleanup ? "Styles shape the AI cleanup pass. With no AI key, PieFlow applies the capitalization and punctuation rules directly."
                                              : "AI cleanup is off, so PieFlow applies only the capitalization and punctuation rules. Turn it on in Settings > Transcription.")
                    .font(.sans(13.5)).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 40).padding(.vertical, 36)
        }
    }

    private func appsFor(_ c: AppCategory) -> String {
        switch c {
        case .personal: return "WhatsApp, Messages, Telegram, Discord"
        case .work: return "Slack, Teams, Linear"
        case .email: return "Mail, Outlook, Superhuman, Spark"
        default: return "every other app"
        }
    }
}

// MARK: Transforms

struct TransformsPage: View {
    @EnvironmentObject var store: Store
    @State private var editing: Transform?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 14) {
                    PageTitle(text: "Transforms", beta: true)
                    Spacer()
                    Text("Opt in").font(.sans(15))
                    PillToggle(isOn: $store.settings.transformsEnabled)
                    HStack(spacing: 6) { KeyCap(text: "⌥ Opt"); KeyCap(text: "1"); Text("to run").font(.sans(14)) }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                }
                if !store.settings.dismissedHero.contains("transforms") {
                    HeroBanner(tint: [Color(hex: 0x203A43), Color(hex: 0x4B5D4F), Color(hex: 0x6C4A35)],
                               onClose: { store.settings.dismissedHero.append("transforms") }) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Transform works anywhere you write").font(.serif(36)).foregroundStyle(.white)
                            Text("Select text in any app and press ⌥ plus a number to rewrite, clean up, or restructure it.")
                                .font(.sans(15.5)).foregroundStyle(.white.opacity(0.92)).frame(maxWidth: 460, alignment: .leading)
                        }
                    }.frame(height: 200)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auto Apply After Dictation").font(.sans(16, .medium))
                        Text("Run a transform on everything you dictate, automatically.").font(.sans(14)).foregroundStyle(Theme.ink2)
                    }
                    Spacer()
                    ThemedPicker(selection: Binding(get: { store.settings.autoApplyTransformID ?? store.transforms.first?.id },
                                                    set: { store.settings.autoApplyTransformID = $0 }),
                                 options: store.transforms.map { (Optional($0.id), $0.name) }, width: 200)
                    PillToggle(isOn: Binding(get: { store.settings.autoApplyTransform }, set: {
                        store.settings.autoApplyTransform = $0
                        if $0 && store.settings.autoApplyTransformID == nil { store.settings.autoApplyTransformID = store.transforms.first?.id }
                    }))
                }
                HStack {
                    Text("My Transforms").font(.serif(34))
                    Spacer()
                    Button { store.transforms = Transform.defaults } label: {
                        HStack(spacing: 6) { Image(systemName: "arrow.counterclockwise"); Text("Reset to defaults") }.font(.sans(15)).foregroundStyle(Theme.ink)
                    }.buttonStyle(.plain)
                    Button("Create New") { editing = Transform(name: "", summary: "", prompt: "", hotkeyDigit: nextDigit) }.buttonStyle(PrimaryButton())
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)], spacing: 20) {
                    ForEach(store.transforms) { t in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 4) {
                                if let d = t.hotkeyDigit { KeyCap(text: "⌥ Opt"); KeyCap(text: "\(d)") }
                                Spacer()
                                Menu {
                                    Button("Edit") { editing = t }
                                    Button("Delete", role: .destructive) { store.transforms.removeAll { $0.id == t.id } }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                            }
                            Text(t.name).font(.sans(17, .medium)).padding(.top, 14)
                            Text(t.summary).font(.sans(15)).foregroundStyle(Theme.ink2).lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(22).frame(height: 190, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
                        .onTapGesture(count: 2) { editing = t }
                    }
                    Button { editing = Transform(name: "", summary: "", prompt: "", hotkeyDigit: nextDigit) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "plus").font(.system(size: 12)).frame(width: 34, height: 34).background(Circle().fill(Theme.card))
                            Text("Create your own").font(.sans(17, .medium)).padding(.top, 14)
                            Text("Write your own prompt").font(.sans(15)).foregroundStyle(Theme.ink2)
                            Spacer(minLength: 0)
                        }
                        .padding(22).frame(maxWidth: .infinity, minHeight: 190, maxHeight: 190, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 40).padding(.vertical, 36)
        }
        .sheet(item: $editing) { t in
            TransformEditor(tf: t) { saved in
                if let i = store.transforms.firstIndex(where: { $0.id == saved.id }) { store.transforms[i] = saved }
                else { store.transforms.append(saved) }
            }
        }
    }

    private var nextDigit: Int? {
        let used = Set(store.transforms.compactMap(\.hotkeyDigit))
        return (1...9).first { !used.contains($0) }
    }
}

struct TransformEditor: View {
    @Environment(\.dismiss) var dismiss
    @State var tf: Transform
    let save: (Transform) -> Void
    var body: some View {
        EditorSheet(title: tf.name.isEmpty ? "New transform" : "Edit transform", canSave: !tf.name.isEmpty && !tf.prompt.isEmpty) {
            Text("Name").font(.sans(13, .medium)).foregroundStyle(Theme.ink2)
            TextField("e.g. Make it friendly", text: $tf.name).pieField()
            Text("Short description").font(.sans(13, .medium)).foregroundStyle(Theme.ink2).padding(.top, 6)
            TextField("Shown on the card", text: $tf.summary).pieField()
            Text("Instructions").font(.sans(13, .medium)).foregroundStyle(Theme.ink2).padding(.top, 6)
            TextEditor(text: $tf.prompt).font(.sans(14)).scrollContentBackground(.hidden).padding(8)
                .frame(height: 140).background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
            HStack {
                Text("Shortcut").font(.sans(13, .medium)).foregroundStyle(Theme.ink2)
                ThemedPicker(selection: $tf.hotkeyDigit,
                             options: [(Int?.none, "None")] + (1...9).map { (Int?.some($0), "⌥ \($0)") }, width: 120)
            }.padding(.top, 6)
        } onSave: { save(tf); dismiss() }
    }
}

// MARK: Scratchpad

struct ScratchpadPage: View {
    @EnvironmentObject var store: Store
    @State private var selected: UUID?
    @State private var search = ""
    @State private var searching = false

    var body: some View {
        if let id = selected, let i = store.notes.firstIndex(where: { $0.id == id }) {
            NoteEditor(index: i) { selected = nil }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    PageTitle(text: "Scratchpad", beta: true)
                    if !store.settings.dismissedHero.contains("scratchpad") {
                        HeroBanner(tint: [Color(hex: 0x3A2618), Color(hex: 0x7A5634), Color(hex: 0xB8895A)],
                                   onClose: { store.settings.dismissedHero.append("scratchpad") }) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("For quick thoughts you want to come back to").font(.serif(38)).foregroundStyle(.white)
                                Text("Drop a to-do list, polish a message before you send it, brain dump an idea. Scratchpad is your safe space to save, create, and explore.")
                                    .font(.sans(15.5)).foregroundStyle(.white.opacity(0.92)).frame(maxWidth: 620, alignment: .leading)
                                Button("Start new note") { newNote() }.buttonStyle(HeroButton()).padding(.top, 10)
                            }
                        }.frame(height: 250)
                    }
                    HStack {
                        Text("Recents").font(.sans(18, .semibold))
                        Spacer()
                        if searching { TextField("Search notes", text: $search).pieField().frame(width: 220) }
                        IconButton(symbol: "magnifyingglass", help: "Search") { searching.toggle(); if !searching { search = "" } }
                        IconButton(symbol: "plus", help: "New note") { newNote() }
                    }
                    .padding(.bottom, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
                    let notes = store.notes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.body.localizedCaseInsensitiveContains(search) }
                        .sorted { $0.updated > $1.updated }
                    if notes.isEmpty {
                        Text("No notes found").font(.sans(17)).foregroundStyle(Theme.ink2).frame(maxWidth: .infinity).padding(.top, 80)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(notes) { n in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(n.title.isEmpty ? "Untitled" : n.title).font(.sans(16, .medium))
                                        Text(n.body.prefix(140).replacingOccurrences(of: "\n", with: " ")).font(.sans(14)).foregroundStyle(Theme.ink2).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(RelativeDateTimeFormatter().localizedString(for: n.updated, relativeTo: Date())).font(.sans(13)).foregroundStyle(Theme.ink3)
                                }
                                .padding(.vertical, 14).contentShape(Rectangle())
                                .onTapGesture { selected = n.id }
                                Rectangle().fill(Theme.line).frame(height: 1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 40).padding(.vertical, 36)
            }
        }
    }

    private func newNote() {
        let n = Note()
        store.notes.insert(n, at: 0)
        selected = n.id
    }
}

struct NoteEditor: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var llmBox: LLMBox
    let index: Int
    let close: () -> Void
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: close) {
                    HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("Scratchpad") }.font(.sans(14)).foregroundStyle(Theme.ink2)
                }.buttonStyle(.plain)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Menu("Transform") {
                    ForEach(store.transforms) { t in Button(t.name) { run(t) } }
                }.menuStyle(.borderlessButton).frame(width: 100)
                IconButton(symbol: "doc.on.doc", help: "Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(store.notes[index].body, forType: .string)
                }
                IconButton(symbol: "trash", help: "Delete") {
                    let id = store.notes[index].id
                    close()
                    DispatchQueue.main.async { store.notes.removeAll { $0.id == id } }
                }
            }
            TextField("Untitled", text: Binding(get: { store.notes[safe: index]?.title ?? "" },
                                                set: { store.notes[index].title = $0; store.notes[index].updated = Date() }))
                .textFieldStyle(.plain).font(.serif(32))
            TextEditor(text: Binding(get: { store.notes[safe: index]?.body ?? "" },
                                     set: { store.notes[index].body = $0; store.notes[index].updated = Date() }))
                .font(.sans(16)).lineSpacing(5).scrollContentBackground(.hidden)
            Text("Tip: click into the note and hold \(store.settings.hotkey.label) to dictate.").font(.sans(12.5)).foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 48).padding(.vertical, 32)
    }

    private func run(_ t: Transform) {
        let body = store.notes[index].body
        guard !body.isEmpty else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            if let out = try? await llmBox.engine.transform(body, with: t) { store.notes[index].body = out; store.notes[index].updated = Date() }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
