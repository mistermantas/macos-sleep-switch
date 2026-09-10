import CloudKit
import Charts
import SwiftUI
import UIKit
import WidgetKit
import UserNotifications

extension Notification.Name {
    static let sleepSwitchStatusPush = Notification.Name("sleepSwitchStatusPush")
}

@main
struct SleepSwitchCompanionApp: App {
    @UIApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate
    @StateObject private var model = CompanionAppModel()

    var body: some Scene {
        WindowGroup {
            CompanionDashboardRoot(model: model)
                .onOpenURL { _ in model.reloadSharedContextDrafts() }
        }
    }
}

final class CompanionAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if application.applicationState == .active {
            NotificationCenter.default.post(name: .sleepSwitchStatusPush, object: nil)
            completionHandler(.newData)
            return
        }
        Task {
            completionHandler(await CompanionWidgetBackgroundRefresher.refresh())
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

private enum CompanionWidgetPublisher {
    static func publish(_ macs: [CompanionMacStatus]) {
        let selectedID = UserDefaults.standard.string(forKey: "selectedMacDeviceID") ?? ""
        let selected = CompanionMacSelection.preferred(from: macs, persistedDeviceID: selectedID)
        let snapshots = CompanionMacSelection.canonicalDevices(macs).map { mac in
            CompanionWidgetSnapshot(
                deviceID: mac.deviceID,
                macName: mac.displayName,
                batteryPercent: mac.batteryPercent,
                temperatureCelsius: mac.cooling?.temperatureCelsius,
                fanRPM: mac.cooling?.fans.map(\.actualRPM).max(),
                isCharging: mac.isCharging,
                activeSessionCount: mac.activeSessionCount,
                thermalState: mac.thermalState,
                updatedAt: mac.lastSeen
            )
        }
        CompanionWidgetStore.save(macs: snapshots, defaultDeviceID: selected?.deviceID)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Receives a silent CloudKit status notification while the iPhone app is not
/// open. The old path only notified an in-memory dashboard model, which meant
/// a cold or backgrounded app left every widget showing its old timeline.
private enum CompanionWidgetBackgroundRefresher {
    static func refresh() async -> UIBackgroundFetchResult {
        do {
            let cloud = CompanionCloudClient()
            let account = try await cloud.accountStatus()
            guard account == .available else {
                if account == .noAccount || account == .restricted { await CompanionLiveActivityController.shared.endAll() }
                return .failed
            }
            let macs = try await cloud.fetchMacs()
            CompanionWidgetPublisher.publish(macs)
            await CompanionLiveActivityController.shared.synchronize(with: macs)
            CompanionWorkNotificationManager().evaluate(CompanionMacSelection.canonicalDevices(macs))
            return macs.isEmpty ? .noData : .newData
        } catch is CancellationError {
            return .noData
        } catch {
            return .failed
        }
    }
}

@MainActor
final class CompanionAppModel: ObservableObject {
    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published private(set) var macs: [CompanionMacStatus] = []
    @Published private(set) var histories: [String: CompanionHistorySnapshot] = [:]
    @Published private(set) var artifactOffersByDeviceID: [String: [CompanionPendingArtifactOffer]] = [:]
    @Published private(set) var artifactDownloadURLs: [UUID: URL] = [:]
    @Published private(set) var artifactDownloadIDs: Set<UUID> = []
    @Published private(set) var artifactDownloadIssuesByRecordName: [String: String] = [:]
    @Published private(set) var message: String?
    @Published private(set) var isLoading = false
    @Published private(set) var commandInFlight = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastSuccessfulSyncAt: Date?
    @Published private(set) var lastSyncIssue: String?
    @Published private(set) var lastConnectionError: CompanionConnectionError?
    @Published private(set) var syncStage = "Not checked"
    @Published private(set) var lastCommandStatus = "Never"
    @Published private(set) var lastContextTransferStatus = "Never"
    @Published private(set) var contextTransferActivities: [CompanionContextTransferActivity]
    @Published private(set) var commandProgress: CompanionCommandProgress?
    @Published private(set) var operatorContents: [String: CompanionOperatorContent] = [:]
    @Published private(set) var operatorIssues: [String: String] = [:]
    @Published private(set) var sharedContextDrafts: [SharedContextDraft] = []
    @Published private(set) var sharedContextDraftIDsInFlight: Set<UUID> = []

    private lazy var cloud = CompanionCloudClient()
    let heatNotifications = CompanionHeatNotificationManager()
    let workNotifications = CompanionWorkNotificationManager()
    let liveActivity = CompanionLiveActivityController.shared
    private let contextTransferHistory = CompanionContextTransferHistoryStore()
    private let artifactDownloadStore = RemoteArtifactDownloadStore()
    private let sharedContextIntake = SharedContextIntake()
    private let requesterDeviceID = CompanionDeviceIdentity.load(key: "companionIOSDeviceID")
    private var refreshTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var progressDismissTask: Task<Void, Never>?

    #if DEBUG
    private let isScreenshotDemo = ProcessInfo.processInfo.arguments.contains("--screenshot-demo")
    private let isSharedContextDemo = ProcessInfo.processInfo.arguments.contains("--screenshot-shared-context")
    private let isConnectionDemo = ProcessInfo.processInfo.arguments.contains("--screenshot-connection")
    private let isCommandProgressDemo = ProcessInfo.processInfo.arguments.contains("--screenshot-command-progress")
    #endif

    init() {
        contextTransferActivities = contextTransferHistory.items
        sharedContextDrafts = sharedContextIntake.drafts()
        NotificationCenter.default.addObserver(
            forName: .sleepSwitchStatusPush,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        #if DEBUG
        if isScreenshotDemo {
            let demo = CompanionScreenshotDemo.make()
            var demoMac = demo.mac
            demoMac.operatorSnapshot = CompanionOperatorDemo.make()
            if !ProcessInfo.processInfo.arguments.contains("--screenshot-no-telemetry") {
                demoMac.systemLoad = CompanionSystemLoad(sampledAt: demoMac.lastSeen, cpuPercent: 23, memoryUsedBytes: 20_615_843_021, memoryTotalBytes: 34_359_738_368)
            }
            if ProcessInfo.processInfo.arguments.contains("--screenshot-live-stale") {
                demoMac = demoMac.refreshingLastSeen(at: Date().addingTimeInterval(-600))
                demoMac.systemLoad = nil
            }
            macs = [demoMac]
            histories = [demo.mac.deviceID: demo.history]
            artifactOffersByDeviceID = demo.artifactOffersByDeviceID
            if isSharedContextDemo {
                sharedContextDrafts = [
                    SharedContextDraft(
                        id: UUID(),
                        filename: "field-notes.pdf",
                        byteCount: 1_820_000,
                        receivedAt: Date().addingTimeInterval(-60),
                        expiresAt: Date().addingTimeInterval(23 * 60 * 60)
                    )
                ]
            }
            message = "Demo data · connected to your private iCloud"
            lastSyncAt = Date()
            lastSuccessfulSyncAt = lastSyncAt
            syncStage = "Connected"
            if isCommandProgressDemo {
                commandInFlight = true
                commandProgress = CompanionCommandProgress(
                    commandID: UUID(),
                    actionTitle: "Prevent Sleep",
                    stage: .waitingForMac
                )
            }
        } else if isConnectionDemo {
            accountStatus = .available
            lastSyncAt = Date()
            syncStage = "Connection failed"
            let error = NSError(
                domain: CKErrorDomain,
                code: CKError.networkFailure.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
            )
            lastConnectionError = CompanionConnectionError(error: error)
            message = lastConnectionError?.userMessage
        }
        #endif
    }

    deinit {
        refreshTask?.cancel()
        commandTask?.cancel()
        progressDismissTask?.cancel()
    }

    func refresh() {
        reloadSharedContextDrafts()
#if targetEnvironment(simulator)
        showSimulatorCloudKitMessageIfNeeded()
#else
#if DEBUG
        if isScreenshotDemo || isConnectionDemo { return }
#endif
        guard !isLoading else { return }
        isLoading = true
        message = nil
        lastSyncIssue = nil
        syncStage = "Checking iCloud"
        refreshTask = Task { @MainActor [weak self] in
            await self?.performRefresh()
        }
#endif
    }

    func refreshAndWait() async {
        refresh()
        await refreshTask?.value
    }

    private func performRefresh() async {
        defer {
            isLoading = false
            refreshTask = nil
        }

        do {
            let currentAccountStatus = try await cloud.accountStatus()
            accountStatus = currentAccountStatus
            guard currentAccountStatus == .available else {
                let issue = accountStatusMessage(for: currentAccountStatus)
                lastSyncIssue = issue
                lastConnectionError = CompanionConnectionError.account(
                    status: currentAccountStatus,
                    message: issue
                )
                message = issue
                macs = []
                histories = [:]
                artifactOffersByDeviceID = [:]
                operatorContents = [:]
                lastSyncAt = Date()
                syncStage = "iCloud unavailable"
                if currentAccountStatus == .noAccount || currentAccountStatus == .restricted { await liveActivity.endAll() }
                return
            }

            try? await cloud.ensureStatusSubscription()

            syncStage = "Loading Macs"
            let rawMacs = try await cloud.fetchMacs()
            let savedID = UserDefaults.standard.string(forKey: "selectedMacDeviceID") ?? ""
            if let selected = CompanionMacSelection.preferred(from: rawMacs, persistedDeviceID: savedID) {
                UserDefaults.standard.set(selected.deviceID, forKey: "selectedMacDeviceID")
            }
            let fetchedMacs = CompanionStatusReconciliation.merge(rawMacs, current: macs)
            macs = fetchedMacs
            for mac in fetchedMacs where mac.operatorSnapshot?.sharingEnabled != true {
                operatorContents = operatorContents.filter { !$0.key.hasPrefix(mac.deviceID + ":") }
            }
            publishCompanionSurfaces(for: fetchedMacs)
            syncStage = "Loading results"
            let artifactResults = await fetchArtifactOffers(for: fetchedMacs)
            artifactOffersByDeviceID = artifactResults.offers
            syncStage = "Loading history"
            let historyResults = await fetchHistories(for: fetchedMacs)
            histories = historyResults.histories
            let syncIssues = artifactResults.issues + historyResults.issues
            lastSyncIssue = syncIssues.isEmpty
                ? cloud.consumeLastIssue()
                : syncIssues.joined(separator: " ")
            lastSyncAt = Date()
            lastSuccessfulSyncAt = lastSyncAt
            lastConnectionError = nil
            syncStage = "Connected"

            if fetchedMacs.isEmpty {
                message = "No Mac is paired yet. Open Sleep Switch on the Mac and keep it running."
            } else if !syncIssues.isEmpty {
                message = "Some private data is unavailable. Refresh to try again."
            } else if let lastSyncIssue {
                message = lastSyncIssue
            }
        } catch is CancellationError {
            syncStage = "Cancelled"
            return
        } catch {
            let connectionError = CompanionConnectionError(error: error)
            lastConnectionError = connectionError
            lastSyncIssue = cloud.consumeLastIssue() ?? connectionError.summary
            lastSyncAt = Date()
            syncStage = "Connection failed"
            message = connectionError.userMessage
        }
    }

    private func publishCompanionSurfaces(for macs: [CompanionMacStatus]) {
        CompanionWidgetPublisher.publish(macs)
        let selectedID = UserDefaults.standard.string(forKey: "selectedMacDeviceID") ?? ""
        let selected = CompanionMacSelection.preferred(from: macs, persistedDeviceID: selectedID)
        Task { await liveActivity.synchronize(with: macs, automaticDeviceID: selected?.deviceID, allowAutomaticStart: true) }
        heatNotifications.evaluate(macs)
        workNotifications.evaluate(macs)
    }

    func selectDashboardMac(_ deviceID: String) {
        UserDefaults.standard.set(deviceID, forKey: "selectedMacDeviceID")
        publishCompanionSurfaces(for: macs)
    }

    func operatorContent(for mac: CompanionMacStatus, itemID: String) -> CompanionOperatorContent? {
        operatorContents[mac.deviceID + ":" + itemID]
    }

    func sendOperator(_ operation: String, to mac: CompanionMacStatus, parameters: [String: String] = [:]) {
        var parameters = parameters
        parameters["operation"] = operation
        operatorIssues[mac.deviceID] = nil
        send(.operatorRequest, to: mac, parameters: parameters)
    }

    func enableHeatNotifications() {
        Task { [weak self] in
            guard let self else { return }
            let granted = await heatNotifications.requestAuthorization()
            if !granted { message = "Notifications are disabled in iPhone Settings." }
        }
    }

    func enableWorkNotifications() {
        Task { [weak self] in
            guard let self else { return }
            let granted = await workNotifications.requestAuthorization()
            if !granted { message = "Notifications are disabled in iPhone Settings." }
        }
    }

    private func fetchHistories(
        for macs: [CompanionMacStatus]
    ) async -> (
        histories: [String: CompanionHistorySnapshot],
        issues: [String]
    ) {
        let cloud = self.cloud
        return await withTaskGroup(of: HistoryFetchResult.self) { group in
            for mac in macs {
                group.addTask {
                    do {
                        let history = try await cloud.fetchHistory(for: mac.deviceID)
                        return HistoryFetchResult(
                            deviceID: mac.deviceID,
                            history: history,
                            issue: nil
                        )
                    } catch is CancellationError {
                        return HistoryFetchResult(
                            deviceID: mac.deviceID,
                            history: nil,
                            issue: "History loading was cancelled."
                        )
                    } catch {
                        return HistoryFetchResult(
                            deviceID: mac.deviceID,
                            history: nil,
                            issue: "History for \(mac.displayName) is unavailable."
                        )
                    }
                }
            }

            var histories: [String: CompanionHistorySnapshot] = [:]
            var issues: [String] = []
            for await result in group {
                if let history = result.history {
                    histories[result.deviceID] = history
                }
                if let issue = result.issue {
                    issues.append(issue)
                }
            }
            return (histories, issues)
        }
    }

    private func fetchArtifactOffers(
        for macs: [CompanionMacStatus]
    ) async -> (
        offers: [String: [CompanionPendingArtifactOffer]],
        issues: [String]
    ) {
        let cloud = self.cloud
        return await withTaskGroup(of: (String, [CompanionPendingArtifactOffer]?, String?).self) { group in
            for mac in macs {
                group.addTask {
                    do {
                        let offers = try await cloud.fetchArtifactOffers(for: mac.deviceID)
                        return (mac.deviceID, offers, nil)
                    } catch is CancellationError {
                        return (mac.deviceID, nil, "Result loading was cancelled.")
                    } catch {
                        return (mac.deviceID, nil, "Results for \(mac.displayName) are unavailable.")
                    }
                }
            }

            var offersByDeviceID: [String: [CompanionPendingArtifactOffer]] = [:]
            var issues: [String] = []
            for await result in group {
                if let offers = result.1 {
                    offersByDeviceID[result.0] = offers
                }
                if let issue = result.2 {
                    issues.append(issue)
                }
            }
            return (offersByDeviceID, issues)
        }
    }

    private func accountStatusMessage(for status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return "iCloud is ready."
        case .noAccount:
            return "Sign in to iCloud on this iPhone to see a paired Mac."
        case .restricted:
            return "iCloud access is restricted on this iPhone."
        case .couldNotDetermine:
            return "Sleep Switch could not determine the iCloud account status."
        case .temporarilyUnavailable:
            return "iCloud is temporarily unavailable. Try again in a moment."
        @unknown default:
            return "Sleep Switch could not determine the iCloud account status."
        }
    }

    func history(for mac: CompanionMacStatus) -> CompanionHistorySnapshot? {
        histories[mac.deviceID]
    }

    func contextTransfers(for mac: CompanionMacStatus, limit: Int = 3) -> [CompanionContextTransferActivity] {
        contextTransferActivities
            .filter { $0.targetDeviceID == mac.deviceID }
            .prefix(max(0, limit))
            .map { $0 }
    }

    func artifactOffers(for mac: CompanionMacStatus, limit: Int = 3) -> [CompanionPendingArtifactOffer] {
        (artifactOffersByDeviceID[mac.deviceID] ?? [])
            .prefix(max(0, limit))
            .map { $0 }
    }

    func artifactDownloadURL(for pending: CompanionPendingArtifactOffer) -> URL? {
        guard let offer = pending.offer else { return nil }
        return artifactDownloadURLs[offer.id] ?? artifactDownloadStore.existingFile(for: offer)
    }

    func artifactDownloadIssue(for pending: CompanionPendingArtifactOffer) -> String? {
        artifactDownloadIssuesByRecordName[pending.recordName]
    }

    func isDownloadingArtifact(_ pending: CompanionPendingArtifactOffer) -> Bool {
        guard let offer = pending.offer else { return false }
        return artifactDownloadIDs.contains(offer.id)
    }

    func downloadArtifact(_ pending: CompanionPendingArtifactOffer) {
        guard let offer = pending.offer,
              !offer.isExpired,
              !artifactDownloadIDs.contains(offer.id),
              artifactDownloadURL(for: pending) == nil
        else {
            return
        }

        artifactDownloadIDs.insert(offer.id)
        artifactDownloadIssuesByRecordName.removeValue(forKey: pending.recordName)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.artifactDownloadIDs.remove(offer.id) }
            do {
                let assetURL = try await cloud.fetchArtifactAsset(for: pending.recordName)
                let receivedURL = try artifactDownloadStore.store(assetAt: assetURL, for: offer)
                artifactDownloadURLs[offer.id] = receivedURL
                artifactDownloadIssuesByRecordName.removeValue(forKey: pending.recordName)
                message = "\(offer.filename) is ready on this iPhone."
            } catch is CancellationError {
                return
            } catch {
                let issue = (error as? LocalizedError)?.errorDescription
                    ?? "Sleep Switch could not get this result."
                artifactDownloadIssuesByRecordName[pending.recordName] = issue
                message = issue
            }
        }
    }

    var connectionTitle: String {
        if lastConnectionError != nil || accountStatus != .available {
            return "iCloud connection unavailable"
        }
        return "No paired Mac"
    }

    var connectionMessage: String {
        if let lastConnectionError {
            return lastConnectionError.userMessage
        }
        return message ?? "Open Sleep Switch on the Mac to begin."
    }

    var diagnosticsReport: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let checked = lastSyncAt?.formatted(date: .numeric, time: .standard) ?? "never"
        let succeeded = lastSuccessfulSyncAt?.formatted(date: .numeric, time: .standard) ?? "never"
        let error = lastConnectionError?.reportLines.joined(separator: "\n") ?? "Error: none"
        return """
        Sleep Switch Companion Diagnostics
        App: \(version) (\(build))
        CloudKit environment: \(Self.cloudEnvironmentName)
        Container: \(CompanionCloudStore.containerIdentifier)
        Account: \(accountStatus.diagnosticName)
        Stage: \(syncStage)
        Last checked: \(checked)
        Last successful sync: \(succeeded)
        Macs returned: \(macs.count)
        Last command: \(lastCommandStatus)
        \(error)
        """
    }

    static var cloudEnvironmentName: String {
        #if DEBUG
        return "Development"
        #else
        return "Production"
        #endif
    }

    func send(
        _ action: CompanionRemoteAction,
        to mac: CompanionMacStatus,
        parameters: [String: String] = [:]
    ) {
        guard !commandInFlight else { return }

#if targetEnvironment(simulator)
        applySimulatedCommand(action, to: mac, parameters: parameters)
#else
        commandInFlight = true
        message = nil
        lastCommandStatus = "Waiting — \(action.title)"

        let originalMac = mac
        if action == .setKeepAwake {
            replaceMac(mac.applyingKeepAwake(parameters: parameters))
        }

        let now = Date()
        let command = CompanionRemoteCommand(
            id: UUID(),
            targetDeviceID: mac.deviceID,
            action: action,
            parameters: parameters,
            requesterDeviceID: requesterDeviceID,
            nonce: UUID().uuidString,
            createdAt: now,
            expiresAt: now.addingTimeInterval(90),
            policyVersion: 1
        )
        progressDismissTask?.cancel()
        commandProgress = CompanionCommandProgress(
            commandID: command.id,
            actionTitle: action.title,
            stage: .sending
        )

        commandTask?.cancel()
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.commandInFlight = false
                self.commandTask = nil
            }
            do {
                try await self.cloud.send(command)
                self.commandProgress = self.commandProgress?.withStage(.waitingForMac)
                self.message = "\(action.title) requested for \(mac.displayName). Waiting for the Mac…"
                let result = try await self.waitForCommandResult(command.id)
                let completionMessage: String
                if let result {
                    self.commandProgress = self.commandProgress?.withStage(.confirming)
                    if let confirmed = CompanionStatusReconciliation.confirmedStatus(for: command, result: result, previous: originalMac) {
                        self.replaceMac(confirmed)
                        self.publishCompanionSurfaces(for: self.macs)
                    }
                    if result.executed, let content = result.operatorContent {
                        self.operatorContents[mac.deviceID + ":" + content.itemID] = content
                    }
                    if action == .operatorRequest, !result.executed { self.operatorIssues[mac.deviceID] = result.message ?? "Operator could not complete this request." }
                    completionMessage = result.message ?? (result.executed
                        ? "\(action.title) completed."
                        : "The Mac rejected \(action.title.lowercased()).")
                    self.lastCommandStatus = result.executed
                        ? "Completed — \(action.title)"
                        : "Rejected — \(action.title): \(completionMessage)"
                    if !result.executed, action == .setKeepAwake {
                        self.replaceMac(originalMac)
                    }
                    self.commandProgress = self.commandProgress?.withStage(
                        result.executed ? .completed : .failed
                    )
                } else {
                    if action == .operatorRequest { self.operatorIssues[mac.deviceID] = "The Mac has not replied yet. Try again when it is online." }
                    completionMessage = "\(action.title) is still pending. The Mac may be asleep or offline."
                    self.lastCommandStatus = "Pending — \(action.title)"
                    self.commandProgress = self.commandProgress?.withStage(.failed)
                }
                if ![.sleepMac, .restartMac, .shutdownMac].contains(action) {
                    await self.refreshAndWait()
                }
                self.message = completionMessage
                self.dismissCommandProgress(commandID: command.id)
            } catch is CancellationError {
                return
            } catch {
                if action == .operatorRequest { self.operatorIssues[mac.deviceID] = error.localizedDescription }
                if action == .setKeepAwake {
                    self.replaceMac(originalMac)
                }
                let issue = CompanionConnectionError(error: error)
                self.lastCommandStatus = "Failed — \(action.title): \(issue.domain) \(issue.code)"
                self.lastSyncIssue = issue.userMessage
                self.message = "Could not send \(action.title.lowercased()). \(issue.recovery)"
                self.commandProgress = self.commandProgress?.withStage(.failed)
                self.dismissCommandProgress(commandID: command.id)
            }
        }
