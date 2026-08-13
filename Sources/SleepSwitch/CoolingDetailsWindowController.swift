#if !APP_STORE
import AppKit

@MainActor
final class CoolingDetailsWindowController: NSWindowController {
    private let stateLabel = NSTextField(labelWithString: "System Control")
    private let temperatureLabel = NSTextField(labelWithString: "—")
    private let modelValue = NSTextField(labelWithString: "—")
    private let fansValue = NSTextField(labelWithString: "—")
    private let helperValue = NSTextField(labelWithString: "—")
    private let sensorStack = NSStackView()
    private let sensorScroll = NSScrollView()
    private let copyButton = NSButton(
        title: "Copy Diagnostics",
        target: nil,
        action: nil
    )
    private let noteLabel = NSTextField(
        wrappingLabelWithString:
            "Use cooling only with open airflow on a hard surface."
    )
    private var latestPresentation: CoolingPresentationSnapshot?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sleep Switch Cooling"
        panel.isReleasedWhenClosed = false
        panel.center()
        super.init(window: panel)
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ presentation: CoolingPresentationSnapshot) {
        update(presentation)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(_ presentation: CoolingPresentationSnapshot) {
        latestPresentation = presentation
        let snapshot = presentation.helperSnapshot
        stateLabel.stringValue = stateTitle(for: presentation)
        temperatureLabel.stringValue = snapshot?
            .optionalAggregateTemperatureCelsius
            .map { String(format: "%.0f°", $0) } ?? "—"
        modelValue.stringValue = snapshot?.model ?? "—"
        fansValue.stringValue = fanText(snapshot?.fans ?? [])
        helperValue.stringValue = helperText(presentation.registrationState)
        updateSensors(snapshot?.diagnosticMetadata)
        noteLabel.textColor = snapshot?.state == .restoreFailed
            ? .systemRed
            : .secondaryLabelColor
        noteLabel.stringValue = snapshot?.state == .restoreFailed
            ? "Fan restoration could not be verified. Quit other fan tools and restart the Mac."
            : "Use cooling only with open airflow on a hard surface."
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let icon = NSImageView(
            image: NSImage(
                systemSymbolName: "fan.fill",
                accessibilityDescription: "Cooling"
            ) ?? NSImage()
        )
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 28,
            weight: .medium
        )

        stateLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        stateLabel.lineBreakMode = .byTruncatingTail
        temperatureLabel.font = .monospacedDigitSystemFont(
            ofSize: 34,
            weight: .medium
        )
        temperatureLabel.alignment = .right

        let header = NSStackView(views: [
            icon,
            stateLabel,
            NSView(),
            temperatureLabel
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        icon.setContentHuggingPriority(.required, for: .horizontal)
        temperatureLabel.setContentHuggingPriority(.required, for: .horizontal)

        let details = NSGridView(views: [
            [label("Mac"), modelValue],
            [label("Fans"), fansValue],
            [label("Helper"), helperValue]
        ])
        details.rowSpacing = 10
        details.columnSpacing = 24
        details.column(at: 0).xPlacement = .trailing
        details.column(at: 1).xPlacement = .leading
        [modelValue, fansValue, helperValue].forEach {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
        }

        let sensorTitle = NSTextField(labelWithString: "Temperature sensors")
        sensorTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        sensorStack.orientation = .vertical
        sensorStack.alignment = .leading
        sensorStack.spacing = 6
        sensorStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 8)
        sensorStack.translatesAutoresizingMaskIntoConstraints = false
        sensorScroll.documentView = sensorStack
        sensorScroll.hasVerticalScroller = true
        sensorScroll.drawsBackground = false
        sensorScroll.borderType = .noBorder

        noteLabel.maximumNumberOfLines = 2
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        copyButton.target = self
        copyButton.action = #selector(copyDiagnostics)
        copyButton.bezelStyle = .rounded
        copyButton.setContentHuggingPriority(
            .required,
            for: .horizontal
        )

        let footer = NSStackView(views: [
            noteLabel,
            NSView(),
            copyButton
        ])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        let stack = NSStackView(views: [
            header,
            separator(),
            details,
            separator(),
            sensorTitle,
            sensorScroll,
            separator(),
            footer
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: 24
            ),
            stack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -24
            ),
            stack.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: 24
            ),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: contentView.bottomAnchor,
                constant: -24
            ),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sensorScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sensorScroll.heightAnchor.constraint(equalToConstant: 190),
            sensorStack.widthAnchor.constraint(
                equalTo: sensorScroll.contentView.widthAnchor,
                constant: -8
            ),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func updateSensors(_ diagnosticMetadata: String?) {
        sensorStack.arrangedSubviews.forEach {
            sensorStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let sensors = CompanionTemperatureParser.sensors(
            from: diagnosticMetadata
        )
        guard !sensors.isEmpty else {
            let unavailable = NSTextField(
                labelWithString: "No detailed sensor readings are available."
            )
            unavailable.textColor = .secondaryLabelColor
            unavailable.font = .systemFont(ofSize: 12)
            sensorStack.addArrangedSubview(unavailable)
            return
        }

        for group in CompanionTemperatureGroup.allCases {
            let values = sensors.filter { $0.group == group }
            guard !values.isEmpty else { continue }
            let heading = NSTextField(labelWithString: group.title)
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            sensorStack.addArrangedSubview(heading)
            for sensor in values {
                let key = NSTextField(labelWithString: sensor.key)
                key.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                let value = NSTextField(
                    labelWithString: String(format: "%.1f°C", sensor.celsius)
                )
                value.font = .monospacedDigitSystemFont(
                    ofSize: 12,
                    weight: .semibold
                )
                if sensor.celsius >= 85 {
                    value.textColor = .systemRed
                } else if sensor.celsius >= 70 {
                    value.textColor = .systemOrange
                }
                let row = NSStackView(views: [key, NSView(), value])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.translatesAutoresizingMaskIntoConstraints = false
                row.widthAnchor.constraint(equalTo: sensorStack.widthAnchor).isActive = true
                sensorStack.addArrangedSubview(row)
            }
        }
    }

    @objc private func copyDiagnostics() {
        guard let latestPresentation else {
            NSSound.beep()
            return
        }
        let report = CoolingDiagnosticReport.text(
            presentation: latestPresentation,
            thermalLevel: ProcessInfoThermalMonitor().currentLevel
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copyButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            [weak self] in
            self?.copyButton.title = "Copy Diagnostics"
        }
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func stateTitle(
        for presentation: CoolingPresentationSnapshot
    ) -> String {
        guard let snapshot = presentation.helperSnapshot else {
            return switch presentation.registrationState {
            case .requiresSignedBuild:
                "Signed Build Required"
            case .notRegistered:
                "Helper Not Installed"
            case .requiresApproval:
                "Approval Needed"
            case .notFound:
                "Helper Unavailable"
            case .enabled:
                "Connecting…"
            }
        }

        return switch snapshot.state {
        case .systemControl:
            "System Control"
        case .cooling:
            presentation.selectedProfile.menuTitle
        case .monitoringOnly:
            "Monitoring Only"
        case .unsupported:
            "No Supported Fans"
        case .externalControllerConflict:
            "Another Controller Is Open"
        case .unavailable:
            "Cooling Unavailable"
        case .restoreFailed:
            "Check Fan Control"
        }
    }

    private func fanText(_ fans: [FanTelemetryMessage]) -> String {
        guard !fans.isEmpty else { return "—" }
        return fans.map {
            "Fan \($0.index + 1) · \(Int($0.actualRPM)) RPM"
        }.joined(separator: "   ")
    }

    private func helperText(
        _ state: FanHelperRegistrationState
    ) -> String {
        switch state {
        case .requiresSignedBuild:
            return "Signed build required"
        case .notRegistered:
            return "Not installed"
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Needs approval"
        case .notFound:
            return "Unavailable"
        }
    }
}
#endif
