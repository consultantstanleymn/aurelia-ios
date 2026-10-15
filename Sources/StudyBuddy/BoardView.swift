#if canImport(SwiftUI)
import SwiftUI
import WebKit
import StudyBuddyCore

/// Draws a whiteboard item.
///
/// Five shapes, one view. The kinds mean genuinely different things, so a table is a real table and
/// code is monospaced — the alternative is five screens and a lot of `if` in the parent.
///
/// `diagram` is the exception: mermaid is JavaScript, so it gets a small web view. That is the only
/// web view in the app, and it is scoped to this one case rather than wrapping the whole interface.
struct BoardView: View {
    let shape: BoardShape
    /// Nodes the tutor asked to highlight, from `<focus nodes="a,b"/>`.
    var focus: Set<String> = []
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .glass(cornerRadius: 18, prominent: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(shape.title)
                .font(Theme.label(11))
                .foregroundStyle(Theme.goldInk)
                .textCase(.uppercase)
                .tracking(0.8)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textMuted)
                }
                .accessibilityLabel("Clear the board")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch shape {
        case let .points(_, items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(index + 1, format: .number)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.gold)
                            .frame(width: 18, alignment: .trailing)
                        Text(item)
                            .font(Theme.body(16))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .table(_, header, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !header.isEmpty {
                        row(header, isHeader: true)
                        Divider().overlay(Theme.hairline)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                        row(cells, isHeader: false)
                        Divider().overlay(Theme.hairline)
                    }
                }
            }

        case let .code(_, lines):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(lines.joined(separator: "\n"))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
            }

        case let .formula(_, pairs):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pairs, id: \.key) { pair in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(pair.key)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.goldInk)
                        Text("=")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                        Text(pair.value)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .diagram(_, source):
            MermaidView(source: source)
                .frame(minHeight: 180)
        }
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell)
                    .font(.system(size: 14, weight: isHeader ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(isHeader ? Theme.goldInk : Theme.text)
                    .frame(minWidth: 90, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
    }
}

/// Renders mermaid, which is JavaScript.
///
/// Scoped deliberately: this is the only web view in the app. Everything else is SwiftUI, and
/// keeping it that way is why the app builds from Linux with no storyboards and no asset catalog.
struct MermaidView: UIViewRepresentable {
    let source: String

    func makeUIView(context: Context) -> WKWebView {
        // No script message handler: the diagram page has no reason to talk to Swift, and
        // `userContentController` is read-only anyway, so wiring one up was never possible here.
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.loadHTMLString(Self.document(for: source), baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard let current = context.coordinator.source else { return }
        guard current != source else { return }
        context.coordinator.source = source
        view.loadHTMLString(Self.document(for: source), baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var source: String?
    }

    /// A self-contained page: mermaid from a CDN, light theme forced to match the app, and an error
    /// path that shows the source instead of a blank rectangle when the CDN is unreachable.
    static func document(for source: String) -> String {
        let escaped = source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          html,body{margin:0;background:transparent;font:14px -apple-system,sans-serif}
          #out{color:#16150F}
          #err{color:#8A6A00;font:11px ui-monospace,monospace;white-space:pre-wrap;padding:6px}
        </style></head><body>
        <div id="out"></div><div id="err"></div>
        <script type="module">
          import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
          mermaid.initialize({ startOnLoad: false, theme: "base", themeVariables: {
            primaryColor: "#FDF6E3", primaryTextColor: "#16150F", primaryBorderColor: "#D4A017",
            lineColor: "#8A6A00", fontSize: "13px" } });
          try {
            const { svg } = await mermaid.render("g" + Date.now(), `\(escaped)`);
            document.getElementById("out").innerHTML = svg;
          } catch (e) {
            document.getElementById("err").textContent = String(e).slice(0, 200);
          }
        </script></body></html>
        """
    }
}
#endif
