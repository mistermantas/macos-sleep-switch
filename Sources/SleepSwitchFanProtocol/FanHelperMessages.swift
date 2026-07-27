import Foundation

enum FanHelperConstants {
    static let applicationBundleIdentifier = "lt.mantas.sleepswitch"
    static let helperSigningIdentifier = "lt.mantas.sleepswitch.fanhelper"
    static let machServiceName = "lt.mantas.sleepswitch.fanhelper"
    static let daemonPlistName = "lt.mantas.sleepswitch.fanhelper.plist"
    static let teamIdentifier = "C43F5MKJF2"
    static let leaseDuration: TimeInterval = 10
    static let heartbeatInterval: TimeInterval = 3

    static let applicationCodeSigningRequirement =
        codeSigningRequirement(
            identifier: applicationBundleIdentifier,
            teamIdentifier: teamIdentifier
        )
    static let helperCodeSigningRequirement =
        codeSigningRequirement(
            identifier: helperSigningIdentifier,
            teamIdentifier: teamIdentifier
        )

    private static func codeSigningRequirement(
        identifier: String,
        teamIdentifier: String
    ) -> String {
        "anchor apple generic"
            + " and identifier \"\(identifier)\""
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

enum FanHelperSigningPolicy {
    static func acceptsCertificateCommonName(
        _ certificateCommonName: String
    ) -> Bool {
        certificateCommonName.hasPrefix("Apple Development:")
            || certificateCommonName.hasPrefix(
                "Developer ID Application:"
            )
    }
}

enum FanHelperRequestedProfile: Int {
    case systemControl
    case aggressive
    case maximum
}

enum FanControlQualification: Int {
    case monitoringOnly
    case maximumQualified
    case adaptiveQualified

    var permitsMaximumControl: Bool {
        self == .maximumQualified || self == .adaptiveQualified
    }

    var permitsAggressiveControl: Bool {
        self == .adaptiveQualified
    }
}

enum FanHelperState: Int {
    case systemControl
    case cooling
    case monitoringOnly
    case unsupported
    case externalControllerConflict
    case unavailable
    case restoreFailed
}

enum FanHelperErrorCode: Int {
    case none
    case invalidRequest
    case unavailable
    case unsupportedHardware
    case unqualifiedHardware
    case externalControllerConflict
    case leaseOwnedByAnotherConnection
    case invalidLease
    case telemetryFailed
    case applyFailed
    case restoreFailed
}

@objc(FanTelemetryMessage)
final class FanTelemetryMessage: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let index: Int
    let actualRPM: Double
    let minimumRPM: Double
    let maximumRPM: Double
    let targetRPM: Double
    let mode: Int

    init(
        index: Int,
        actualRPM: Double,
        minimumRPM: Double?,
        maximumRPM: Double?,
        targetRPM: Double?,
        mode: Int?
    ) {
        self.index = index
        self.actualRPM = actualRPM
        self.minimumRPM = minimumRPM ?? -1
        self.maximumRPM = maximumRPM ?? -1
        self.targetRPM = targetRPM ?? -1
        self.mode = mode ?? -1
    }

    required init?(coder: NSCoder) {
        index = coder.decodeInteger(forKey: "index")
        actualRPM = coder.decodeDouble(forKey: "actualRPM")
        minimumRPM = coder.decodeDouble(forKey: "minimumRPM")
        maximumRPM = coder.decodeDouble(forKey: "maximumRPM")
        targetRPM = coder.decodeDouble(forKey: "targetRPM")
        mode = coder.decodeInteger(forKey: "mode")
    }

    func encode(with coder: NSCoder) {
        coder.encode(index, forKey: "index")
        coder.encode(actualRPM, forKey: "actualRPM")
        coder.encode(minimumRPM, forKey: "minimumRPM")
        coder.encode(maximumRPM, forKey: "maximumRPM")
        coder.encode(targetRPM, forKey: "targetRPM")
        coder.encode(mode, forKey: "mode")
    }

    var optionalMinimumRPM: Double? {
        minimumRPM >= 0 ? minimumRPM : nil
    }

    var optionalMaximumRPM: Double? {
        maximumRPM >= 0 ? maximumRPM : nil
    }

    var optionalTargetRPM: Double? {
        targetRPM >= 0 ? targetRPM : nil
    }

    var optionalMode: Int? {
        mode >= 0 ? mode : nil
    }
}

@objc(FanHelperSnapshot)
final class FanHelperSnapshot: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let model: String
    let stateRawValue: Int
    let qualificationRawValue: Int
    let aggregateTemperatureCelsius: Double
    let temperatureRecordedAt: Date?
    let fans: [FanTelemetryMessage]
    let verifiedDemand: Double
    let systemControlVerified: Bool
    let leaseExpiresAt: Date?
    let detail: String?
    let diagnosticMetadata: String?

