import AppKit
import SwiftUI

/// Draws a plugin's rendered tree (PluginHost.swift) with SwiftUI: the plugin SDK's components
/// become native controls in the app's glass (recipe H), and its Tailwind-styled `div`s become
/// stacks, padding, text styles and glass cards. A plugin is never shown as a web page.
///
/// The translation, in short:
/// - `flex` → HStack, `flex-col`/block → VStack, `gap-*`/`p-*`/`m-*`/`w-*` → spacing, padding, frames,
///   `flex-1`/`w-full` → fill, `overflow-*-auto` → ScrollView, `grid-cols-N` → a grid.
/// - `rounded + border` → glass card, `aside` → glass panel, `border-b/-r` → hairlines.
/// - `text-*`, `font-*`, `truncate`, the Desktop's colour variables → SwiftUI text styles.
/// - A track with `%`-wide fills → a native progress bar; a run of filter Buttons → a segmented
///   control; glyphs like ✔ ◐ ✗ → SF Symbols.
struct PluginRootView: View {
    let node: PluginNode

    var body: some View {
        PluginDraw.children(node.children, in: .init(row: false, text: .base, stretch: true))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
    }
}

// MARK: - Styles parsed from class names

/// Text style handed down the tree, as CSS inherits it.
struct PluginTextStyle {
    var size: CGFloat = 12.5
    var weight: Font.Weight = .regular
    var mono = false
    var color: Color = .white.opacity(0.9)
    var uppercase = false
    var tracking: CGFloat = 0
    var italic = false
    static let base = PluginTextStyle()

    var font: Font {
        var f = Font.system(size: size, weight: weight, design: mono ? .monospaced : .default)
        if italic { f = f.italic() }
        return f
    }
}

/// What a node is drawn inside: a row or a column, and whether block children stretch.
struct PluginContext {
    var row: Bool
    var text: PluginTextStyle
    var stretch: Bool
    var formSubmit: String? = nil
}

/// One element's classes, read once.
struct TW {
    var flex = false, col = false, grid = false, cols = 0
    var gap: CGFloat?
    var pad = EdgeInsets(), margin = EdgeInsets()
    var width: CGFloat?, height: CGFloat?, minHeight: CGFloat?, maxHeight: CGFloat?, maxWidth: CGFloat?
    var fillW = false, fillH = false, grow = false
    var align: String?, justify: String?
    var scrollY = false, scrollX = false
    var hidden = false, truncate = false, lines: Int?, noWrap = false
    var size: CGFloat?, weight: Font.Weight?, mono = false, italic = false, uppercase = false, tracking: CGFloat?
    var color: Color?, bg: Color?, selectedBG = false, hoverBG = false
    var border = false, borderB = false, borderT = false, borderR = false, borderL = false
    var radius: CGFloat?, roundedFull = false
    var textAlign: String?
    var opacity: Double?

    init(_ className: String) {
        for raw in className.split(separator: " ") {
            var c = String(raw)
            if c.hasPrefix("hover:bg") { hoverBG = true; continue }
            if c.hasPrefix("last:") || c.hasPrefix("first:") || c.hasPrefix("focus") || c.hasPrefix("group-") || c.hasPrefix("data-") || c.hasPrefix("aria-") || c.hasPrefix("dark:") || c.hasPrefix("disabled:") { continue }
            // Responsive prefixes: the Mac window is wide, so take the desktop value.
            for p in ["sm:", "md:", "lg:", "xl:", "2xl:"] where c.hasPrefix(p) { c.removeFirst(p.count) }
            if c.contains(":") && !c.hasPrefix("[") { continue }
            parse(c)
        }
    }

    static func space(_ s: Substring) -> CGFloat? { space(String(s)) }
    static func space(_ s: String) -> CGFloat? {
        if s == "px" { return 1 }
        if s.hasPrefix("[") && s.hasSuffix("]") { return length(String(s.dropFirst().dropLast())) }
        return Double(s).map { CGFloat($0 * 4) }
    }
    static func length(_ s: String) -> CGFloat? {
        if s.hasSuffix("px") { return Double(s.dropLast(2)).map { CGFloat($0) } }
        if s.hasSuffix("rem") { return Double(s.dropLast(3)).map { CGFloat($0 * 16) } }
        if s.hasSuffix("em") { return Double(s.dropLast(2)).map { CGFloat($0 * 13) } }
        return Double(s).map { CGFloat($0) }
    }

