import Foundation

enum FanHardwareError: Error, Equatable {
    case unavailable
    case unsupportedHardware
    case unqualifiedHardware
    case externalControllerConflict
    case ownershipLost
    case invalidTelemetry
    case writeFailed
    case verificationFailed
    case restoreFailed
}

protocol FanHardwareControlling: AnyObject {
    var model: String { get }
    var qualification: FanControlQualification { get }

    func externalControllerIsRunning() -> Bool
    func hasRecoveryMarker() -> Bool
    func setRecoveryMarker(active: Bool) throws

    func snapshot(
        state: FanHelperState,
        verifiedDemand: Double?,
        leaseExpiresAt: Date?,
        detail: String?
    ) throws -> FanHelperSnapshot

    func applyCoolingDemand(_ demand: Double) throws
    func restoreSystemControl() throws
}
