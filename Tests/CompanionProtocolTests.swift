import Foundation

enum CompanionProtocolTests {
    static func run() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let capabilities = CompanionMacCapabilities(
            canSleepMac: true,
            canSleepDisplay: false,
            canLockMac: false,
            canRestartMac: false,
            canShutdownMac: false,
            canSetKeepAwake: false,
            supportsCloudKit: false
        )
        let command = CompanionRemoteCommand(
            id: UUID(),
            targetDeviceID: "mac-1",
            action: .sleepMac,
            parameters: [:],
            requesterDeviceID: "iphone-1",
            nonce: "nonce-1",
            createdAt: now.addingTimeInterval(-10),
            expiresAt: now.addingTimeInterval(60),
            policyVersion: 1
        )

        let accepted = CompanionCommandPolicy.validate(
            command,
            targetDeviceID: "mac-1",
            capabilities: capabilities,
            now: now
        )
        expect(isSuccess(accepted), "accepts an unexpired supported command")

        let wrongDevice = CompanionCommandPolicy.validate(
            command,
            targetDeviceID: "other-mac",
            capabilities: capabilities,
            now: now
        )
        expect(isFailure(wrongDevice, .wrongDevice), "rejects a command for another Mac")

        let replay = CompanionCommandPolicy.validate(
            command,
            targetDeviceID: "mac-1",
            capabilities: capabilities,
            now: now,
            seenNonces: ["nonce-1"]
        )
        expect(isFailure(replay, .replay), "rejects a replayed nonce")

        let expired = CompanionRemoteCommand(
            id: command.id,
            targetDeviceID: command.targetDeviceID,
            action: command.action,
            parameters: command.parameters,
            requesterDeviceID: command.requesterDeviceID,
            nonce: command.nonce,
            createdAt: now.addingTimeInterval(-120),
            expiresAt: now.addingTimeInterval(-1),
            policyVersion: command.policyVersion
        )
        let expiredResult = CompanionCommandPolicy.validate(
            expired,
            targetDeviceID: "mac-1",
            capabilities: capabilities,
            now: now
        )
        expect(isFailure(expiredResult, .expired), "rejects an expired command")

        let unsupported = CompanionRemoteCommand(
            id: UUID(),
            targetDeviceID: "mac-1",
            action: .shutdownMac,
            parameters: [:],
            requesterDeviceID: "iphone-1",
            nonce: "nonce-2",
            createdAt: now,
            expiresAt: now.addingTimeInterval(60),
            policyVersion: 1
        )
        let unsupportedResult = CompanionCommandPolicy.validate(
            unsupported,
            targetDeviceID: "mac-1",
            capabilities: capabilities,
            now: now
        )
        expect(
            isFailure(unsupportedResult, .unsupportedAction),
            "rejects a capability-gated destructive command"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("Test failed: \(message)")
        }
    }

    private static func isSuccess(
        _ result: Result<Void, CompanionCommandValidationError>
    ) -> Bool {
        if case .success = result { return true }
        return false
    }

    private static func isFailure(
        _ result: Result<Void, CompanionCommandValidationError>,
        _ expected: CompanionCommandValidationError
    ) -> Bool {
        guard case .failure(let error) = result else { return false }
        return error == expected
    }
}