    mutating func parse(_ c: String) {
        func after(_ p: String) -> String? { c.hasPrefix(p) ? String(c.dropFirst(p.count)) : nil }
        switch c {
        case "flex", "inline-flex": flex = true; return
        case "flex-col": flex = true; col = true; return
        case "flex-row": flex = true; col = false; return
        case "grid": grid = true; return
        case "hidden", "sr-only", "invisible": hidden = true; return
        case "flex-1", "grow", "flex-auto": grow = true; return
        case "w-full", "min-w-full": fillW = true; return
        case "h-full", "min-h-full", "h-screen": fillH = true; return
        case "overflow-auto", "overflow-y-auto", "overflow-y-scroll", "overflow-scroll": scrollY = true; return
        case "overflow-x-auto", "overflow-x-scroll": scrollX = true; return
        case "truncate": truncate = true; return
        case "whitespace-pre", "whitespace-nowrap": noWrap = true; return
        case "font-mono": mono = true; return
        case "italic": italic = true; return
        case "uppercase": uppercase = true; return
        case "tracking-wide": tracking = 0.4; return
        case "tracking-wider", "tracking-widest": tracking = 0.9; return
        case "font-medium": weight = .medium; return
        case "font-semibold": weight = .semibold; return
        case "font-bold": weight = .bold; return
        case "font-normal": weight = .regular; return
        case "text-xs": size = 11.5; return
        case "text-sm": size = 12.5; return
        case "text-base": size = 14; return
        case "text-lg": size = 16; return
        case "text-xl": size = 18; return
        case "text-2xl": size = 22; return
        case "text-left": textAlign = "left"; return
        case "text-center": textAlign = "center"; return
        case "text-right": textAlign = "right"; return
        case "border": border = true; return
        case "border-b": borderB = true; return
        case "border-t": borderT = true; return
        case "border-r": borderR = true; return
        case "border-l": borderL = true; return
        case "rounded": radius = 6; return
        case "rounded-full": roundedFull = true; return
        default: break
        }
        if let v = after("items-") { align = v; return }
        if let v = after("justify-") { justify = v; return }
        if let v = after("grid-cols-"), let n = Int(v) { cols = n; return }
        if let v = after("gap-x-") ?? after("gap-y-") ?? after("gap-") { gap = Self.space(v); return }
        if let v = after("space-y-") { gap = Self.space(v); flex = true; col = true; return }
        if let v = after("space-x-") { gap = Self.space(v); flex = true; return }
        if let v = after("line-clamp-") { lines = Int(v); return }
        if let v = after("opacity-") { opacity = Double(v).map { $0 / 100 }; return }
        if let v = after("rounded-") {
            if v.hasPrefix("[") { radius = Self.space(v) } else {
                radius = ["sm": 4, "md": 6, "lg": 8, "xl": 12, "2xl": 16, "3xl": 24, "none": 0][v] ?? 6
            }
            return
        }
        if let v = after("text-[") { size = Self.length(String(v.dropLast())); return }
        if let v = after("text-") { color = Self.color(v); return }
        if let v = after("bg-") {
            if v.contains("selected") || v.contains("active") { selectedBG = true } else { bg = Self.fill(v) }
            return
        }
        if c.hasPrefix("p-") || c.hasPrefix("px-") || c.hasPrefix("py-") || c.hasPrefix("pt-") || c.hasPrefix("pb-") || c.hasPrefix("pl-") || c.hasPrefix("pr-") {
            Self.edges(c, into: &pad)
            return
        }
        if c.hasPrefix("m-") || c.hasPrefix("mx-") || c.hasPrefix("my-") || c.hasPrefix("mt-") || c.hasPrefix("mb-") || c.hasPrefix("ml-") || c.hasPrefix("mr-") {
            Self.edges(c, into: &margin)
            return
        }
        if let v = after("max-h-") { maxHeight = Self.space(v); return }
        if let v = after("min-h-") { minHeight = Self.space(v); return }
        if let v = after("max-w-") {
            maxWidth = Self.space(v) ?? ["xs": 320, "sm": 384, "md": 448, "lg": 512, "xl": 576, "2xl": 672, "3xl": 768, "4xl": 896, "5xl": 1024, "prose": 640][v]
            return
        }
        if let v = after("w-") { width = Self.space(v); return }
        if let v = after("h-") { height = Self.space(v); return }
        if let v = after("size-") { width = Self.space(v); height = width; return }
    }

    static func edges(_ c: String, into e: inout EdgeInsets) {
        let parts = c.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let v = space(parts[1]) else { return }
        switch parts[0].dropFirst() {
        case "": e = EdgeInsets(top: v, leading: v, bottom: v, trailing: v)
        case "x": e.leading = v; e.trailing = v
        case "y": e.top = v; e.bottom = v
        case "t": e.top = v
        case "b": e.bottom = v
        case "l": e.leading = v
        case "r": e.trailing = v
        default: break
        }
    }

    /// The Desktop's text colours (its CSS variables and Tailwind names) on the app's dark glass.
    static func color(_ v: String) -> Color? {
        let s = v.lowercased()
        if s.contains("danger") || s.contains("destructive") || s.contains("red") || s.contains("error") { return Color(red: 1, green: 0.48, blue: 0.48) }
        if s.contains("warn") || s.contains("amber") || s.contains("yellow") || s.contains("orange") { return Color(red: 1, green: 0.75, blue: 0.4) }
        if s.contains("success") || s.contains("green") || s.contains("emerald") { return Color(red: 0.45, green: 0.88, blue: 0.6) }
        if s.contains("accent") || s.contains("primary") || s.contains("blue") || s.contains("link") { return Color(red: 0.6, green: 0.75, blue: 1) }
        if s.contains("tertiary") || s.contains("muted") || s.contains("quaternary") || s.contains("faint") { return .white.opacity(0.45) }
        if s.contains("secondary") { return .white.opacity(0.62) }
        if s.contains("foreground") || s.contains("primary") || s == "white" { return .white.opacity(0.92) }
        return nil
    }

    static func fill(_ v: String) -> Color? {
        let s = v.lowercased()
        if s.contains("hover") || s.contains("transparent") || s == "background" || s.contains("(--ui-bg)") { return nil }
        if s.contains("danger") || s.contains("destructive") || s.contains("red") { return Color(red: 1, green: 0.38, blue: 0.4) }
        if s.contains("warn") || s.contains("amber") || s.contains("yellow") { return Color(red: 1, green: 0.72, blue: 0.3) }
        if s.contains("success") || s.contains("green") || s.contains("emerald") { return Color(red: 0.35, green: 0.85, blue: 0.55) }
        if s.contains("accent") || s.contains("primary") || s.contains("blue") { return Color(red: 0.45, green: 0.62, blue: 1) }
        if s.contains("stroke") || s.contains("muted") || s.contains("secondary") || s.contains("border") { return .white.opacity(0.1) }
        return .white.opacity(0.05)
    }

    func applied(to t: PluginTextStyle) -> PluginTextStyle {
        var t = t
        if let size { t.size = size }
        if let weight { t.weight = weight }
        if mono { t.mono = true }
        if italic { t.italic = true }
        if uppercase { t.uppercase = true }
        if let tracking { t.tracking = tracking }
        if let color { t.color = color }
        return t
    }

    var hAlign: HorizontalAlignment { align == "center" ? .center : align == "end" ? .trailing : .leading }
    var vAlign: VerticalAlignment {
        switch align { case "start": .top; case "end": .bottom; case "baseline": .firstTextBaseline; default: .center }
    }
    var frameAlign: Alignment {
        switch textAlign { case "center": .center; case "right": .trailing; default: .leading }
    }
}

// MARK: - The translation

