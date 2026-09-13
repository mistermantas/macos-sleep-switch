import Foundation
import ServiceManagement

enum PowerHelperTests {
    private final class Backend: SystemSleepControlling {
        var disabled = false
        var writes: [Bool] = []
        var failRestore = false
        var failEnable = false
        var beforeEnable: (() -> Void)?
        func sleepDisabled() throws -> Bool { disabled }
        func setSleepDisabled(_ disabled: Bool) throws {
            if disabled { beforeEnable?() }
            if (disabled && failEnable) || (!disabled && failRestore) { throw PowerBackendError.command }
            writes.append(disabled)
            self.disabled = disabled
        }
    }
    private final class Journal: PowerRecoveryJournaling {
        var pending = false
        var failWrite = false
        func needsRecovery() throws -> Bool { pending }
        func markPending() throws { if failWrite { throw PowerBackendError.journal }; pending = true }
        func clear() throws { pending = false }
    }
    private final class Client: PowerHelperConnecting {
        var isReady = true
        var setupMessage: String { "Approve the lid-closed helper once in System Settings." }
        let manager: PowerLeaseManager
        let connection = UUID()
        var begins = 0
        var beginGate: DispatchSemaphore?
        var endGate: DispatchSemaphore?
        init(_ manager: PowerLeaseManager) { self.manager = manager }
        func begin() throws -> String {
            begins += 1
            if let beginGate { _ = beginGate.wait(timeout: .now() + 2) }
            let reply = manager.begin(connection: connection)
            guard reply.succeeded else { throw PowerHelperError(message: reply.message) }
            return reply.token
        }
        func renew(_ token: String) throws {
            let result = manager.renew(connection: connection, token: token)
            if !result.succeeded { throw PowerHelperError(message: result.message) }
        }
        func end(_ token: String) throws {
            if let endGate { _ = endGate.wait(timeout: .now() + 2) }
            let result = manager.end(connection: connection, token: token)
            if !result.succeeded { throw PowerHelperError(message: result.message) }
        }
        func disconnect() { manager.connectionEnded(connection) }
    }

    static func run() {
        testRegistration()
        testLeaseLifecycle()
        testRecovery()
        testControllerSessions()
        testSigningPolicy()
        expect(SystemSleepBackend.parseSleepDisabled("System-wide power settings:\n SleepDisabled 1\n") == true, "parses enabled sleep override")
        expect(SystemSleepBackend.parseSleepDisabled(" SleepDisabled 0\n") == false, "parses disabled sleep override")
        expect(SystemSleepBackend.parseSleepDisabled("SleepDisabledGarbage 1") == nil, "rejects malformed state")
        _ = NSXPCInterface(with: PowerHelperProtocol.self)
        print("Power helper tests passed: repeated sessions, setup, expiry, disconnect, crash recovery and signing")
    }

    private static func testRegistration() {
        final class Service: PowerServiceRegistering {
            var status: SMAppService.Status = .notFound
            var registrations = 0
            func register() throws { registrations += 1; status = .enabled }
        }
        let service = Service()
        let client = PowerHelperClient(service: service, signatureIsValid: { true }, helperIsBundled: { true })
        expect(client.setupMessage.contains("Set up"), "notFound with a bundled helper offers setup")
        try! client.register()
        try! client.register()
        expect(service.registrations == 1 && client.isReady, "first registration accepts notFound and is not repeated")
        service.status = .requiresApproval
        try! client.register()
        expect(service.registrations == 1, "pending approval never triggers another registration")
        service.status = .notRegistered
        let unsigned = PowerHelperClient(service: service, signatureIsValid: { false }, helperIsBundled: { true })
        do { try unsigned.register(); fatalError("Unsigned registration accepted") } catch {}
        expect(service.registrations == 1, "unsigned app cannot register helper")
    }

    private static func testLeaseLifecycle() {
        let backend = Backend(), journal = Journal()
        var time: TimeInterval = 0
        let manager = PowerLeaseManager(backend: backend, journal: journal, now: { time })
        expect(manager.recoverOnStartup().succeeded, "starts without changing normal sleep")
        backend.beforeEnable = { expect(journal.pending, "recovery record exists before changing power") }
        let owner = UUID(), other = UUID()
        for _ in 0..<2 {
            let start = manager.begin(connection: owner)
            expect(start.succeeded && backend.disabled, "starts session")
            expect(manager.begin(connection: owner).token == start.token, "repeated start is idempotent")
            expect(!manager.begin(connection: other).succeeded, "rejects competing connection")
            expect(!manager.end(connection: other, token: start.token).succeeded, "rejects stolen token on another connection")
            expect(!manager.renew(connection: owner, token: "wrong").succeeded, "rejects wrong token")
            expect(manager.end(connection: owner, token: start.token).succeeded, "ends session")
            expect(!backend.disabled && !journal.pending, "verifies restoration and clears journal")
        }
        expect(backend.writes == [true, false, true, false], "two sessions use fixed backend operations without administrator scripts")
        let token = manager.begin(connection: owner).token
        time = 10
        expect(manager.renew(connection: owner, token: token).succeeded, "renews live session")
        time = 20
        manager.tick()
        expect(backend.disabled, "renewal extends expiry")
        time = 23
        manager.tick()
        expect(!backend.disabled, "expiry restores normal sleep")
        expect(!manager.renew(connection: owner, token: token).succeeded, "expired lease cannot resurrect")
        _ = manager.begin(connection: owner)
        manager.connectionEnded(other)
        expect(backend.disabled, "unrelated disconnect cannot end owner's session")
        manager.connectionEnded(owner)
        expect(!backend.disabled, "owner crash/disconnect restores sleep")
        _ = manager.begin(connection: owner)
        manager.restoreForSleepOrExit()
        expect(!backend.disabled, "system sleep and shutdown restore sleep")
        backend.disabled = true
        let external = manager.begin(connection: owner)
        _ = manager.end(connection: owner, token: external.token)
        expect(backend.disabled && !journal.pending, "preserves an externally owned override")
    }

