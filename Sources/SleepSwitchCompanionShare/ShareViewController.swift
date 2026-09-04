import UIKit
import UniformTypeIdentifiers

/// A deliberately small Share Sheet destination. It receives one system-owned
/// file, copies it to the private App Group, and lets the main companion ask
/// where to send it. This extension never contacts CloudKit or a Mac itself.
final class ShareViewController: UIViewController {
    private let intake = SharedContextIntake()
    private let statusLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        importFirstSharedFile()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "Preparing shared item…"

        var openConfiguration = UIButton.Configuration.filled()
        openConfiguration.title = "Open Sleep Switch"
        openButton.configuration = openConfiguration
        openButton.isHidden = true
        openButton.addTarget(self, action: #selector(openCompanion), for: .touchUpInside)

        var doneConfiguration = UIButton.Configuration.gray()
        doneConfiguration.title = "Done"
        doneButton.configuration = doneConfiguration
        doneButton.isHidden = true
        doneButton.addTarget(self, action: #selector(finish), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [statusLabel, openButton, doneButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func importFirstSharedFile() {
        let items = (extensionContext?.inputItems ?? [])
            .compactMap { $0 as? NSExtensionItem }
        let providers: [NSItemProvider] = items.flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: { supportedTypeIdentifier(for: $0) != nil }),
              let typeIdentifier = supportedTypeIdentifier(for: provider)
        else {
            showFailure("Share a single file, image, PDF, or document to Sleep Switch.")
            return
        }

        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, error in
            guard let self else { return }
            let result: Result<SharedContextDraft, Error>
            if let url {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                result = Result { try self.intake.stage(fileAt: url) }
            } else {
                result = .failure(error ?? SharedContextIntakeError.sourceUnavailable)
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let draft): self.showReady(draft)
                case .failure(let error): self.showFailure(error.localizedDescription)
                }
            }
        }
    }

    private func supportedTypeIdentifier(for provider: NSItemProvider) -> String? {
        provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .data) || type.conforms(to: .image) || type.conforms(to: .audiovisualContent)
        }
    }

    private func showReady(_ draft: SharedContextDraft) {
        statusLabel.text = "\(draft.filename) is ready in Sleep Switch. Choose a Mac there before it is sent."
        statusLabel.textColor = .secondaryLabel
        openButton.isHidden = false
        doneButton.isHidden = false
    }

    private func showFailure(_ message: String) {
        statusLabel.text = message
        statusLabel.textColor = .systemRed
        doneButton.isHidden = false
    }

    @objc private func openCompanion() {
        guard let url = URL(string: "sleepswitch-companion://shared-context") else { return }
        extensionContext?.open(url) { [weak self] _ in self?.finish() }
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