@MainActor
enum PluginDraw {
    static let inlineTags: Set<String> = ["span", "strong", "b", "em", "i", "code", "small", "a", "label", "kbd", "mark", "s", "u", "abbr", "time"]
    static let blockTags: Set<String> = ["div", "section", "header", "footer", "main", "nav", "article", "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "pre", "form", "aside", "table", "tr", "details", "fieldset", "blockquote", "hr", "EmptyState", "ErrorState", "Separator", "ScrollArea", "FadeScroll"]

    static let glyphs: [String: (String, Color)] = [
        "✔": ("checkmark.circle.fill", Color(red: 0.45, green: 0.88, blue: 0.6)),
        "✓": ("checkmark.circle.fill", Color(red: 0.45, green: 0.88, blue: 0.6)),
        "◐": ("circle.lefthalf.filled", Color(red: 0.6, green: 0.75, blue: 1)),
        "◑": ("circle.righthalf.filled", Color(red: 0.6, green: 0.75, blue: 1)),
        "✗": ("xmark.circle.fill", Color(red: 1, green: 0.48, blue: 0.48)),
        "✕": ("xmark.circle.fill", Color(red: 1, green: 0.48, blue: 0.48)),
        "✘": ("xmark.circle.fill", Color(red: 1, green: 0.48, blue: 0.48)),
        "■": ("stop.circle.fill", .white.opacity(0.5)),
        "○": ("circle.dashed", .white.opacity(0.4)),
        "●": ("circle.fill", .white.opacity(0.7)),
        "⏸": ("pause.circle.fill", Color(red: 1, green: 0.75, blue: 0.4)),
        "⚠": ("exclamationmark.triangle.fill", Color(red: 1, green: 0.75, blue: 0.4)),
        "⚠️": ("exclamationmark.triangle.fill", Color(red: 1, green: 0.75, blue: 0.4)),
    ]

    static func visible(_ nodes: [PluginNode]) -> [PluginNode] {
        nodes.filter { n in
            if n.isText { return !(n.text ?? "").isEmpty }
            return !TW(n.className).hidden && n.type != "svg" && n.type != "script" && n.type != "style"
        }
    }

    /// A node's children laid out in a column (block flow).
    static func children(_ nodes: [PluginNode], in ctx: PluginContext) -> AnyView {
        let kids = visible(nodes)
        if let text = inlineText(kids, ctx.text) { return AnyView(text) }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            ForEach(kids) { k in node(k, in: PluginContext(row: false, text: ctx.text, stretch: ctx.stretch, formSubmit: ctx.formSubmit)) }
        })
    }

    // MARK: Text

    /// Children that are only text and inline elements, as one Text (so a sentence wraps as one).
    static func inlineText(_ kids: [PluginNode], _ ts: PluginTextStyle) -> Text? {
        guard !kids.isEmpty, kids.allSatisfy({ isInline($0) }) else { return nil }
        if kids.count == 1, kids[0].isText, let g = glyphs[(kids[0].text ?? "").trimmingCharacters(in: .whitespaces)] {
            return Text(Image(systemName: g.0)).foregroundStyle(g.1).font(.system(size: ts.size))
        }
        var out = AttributedString()
        for k in kids { append(k, ts, into: &out) }
        return Text(out)
    }

    static func isInline(_ n: PluginNode) -> Bool {
        if n.isText { return true }
        guard inlineTags.contains(n.type) else { return false }
        let tw = TW(n.className)
        if tw.flex || tw.width != nil || tw.grow || tw.border || tw.bg != nil || n.handler("onClick") != nil { return false }
        return n.children.allSatisfy { isInline($0) }
    }

    static func append(_ n: PluginNode, _ ts: PluginTextStyle, into out: inout AttributedString) {
        if n.isText {
            var s = n.text ?? ""
            if ts.uppercase { s = s.uppercased() }
            var a = AttributedString(s)
            a.swiftUI.font = ts.font
            a.swiftUI.foregroundColor = ts.color
            if ts.tracking != 0 { a.swiftUI.tracking = ts.tracking }
            out.append(a)
            return
        }
        var t = TW(n.className).applied(to: ts)
        switch n.type {
        case "strong", "b": t.weight = .semibold
        case "em", "i": t.italic = true
        case "code", "kbd": t.mono = true; t.size = max(10, t.size - 1)
        case "small": t.size = max(10, t.size - 1.5)
        case "a": t.color = Color(red: 0.6, green: 0.75, blue: 1)
        default: break
        }
        for k in n.children { append(k, t, into: &out) }
    }

    static func styledText(_ s: String, _ ts: PluginTextStyle) -> Text {
        Text(ts.uppercase ? s.uppercased() : s).font(ts.font).foregroundStyle(ts.color).tracking(ts.tracking)
    }

    // MARK: Nodes

    static func node(_ n: PluginNode, in ctx: PluginContext) -> AnyView {
        if n.isText {
            let s = n.text ?? ""
            if let g = glyphs[s.trimmingCharacters(in: .whitespaces)] {
                return AnyView(Image(systemName: g.0).font(.system(size: ctx.text.size)).foregroundStyle(g.1))
            }
            return AnyView(styledText(s, ctx.text))
        }
        let tw = TW(n.className)
        let ts = tw.applied(to: ctx.text)
        let view: AnyView
        switch n.type {
        // The SDK's components: native controls.
        case "Button": view = AnyView(PluginButton(node: n, ts: ts))
        case "Badge": view = AnyView(PluginBadge(node: n))
        case "Codicon":
            view = AnyView(Image(systemName: PluginSymbols.symbol(n.string("name")))
                .font(.system(size: max(10, ts.size - 0.5)))
                .foregroundStyle(ts.color))
        case "EmptyState", "ErrorState": view = AnyView(PluginEmptyState(node: n, error: n.type == "ErrorState"))
        case "Input", "SearchField", "input":
            if n.string("type") == "checkbox" {
                view = AnyView(PluginToggle(node: n, style: .checkbox))
            } else {
                view = AnyView(PluginTextField(node: n, multiline: false, formSubmit: ctx.formSubmit))
            }
        case "Textarea", "textarea": view = AnyView(PluginTextField(node: n, multiline: true, formSubmit: ctx.formSubmit))
        case "Checkbox": view = AnyView(PluginToggle(node: n, style: .checkbox))
        case "Switch": view = AnyView(PluginToggle(node: n, style: .switch))
        case "Select", "select": view = AnyView(PluginSelect(node: n))
        case "SegmentedControl": view = AnyView(PluginSegments.fromOptions(n))
        case "Tabs": view = AnyView(PluginSegments.fromTabs(n, ctx: ctx))
        case "ConfirmDialog": view = AnyView(PluginConfirm(node: n))
        case "Dialog": view = AnyView(PluginDialog(node: n, ctx: ctx))
        case "DropdownMenu": view = AnyView(PluginMenu(node: n, ctx: ctx))
        case "Popover": view = AnyView(PluginPopover(node: n, ctx: ctx))
        case "Tip", "Tooltip":
            let tip = n.string("content") ?? find(n, "TooltipContent")?.plainText ?? ""
            let body = n.type == "Tooltip" ? (find(n, "TooltipTrigger")?.children ?? []) : n.children
            view = AnyView(row(body, tw: TW(""), ctx: ctx).help(tip))
        case "TooltipProvider": view = children(n.children, in: ctx)
        case "Separator", "DropdownMenuSeparator", "hr":
            view = AnyView(Rectangle().fill(.white.opacity(0.1)).frame(height: 0.5).frame(maxWidth: .infinity).padding(.vertical, 4))
        case "Loader", "GlyphSpinner": view = AnyView(ProgressView().controlSize(.small).scaleEffect(0.8))
        case "Skeleton": view = AnyView(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)).frame(height: tw.height ?? 14))
        case "Kbd":
            view = AnyView(Text(n.plainText).font(.system(size: 10.5, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 5).padding(.vertical, 1).background(.white.opacity(0.08), in: .rect(cornerRadius: 4)))
        case "StatusDot":
            view = AnyView(Circle().fill(TW.fill(n.string("tone") ?? "muted") ?? .white.opacity(0.4)).frame(width: 7, height: 7))
        case "CopyButton":
            let text = n.string("text") ?? n.string("value") ?? ""
            view = AnyView(Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.55)).help("Copy"))
        case "DisclosureCaret":
            view = AnyView(Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(n.bool("open") ? 90 : 0)).foregroundStyle(.white.opacity(0.5)))
        case "MessageTextContent":
            let md = n.string("text") ?? n.string("content") ?? n.plainText
            view = AnyView(Text((try? AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(md))
                .font(ts.font).foregroundStyle(ts.color).textSelection(.enabled))
        case "LogView":
            let text = n.string("text") ?? (n.props["lines"] as? [String])?.joined(separator: "\n") ?? n.plainText
            view = AnyView(ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 320))
        case "img":
            let url = n.string("src").flatMap(URL.init(string:))
            view = AnyView(AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.white.opacity(0.05) }
                .frame(width: tw.width, height: tw.height))
        // Plain elements.
        case "button", "RowButton", "a":
            view = AnyView(PluginRowButton(node: n, tw: tw, ctx: PluginContext(row: tw.flex && !tw.col, text: ts, stretch: true, formSubmit: ctx.formSubmit)))
        case "pre", "code" where !isInline(n) || n.type == "pre":
            var mono = ts; mono.mono = true; mono.size = min(ts.size, 11.5)
            let text = styledText(n.plainText, mono).textSelection(.enabled)
            let body: AnyView = tw.noWrap || n.className.contains("whitespace-pre ") || n.className.hasSuffix("whitespace-pre")
                ? AnyView(ScrollView(.horizontal, showsIndicators: false) { text.fixedSize(horizontal: true, vertical: false) })
                : AnyView(text)
            view = decorate(body, n, tw, ctx: ctx)
        default:
            view = element(n, tw: tw, ts: ts, ctx: ctx)
        }
        return sized(view, n, tw, ctx: ctx)
    }

    /// Size against the parent: fixed widths, fill, stretch, margins.
    static func sized(_ v: AnyView, _ n: PluginNode, _ tw: TW, ctx: PluginContext) -> AnyView {
        var v = v
        if let o = tw.opacity { v = AnyView(v.opacity(o)) }
        let block = blockTags.contains(n.type) || tw.flex || tw.grid
        if tw.width != nil || tw.height != nil {
            v = AnyView(v.frame(width: tw.width, height: tw.height, alignment: tw.frameAlign))
        }
        let fillW = tw.fillW || (ctx.row && tw.grow) || (!ctx.row && ctx.stretch && block && tw.width == nil)
            || (tw.truncate && tw.width == nil && (tw.grow || !ctx.row))
        let fillH = tw.fillH || (!ctx.row && tw.grow)
        if fillW || fillH {
            v = AnyView(v.frame(maxWidth: fillW ? .infinity : nil, maxHeight: fillH ? .infinity : nil,
                                alignment: Alignment(horizontal: tw.frameAlign.horizontal, vertical: .top)))
        }
        if tw.margin != EdgeInsets() { v = AnyView(v.padding(tw.margin)) }
        return v
    }

    /// The generic element: a stack (or grid) of its children, with padding, card and borders.
    static func element(_ n: PluginNode, tw: TW, ts: PluginTextStyle, ctx: PluginContext) -> AnyView {
        var ts = ts
        switch n.type {
        case "h1": if tw.size == nil { ts.size = 17 }; if tw.weight == nil { ts.weight = .semibold }
        case "h2": if tw.size == nil { ts.size = 15 }; if tw.weight == nil { ts.weight = .semibold }
        case "h3", "h4": if tw.size == nil { ts.size = 13.5 }; if tw.weight == nil { ts.weight = .semibold }
        case "strong", "b", "th": ts.weight = .semibold
        default: break
        }
        let submit = n.type == "form" ? (n.handler("onSubmit") ?? ctx.formSubmit) : ctx.formSubmit
        let kids = visible(n.children)
        let inner = PluginContext(row: false, text: ts, stretch: tw.align == nil, formSubmit: submit)
        var content: AnyView
        if let text = inlineText(kids, ts) {
            var t = AnyView(text.multilineTextAlignment(tw.textAlign == "center" ? .center : tw.textAlign == "right" ? .trailing : .leading))
            if tw.truncate || tw.noWrap { t = AnyView(text.lineLimit(1).truncationMode(.tail)) }
            else if let l = tw.lines { t = AnyView(text.lineLimit(l)) }
            content = t
        } else if let bar = progressBar(n, tw) {
            return bar
        } else if tw.grid && tw.cols > 1 {
            content = AnyView(LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: tw.gap ?? 0, alignment: .topLeading), count: tw.cols),
                                        alignment: .leading, spacing: tw.gap ?? 0) {
                ForEach(kids) { k in node(k, in: inner) }
            })
        } else if (tw.flex && !tw.col) || n.type == "tr" || n.type == "label" && kids.count > 1 {
            content = row(kids, tw: tw, ctx: PluginContext(row: true, text: ts, stretch: false, formSubmit: submit))
        } else {
            content = column(kids, tw: tw, ctx: inner)
        }
        return decorate(content, n, tw, ctx: ctx)
    }

    static func row(_ kids: [PluginNode], tw: TW, ctx: PluginContext) -> AnyView {
        let kids = visible(kids)
        let segments = segmentRuns(kids)
        let between = tw.justify == "between"
        return AnyView(HStack(alignment: tw.vAlign, spacing: tw.gap ?? (ctx.row ? 0 : 0)) {
            if tw.justify == "end" || tw.justify == "center" { Spacer(minLength: 0) }
            ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                if between && i > 0 { Spacer(minLength: 0) }
                switch seg {
                case .one(let k): node(k, in: ctx)
                case .segmented(let buttons): PluginSegments.fromButtons(buttons)
                }
            }
            if tw.justify == "center" { Spacer(minLength: 0) }
        })
    }

    static func column(_ kids: [PluginNode], tw: TW, ctx: PluginContext) -> AnyView {
        AnyView(VStack(alignment: tw.hAlign, spacing: tw.gap ?? 0) {
            if tw.justify == "end" || tw.justify == "center" { Spacer(minLength: 0) }
            ForEach(Array(kids.enumerated()), id: \.element.id) { i, k in
                if tw.justify == "between" && i > 0 { Spacer(minLength: 0) }
                node(k, in: ctx)
            }
            if tw.justify == "center" { Spacer(minLength: 0) }
        })
    }

    /// Padding, scrolling, the card or panel look, hairlines.
    static func decorate(_ content: AnyView, _ n: PluginNode, _ tw: TW, ctx: PluginContext) -> AnyView {
        var v = content
        let panel = n.type == "aside"
        let card = !panel && tw.border && (tw.radius ?? 0) > 0
        var pad = tw.pad
        if card { pad = EdgeInsets(top: max(pad.top, 10), leading: max(pad.leading, 12), bottom: max(pad.bottom, 10), trailing: max(pad.trailing, 12)) }
        if tw.scrollY || tw.scrollX {
            v = AnyView(ScrollView(tw.scrollX && !tw.scrollY ? .horizontal : .vertical) {
                v.padding(pad).frame(maxWidth: tw.scrollX ? nil : .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: tw.maxHeight))
        } else {
            if pad != EdgeInsets() { v = AnyView(v.padding(pad)) }
            if tw.maxHeight != nil || tw.minHeight != nil { v = AnyView(v.frame(minHeight: tw.minHeight, maxHeight: tw.maxHeight, alignment: .top)) }
        }
        if let w = tw.maxWidth { v = AnyView(v.frame(maxWidth: w, alignment: .leading)) }
        let radius = max(tw.radius ?? 0, tw.roundedFull ? 999 : 0)
        if panel {
            // The plugin's side list: a glass panel floating over the sky, as the app's sidebar.
            v = AnyView(v.frame(maxHeight: .infinity, alignment: .top)
                .vibeGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.leading, 10).padding(.vertical, 10).padding(.trailing, 4))
            return v
        }
        if card {
            v = AnyView(v.vibeGlass(RoundedRectangle(cornerRadius: max(radius, 12), style: .continuous)))
        } else if tw.selectedBG {
            v = AnyView(v.background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: max(radius, 8), style: .continuous)))
        } else if let bg = tw.bg {
            v = AnyView(v.background(bg.opacity(0.9), in: RoundedRectangle(cornerRadius: radius, style: .continuous)))
        } else if tw.border && radius == 0 {
            v = AnyView(v.overlay(Rectangle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5)))
        }
        if tw.borderB { v = AnyView(v.overlay(alignment: .bottom) { hairline(h: true) }) }
        if tw.borderT { v = AnyView(v.overlay(alignment: .top) { hairline(h: true) }) }
        if tw.borderR && n.type != "aside" { v = AnyView(v.overlay(alignment: .trailing) { hairline(h: false) }) }
        if tw.borderL { v = AnyView(v.overlay(alignment: .leading) { hairline(h: false) }) }
        return v
    }

    static func hairline(h: Bool) -> some View {
        Rectangle().fill(.white.opacity(0.08)).frame(width: h ? nil : 0.5, height: h ? 0.5 : nil)
    }

    // MARK: Patterns

    /// A track whose children are `%`-wide fills: a progress bar.
    static func progressBar(_ n: PluginNode, _ tw: TW) -> AnyView? {
        let kids = n.children.filter { !$0.isText }
        guard !kids.isEmpty, kids.count == n.children.count, kids.allSatisfy({ $0.children.isEmpty }) else { return nil }
        let parts: [(Double, Color)] = kids.compactMap { k in
            guard let style = k.props["style"] as? [String: Any], let w = style["width"] as? String, w.hasSuffix("%"),
                  let pct = Double(w.dropLast()) else { return nil }
            // Done is white, as in the design; only warning and failure keep a colour.
            let cls = k.className.lowercased()
            let coloured = ["danger", "destructive", "red", "warn", "amber", "yellow"].contains { cls.contains($0) }
            let fill = coloured ? (TW(k.className).bg ?? .white.opacity(0.85)) : .white.opacity(0.85)
            return (pct / 100, fill)
        }
        guard parts.count == kids.count else { return nil }
        let h = max(4, min(tw.height ?? 5, 8))
        return AnyView(GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1))
                HStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                        Rectangle().fill(p.1.gradient).frame(width: geo.size.width * min(max(p.0, 0), 1))
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: h)
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.4), value: parts.map(\.0)))
    }

    enum Segment { case one(PluginNode), segmented([PluginNode]) }

    /// Three or more small Buttons side by side, one of them marked as chosen: filter tabs.
    static func segmentRuns(_ kids: [PluginNode]) -> [Segment] {
        var out: [Segment] = []
        var run: [PluginNode] = []
        func close() {
            let chosen = run.filter { $0.string("variant") == "secondary" || $0.string("variant") == "default" }.count
            if run.count >= 3 && chosen == 1 && run.allSatisfy({ $0.plainText.count <= 16 }) { out.append(.segmented(run)) }
            else { out.append(contentsOf: run.map { .one($0) }) }
            run = []
        }
        for k in kids {
            let v = k.string("variant") ?? "default"
            if k.type == "Button", ["secondary", "ghost", "default"].contains(v), k.handler("onClick") != nil { run.append(k) }
            else { close(); out.append(.one(k)) }
        }
        close()
        return out
    }

    static func find(_ n: PluginNode, _ type: String) -> PluginNode? {
        for k in n.children {
            if k.type == type { return k }
            if let f = find(k, type) { return f }
        }
        return nil
    }

    static func findAll(_ n: PluginNode, _ type: String) -> [PluginNode] {
        n.children.flatMap { k in (k.type == type ? [k] : []) + findAll(k, type) }
    }
}

