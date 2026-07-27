#if !APP_STORE
import AppKit
import Foundation
import Security
import ServiceManagement

enum FanHelperRegistrationState: Equatable {
    case requiresSignedBuild
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

protocol FanHelperClienting: AnyObject {
    var registrationState: FanHelperRegistrationState { get }

    func status(_ completion: @escaping (FanHelperResponse) -> Void)
    func beginLease(
        profile: FanHelperRequestedProfile,
        completion: @escaping (FanHelperResponse) -> Void
    )
    func renewLease(
        token: UUID,
        demand: Double,
        completion: @escaping (FanHelperResponse) -> Void
    )
    func endLease(
        token: UUID,
        completion: @escaping (FanHelperResponse) -> Void
    )
    func restoreSystemControl(
        _ completion: @escaping (FanHelperResponse) -> Void
    )
}

final class FanHelperClient: FanHelperClienting {
    private let service = SMAppService.daemon(
        plistName: FanHelperConstants.daemonPlistName
    )
    private var connection: NSXPCConnection?

    var registrationState: FanHelperRegistrationState {
        guard Self.currentApplicationCanUseHelper else {
            return .requiresSignedBuild
        }
        switch service.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() throws {
        guard Self.currentApplicationCanUseHelper else {
            throw FanHelperClientError.requiresSignedBuild
        }
        guard service.status != .enabled else { return }
        do {
            try service.register()
        } catch {
            if service.status != .requiresApproval {
                throw error
            }
        }
    }

    func unregister(
        completion: @escaping (Error?) -> Void
    ) {
        restoreSystemControl { [weak self] response in
            guard response.succeeded else {
                completion(FanHelperClientError.restoreRequired)
                return
            }
            do {
                try self?.service.unregister()
                self?.invalidateConnection()
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func status(_ completion: @escaping (FanHelperResponse) -> Void) {
        withProxy(completion: completion) { proxy, reply in
            proxy.status(withReply: reply)
        }
    }

    func beginLease(
        profile: FanHelperRequestedProfile,
        completion: @escaping (FanHelperResponse) -> Void
    ) {
        withProxy(completion: completion) { proxy, reply in
            proxy.beginLease(
                profileRawValue: profile.rawValue,
                withReply: reply
            )
        }
    }

    func renewLease(
        token: UUID,
        demand: Double,
        completion: @escaping (FanHelperResponse) -> Void
    ) {
        withProxy(completion: completion) { proxy, reply in
            proxy.renewLease(
                token,
                coolingDemand: demand,
                withReply: reply
            )
        }
    }

    func endLease(
        token: UUID,
        completion: @escaping (FanHelperResponse) -> Void
    ) {
        withProxy(completion: completion) { proxy, reply in
            proxy.endLease(token, withReply: reply)
        }
    }

    func restoreSystemControl(
        _ completion: @escaping (FanHelperResponse) -> Void
    ) {
        withProxy(completion: completion) { proxy, reply in
            proxy.restoreSystemControl(withReply: reply)
        }
    }

    private func withProxy(
        completion: @escaping (FanHelperResponse) -> Void,
        operation: @escaping (
            FanHelperProtocol,
            @escaping (FanHelperResponse) -> Void
        ) -> Void
    ) {
        guard registrationState == .enabled else {
            completion(unavailableResponse())
            return
        }

        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({
            [weak self] _ in
            self?.invalidateConnection()
            DispatchQueue.main.async {
                completion(self?.unavailableResponse() ?? Self.fallbackResponse())
            }
        }) as? FanHelperProtocol else {
            completion(unavailableResponse())
            return
        }

        operation(proxy) { response in
            DispatchQueue.main.async {
                completion(response)
            }
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: FanHelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = FanHelperXPCInterface.make()
        connection.setCodeSigningRequirement(
            FanHelperConstants.helperCodeSigningRequirement
        )
        connection.interruptionHandler = { [weak self] in
            self?.invalidateConnection()
        }
        connection.invalidationHandler = { [weak self] in
            self?.invalidateConnection()
        }
        self.connection = connection
        connection.activate()
        return connection
    }

    private func invalidateConnection() {
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
    }

    private func unavailableResponse() -> FanHelperResponse {
        Self.fallbackResponse(model: "Unavailable")
    }

    private static let currentApplicationCanUseHelper: Bool = {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
              let dynamicCode
        else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            dynamicCode,
            [],
            &staticCode
        ) == errSecSuccess,
        let staticCode
        else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            FanHelperConstants.applicationCodeSigningRequirement
                as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement,
        SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        ) == errSecSuccess
        else {
            return false
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [String: Any],
        information[kSecCodeInfoRuntimeVersion as String] != nil,
        let certificates = information[
            kSecCodeInfoCertificates as String
        ] as? [SecCertificate],
        let leafCertificate = certificates.first
        else {
            return false
        }

        var commonName: CFString?
        guard SecCertificateCopyCommonName(
            leafCertificate,
            &commonName
        ) == errSecSuccess,
        let commonName
        else {
            return false
        }
        return FanHelperSigningPolicy.acceptsCertificateCommonName(
            commonName as String
        )
    }()

    private static func fallbackResponse(
        model: String = "Unavailable"
    ) -> FanHelperResponse {
        FanHelperResponse(
            succeeded: false,
            errorCode: .unavailable,
            leaseToken: nil,
            snapshot: FanHelperSnapshot(
                model: model,
                state: .unavailable,
                qualification: .monitoringOnly,
                aggregateTemperatureCelsius: nil,
                temperatureRecordedAt: nil,
                fans: [],
                verifiedDemand: nil,
                systemControlVerified: false,
                leaseExpiresAt: nil,
                detail: "The cooling helper is unavailable."
            ),
            message: "The cooling helper is unavailable."
        )
    }
}

enum FanHelperClientError: Error, LocalizedError {
    case restoreRequired
    case requiresSignedBuild

    var errorDescription: String? {
        switch self {
        case .restoreRequired:
            return "Sleep Switch could not verify macOS fan control before removing the helper."
        case .requiresSignedBuild:
            return "Cooling requires Sleep Switch to be signed with an Apple Development or Developer ID certificate."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .restoreRequired:
            return nil
        case .requiresSignedBuild:
            return "Sign in to your Apple Developer account in Xcode, then rebuild Sleep Switch."
        }
    }
}
#endif