    init(
        model: String,
        state: FanHelperState,
        qualification: FanControlQualification,
        aggregateTemperatureCelsius: Double?,
        temperatureRecordedAt: Date?,
        fans: [FanTelemetryMessage],
        verifiedDemand: Double?,
        systemControlVerified: Bool,
        leaseExpiresAt: Date?,
        detail: String?,
        diagnosticMetadata: String? = nil
    ) {
        self.model = model
        stateRawValue = state.rawValue
        qualificationRawValue = qualification.rawValue
        self.aggregateTemperatureCelsius =
            aggregateTemperatureCelsius ?? -1
        self.temperatureRecordedAt = temperatureRecordedAt
        self.fans = fans
        self.verifiedDemand = verifiedDemand ?? -1
        self.systemControlVerified = systemControlVerified
        self.leaseExpiresAt = leaseExpiresAt
        self.detail = detail
        self.diagnosticMetadata = diagnosticMetadata
    }

    required init?(coder: NSCoder) {
        guard let model = coder.decodeObject(
            of: NSString.self,
            forKey: "model"
        ) as String? else {
            return nil
        }
        self.model = model
        stateRawValue = coder.decodeInteger(forKey: "stateRawValue")
        qualificationRawValue = coder.decodeInteger(
            forKey: "qualificationRawValue"
        )
        aggregateTemperatureCelsius = coder.decodeDouble(
            forKey: "aggregateTemperatureCelsius"
        )
        temperatureRecordedAt = coder.decodeObject(
            of: NSDate.self,
            forKey: "temperatureRecordedAt"
        ) as Date?
        fans = coder.decodeObject(
            of: [NSArray.self, FanTelemetryMessage.self],
            forKey: "fans"
        ) as? [FanTelemetryMessage] ?? []
        verifiedDemand = coder.decodeDouble(forKey: "verifiedDemand")
        systemControlVerified = coder.decodeBool(
            forKey: "systemControlVerified"
        )
        leaseExpiresAt = coder.decodeObject(
            of: NSDate.self,
            forKey: "leaseExpiresAt"
        ) as Date?
        detail = coder.decodeObject(
            of: NSString.self,
            forKey: "detail"
        ) as String?
        diagnosticMetadata = coder.decodeObject(
            of: NSString.self,
            forKey: "diagnosticMetadata"
        ) as String?
    }

    func encode(with coder: NSCoder) {
        coder.encode(model, forKey: "model")
        coder.encode(stateRawValue, forKey: "stateRawValue")
        coder.encode(qualificationRawValue, forKey: "qualificationRawValue")
        coder.encode(
            aggregateTemperatureCelsius,
            forKey: "aggregateTemperatureCelsius"
        )
        coder.encode(temperatureRecordedAt, forKey: "temperatureRecordedAt")
        coder.encode(fans, forKey: "fans")
        coder.encode(verifiedDemand, forKey: "verifiedDemand")
        coder.encode(
            systemControlVerified,
            forKey: "systemControlVerified"
        )
        coder.encode(leaseExpiresAt, forKey: "leaseExpiresAt")
        coder.encode(detail, forKey: "detail")
        coder.encode(
            diagnosticMetadata,
            forKey: "diagnosticMetadata"
        )
    }