// MARK: - Controls

@MainActor private var host: PluginHost { PluginHost.shared }

struct PluginButton: View {
    let node: PluginNode
    let ts: PluginTextStyle

    var body: some View {
        let variant = node.string("variant") ?? "default"
        let size = node.string("size") ?? "default"
        let icon = size.hasPrefix("icon")
        Button {
            if let h = node.handler("onClick") { host.dispatch(h) }
        } label: {
            HStack(spacing: 5) {
                ForEach(PluginDraw.visible(node.children)) { k in
                    if k.isText { Text(k.text ?? "") } else { PluginDraw.node(k, in: PluginContext(row: true, text: labelStyle(variant), stretch: false)) }
                }
            }
            .font(.system(size: size == "sm" || size == "xs" ? 11.5 : 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, icon ? 6 : size == "sm" || size == "xs" ? 10 : 13)
            .frame(minWidth: icon ? 24 : nil)
            .frame(height: size == "sm" || size == "xs" || icon ? 24 : 28)
            .contentShape(.capsule)
        }
        .buttonStyle(PluginButtonStyle(variant: variant))
        .disabled(node.bool("disabled") || node.bool("loading"))
    }

    func labelStyle(_ variant: String) -> PluginTextStyle {
        var t = PluginTextStyle.base
        t.size = 11.5; t.weight = .medium
        t.color = variant == "destructive" ? Color(red: 1, green: 0.62, blue: 0.62) : .white.opacity(0.92)
        return t
    }
}

struct PluginButtonStyle: ButtonStyle {
    var variant: String
    func makeBody(configuration: Configuration) -> some View {
        PluginButtonFace(configuration: configuration, variant: variant)
    }
}

private struct PluginButtonFace: View {
    let configuration: ButtonStyleConfiguration
    let variant: String
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        let label = configuration.label
            .foregroundStyle(variant == "destructive" ? Color(red: 1, green: 0.62, blue: 0.62) : variant == "link" ? Color(red: 0.6, green: 0.75, blue: 1) : .white.opacity(0.92))
        Group {
            switch variant {
            case "ghost", "link", "textStrong", "text":
                label.background(.white.opacity(hovered ? 0.08 : 0), in: .capsule)
            case "outline":
                label.background(.white.opacity(hovered ? 0.06 : 0), in: .capsule)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            case "destructive":
                label.vibeGlass(Capsule(), tint: Color.red.opacity(hovered ? 0.3 : 0.22))
            case "secondary":
                label.vibeGlass(Capsule(), tint: .white.opacity(hovered ? 0.09 : 0.04))
            default:
                label.vibeGlass(Capsule(), tint: Color(red: 0.42, green: 0.55, blue: 1).opacity(hovered ? 0.55 : 0.45))
            }
        }
        .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
        .onHover { hovered = $0 }
        .animation(.smooth(duration: 0.12), value: hovered)
    }
}

