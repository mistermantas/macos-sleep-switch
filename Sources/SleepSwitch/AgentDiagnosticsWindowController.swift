import AppKit

struct AgentDetectionSnapshot {
    let scannedAt: Date?
    let agents: [DetectedAgent]
    let codexSessionCount: Int?
    let note: String
}

@MainActor
final class AgentDiagnosticsWindowController: NSWindowController {
    private let summaryLabel = NSTextField(wrappingLabelWithString: "Checking agent detection…")
    private let rows = NSTextField(wrappingLabelWithString: "")
    private let refreshAction: () -> AgentDetectionSnapshot

    init(refresh: @escaping () -> AgentDetectionSnapshot) {
        refreshAction = refresh
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Agent Detection Diagnostics"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        refresh()
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "What Sleep Switch sees")
        title.font = .systemFont(ofSize: 21, weight: .bold)
        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.textColor = .secondaryLabelColor
        rows.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        rows.textColor = .labelColor
        rows.maximumNumberOfLines = 0

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = rows
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -8).isActive = true

        let refreshButton = NSButton(title: "Refresh Now", target: self, action: #selector(refresh))
        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyReport))
        let note = NSTextField(wrappingLabelWithString: "This view never uploads process names or paths. It is here to make false positives and missed sessions debuggable on the Mac that sees them.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor

        let footer = NSStackView(views: [note, NSView(), refreshButton, copyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10

        let stack = NSStackView(views: [title, summaryLabel, separator(), scroll, separator(), footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func refresh() {
        let snapshot = refreshAction()
        let timestamp = snapshot.scannedAt?.formatted(date: .omitted, time: .standard) ?? "not yet"
        summaryLabel.stringValue = "Last local scan: \(timestamp) · \(snapshot.note)"
        let detectedRows = snapshot.agents.isEmpty
            ? ["No supported agent sessions are currently detected."]
            : snapshot.agents.map { agent in
                "\(agent.definition.name): \(agent.processCount) session\(agent.processCount == 1 ? "" : "s")"
            }
        let codexLine = snapshot.codexSessionCount.map { "Codex session-log tasks: \($0)" }
            ?? "Codex session-log tasks: unavailable"
        rows.stringValue = ([codexLine] + detectedRows).joined(separator: "\n")
    }

    @objc private func copyReport() {
        let report = """
        Sleep Switch Agent Detection Diagnostics
        \(summaryLabel.stringValue)

        \(rows.stringValue)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
