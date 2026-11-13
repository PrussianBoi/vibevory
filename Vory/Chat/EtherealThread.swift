#if os(macOS)
import AppKit
import SwiftUI
import VoryCore

/// VibeVory's "ethereal" chat on the Mac: small, light text with a faint glow over the window's aurora, soft glass for
/// the person's own messages and the composer, and each run of tool calls folded into one quiet line. The iPhone and
/// iPad keep Vory's bubbles; everything here is Mac-only.
enum Ethereal {
    /// Text and fills: near-white over the dark sky, near-black in the light appearance.
    static func ink(_ alpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.965, green: 0.957, blue: 1, alpha: alpha)
                : NSColor(srgbRed: 0.06, green: 0.06, blue: 0.12, alpha: min(1, alpha + 0.04))
        })
    }

    /// Primary words (about 90 %).
    static let text = ink(0.90)
    /// The folded work line, step summaries (about 58 %).
    static let dim = ink(0.58)
    /// Timestamps, system lines, details after a "·" (about 36 %).
    static let faint = ink(0.36)
    /// Soft glass and pill fills (6 %).
    static let fill = ink(0.06)
    /// The user's pill's inner stroke (9 %).
    static let pillStroke = ink(0.09)
    /// The composer's inner stroke (16 %).
    static let composerStroke = ink(0.16)

    /// The faint glow under the replies' words: a light blue-white at 12 % in the dark, nothing in the light.
    static let glow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.78, green: 0.82, blue: 1, alpha: 0.12)
            : NSColor.clear
    })

    /// Inline code: a light periwinkle (#d6dcff) in the dark, a deeper one in the light.
    static let code = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xD6 / 255, green: 0xDC / 255, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0.29, green: 0.34, blue: 0.69, alpha: 1)
    })

    /// The send button's circle (85 %) and its dark arrow.
    static let sendFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.85)
            : NSColor(srgbRed: 0.08, green: 0.08, blue: 0.16, alpha: 0.85)
    })
    static let sendGlyph = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.08, green: 0.08, blue: 0.16, alpha: 1)
            : NSColor(white: 1, alpha: 0.95)
    })

    static let bodySize: CGFloat = 12.5
    static let body = Font.system(size: bodySize)
    /// About 1.7× line height at 12.5 pt.
    static let lineSpacing: CGFloat = 6
    static let codeFont = Font.system(size: 11.5, design: .monospaced)
    /// Timestamps and system lines.
    static let small = Font.system(size: 11)
    /// The reading column the thread and the composer share.
    static let column: CGFloat = 620

    /// Inline code runs in the periwinkle monospace (`MarkdownView.inlineCached`).
    static func styleInlineCode(_ a: inout AttributedString) {
        var ranges: [Range<AttributedString.Index>] = []
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true { ranges.append(run.range) }
        // The SwiftUI keys by type: on the Mac `foregroundColor` and `font` also name AppKit's attributes.
        for r in ranges {
            a[r][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = code
            a[r][AttributeScopes.SwiftUIAttributes.FontAttribute.self] = codeFont
        }
    }
}

extension View {
    /// Glass recipe H, Dev's pick from the glass test (2026-11-12): clear Liquid Glass with a light
    /// frost underneath and a hairline rim. `frost` thickens it where text must stay readable.
    func vibeGlass<S: InsettableShape>(_ shape: S, tint: Color = .white.opacity(0.03), frost: Double = 0.5, rim: Bool = true) -> some View {
        glassEffect(.clear.tint(tint), in: shape)
            .background(.ultraThinMaterial.opacity(frost), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(rim ? 0.16 : 0), lineWidth: 0.5).allowsHitTesting(false))
    }

    /// A reply's words on the Mac: 12.5 pt, airy, near-white.
    func etherealReply() -> some View {
        font(Ethereal.body)
            .lineSpacing(Ethereal.lineSpacing)
            .foregroundStyle(Ethereal.text)
        // No glow: a shadow on a whole reply renders it twice, off-screen, on every redraw
        // (streaming, scrolling, the sky moving), which made long chats lag.
    }

    /// The soft glass pill of the person's own message.
    func etherealPill(cornerRadius: CGFloat = 16) -> some View {
        vibeGlass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// A small 22 pt control pill in the composer (model, effort, +).
    func etherealControlPill(hovered: Bool = false) -> some View {
        font(.system(size: 11))
            .foregroundStyle(Ethereal.dim)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Ethereal.ink(hovered ? 0.10 : 0.06), in: .capsule)
            .contentShape(.capsule)
    }
}