/// A plain `<button>`: a row that highlights under the pointer and when it is the chosen one.
struct PluginRowButton: View {
    let node: PluginNode
    let tw: TW
    let ctx: PluginContext
    @State private var hovered = false

    var body: some View {
        let radius = max(tw.radius ?? 0, 8)
        let selected = tw.selectedBG
        let card = tw.border && (tw.radius ?? 0) > 0
        var inner = tw
        inner.selectedBG = false
        inner.bg = nil
        inner.border = card ? tw.border : false
        return Button {
            if let h = node.handler("onClick") { host.dispatch(h) }
            else if let href = node.string("href"), let url = URL(string: href) { NSWorkspace.shared.open(url) }
        } label: {
            PluginDraw.element(node, tw: inner, ts: ctx.text, ctx: ctx)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.white.opacity(selected ? 0.11 : hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onHover { hovered = $0 }
        .disabled(node.bool("disabled"))
        .animation(.smooth(duration: 0.12), value: hovered)
    }
}

struct PluginBadge: View {
    let node: PluginNode

    var body: some View {
        let text = node.plainText
        let tint = Self.tint(text: text.lowercased(), variant: node.string("variant") ?? "default")
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint == nil ? .white.opacity(0.75) : tint!.mix(with: .white, by: 0.35))
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background((tint ?? .white).opacity(tint == nil ? 0.08 : 0.18), in: .capsule)
            .overlay(Capsule().strokeBorder((tint ?? .white).opacity(0.25), lineWidth: 0.5))
            .lineLimit(1)
            .fixedSize()
    }

    /// Status words get their usual colours, whatever variant the plugin picked.
    static func tint(text: String, variant: String) -> Color? {
        let green = Color(red: 0.35, green: 0.85, blue: 0.55), blue = Color(red: 0.45, green: 0.62, blue: 1)
        let red = Color(red: 1, green: 0.4, blue: 0.42), amber = Color(red: 1, green: 0.72, blue: 0.3)
        if ["completed", "complete", "done", "success", "succeeded", "finished", "passed", "ok", "ready", "active", "enabled", "open", "connected"].contains(text) { return green }
        if ["running", "starting", "in progress", "in_progress", "working", "planning", "researching", "writing", "reviewing", "auditing", "live"].contains(text) { return blue }
        if ["failed", "error", "interrupted", "cancelled", "canceled", "blocked", "rejected", "offline"].contains(text) { return red }
        if ["paused", "stopping", "stopped", "queued", "pending", "waiting", "warning", "stale", "draft"].contains(text) { return amber }
        switch variant {
        case "destructive": return red
        case "default": return blue
        default: return nil
        }
    }
}

struct PluginEmptyState: View {
    let node: PluginNode
    var error = false