#endif
    }

    func sendContextItem(
        from sourceURL: URL,
        to mac: CompanionMacStatus,
        completion: ((CompanionContextTransferActivityState) -> Void)? = nil
    ) {
        guard !commandInFlight else {
            completion?(.failed)
            return
        }

#if targetEnvironment(simulator)
        lastContextTransferStatus = "Simulated — \(sourceURL.lastPathComponent)"
        recordContextTransfer(
            transferID: UUID(),
            filename: sourceURL.lastPathComponent,
            byteCount: Int64((try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
            mac: mac,
            state: .delivered
        )
        message = "Simulated sending \(sourceURL.lastPathComponent) to \(mac.displayName)."
        completion?(.delivered)
#else
        do {
            let draft = try prepareContextTransfer(from: sourceURL, to: mac)
            commandInFlight = true
            message = nil
            lastContextTransferStatus = "Waiting — \(draft.transfer.filename)"
            recordContextTransfer(
                transferID: draft.transfer.id,
                filename: draft.transfer.filename,
                byteCount: draft.transfer.byteCount,
                mac: mac,
                state: .sending
            )
            progressDismissTask?.cancel()
            commandProgress = CompanionCommandProgress(
                commandID: draft.transfer.id,
                actionTitle: "Send \(draft.transfer.filename)",
                stage: .sending
            )

            commandTask?.cancel()
            commandTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.commandInFlight = false
                    self.commandTask = nil
                    try? FileManager.default.removeItem(at: draft.stagingDirectoryURL)
                }

                do {
                    try await self.cloud.send(draft.transfer, assetURL: draft.stagingFileURL)
                    self.commandProgress = self.commandProgress?.withStage(.waitingForMac)
                    self.recordContextTransfer(
                        transferID: draft.transfer.id,
                        filename: draft.transfer.filename,
                        byteCount: draft.transfer.byteCount,
                        mac: mac,
                        state: .waitingForMac
                    )
                    self.message = "\(draft.transfer.filename) is queued for \(mac.displayName)."
                    let result = try await self.waitForTransferResult(draft.transfer.id)
                    let completionMessage: String
                    if let result {
                        self.commandProgress = self.commandProgress?.withStage(.confirming)
                        completionMessage = result.message ?? (result.accepted
                            ? "\(draft.transfer.filename) reached the Remote Inbox."
                            : "\(draft.transfer.filename) was rejected by the Mac.")
                        self.lastContextTransferStatus = result.accepted
                            ? "Delivered — \(draft.transfer.filename)"
                            : "Rejected — \(draft.transfer.filename)"
                        self.recordContextTransfer(
                            transferID: draft.transfer.id,
                            filename: draft.transfer.filename,
                            byteCount: draft.transfer.byteCount,
                            mac: mac,
                            state: result.accepted ? .delivered : .rejected
                        )
                        self.commandProgress = self.commandProgress?.withStage(
                            result.accepted ? .completed : .failed
                        )
                        completion?(result.accepted ? .delivered : .rejected)
                    } else {
                        completionMessage = "\(draft.transfer.filename) is still queued. The Mac may be offline."
                        self.lastContextTransferStatus = "Pending — \(draft.transfer.filename)"
                        self.recordContextTransfer(
                            transferID: draft.transfer.id,
                            filename: draft.transfer.filename,
                            byteCount: draft.transfer.byteCount,
                            mac: mac,
                            state: .pending
                        )
                        self.commandProgress = self.commandProgress?.withStage(.failed)
                        completion?(.pending)
                    }
                    await self.refreshAndWait()
                    self.message = completionMessage
                    self.dismissCommandProgress(commandID: draft.transfer.id)
                } catch is CancellationError {
                    completion?(.failed)
                    return
                } catch {
                    let issue = CompanionConnectionError(error: error)
                    self.lastContextTransferStatus = "Failed — \(draft.transfer.filename)"
                    self.recordContextTransfer(
                        transferID: draft.transfer.id,
                        filename: draft.transfer.filename,
                        byteCount: draft.transfer.byteCount,
                        mac: mac,
                        state: .failed
                    )
                    self.lastSyncIssue = issue.userMessage
                    self.message = "Could not send \(draft.transfer.filename). \(issue.recovery)"
                    self.commandProgress = self.commandProgress?.withStage(.failed)
                    completion?(.failed)
                    self.dismissCommandProgress(commandID: draft.transfer.id)
                }
            }
        } catch {
            let issue = error as? CompanionContextTransferPreparationError
            message = issue?.errorDescription ?? "Sleep Switch could not prepare that file."
            lastContextTransferStatus = "Failed — \(sourceURL.lastPathComponent)"
            completion?(.failed)
        }
#endif
    }

    func handleContextImportResult(
        _ result: Result<[URL], Error>,
        for mac: CompanionMacStatus
    ) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                message = "No file was selected."
                lastContextTransferStatus = "Failed — import"
                return
            }
            sendContextItem(from: url, to: mac)
        case .failure(let error):
            if let cocoa = error as? CocoaError, cocoa.code == .userCancelled {
                return
            }
            message = "Sleep Switch could not open that file."
            lastContextTransferStatus = "Failed — import"
        }
    }

    /// Sends a short, explicit mobile follow-up through the existing private
    /// inbox contract. It never opens or controls a harness directly.
    func sendFollowUpNote(_ text: String, to mac: CompanionMacStatus) {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(note.utf8)
        guard CompanionFollowUpNotePolicy.isAllowed(byteCount: data.count) else {
            message = note.isEmpty
                ? "Write a follow-up before sending it."
                : "Follow-up notes are limited to 16 KB."
            return
        }

        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Sleep Switch/Follow-up Drafts/\(UUID().uuidString)", isDirectory: true)
        let sourceURL = directory.appendingPathComponent("follow-up-note.txt", isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: sourceURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceURL.path)
            sendContextItem(from: sourceURL, to: mac) { _ in
                try? FileManager.default.removeItem(at: directory)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            message = "Sleep Switch could not prepare that follow-up."
        }
    }

    func reloadSharedContextDrafts() {
#if DEBUG
        if isSharedContextDemo { return }
#endif
        sharedContextDrafts = sharedContextIntake.drafts()
    }

    func discardSharedContextDraft(_ draft: SharedContextDraft) {
        sharedContextIntake.discard(draft)
        reloadSharedContextDrafts()
    }

    func isSendingSharedContextDraft(_ draft: SharedContextDraft) -> Bool {
        sharedContextDraftIDsInFlight.contains(draft.id)
    }

    /// The Share extension only staged this item. Delivery still starts from
    /// an explicit choice in the companion, addressed to one selected Mac.
    func sendSharedContextDraft(_ draft: SharedContextDraft, to mac: CompanionMacStatus) {
        guard !commandInFlight,
              !sharedContextDraftIDsInFlight.contains(draft.id),
              let sourceURL = sharedContextIntake.fileURL(for: draft),
              FileManager.default.fileExists(atPath: sourceURL.path)
        else {
            reloadSharedContextDrafts()
            return
        }
        sharedContextDraftIDsInFlight.insert(draft.id)
        sendContextItem(from: sourceURL, to: mac) { [weak self] state in
            guard let self else { return }
            self.sharedContextDraftIDsInFlight.remove(draft.id)
            if state == .delivered || state == .pending {
                self.sharedContextIntake.discard(draft)
            }
            self.reloadSharedContextDrafts()
        }
    }

    private func dismissCommandProgress(commandID: UUID) {
        progressDismissTask?.cancel()
        progressDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard let self,
                  self.commandProgress?.commandID == commandID,
                  self.commandProgress?.isTerminal == true
            else { return }
            self.commandProgress = nil
            self.progressDismissTask = nil
        }
    }

    private func replaceMac(_ updatedMac: CompanionMacStatus) {
        guard let index = macs.firstIndex(where: { $0.deviceID == updatedMac.deviceID }) else {
            return
        }
        guard updatedMac.lastSeen >= macs[index].lastSeen else { return }
        macs[index] = updatedMac
        if updatedMac.operatorSnapshot?.sharingEnabled != true {
            operatorContents = operatorContents.filter { !$0.key.hasPrefix(updatedMac.deviceID + ":") }
        }
    }