    var state: FanHelperState {
        FanHelperState(rawValue: stateRawValue) ?? .unavailable
    }

    var qualification: FanControlQualification {
        FanControlQualification(rawValue: qualificationRawValue)
            ?? .monitoringOnly
    }

    var optionalAggregateTemperatureCelsius: Double? {
        aggregateTemperatureCelsius >= 0
            ? aggregateTemperatureCelsius
            : nil
    }

    var optionalVerifiedDemand: Double? {
        verifiedDemand >= 0 ? verifiedDemand : nil
    }
}

@objc(FanHelperResponse)
final class FanHelperResponse: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let succeeded: Bool
    let errorCodeRawValue: Int
    let leaseToken: UUID?
    let snapshot: FanHelperSnapshot
    let message: String?

    init(
        succeeded: Bool,
        errorCode: FanHelperErrorCode,
        leaseToken: UUID?,
        snapshot: FanHelperSnapshot,
        message: String?
    ) {
        self.succeeded = succeeded
        errorCodeRawValue = errorCode.rawValue
        self.leaseToken = leaseToken
        self.snapshot = snapshot
        self.message = message
    }

    required init?(coder: NSCoder) {
        succeeded = coder.decodeBool(forKey: "succeeded")
        errorCodeRawValue = coder.decodeInteger(
            forKey: "errorCodeRawValue"
        )
        leaseToken = coder.decodeObject(
            of: NSUUID.self,
            forKey: "leaseToken"
        ) as UUID?
        guard let snapshot = coder.decodeObject(
            of: FanHelperSnapshot.self,
            forKey: "snapshot"
        ) else {
            return nil
        }
        self.snapshot = snapshot
        message = coder.decodeObject(
            of: NSString.self,
            forKey: "message"
        ) as String?
    }

    func encode(with coder: NSCoder) {
        coder.encode(succeeded, forKey: "succeeded")
        coder.encode(errorCodeRawValue, forKey: "errorCodeRawValue")
        coder.encode(leaseToken, forKey: "leaseToken")
        coder.encode(snapshot, forKey: "snapshot")
        coder.encode(message, forKey: "message")
    }

    var errorCode: FanHelperErrorCode {
        FanHelperErrorCode(rawValue: errorCodeRawValue) ?? .unavailable
    }
}

@objc protocol FanHelperProtocol {
    func status(withReply reply: @escaping (FanHelperResponse) -> Void)

    func beginLease(
        profileRawValue: Int,
        withReply reply: @escaping (FanHelperResponse) -> Void
    )

    func renewLease(
        _ leaseToken: UUID,
        coolingDemand: Double,
        withReply reply: @escaping (FanHelperResponse) -> Void
    )

    func endLease(
        _ leaseToken: UUID,
        withReply reply: @escaping (FanHelperResponse) -> Void
    )

    func restoreSystemControl(
        withReply reply: @escaping (FanHelperResponse) -> Void
    )
}

enum FanHelperXPCInterface {
    static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: FanHelperProtocol.self)
        let responseClasses = NSSet(array: [
            FanHelperResponse.self,
            FanHelperSnapshot.self,
            FanTelemetryMessage.self,
            NSArray.self,
            NSString.self,
            NSNumber.self,
            NSDate.self,
            NSUUID.self
        ]) as! Set<AnyHashable>

        for selector in responseSelectors {
            interface.setClasses(
                responseClasses,
                for: selector,
                argumentIndex: 0,
                ofReply: true
            )
        }
        return interface
    }

    private static let responseSelectors: [Selector] = [
        #selector(FanHelperProtocol.status(withReply:)),
        #selector(FanHelperProtocol.beginLease(profileRawValue:withReply:)),
        #selector(
            FanHelperProtocol.renewLease(
                _:coolingDemand:withReply:
            )
        ),
        #selector(FanHelperProtocol.endLease(_:withReply:)),
        #selector(FanHelperProtocol.restoreSystemControl(withReply:))
    ]
}