    var body: some View {
        VStack(spacing: 5) {
            if error { Image(systemName: "exclamationmark.triangle").font(.system(size: 16)).foregroundStyle(.orange.opacity(0.8)) }
            Text(node.string("title") ?? node.plainText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
            if let d = node.string("description"), !d.isEmpty {
                Text(d).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.42))
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }
}

/// A text field the plugin controls (`value` + `onChange`), kept local while typing.
struct PluginTextField: View {
    let node: PluginNode
    let multiline: Bool
    let formSubmit: String?
    @State private var text = ""
    @State private var synced: String?
    @FocusState private var focused: Bool

    var body: some View {
        let value = node.string("value") ?? ""
        let prompt = Text(node.string("placeholder") ?? "").foregroundStyle(.white.opacity(0.4))
        Group {
            if multiline {
                TextField("", text: $text, prompt: prompt, axis: .vertical).lineLimit((Int(node.string("rows") ?? "") ?? 3)...12)
            } else if node.string("type") == "password" {
                SecureField("", text: $text, prompt: prompt)
            } else {
                TextField("", text: $text, prompt: prompt)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12.5))
        .focused($focused)
        .padding(.horizontal, 10)
        .padding(.vertical, multiline ? 8 : 5)
        .frame(minHeight: 28)
        .vibeGlass(RoundedRectangle(cornerRadius: multiline ? 10 : 9, style: .continuous), tint: .black.opacity(focused ? 0.12 : 0.06))
        .disabled(node.bool("disabled"))
        .onAppear { text = value; synced = value }
        .onChange(of: value) { _, v in
            // The plugin changed it (cleared after submit, say): take it unless it is what we sent.
            if v != text { text = v }
            synced = v
        }
        .onChange(of: text) { _, v in
            guard v != synced, let h = node.handler("onChange") else { return }
            synced = v
            host.dispatch(h, [["value": v]])
        }
        .onSubmit {
            if let h = node.handler("onKeyDown") { host.dispatch(h, [["$event": true, "key": "Enter"]]) }
            if let f = formSubmit { host.dispatch(f) }
        }
    }
}

struct PluginToggle: View {
    enum Style { case checkbox, `switch` }
    let node: PluginNode
    let style: Style

