import AppKit
import ApplicationServices

/// After a dictation is pasted, watches the focused text field in the target app for a short while.
/// If the user corrects a word in what was just pasted, the correction becomes a Dictionary entry so
/// the next dictation gets it right. Reads only the focused field, only for 45 s, stores nothing but
/// the learned words.
final class EditWatcher {
    private var timer: Timer?
    private var element: AXUIElement?
    private var pasted = ""
    private var baseline = ""
    private var lastSeen = ""
    private var stableTicks = 0
    private var ticks = 0
    private var learned = false
    var onLearned: ((String, String) -> Void)?

    static func focusedValue() -> (AXUIElement, String)? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused else { return nil }
        let element = el as! AXUIElement
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let s = value as? String else { return nil }
        return (element, s)
    }

    /// Call right after the paste landed (give the app ~0.5 s).
    func watch(pasted text: String) {
        stop()
        guard text.split(separator: " ").count >= 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let (el, value) = Self.focusedValue(), value.contains(text) else { return }
            self.element = el; self.pasted = text; self.baseline = value; self.lastSeen = value
            self.ticks = 0; self.stableTicks = 0; self.learned = false
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; element = nil }

    private func tick() {
        ticks += 1
        guard let element, ticks <= 30, !learned else { stop(); return }
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let current = value as? String else { stop(); return }
        if current == lastSeen { stableTicks += 1 } else { stableTicks = 0; lastSeen = current }
        guard current != baseline, stableTicks >= 2 else { return }
        if let (heard, corrected) = Self.correction(baseline: baseline, current: current, pasted: pasted) {
            learned = true
            Log.write("edit watcher: learned \"\(heard)\" -> \"\(corrected)\"")
            onLearned?(heard, corrected)
            stop()
        } else {
            // The user changed something larger than a word; stop watching rather than guess.
            if abs(current.count - baseline.count) > 40 { stop() }
        }
    }

    /// Finds a single word replacement inside the pasted region: same word count, exactly one word
    /// differs, letters only, not just a case change. Returns (heard, corrected).
    static func correction(baseline: String, current: String, pasted: String) -> (String, String)? {
        guard let range = baseline.range(of: pasted) else { return nil }
        // Map the pasted region onto the current text using the unchanged prefix and suffix around it.
        let prefix = String(baseline[..<range.lowerBound]), suffix = String(baseline[range.upperBound...])
        guard current.hasPrefix(prefix), current.hasSuffix(suffix), current.count >= prefix.count + suffix.count else { return nil }
        let start = current.index(current.startIndex, offsetBy: prefix.count)
        let end = current.index(current.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        let edited = String(current[start..<end])
        let a = pasted.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        let b = edited.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        guard a.count == b.count, !a.isEmpty else { return nil }
        let strip: (String) -> String = { $0.trimmingCharacters(in: .punctuationCharacters) }
        var diffs: [(String, String)] = []
        for (x, y) in zip(a, b) where strip(x) != strip(y) { diffs.append((strip(x), strip(y))) }
        guard diffs.count == 1, let (heard, corrected) = diffs.first else { return nil }
        guard heard.lowercased() != corrected.lowercased(), corrected.count >= 3, heard.count >= 2,
              corrected.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }), heard.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" })
        else { return nil }
        return (heard, corrected)
    }
}