    private static func testRecovery() {
        let backend = Backend(), journal = Journal()
        journal.pending = true
        backend.disabled = true
        backend.failRestore = true
        let manager = PowerLeaseManager(backend: backend, journal: journal)
        expect(!manager.recoverOnStartup().succeeded && journal.pending, "retains record after failed startup restoration")
        expect(!manager.begin(connection: UUID()).succeeded, "blocks new lease while restoration fails")
        backend.failRestore = false
        manager.tick()
        expect(!backend.disabled && !journal.pending, "watchdog retries failed restoration")
        journal.failWrite = true
        let previousWrites = backend.writes
        expect(!manager.begin(connection: UUID()).succeeded, "refuses power change without recovery journal")
        expect(backend.writes == previousWrites, "failed journal cannot change sleep state")
        journal.failWrite = false
        backend.failEnable = true
        expect(!manager.begin(connection: UUID()).succeeded && !journal.pending && !backend.disabled, "failed enable rolls back")
        backend.failEnable = false
        let owner = UUID()
        let token = manager.begin(connection: owner).token
        backend.failRestore = true
        expect(!manager.end(connection: owner, token: token).succeeded && journal.pending, "failed end retains recovery intent")
        backend.failRestore = false
        let restarted = PowerLeaseManager(backend: backend, journal: journal)
        expect(restarted.recoverOnStartup().succeeded && !backend.disabled, "daemon restart restores unfinished session")
    }

    private static func testControllerSessions() {
        let backend = Backend(), journal = Journal()
        let manager = PowerLeaseManager(backend: backend, journal: journal)
        _ = manager.recoverOnStartup()
        let client = Client(manager)
        let app = LidClosedSleepController(client: client)
        client.isReady = false
        for _ in 0..<30 { try! app.start() }
        expect(client.begins == 0 && app.setupMessage != nil, "automatic scans never register or prompt when setup is missing")
        client.isReady = true
        for _ in 0..<2 {
            try! app.start()
            spin { app.isActive }
            try! app.stop()
            expect(!app.isActive && !backend.disabled, "app completes start and stop through helper")
        }
        expect(client.begins == 2, "repeated sessions reuse installed helper")
        client.beginGate = DispatchSemaphore(value: 0)
        try! app.start()
        let started = Date()
        try! app.stop(waitForRestoration: false)
        expect(Date().timeIntervalSince(started) < 0.25, "stop does not block menu during pending start")
        client.beginGate?.signal()
        spin { !app.isRestoring }
        expect(!app.isActive && !backend.disabled, "late start reply is released instead of resurrecting session")
        client.beginGate = nil
        try! app.start()
        spin { app.isActive }
        client.endGate = DispatchSemaphore(value: 0)
        try! app.stop(waitForRestoration: false)
        expect(app.isRestoring, "shows restoration while helper works")
        client.endGate?.signal()
        spin { !app.isRestoring }
        client.endGate = nil
        try! app.start()
        spin { app.isActive }
        backend.failRestore = true
        do { try app.stop(); fatalError("Expected restore error") } catch {}
        expect(app.issue != nil && journal.pending, "retains restoration failure without automatically prompting")
        backend.failRestore = false
        manager.tick()
    }

    private static func testSigningPolicy() {
        let policy = PowerClientPolicy(expectedSigningIdentifier: "lt.mantas.sleepswitch", expectedTeamIdentifier: "C43F5MKJF2")
        func identity(id: String = "lt.mantas.sleepswitch", team: String = "C43F5MKJF2", runtime: Bool = true, valid: Bool = true) -> PowerClientIdentity {
            PowerClientIdentity(signingIdentifier: id, teamIdentifier: team,
                certificateCommonName: "Apple Development: Test", hasHardenedRuntime: runtime, signatureIsValid: valid)
        }
        expect(policy.accepts(identity()), "accepts signed hardened app")
        expect(!policy.accepts(identity(id: "other")), "rejects other app")
        expect(!policy.accepts(identity(team: "other")), "rejects other team")
        expect(!policy.accepts(identity(runtime: false)), "requires hardened runtime")
        expect(!policy.accepts(identity(valid: false)), "requires valid signature")
    }

    private static func spin(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        expect(condition(), "asynchronous controller transition completes")
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("Power helper test failed: \(message)") }
    }
}