    var body: some View {
        let on = node.bool("checked")
        let binding = Binding(get: { on }, set: { v in
            if let h = node.handler("onCheckedChange") { host.dispatch(h, [v]) }
            else if let h = node.handler("onChange") { host.dispatch(h, [["value": v, "checked": v]]) }
        })
        Group {
            if style == .checkbox { Toggle("", isOn: binding).toggleStyle(.checkbox) }
            else { Toggle("", isOn: binding).toggleStyle(.switch).controlSize(.mini) }
        }
        .labelsHidden()
        .disabled(node.bool("disabled"))
    }
}

struct PluginSelect: View {
    let node: PluginNode

    var body: some View {
        let raw = node.type == "select"
        let items: [(String, String)] = raw
            ? PluginDraw.findAll(node, "option").map { ($0.string("value") ?? $0.plainText, $0.plainText) }
            : PluginDraw.findAll(node, "SelectItem").map { ($0.string("value") ?? $0.plainText, $0.plainText) }
        let value = node.string("value") ?? node.string("defaultValue") ?? ""
        let binding = Binding(get: { value }, set: { v in
            if let h = node.handler("onValueChange") { host.dispatch(h, [v]) }
            else if let h = node.handler("onChange") { host.dispatch(h, [["value": v]]) }
        })
        Picker("", selection: binding) {
            if !items.contains(where: { $0.0 == value }) {
                Text(PluginDraw.find(node, "SelectValue")?.string("placeholder") ?? "Choose…").tag(value)
            }
            ForEach(items, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .disabled(node.bool("disabled"))
    }
}

enum PluginSegments {
    @MainActor static func fromButtons(_ buttons: [PluginNode]) -> AnyView {
        let chosen = buttons.firstIndex { $0.string("variant") == "secondary" || $0.string("variant") == "default" } ?? 0
        let binding = Binding(get: { chosen }, set: { i in
            if let h = buttons[i].handler("onClick") { host.dispatch(h) }
        })
        return AnyView(Picker("", selection: binding) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { i, b in Text(b.plainText.capitalized).tag(i) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .tint(.white.opacity(0.25))
        .fixedSize())
    }

    @MainActor static func fromOptions(_ n: PluginNode) -> AnyView {
        let options = (n.props["options"] as? [[String: Any]] ?? []).map { (($0["id"] as? String) ?? "", ($0["label"] as? String) ?? "") }
        let value = n.string("value") ?? ""
        let binding = Binding(get: { value }, set: { v in if let h = n.handler("onChange") { host.dispatch(h, [v]) } })
        return AnyView(Picker("", selection: binding) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }.pickerStyle(.segmented).labelsHidden().tint(.white.opacity(0.25)).fixedSize())
    }

    @MainActor static func fromTabs(_ n: PluginNode, ctx: PluginContext) -> AnyView {
        let triggers = PluginDraw.findAll(n, "TabsTrigger")
        let value = n.string("value") ?? triggers.first?.string("value") ?? ""
        let binding = Binding(get: { value }, set: { v in if let h = n.handler("onValueChange") { host.dispatch(h, [v]) } })
        let rest = n.children.filter { $0.type != "TabsList" }
        return AnyView(VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: binding) {
                ForEach(triggers) { t in Text(t.plainText).tag(t.string("value") ?? t.plainText) }
            }.pickerStyle(.segmented).labelsHidden().tint(.white.opacity(0.25)).fixedSize()
            PluginDraw.children(rest, in: ctx)
        })
    }
}

struct PluginConfirm: View {
    let node: PluginNode