#if targetEnvironment(simulator)
    private func applySimulatedCommand(
        _ action: CompanionRemoteAction,
        to mac: CompanionMacStatus,
        parameters: [String: String]
    ) {
        if action == .operatorRequest, var snapshot = mac.operatorSnapshot {
            let operation = parameters["operation"] ?? ""
            let itemID = parameters["itemID"] ?? ""
            switch operation {
            case "sharing": snapshot.sharingEnabled = parameters["enabled"] == "true"
            case "readThread", "readSkill":
                if let content = CompanionOperatorDemo.content(itemID: itemID) { operatorContents[mac.deviceID + ":" + itemID] = content }
            case "favourite":
                if let index = snapshot.skills.firstIndex(where: { $0.id == itemID }) { snapshot.skills[index].isFavourite = parameters["enabled"] == "true" }
            case "tags":
                if let index = snapshot.skills.firstIndex(where: { $0.id == itemID }) { snapshot.skills[index].tags = (parameters["tags"] ?? "").split(separator: ",").map(String.init) }
            case "recordUse":
                if let index = snapshot.skills.firstIndex(where: { $0.id == itemID }) { snapshot.skills[index].useCount += 1 }
            case "workflow":
                if let index = snapshot.threads.firstIndex(where: { $0.id == itemID }) { snapshot.threads[index].workflowLane = parameters["lane"] ?? "Inbox" }
            case "preferences":
                let enabled = parameters["enabled"] == "true"
                switch parameters["key"] {
                case "history": snapshot.historyEnabled = enabled
                case "triggers": snapshot.triggersEnabled = enabled
                case "diagnostics": snapshot.diagnosticsEnabled = enabled
                default: break
                }
            default: break
            }
            var updated = mac.refreshingLastSeen()
            updated.operatorSnapshot = snapshot
            replaceMac(updated)
        }
        let now = Date()
        let command = CompanionRemoteCommand(id: UUID(), targetDeviceID: mac.deviceID, action: action, parameters: parameters, requesterDeviceID: requesterDeviceID, nonce: UUID().uuidString, createdAt: now, expiresAt: now.addingTimeInterval(90), policyVersion: 1)
        let result = CompanionRemoteResult(commandID: command.id, accepted: true, executed: true, completedAt: now, message: nil)
        if let confirmed = CompanionStatusReconciliation.confirmedStatus(for: command, result: result, previous: mac) {
            replaceMac(confirmed)
        }
        lastCommandStatus = "Simulated — \(action.title)"
        message = "Simulated \(action.title.lowercased()). No command was sent to iCloud."
    }

    private func showSimulatorCloudKitMessageIfNeeded() {
#if DEBUG
        if isScreenshotDemo || isConnectionDemo { return }
#endif
        accountStatus = .couldNotDetermine
        syncStage = "Simulator"
        lastSyncAt = Date()
        message = "CloudKit pairing is unavailable in this unsigned Simulator build. Install the TestFlight app on an iPhone to control a Mac."
    }
