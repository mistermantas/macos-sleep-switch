#if !APP_STORE
import Foundation
import Security
import ServiceManagement

protocol PowerHelperConnecting: AnyObject {
    var isReady: Bool { get }
    var setupMessage: String { get }
    func begin() throws -> String
    func renew(_ token: String) throws
    func end(_ token: String) throws
    func disconnect()
}

struct PowerHelperError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol PowerServiceRegistering {
    var status: SMAppService.Status { get }
    func register() throws
}
extension SMAppService: PowerServiceRegistering {}

final class PowerHelperClient: PowerHelperConnecting {
    private let service: PowerServiceRegistering
    private let signatureIsValid: () -> Bool
    private let helperIsBundled: () -> Bool
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    init(service: PowerServiceRegistering = SMAppService.daemon(plistName: PowerHelperConstants.plistName),
         signatureIsValid: @escaping () -> Bool = PowerHelperClient.currentSignatureIsValid,
         helperIsBundled: @escaping () -> Bool = {
             FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(PowerHelperConstants.plistName)").path)
                 && FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/SleepSwitchPowerHelper").path)
         }) {
        self.service = service
        self.signatureIsValid = signatureIsValid
        self.helperIsBundled = helperIsBundled
    }
    var isReady: Bool { service.status == .enabled }
    var needsApproval: Bool { service.status == .requiresApproval }
    var setupMessage: String {
        switch service.status {
        case .enabled: return "Lid-closed helper ready"
        case .requiresApproval: return "Approve Sleep Switch in System Settings → General → Login Items & Extensions."
        case .notRegistered: return "Set up the lid-closed helper once from Awake Mode."
        case .notFound: return helperIsBundled()
            ? "Set up the lid-closed helper once from Awake Mode."
            : "Reinstall the signed direct version of Sleep Switch to use lid-closed mode."
        @unknown default: return "The lid-closed helper is unavailable."
        }
    }

    /// Only an explicit setup action may call this. Session transitions never register.
    func register() throws {
        guard service.status != .enabled, service.status != .requiresApproval else { return }
        guard helperIsBundled(), signatureIsValid() else {
            throw PowerHelperError(message: "Lid-closed setup requires the signed Sleep Switch app and its bundled power helper.")
        }
        // macOS can return notFound before this daemon's first registration.
        do { try service.register() }
        catch { if !needsApproval { throw error } }
    }

    private static func currentSignatureIsValid() -> Bool {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(PowerHelperConstants.applicationRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { return false }
        return true
    }

    func status() throws -> String { try request { $0.status(withReply: $1) }.message }
    func begin() throws -> String {
        let result = try request { $0.beginLease(withReply: $1) }
        guard !result.token.isEmpty else { throw PowerHelperError(message: "The power helper did not return a session.") }
        return result.token
    }
    func renew(_ token: String) throws { _ = try request { $0.renewLease(token, withReply: $1) } }
    func end(_ token: String) throws { _ = try request { $0.endLease(token, withReply: $1) } }

    private final class ReplyBox {
        private let lock = NSLock()
        private var value: PowerHelperReply?
        let semaphore = DispatchSemaphore(value: 0)
        func receive(_ reply: PowerHelperReply) {
            lock.lock()
            defer { lock.unlock() }
            guard value == nil else { return }
            value = reply
            semaphore.signal()
        }
        func result() -> PowerHelperReply { lock.lock(); defer { lock.unlock() }; return value! }
    }

    private func request(_ operation: (PowerHelperProtocol, @escaping (Bool, String, String) -> Void) -> Void) throws -> PowerHelperReply {
        guard isReady else { throw PowerHelperError(message: setupMessage) }
        lock.lock()
        let current: NSXPCConnection
        if let connection { current = connection }
        else {
            current = NSXPCConnection(machServiceName: PowerHelperConstants.identifier, options: .privileged)
            current.remoteObjectInterface = NSXPCInterface(with: PowerHelperProtocol.self)
            current.setCodeSigningRequirement(PowerHelperConstants.helperRequirement)
            connection = current
            current.activate()
        }
        lock.unlock()
        let box = ReplyBox()
        let proxy = current.remoteObjectProxyWithErrorHandler { error in
            box.receive(PowerHelperReply(succeeded: false, message: "Lid-closed helper disconnected: \(error.localizedDescription)"))
        } as? PowerHelperProtocol
        guard let proxy else { throw PowerHelperError(message: "Could not connect to the lid-closed helper.") }
        operation(proxy) { box.receive(PowerHelperReply(succeeded: $0, token: $1, message: $2)) }
        guard box.semaphore.wait(timeout: .now() + 6) == .success else {
            disconnect()
            throw PowerHelperError(message: "The lid-closed helper did not respond. Normal sleep will be restored automatically.")
        }
        let reply = box.result()
        guard reply.succeeded else {
            disconnect()
            throw PowerHelperError(message: reply.message)
        }
        return reply
    }

    func disconnect() {
        lock.lock()
        let old = connection
        connection = nil
        lock.unlock()
        old?.invalidate()
    }
    deinit { disconnect() }
}
#endif