// MARK: - Folded work

extension TranscriptRowModel {
    /// A tool call (not a message to another bot, which keeps its notice) or a step that only thought: what a run of
    /// work between replies is made of.
    static func isStep(_ item: TranscriptItem) -> Bool {
        if case .tool(let a) = item.kind { return a.delivery == nil }
        return item.isThinkingOnly
    }

    static func isToolStep(_ item: TranscriptItem) -> Bool {
        if case .tool(let a) = item.kind { return a.delivery == nil }
        return false
    }

    /// Each run of work between replies as one row: the run's first row, carrying the run's items as its `steps`. A
    /// run of thinking alone (no tool call) stays as it was. The row keeps its first item's id, so it stays the same
    /// row as the run grows, and its open state goes with it.
    static func foldingSteps(_ rows: [TranscriptRowModel]) -> [TranscriptRowModel] {
        guard rows.contains(where: { isToolStep($0.item) }) else { return rows }
        var out: [TranscriptRowModel] = []
        out.reserveCapacity(rows.count)
        var i = 0
        while i < rows.count {
            guard isStep(rows[i].item) else { out.append(rows[i]); i += 1; continue }
            var j = i
            while j < rows.count, isStep(rows[j].item) { j += 1 }
            let run = rows[i..<j]
            if run.contains(where: { isToolStep($0.item) }) {
                var head = rows[i]
                head.steps = run.map(\.item)
                out.append(head)
            } else {
                out.append(contentsOf: run)
            }
            i = j
        }
        return out
    }
}

/// One quiet line for a run of tool calls: "Worked for 1m 42s · 7 steps ▸". A click opens the list of steps, one line
/// each; a step's line opens its full call (a tool) or its whole reasoning (a step that only thought). Failures stay
/// in the line, so nothing that went wrong is folded out of sight.
struct WorkedLine: View {
    var steps: [TranscriptItem]
    var open: Binding<Bool>
    var botLabel: String?
    var onShowAll: (_ title: String, _ text: String) -> Void = { _, _ in }
    @State private var shownCall: ToolActivity?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Its top on screen, for the thread's hold of it while it opens (`CardHold`).
    @State private var top = CardHold.Top()

    nonisolated static func tool(_ item: TranscriptItem) -> ToolActivity? {
        guard case .tool(let a) = item.kind else { return nil }
        return a
    }

    private var tools: [ToolActivity] { steps.compactMap { Self.tool($0) } }
    private var running: Bool { tools.contains { $0.status == .running } }
    private var failed: Int { tools.filter { $0.status == .failed }.count }

    /// From the first step's start to the last one's end, or the steps' own durations added up when the times say
    /// less (a history without times); nil under a second.
    private var elapsed: TimeInterval? {
        guard let first = steps.first, let last = steps.last else { return nil }
        let end = last.timestamp.addingTimeInterval(Self.tool(last)?.durationSeconds ?? 0)
        let span = end.timeIntervalSince(first.timestamp)
        let sum = tools.compactMap(\.durationSeconds).reduce(0, +)
        let best = max(span, sum)
        return best >= 1 ? best : nil
    }