#endif

    private func waitForCommandResult(_ commandID: UUID) async throws -> CompanionRemoteResult? {
        // The Mac uses a lightweight three-second command poll. Keep a longer
        // timeout for CloudKit propagation and temporarily slow connections.
        for _ in 0..<60 {
            try Task.checkCancellation()
            if let result = try await cloud.fetchCommandResult(for: commandID) {
                return result
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    private func waitForTransferResult(_ transferID: UUID) async throws -> CompanionContextTransferResult? {
        for _ in 0..<120 {
            try Task.checkCancellation()
            if let result = try await cloud.fetchContextTransferResult(for: transferID) {
                return result
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    private func prepareContextTransfer(
        from sourceURL: URL,
        to mac: CompanionMacStatus
    ) throws -> PreparedContextTransfer {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let values = try sourceURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .nameKey,
            .typeIdentifierKey
        ])
        if values.isRegularFile == false {
            throw CompanionContextTransferPreparationError.folderNotSupported
        }

        let filename = values.name ?? sourceURL.lastPathComponent
        guard !filename.isEmpty else {
            throw CompanionContextTransferPreparationError.missingFilename
        }
        let byteCount = Int64(values.fileSize ?? 0)
        guard CompanionContextTransferPolicy.isAllowed(byteCount: byteCount) else {
            throw CompanionContextTransferPreparationError.invalidSize(maximum: CompanionContextTransferPolicy.maximumByteCount)
        }

        let now = Date()
        let transfer = CompanionContextTransfer(
            id: UUID(),
            targetDeviceID: mac.deviceID,
            requesterDeviceID: requesterDeviceID,
            filename: filename,
            typeIdentifier: values.typeIdentifier,
            byteCount: byteCount,
            createdAt: now,
            expiresAt: now.addingTimeInterval(CompanionContextTransferPolicy.lifetime)
        )

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SleepSwitch-RemoteInbox-Staging", isDirectory: true)
        let stagingDirectoryURL = stagingRoot.appendingPathComponent(transfer.id.uuidString, isDirectory: true)
        let stagingFileURL = stagingDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        try FileManager.default.createDirectory(
            at: stagingDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: stagingFileURL)
        } catch {
            throw CompanionContextTransferPreparationError.copyFailed
        }

        return PreparedContextTransfer(
            transfer: transfer,
            stagingDirectoryURL: stagingDirectoryURL,
            stagingFileURL: stagingFileURL
        )
    }

    private struct HistoryFetchResult {
        let deviceID: String
        let history: CompanionHistorySnapshot?
        let issue: String?
    }

    private struct PreparedContextTransfer {
        let transfer: CompanionContextTransfer
        let stagingDirectoryURL: URL
        let stagingFileURL: URL
    }

    private func recordContextTransfer(
        transferID: UUID,
        filename: String,
        byteCount: Int64,
        mac: CompanionMacStatus,
        state: CompanionContextTransferActivityState,
        updatedAt: Date = .now
    ) {
        contextTransferActivities = contextTransferHistory.record(
            CompanionContextTransferActivity(
                transferID: transferID,
                targetDeviceID: mac.deviceID,
                targetDisplayName: mac.displayName,
                filename: filename,
                byteCount: byteCount,
                updatedAt: updatedAt,
                state: state
            )
        )
    }

    private enum CompanionContextTransferPreparationError: LocalizedError {
        case folderNotSupported
        case missingFilename
        case invalidSize(maximum: Int64)
        case copyFailed

        var errorDescription: String? {
            switch self {
            case .folderNotSupported:
                return "Pick one file for the Remote Inbox, not a folder."
            case .missingFilename:
                return "Sleep Switch could not read that file name."
            case .invalidSize(let maximum):
                let megabytes = Int(maximum / 1_024 / 1_024)
                return "Remote Inbox currently accepts files up to \(megabytes) MB."
            case .copyFailed:
                return "Sleep Switch could not copy that file into its private upload queue."
            }
        }
    }
}

struct CompanionConnectionError: Equatable {
    let domain: String
    let code: Int
    let summary: String
    let recovery: String
    let occurredAt: Date
    let retryAfter: TimeInterval?

    init(error: Error, occurredAt: Date = Date()) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        summary = nsError.localizedDescription
        recovery = Self.recoveryMessage(for: error)
        self.occurredAt = occurredAt
        retryAfter = (nsError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
    }

    static func account(
        status: CKAccountStatus,
        message: String,
        occurredAt: Date = Date()
    ) -> CompanionConnectionError {
        CompanionConnectionError(
            domain: "CKAccountStatus",
            code: status.rawValue,
            summary: message,
            recovery: message,
            occurredAt: occurredAt,
            retryAfter: nil
        )
    }

    private init(
        domain: String,
        code: Int,
        summary: String,
        recovery: String,
        occurredAt: Date,
        retryAfter: TimeInterval?
    ) {
        self.domain = domain
        self.code = code
        self.summary = summary
        self.recovery = recovery
        self.occurredAt = occurredAt
        self.retryAfter = retryAfter
    }

    var userMessage: String { recovery }

    var reportLines: [String] {
        var lines = [
            "Error domain: \(domain)",
            "Error code: \(code)",
            "Error detail: \(summary)",
            "Error time: \(occurredAt.formatted(date: .numeric, time: .standard))"
        ]
        if let retryAfter {
            lines.append("Retry after: \(Int(retryAfter.rounded())) seconds")
        }
        return lines
    }

    private static func recoveryMessage(for error: Error) -> String {
        guard let cloudError = error as? CKError else {
            return "The private iCloud connection could not be read. Open Connection Details for the exact error."
        }
        switch cloudError.code {
        case .notAuthenticated:
            return "Sign in to iCloud on this iPhone, then retry."
        case .networkUnavailable, .networkFailure:
            return "The iCloud network connection is unavailable. Check your connection, then retry."
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "iCloud is temporarily busy. Retry in a moment."
        case .permissionFailure:
            return "iCloud denied access to the private Sleep Switch data. Open Connection Details."
        case .unknownItem, .invalidArguments, .serverRejectedRequest:
            return "The CloudKit data setup does not match this build. Open Connection Details."
        default:
            return "The private iCloud connection could not be read. Open Connection Details for the exact error."
        }
    }
}

private extension CKAccountStatus {
    var diagnosticName: String {
        switch self {
        case .available: return "Available"
        case .noAccount: return "No account"
        case .restricted: return "Restricted"
        case .couldNotDetermine: return "Could not determine"
        case .temporarilyUnavailable: return "Temporarily unavailable"
        @unknown default: return "Unknown (\(rawValue))"
        }
    }
}

#if DEBUG
private enum CompanionScreenshotDemo {
    struct Snapshot {
        let mac: CompanionMacStatus
        let history: CompanionHistorySnapshot
        let artifactOffersByDeviceID: [String: [CompanionPendingArtifactOffer]]
    }

    static func make(now: Date = Date()) -> Snapshot {
        let calendar = Calendar.current
        let deviceID = "demo-macbook-pro"
        let noTelemetry = ProcessInfo.processInfo.arguments.contains("--screenshot-no-telemetry")
        let capabilities = CompanionMacCapabilities(
            canSleepMac: true,
            canSleepDisplay: true,
            canWakeDisplay: true,
            canWakeMac: false,
            canLockMac: true,
            canRestartMac: true,
            canShutdownMac: true,
            canSetKeepAwake: true,
            canSleepDisplayUntilAgentsFinish: true,
            supportsCloudKit: true,
            canControlManualSession: true,
            canSetCoolingProfile: !noTelemetry,
            canPreventSleepWithLidClosed: true,
            canReceiveContextTransfers: true,
            canUseOperator: true
        )
        let mac = CompanionMacStatus(
            deviceID: deviceID,
            displayName: "Mantas’ MacBook Pro",
            build: "2.4.2 (39)",
            lastSeen: now,
            uptimeSeconds: 2.4 * 24 * 3_600,
            powerSource: .ac,
            batteryPercent: 97,
            thermalState: "nominal",
            activeAgentCount: 1,
            activeSessionCount: 1,
            awakeMode: "agents",
            displayAsleep: false,
            isKeepingAwake: true,
            keepDisplayAwake: false,
            automaticAgentAwakeEnabled: true,
            wakeDisplayWhenAgentsFinish: false,
            estimatedWatts: noTelemetry ? nil : 38,
            energySource: .ac,
            energyConfidence: noTelemetry ? .unavailable : .estimated,
            isCharging: !noTelemetry,
            chargingWatts: noTelemetry ? nil : 31,
            network: .online,
            capabilities: capabilities,
            agents: [
                CompanionAgentStatus(id: "codex", name: "Codex", sessionCount: 1)
            ],
            manualSession: nil,
            cooling: noTelemetry ? CompanionCoolingStatus(profile: "systemControl", state: "Needs Attention", temperatureCelsius: nil, verifiedDemand: nil, fans: [], message: "Fan control is not available on this Mac. macOS continues to manage cooling.", availableProfiles: ["systemControl"]) : CompanionCoolingStatus(
                profile: "aggressive",
                state: "Aggressive",
                temperatureCelsius: 56,
                verifiedDemand: 0.72,
                fans: [
                    CompanionFanStatus(id: 0, actualRPM: 4_820, targetRPM: 4_900, maximumRPM: 6_200),
                    CompanionFanStatus(id: 1, actualRPM: 4_760, targetRPM: 4_900, maximumRPM: 6_200)
                ],
                message: nil,
                availableProfiles: ["systemControl", "aggressive", "maximum"],
                sensors: [
                    CompanionTemperatureSensor(key: "Tp01", group: .cpu, celsius: 57.4),
                    CompanionTemperatureSensor(key: "Tp05", group: .cpu, celsius: 58.1),
                    CompanionTemperatureSensor(key: "Tp09", group: .cpu, celsius: 61.8),
                    CompanionTemperatureSensor(key: "Tp0D", group: .cpu, celsius: 59.2),
                    CompanionTemperatureSensor(key: "Tg0K", group: .gpu, celsius: 48.3),
                    CompanionTemperatureSensor(key: "Tg0L", group: .gpu, celsius: 47.9),
                    CompanionTemperatureSensor(key: "Tm0p", group: .auxiliary, celsius: 43.2),
                    CompanionTemperatureSensor(key: "Tm1p", group: .auxiliary, celsius: 44.1)
                ]
            ),
            operatorSummary: CompanionOperatorSummary(
                updatedAt: now,
                harnesses: [
                    CompanionOperatorHarnessSummary(
                        harnessID: "codex",
                        harnessName: "Codex",
                        liveSessionCount: 3,
                        tokenDelta: 18_400,
                        durationDeltaSeconds: 9_120
                    ),
                    CompanionOperatorHarnessSummary(
                        harnessID: "hermes-agent",
                        harnessName: "Hermes",
                        liveSessionCount: 1,
                        tokenDelta: 6_200,
                        durationDeltaSeconds: 2_700
                    )
                ],
                activeSessionCount: 4,
                tokenDelta: 24_600,
                durationDeltaSeconds: 11_820,
                finishAction: CompanionRemoteAction.sleepMacWhenAgentsFinish.rawValue,
                alertCodes: []
            ),
            remoteWork: CompanionRemoteWorkSummary(
                updatedAt: now,
                items: [
                    CompanionWorkItemSummary(
                        id: "demo-codex-active",
                        harnessID: "codex",
                        harnessName: "Codex",
                        state: .active,
                        startedAt: now.addingTimeInterval(-2_760),
                        updatedAt: now.addingTimeInterval(-10),
                        durationSeconds: 2_760,
                        title: "Refine checkout review",
                        projectName: "Storefront",
                        activity: .editingFiles
                    ),
                    CompanionWorkItemSummary(
                        id: "demo-codex-waiting",
                        harnessID: "codex",
                        harnessName: "Codex",
                        state: .rateLimited,
                        startedAt: now.addingTimeInterval(-1_040),
                        updatedAt: now.addingTimeInterval(-95),
                        durationSeconds: 1_040,
                        title: "Audit release notes",
                        projectName: "Release",
                        attentionSummary: "Usage limit reached"
                    ),
                    CompanionWorkItemSummary(
                        id: "demo-hermes-finished",
                        harnessID: "hermes-agent",
                        harnessName: "Hermes",
                        state: .finished,
                        startedAt: now.addingTimeInterval(-3_800),
                        updatedAt: now.addingTimeInterval(-340),
                        durationSeconds: 3_460,
                        title: nil
                    )
                ],
                stateCounts: [
                    CompanionWorkStateCount(state: .active, count: 1),
                    CompanionWorkStateCount(state: .rateLimited, count: 1),
                    CompanionWorkStateCount(state: .finished, count: 1)
                ],
                attentionCount: 0
            )
        )

        let energyDays = (0..<7).compactMap { offset -> CompanionEnergyDay? in
            guard let day = calendar.date(byAdding: .day, value: -6 + offset, to: calendar.startOfDay(for: now)) else { return nil }
            let values = [0.18, 0.24, 0.31, 0.27, 0.42, 0.36, 0.29]
            return CompanionEnergyDay(
                dayStart: day,
                kilowattHours: noTelemetry ? 0 : values[offset],
                averageWatts: noTelemetry ? nil : 31 + Double(offset),
                peakWatts: noTelemetry ? nil : 68 + Double(offset * 3),
                sampleCount: 48
            )
        }
        let agentDays = (0..<7).compactMap { offset -> CompanionAgentDay? in
            guard let day = calendar.date(byAdding: .day, value: -6 + offset, to: calendar.startOfDay(for: now)) else { return nil }
            return CompanionAgentDay(
                dayStart: day,
                activeSeconds: Double([3_600, 7_200, 10_800, 5_400, 14_400, 9_000, 11_700][offset]),
                peakSessionCount: [2, 3, 4, 3, 5, 4, 5][offset],
                agentCount: [1, 2, 3, 2, 4, 3, 3][offset]
            )
        }
        let energyBuckets = (0..<288).compactMap { offset -> EnergyBucket? in
            // Leave one honest gap in the demo so screenshots and visual QA do
            // not imply that missing telemetry means zero consumption.
            guard !noTelemetry, !(86...103).contains(offset) else { return nil }
            let bucketStart = now.addingTimeInterval(TimeInterval(offset - 287) * 300)
            let wave = sin(Double(offset) / 18) * 8
            let workBurst = (164...208).contains(offset) ? 24.0 : 0
            let watts = max(5, 20 + wave + workBurst)
            return EnergyBucket(
                bucketStart: bucketStart,
                durationSeconds: 300,
                averageWatts: watts,
                peakWatts: watts + 7,
                kilowattHours: watts * 300 / 3_600_000,
                source: .ac,
                confidence: .estimated,
                sampleCount: 5
            )
        }
        let history = CompanionHistorySnapshot(
            deviceID: deviceID,
            updatedAt: now,
            historyEnabled: true,
            energyBuckets: energyBuckets,
            energyDays: energyDays,
            agentDays: agentDays,
            agentTypeDays: [
                CompanionAgentTypeDay(
                    dayStart: calendar.startOfDay(for: now),
                    agentID: "codex",
                    agentName: "Codex",
                    activeSeconds: 7_200,
                    peakSessionCount: 3
                ),
                CompanionAgentTypeDay(
                    dayStart: calendar.startOfDay(for: now),
                    agentID: "opencode",
                    agentName: "OpenCode",
                    activeSeconds: 4_500,
                    peakSessionCount: 2
                )
            ],
            storageBytes: 92_160
        )
        let artifactOffer = CompanionArtifactOffer(
            id: UUID(uuidString: "DEBADC0D-0000-4000-8000-000000000001")!,
            sourceDeviceID: deviceID,
            filename: "checkout-review.pdf",
            typeIdentifier: "com.adobe.pdf",
            byteCount: 2_482_900,
            createdAt: now.addingTimeInterval(-95),
            expiresAt: now.addingTimeInterval(60 * 60)
        )

        return Snapshot(
            mac: mac,
            history: history,
            artifactOffersByDeviceID: [
                deviceID: [
                    CompanionPendingArtifactOffer(
                        recordName: "demo-artifact-offer",
                        offer: artifactOffer
                    )
                ]
            ]
        )
    }
}
#endif

struct CompanionHomeView: View {
    @ObservedObject var model: CompanionAppModel
    @AppStorage("selectedMacDeviceID") private var selectedMacDeviceID = ""
    @AppStorage("showConnectionStatus") private var showConnectionStatus = true
    @State private var showingSettings = false

    private var selectedMac: CompanionMacStatus? {
        CompanionMacSelection.preferred(
            from: model.macs,
            persistedDeviceID: selectedMacDeviceID
        )
    }

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--screenshot-settings") {
            NavigationStack {
                CompanionSettingsView(model: model)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--screenshot-actions"), let mac = model.macs.first {
            NavigationStack {
                CompanionActionsView(mac: mac, model: model)
            }
        } else {
            dashboard
        }
        #else
        dashboard
        #endif
    }

    private var dashboard: some View {
        NavigationStack {
            ScrollView {
                if let mac = selectedMac {
                    VStack(alignment: .leading, spacing: 18) {
                        DeviceSelectorBar(
                            macs: model.macs,
                            selectedMac: mac,
                            selectedDeviceID: $selectedMacDeviceID
                        )
                        DeviceStatusCard(mac: mac)
                        AgentControlsCard(mac: mac, model: model)
                        QuickActionsCard(mac: mac, model: model)
                        if let history = model.history(for: mac) {
                            InsightsPreviewCard(history: history)
                        }
                        if showConnectionStatus {
                            ConnectionFooter(
                                lastSyncAt: model.lastSyncAt,
                                issue: model.lastSyncIssue
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                } else {
                    VStack(spacing: 20) {
                        ContentUnavailableView(
                            model.connectionTitle,
                            systemImage: model.lastConnectionError == nil
                                ? "laptopcomputer"
                                : "icloud.slash",
                            description: Text(model.connectionMessage)
                        )

                        HStack(spacing: 12) {
                            Button("Retry", systemImage: "arrow.clockwise") {
                                model.refresh()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isLoading)

                            Button("Connection Details", systemImage: "stethoscope") {
                                showingSettings = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 54)
                }
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Sleep Switch")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 14) {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            model.refresh()
                        }
                        .disabled(model.isLoading || model.commandInFlight)

                        Button("Settings", systemImage: "gearshape") {
                            showingSettings = true
                        }
                    }
                }
            }
            .refreshable { await model.refreshAndWait() }
            .safeAreaInset(edge: .bottom) {
                if selectedMac != nil, shouldShowMessage, let message = model.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
            .task { await model.refreshAndWait() }
            .sheet(isPresented: $showingSettings) {
                CompanionSettingsView(
                    model: model,
                    onDone: { showingSettings = false }
                )
            }
        }
    }

    private var shouldShowMessage: Bool {
        #if DEBUG
        return !ProcessInfo.processInfo.arguments.contains("--screenshot-demo")
        #else
        return true
        #endif
    }
}

private struct DeviceSelectorBar: View {
    let macs: [CompanionMacStatus]
    let selectedMac: CompanionMacStatus
    @Binding var selectedDeviceID: String

    var body: some View {
        HStack(spacing: 12) {
            Label("Connected Mac", systemImage: "laptopcomputer")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Menu {
                ForEach(macs) { mac in
                    Button {
                        selectedDeviceID = mac.deviceID
                    } label: {
                        Label(
                            mac.displayName,
                            systemImage: mac.deviceID == selectedMac.deviceID ? "checkmark" : "laptopcomputer"
                        )
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedMac.displayName)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct DeviceStatusCard: View {
    let mac: CompanionMacStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(mac.isStale ? Color.secondary : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(mac.displayName)
                        .font(.headline)
                    Text(mac.isStale ? "Last seen \(mac.lastSeen.formatted(date: .abbreviated, time: .shortened))" : "Online · Sleep Switch \(mac.build)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Circle()
                    .fill(mac.isStale ? Color.secondary : Color.green)
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                MetricTile(title: "Uptime", value: uptimeText, symbol: "clock")
                MetricTile(title: "Energy", value: energyText, symbol: "bolt")
                MetricTile(title: "Thermal", value: mac.thermalState.capitalized, symbol: "thermometer.medium")
                MetricTile(title: "Agents", value: "\(mac.activeSessionCount) sessions", symbol: "terminal")
            }
        }
        .padding(18)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var uptimeText: String {
        let hours = Int(mac.uptimeSeconds) / 3_600
        let days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        return "\(hours)h"
    }

    private var energyText: String {
        guard let watts = mac.estimatedWatts else { return "—" }
        return "\(Int(watts.rounded())) W"
    }
}

private struct AgentControlsCard: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Agent controls", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Text("\(mac.activeAgentCount) active")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Toggle("Keep Awake for Agents", isOn: Binding(
                get: { mac.automaticAgentAwakeEnabled },
                set: { model.send(.setKeepAwake, to: mac, parameters: ["enabled": String($0)]) }
            ))
            .disabled(!mac.capabilities.canSetKeepAwake || mac.isStale || model.commandInFlight)

            Divider()

            Toggle("Wake Display When Agents Finish", isOn: Binding(
                get: { mac.wakeDisplayWhenAgentsFinish },
                set: { model.send(.setKeepAwake, to: mac, parameters: ["wakeWhenAgentsFinish": String($0)]) }
            ))
            .disabled(!mac.capabilities.canSetKeepAwake || mac.isStale || model.commandInFlight)
        }
        .padding(18)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct QuickActionsCard: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        NavigationLink {
            CompanionActionsView(mac: mac, model: model)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remote controls")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(mac.capabilities.availableActions.count) actions available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct InsightsPreviewCard: View {
    let history: CompanionHistorySnapshot

    private var energyTotal: Double {
        history.energyDays.reduce(0) { $0 + $1.kilowattHours }
    }

    private var agentHours: Double {
        history.agentDays.reduce(0) { $0 + $1.activeSeconds / 3_600 }
    }

    var body: some View {
        NavigationLink {
            CompanionHistoryView(history: history)
                .navigationTitle("Insights")
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Insights", systemImage: "chart.xyaxis.line")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }

                if history.historyEnabled, !history.energyDays.isEmpty {
                    Chart(history.energyDays) { day in
                        BarMark(
                            x: .value("Day", day.dayStart, unit: .day),
                            y: .value("kWh", day.kilowattHours)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 84)

                    HStack(spacing: 16) {
                        Label(String(format: "%.2f kWh", energyTotal), systemImage: "bolt")
                        Label(String(format: "%.1f agent-hours", agentHours), systemImage: "terminal")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                } else {
                    Text("History saving is off on this Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ConnectionFooter: View {
    let lastSyncAt: Date?
    let issue: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.icloud")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Private iCloud connection")
                    .font(.caption.weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    private var statusText: String {
        if let issue {
            return issue
        }
        guard let lastSyncAt else {
            return "Commands are short-lived and addressed to one Mac."
        }
        return "Checked \(lastSyncAt.formatted(date: .omitted, time: .shortened)) · commands are short-lived."
    }
}

private struct CompanionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: CompanionAppModel
    private let onDone: (() -> Void)?
    @AppStorage("refreshOnOpen") private var refreshOnOpen = true
    @AppStorage("showConnectionStatus") private var showConnectionStatus = true

    init(model: CompanionAppModel, onDone: (() -> Void)? = nil) {
        self.model = model
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Toggle("Refresh when opened", isOn: $refreshOnOpen)
                    Toggle("Show connection status", isOn: $showConnectionStatus)
                }

                Section("Connection details") {
                    LabeledContent("Status", value: model.syncStage)
                    LabeledContent("iCloud account", value: model.accountStatus.diagnosticName)
                    LabeledContent("Environment", value: CompanionAppModel.cloudEnvironmentName)
                    LabeledContent("Last checked", value: formatted(model.lastSyncAt))
                    LabeledContent("Last connected", value: formatted(model.lastSuccessfulSyncAt))

                    if let error = model.lastConnectionError {
                        DisclosureGroup("Last error · \(error.domain) \(error.code)") {
                            Text(error.summary)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ShareLink(
                        item: model.diagnosticsReport,
                        subject: Text("Sleep Switch connection diagnostics")
                    ) {
                        Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                    }
                }

                Section("Privacy") {
                    Label("Private iCloud", systemImage: "lock.icloud")
                    Text("The companion reads your Mac’s private CloudKit records. It does not use a developer-operated server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    Link("Privacy policy", destination: URL(string: "https://github.com/mistermantas/macos-sleep-switch/blob/main/PRIVACY.md")!)
                    Link("Support & feedback", destination: URL(string: "https://github.com/mistermantas/macos-sleep-switch/issues")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDone?()
                        dismiss()
                    }
                }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func formatted(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
    }
}

#if DEBUG
private struct CompanionScreenshotActionsView: View {
    let mac: CompanionMacStatus

    private let actions: [CompanionRemoteAction] = [
        .sleepDisplay,
        .wakeDisplay,
        .sleepDisplayUntilAgentsFinish,
        .sleepMac,
        .lockMac,
        .restartMac,
        .shutdownMac
    ]

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Online")
                            .font(.headline)
                        Text("Mantas’ MacBook Pro · 5 agent sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(.green).frame(width: 10, height: 10)
                }
            }

            Section("Agent controls") {
                Toggle("Keep Awake for Agents", isOn: .constant(true))
                Toggle("Wake Display When Agents Finish", isOn: .constant(false))
            }

            Section {
                ForEach(actions, id: \.rawValue) { action in
                    Button {
                    } label: {
                        Label(action.title, systemImage: action.symbolName)
                    }
                }
            } header: {
                Text("Remote actions")
            } footer: {
                Text("Sleep Switch only sends named actions that this Mac has advertised. Sleep, lock, restart, and shutdown ask for confirmation.")
            }

            Section {
                Label("Private iCloud connection", systemImage: "lock.icloud")
                Text("Commands expire quickly and are addressed to this Mac. No developer-operated server is involved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sleep Switch")
    }
}
#endif

private struct CompanionActionsView: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel
    @State private var actionAwaitingConfirmation: CompanionRemoteAction?

    private let actionOrder: [CompanionRemoteAction] = [
        .sleepDisplay,
        .wakeDisplay,
        .sleepDisplayUntilAgentsFinish,
        .sleepMac,
        .lockMac,
        .restartMac,
        .shutdownMac,
        .panicStop
    ]

    private var availableActions: [CompanionRemoteAction] {
        actionOrder.filter { mac.capabilities.availableActions.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mac.displayName)
                            .font(.headline)
                        Text(mac.isStale ? "Offline" : "Online")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(mac.isStale ? Color.secondary : Color.green)
                        .frame(width: 10, height: 10)
                }
                .padding(18)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Power and display")
                        .font(.headline)
                    ForEach(availableActions, id: \.rawValue) { action in
                        Button {
                            if action.requiresConfirmation {
                                actionAwaitingConfirmation = action
                            } else {
                                model.send(action, to: mac)
                            }
                        } label: {
                            Label(action.title, systemImage: action.symbolName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled(mac.isStale || model.commandInFlight)
                    }
                }
                .padding(18)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                if !mac.capabilities.canWakeMac {
                    Label("Wake Mac is unavailable while it is fully asleep.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Remote controls")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            actionAwaitingConfirmation?.title ?? "Confirm action",
            isPresented: Binding(
                get: { actionAwaitingConfirmation != nil },
                set: { if !$0 { actionAwaitingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = actionAwaitingConfirmation {
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    actionAwaitingConfirmation = nil
                    model.send(action, to: mac)
                }
            }
            Button("Cancel", role: .cancel) { actionAwaitingConfirmation = nil }
        } message: {
            if let action = actionAwaitingConfirmation {
                Text(confirmationMessage(for: action))
            }
        }
    }

    private func confirmationMessage(for action: CompanionRemoteAction) -> String {
        switch action {
        case .shutdownMac:
            return "The Mac will shut down. Any running work must already be saved."
        case .restartMac:
            return "The Mac will restart. Any running work must already be saved."
        case .sleepMac:
            return "The Mac will sleep. Sleep Switch will no longer receive commands until it wakes."
        case .sleepDisplay:
            return "Only the display will sleep; the Mac and its agents keep running."
        case .lockMac:
            return "The current macOS user session will be locked."
        default:
            return action.title
        }
    }
}

private struct MacDashboardView: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel
    @State private var actionAwaitingConfirmation: CompanionRemoteAction?

    private let actionOrder: [CompanionRemoteAction] = [
        .sleepDisplay,
        .wakeDisplay,
        .sleepDisplayUntilAgentsFinish,
        .sleepMac,
        .lockMac,
        .restartMac,
        .shutdownMac,
        .panicStop
    ]

    private var availableActions: [CompanionRemoteAction] {
        actionOrder.filter { mac.capabilities.availableActions.contains($0) }
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                header
                metrics
                agentControls
                if let history = model.history(for: mac) {
                    CompanionHistoryView(history: history)
                }
                if availableActions.isEmpty {
                    Text("No remote power actions are available for this Mac build.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    powerActions
                }
                if !mac.capabilities.canWakeMac {
                    Text("Wake Mac is unavailable while the Mac is fully asleep. Sleep Switch must be running and awake to receive commands.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text(mac.displayName)
        }
        .confirmationDialog(
            actionAwaitingConfirmation?.title ?? "Confirm action",
            isPresented: Binding(
                get: { actionAwaitingConfirmation != nil },
                set: { if !$0 { actionAwaitingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = actionAwaitingConfirmation {
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    actionAwaitingConfirmation = nil
                    model.send(action, to: mac)
                }
            }
            Button("Cancel", role: .cancel) { actionAwaitingConfirmation = nil }
        } message: {
            if let action = actionAwaitingConfirmation {
                Text(confirmationMessage(for: action))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.title2)
                .foregroundStyle(mac.isStale ? .secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(mac.isStale ? "Last seen \(mac.lastSeen.formatted(date: .abbreviated, time: .shortened))" : "Online")
                    .font(.headline)
                Text("Sleep Switch \(mac.build)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(mac.isStale ? Color.secondary : Color.green)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricTile(title: "Uptime", value: uptimeText, symbol: "clock")
            MetricTile(title: "Energy", value: energyText, symbol: "bolt")
            MetricTile(title: "Thermal", value: mac.thermalState.capitalized, symbol: "thermometer.medium")
            MetricTile(title: "Agents", value: "\(mac.activeSessionCount) sessions", symbol: "terminal")
        }
    }

    private var agentControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agent controls")
                .font(.subheadline.weight(.semibold))
            Toggle("Keep Awake for Agents", isOn: Binding(
                get: { mac.automaticAgentAwakeEnabled },
                set: { model.send(.setKeepAwake, to: mac, parameters: ["enabled": String($0)]) }
            ))
            .disabled(!mac.capabilities.canSetKeepAwake || mac.isStale || model.commandInFlight)
            Toggle("Wake Display When Agents Finish", isOn: Binding(
                get: { mac.wakeDisplayWhenAgentsFinish },
                set: { model.send(.setKeepAwake, to: mac, parameters: ["wakeWhenAgentsFinish": String($0)]) }
            ))
            .disabled(!mac.capabilities.canSetKeepAwake || mac.isStale || model.commandInFlight)
        }
    }

    private var powerActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Power actions")
                .font(.subheadline.weight(.semibold))
            ForEach(availableActions, id: \.rawValue) { action in
                Button {
                    if action.requiresConfirmation {
                        actionAwaitingConfirmation = action
                    } else {
                        model.send(action, to: mac)
                    }
                } label: {
                    Label(action.title, systemImage: action.symbolName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(mac.isStale || model.commandInFlight)
            }
        }
    }

    private var uptimeText: String {
        let hours = Int(mac.uptimeSeconds) / 3_600
        let days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        return "\(hours)h"
    }

    private var energyText: String {
        guard let watts = mac.estimatedWatts else { return "—" }
        return "\(Int(watts.rounded())) W"
    }

    private func confirmationMessage(for action: CompanionRemoteAction) -> String {
        switch action {
        case .shutdownMac:
            return "The Mac will shut down. Any running work must already be saved."
        case .restartMac:
            return "The Mac will restart. Any running work must already be saved."
        case .sleepMac:
            return "The Mac will sleep. Sleep Switch will no longer receive commands until it wakes."
        case .sleepDisplay:
            return "Only the display will sleep; the Mac and its agents keep running."
        case .lockMac:
            return "The current macOS user session will be locked."
        default:
            return action.title
        }
    }
}

private struct CompanionHistoryView: View {
    let history: CompanionHistorySnapshot
    @State private var range: CompanionHistoryRange = .week

    private var cutoff: Date {
        Date().addingTimeInterval(-range.duration)
    }

    private var energyDays: [CompanionEnergyDay] {
        history.energyDays.filter { $0.dayStart >= cutoff }
    }

    private var energyBuckets: [EnergyBucket] {
        history.energyBuckets.filter { $0.bucketStart >= cutoff }
    }

    private var agentDays: [CompanionAgentDay] {
        history.agentDays.filter { $0.dayStart >= cutoff }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(CompanionHistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }

            if !history.historyEnabled {
                Label("History saving is off on this Mac.", systemImage: "chart.xyaxis.line")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Energy · kWh")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if range == .day ? energyBuckets.isEmpty : energyDays.isEmpty {
                    Text("Energy history is building.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if range == .day {
                    Chart(energyBuckets) { bucket in
                        BarMark(
                            x: .value("Time", bucket.bucketStart, unit: .hour),
                            y: .value("kWh", bucket.kilowattHours ?? 0)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                    }
                    .chartYAxisLabel("kWh")
                    .chartXAxis(.hidden)
                    .frame(height: 130)
                } else {
                    Chart(energyDays) { day in
                        BarMark(
                            x: .value("Day", day.dayStart, unit: .day),
                            y: .value("kWh", day.kilowattHours)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                    }
                    .chartYAxisLabel("kWh")
                    .chartXAxis(.hidden)
                    .frame(height: 130)
                }

                Text("Agent activity · hours")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if agentDays.isEmpty {
                    Text("No agent activity recorded for this range.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Chart(agentDays) { day in
                        BarMark(
                            x: .value("Day", day.dayStart, unit: .day),
                            y: .value("Hours", day.activeSeconds / 3_600)
                        )
                        .foregroundStyle(.orange.gradient)
                    }
                    .chartYAxisLabel("hours")
                    .chartXAxis(.hidden)
                    .frame(height: 130)
                }

                Text("Updated \(history.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }
}

private enum CompanionHistoryRange: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "24h"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .month: 30 * 24 * 60 * 60
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
