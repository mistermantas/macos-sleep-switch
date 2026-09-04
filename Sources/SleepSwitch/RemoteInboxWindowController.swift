import AppKit
import SwiftUI

@MainActor
final class RemoteInboxWindowController: NSWindowController {
    private let viewModel: RemoteInboxViewModel

    init(inbox: RemoteContextInbox) {
        viewModel = RemoteInboxViewModel(inbox: inbox)
        let host = NSHostingController(rootView: RemoteInboxView(viewModel: viewModel))
        let window = NSWindow(contentViewController: host)
        window.title = "Remote Inbox · Sleep Switch"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 460))
        window.minSize = NSSize(width: 500, height: 340)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        viewModel.reload()
    }
}

@MainActor
private final class RemoteInboxViewModel: ObservableObject {
    @Published private(set) var items: [RemoteContextInboxItem] = []
    @Published private(set) var placementStatus: String?

    private let inbox: RemoteContextInbox

    init(inbox: RemoteContextInbox) {
        self.inbox = inbox
    }

    func reload() {
        items = inbox.items()
    }

    func reveal(_ item: RemoteContextInboxItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
    }

    func place(_ item: RemoteContextInboxItem) {
        let panel = NSOpenPanel()
        panel.title = "Place Context Item"
        panel.message = "Choose the folder that should receive this copy."
        panel.prompt = "Place"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let accessing = directory.startAccessingSecurityScopedResource()
        defer {
            if accessing { directory.stopAccessingSecurityScopedResource() }
        }
        do {
            let destination = try inbox.place(item, in: directory)
            placementStatus = "Copied \(destination.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            placementStatus = (error as? LocalizedError)?.errorDescription
                ?? "Sleep Switch could not place this item."
        }
    }
}

private struct RemoteInboxView: View {
    @ObservedObject var viewModel: RemoteInboxViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
                Text("Remote Inbox")
                    .font(.title2.weight(.bold))
                Spacer()
                Text("\(viewModel.items.count) \(viewModel.items.count == 1 ? "item" : "items")")
                    .foregroundStyle(.secondary)
                Button { viewModel.reload() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(20)

            Divider()

            if let status = viewModel.placementStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                Divider()
            }

            if viewModel.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("No received context")
                        .font(.headline)
                    Text("Items shared from your iPhone or iPad appear here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.filename)
                                .lineLimit(1)
                            Text("\(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)) · \(item.receivedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Place…") { viewModel.place(item) }
                            .buttonStyle(.bordered)
                        Button("Reveal") { viewModel.reveal(item) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }
}