    var body: some View {
        let open = node.bool("open")
        Color.clear.frame(width: 0, height: 0)
            .alert(node.string("title") ?? "Are you sure?", isPresented: Binding(get: { open }, set: { v in
                if !v, let h = node.handler("onClose") ?? node.handler("onOpenChange") { host.dispatch(h, [false]) }
            })) {
                Button(node.string("confirmLabel") ?? "Confirm", role: node.bool("destructive") ? .destructive : nil) {
                    if let h = node.handler("onConfirm") { host.dispatch(h) }
                }
                if let secondary = node.props["secondaryAction"] as? [String: Any], let label = secondary["label"] as? String,
                   let h = (secondary["onClick"] as? [String: Any])?["$fn"] as? String {
                    Button(label) { host.dispatch(h) }
                }
                Button(node.string("cancelLabel") ?? "Cancel", role: .cancel) {}
            } message: {
                Text(node.string("description") ?? PluginDraw.visible(node.children).map(\.plainText).joined(separator: " "))
            }
    }
}

struct PluginDialog: View {
    let node: PluginNode
    let ctx: PluginContext

    var body: some View {
        let open = node.bool("open")
        let content = PluginDraw.find(node, "DialogContent")
        Color.clear.frame(width: 0, height: 0)
            .sheet(isPresented: Binding(get: { open }, set: { v in
                if !v, let h = node.handler("onOpenChange") { host.dispatch(h, [false]) }
            })) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(PluginDraw.visible(content?.children ?? [])) { k in part(k) }
                    }
                    .padding(22)
                }
                .frame(minWidth: 440, idealWidth: 520, minHeight: 160, idealHeight: 420)
                .environment(\.colorScheme, .dark)
            }
    }

    func part(_ k: PluginNode) -> AnyView {
        AnyView(partBody(k))
    }

    @ViewBuilder func partBody(_ k: PluginNode) -> some View {
        switch k.type {
        case "DialogHeader":
            VStack(alignment: .leading, spacing: 4) { ForEach(PluginDraw.visible(k.children)) { part($0) } }
        case "DialogTitle":
            Text(k.plainText).font(.system(size: 15, weight: .semibold))
        case "DialogDescription":
            Text(k.plainText).font(.system(size: 12)).foregroundStyle(.secondary)
        case "DialogFooter":
            HStack(spacing: 8) {
                Spacer()
                ForEach(PluginDraw.visible(k.children)) { PluginDraw.node($0, in: PluginContext(row: true, text: .base, stretch: false, formSubmit: ctx.formSubmit)) }
            }
        default:
            PluginDraw.node(k, in: PluginContext(row: false, text: .base, stretch: true, formSubmit: ctx.formSubmit))
        }
    }
}

struct PluginMenu: View {
    let node: PluginNode
    let ctx: PluginContext

    var body: some View {
        let trigger = PluginDraw.find(node, "DropdownMenuTrigger")
        let content = PluginDraw.find(node, "DropdownMenuContent")
        Menu {
            ForEach(PluginDraw.visible(content?.children ?? [])) { item in
                switch item.type {
                case "DropdownMenuSeparator": Divider()
                case "DropdownMenuLabel": Text(item.plainText)
                default:
                    Button(role: item.string("variant") == "destructive" ? .destructive : nil) {
                        if let h = item.handler("onSelect") ?? item.handler("onClick") { host.dispatch(h) }
                    } label: {
                        Text(item.plainText.trimmingCharacters(in: .whitespaces))
                    }
                    .disabled(item.bool("disabled"))
                }
            }
        } label: {
            let label = trigger?.plainText.trimmingCharacters(in: .whitespaces) ?? ""
            if label.isEmpty || label.hasPrefix("[") { Image(systemName: "ellipsis") } else { Text(label) }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct PluginPopover: View {
    let node: PluginNode
    let ctx: PluginContext
    @State private var shown = false

    var body: some View {
        let controlled = node.props["open"] != nil
        let open = controlled ? node.bool("open") : shown
        let trigger = PluginDraw.find(node, "PopoverTrigger")
        let content = PluginDraw.find(node, "PopoverContent")
        Button {
            if controlled, let h = node.handler("onOpenChange") { host.dispatch(h, [!open]) } else { shown.toggle() }
        } label: {
            PluginDraw.row(trigger?.children ?? [], tw: TW(""), ctx: PluginContext(row: true, text: ctx.text, stretch: false))
        }
        .buttonStyle(.plain)
        .popover(isPresented: Binding(get: { open }, set: { v in
            if controlled, let h = node.handler("onOpenChange") { host.dispatch(h, [v]) } else { shown = v }
        })) {
            PluginDraw.children(content?.children ?? [], in: PluginContext(row: false, text: .base, stretch: true))
                .padding(12)
                .frame(minWidth: 220)
        }
    }
}

struct PluginToastView: View {
    let toast: PluginHost.Toast

    var body: some View {
        let (symbol, color): (String, Color) = switch toast.kind {
        case "success": ("checkmark.circle.fill", .green)
        case "error": ("xmark.octagon.fill", .red)
        case "warning": ("exclamationmark.triangle.fill", .orange)
        default: ("info.circle.fill", .blue)
        }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                if let t = toast.title, !t.isEmpty { Text(t).font(.system(size: 12, weight: .semibold)) }
                Text(toast.message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 320, alignment: .leading)
        .vibeGlass(RoundedRectangle(cornerRadius: 12, style: .continuous), tint: .black.opacity(0.15), frost: 0.8)
        .onTapGesture { PluginHost.shared.dismissToast(toast.id) }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