    nonisolated static func duration(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t)s" }
        if t < 3600 { return t % 60 == 0 ? "\(t / 60)m" : "\(t / 60)m \(t % 60)s" }
        return "\(t / 3600)h \((t % 3600) / 60)m"
    }

    private var title: String {
        let n = tools.count
        let count = "\(n) step\(n == 1 ? "" : "s")"
        if running { return "Working · \(count)" }
        if let e = elapsed { return "Worked for \(Self.duration(e)) · \(count)" }
        return count
    }

    var body: some View {
        let isOpen = open.wrappedValue
        VStack(alignment: .leading, spacing: 7) {
            Button { toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square").font(.system(size: 11)).foregroundStyle(Ethereal.dim)
                    Image(systemName: "apple.terminal").font(.system(size: 11)).foregroundStyle(Ethereal.dim)
                    Text(title).foregroundStyle(Ethereal.dim)
                        .contentTransition(.numericText())
                    if failed > 0 {
                        Text("· \(failed) failed").foregroundStyle(Color.red.opacity(0.85))
                    }
                    if running { ProgressView().controlSize(.mini) }
                    Image(systemName: "arrowtriangle.right.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Ethereal.faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .font(.system(size: 12))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title + (failed > 0 ? ", \(failed) failed" : ""))
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .accessibilityHint("Shows the steps")

            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps, id: \.id) { step in stepRow(step) }
            }
            .padding(.leading, 2)
            .folded(open: isOpen, spacing: 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { _, y in
            top.y = y
            if top.armed { CardHold.shared.moved(top, to: y) }
        }
        .sheet(item: $shownCall) { a in
            ToolCallSheet(activity: a, fullCall: ToolCardView.fullCall(for: a)).sheetFrame(.wide).withAppModel()
        }
    }

    private func toggle() {
        CardHold.shared.arm(top)
        withAnimation(reduceMotion ? nil : .snappy) { open.wrappedValue.toggle() }
    }

    @ViewBuilder private func stepRow(_ step: TranscriptItem) -> some View {
        if let a = Self.tool(step) {
            Button { shownCall = a } label: {
                HStack(spacing: 9) {
                    Circle().fill(a.status == .failed ? Color.red.opacity(0.8) : a.status == .running ? Ethereal.code : Ethereal.faint)
                        .frame(width: 4, height: 4)
                    Text(Self.summary(a)).foregroundStyle(Ethereal.dim).lineLimit(1).truncationMode(.middle)
                    if let d = Self.detail(a) {
                        Text("· " + d).foregroundStyle(a.status == .failed ? Color.red.opacity(0.8) : Ethereal.faint).lineLimit(1).fixedSize()
                    }
                }
                .font(.system(size: 12))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the full call")
            .accessibilityLabel(Self.summary(a) + (Self.detail(a).map { ", " + $0 } ?? ""))
        } else if case .assistant(_, let reasoning?, _) = step.kind {
            Button { onShowAll("\(botLabel ?? "Bot") · Reasoning", reasoning) } label: {
                HStack(spacing: 9) {
                    Circle().fill(Ethereal.faint).frame(width: 4, height: 4)
                    Text("Thought").foregroundStyle(Ethereal.dim)
                    Text("· " + Self.firstLine(reasoning)).foregroundStyle(Ethereal.faint).lineLimit(1)
                }
                .font(.system(size: 12))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Show the reasoning")
            .accessibilityLabel("Thought: " + Self.firstLine(reasoning))
        }
    }

    nonisolated static func firstLine(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = t.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? t
        return line.count > 160 ? String(line.prefix(159)) + "…" : line
    }

    /// The step in a few words: "Ran du -sh /var/log/*", "Read /etc/logrotate.d/nginx".
    nonisolated static func summary(_ a: ToolActivity) -> String {
        let name = a.name.lowercased()
        let context = a.context.map(firstLine).flatMap { $0.isEmpty ? nil : $0 }
        let shell = name == "terminal" || name == "bash" || name == "shell" || name.contains("exec") || name.contains("command")
        if shell, let c = ToolCardView.fullCall(for: a).map(firstLine) ?? context, !c.isEmpty { return "Ran " + c }
        if let c = context {
            if name.contains("read") || name.contains("view") || name.contains("cat") { return "Read " + c }
            if name.contains("write") || name.contains("patch") || name.contains("edit") || name.contains("replace") { return "Edited " + c }
            if name.contains("search") || name.contains("grep") || name.contains("find") || name.contains("glob") { return "Searched " + c }
            if name.contains("browse") || name.contains("fetch") || name.contains("web") || name.contains("navigate") { return "Opened " + c }
            return capitalized(a.displayName) + " " + c
        }
        return capitalized(a.displayName)
    }

    /// What came of it, dim after a "·": its time, else how much it gave back.
    nonisolated static func detail(_ a: ToolActivity) -> String? {
        switch a.status {
        case .running: return "running"
        case .failed: return "failed"
        case .done: break
        }
        if let d = a.durationSeconds, d > 0 { return d < 10 ? String(format: "%.1fs", d) : duration(d) }
        if let r = a.resultText, !r.isEmpty {
            let lines = r.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
            if lines > 1 { return "\(lines) lines" }
            return ByteCountFormatter.string(fromByteCount: Int64(r.utf8.count), countStyle: .file)
        }
        return nil
    }

    nonisolated private static func capitalized(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
}
#endif
