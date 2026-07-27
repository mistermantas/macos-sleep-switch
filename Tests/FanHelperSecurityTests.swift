import Foundation

enum FanHelperSecurityTests {
    static func run() {
        testCodeSigningPolicy()
        testSecureCodingRoundTrip()
        _ = FanHelperXPCInterface.make()
    }

    private static func testCodeSigningPolicy() {
        let policy = FanClientPolicy(
            expectedSigningIdentifier:
                FanHelperConstants.applicationBundleIdentifier,
            expectedTeamIdentifier: FanHelperConstants.teamIdentifier
        )
        let valid = FanClientIdentity(
            signingIdentifier: "lt.mantas.sleepswitch",
            teamIdentifier: "C43F5MKJF2",
            certificateCommonName:
                "Developer ID Application: Uncascade, MB (C43F5MKJF2)",
            hasHardenedRuntime: true,
            signatureIsValid: true
        )
        expect(policy.accepts(valid), "accepts the exact hardened Sleep Switch identity")
        expect(
            !policy.accepts(
                FanClientIdentity(
                    signingIdentifier: "lt.mantas.sleepswitch",
                    teamIdentifier: "ATTACKER123",
                    certificateCommonName:
                        "Developer ID Application: Attacker (ATTACKER123)",
                    hasHardenedRuntime: true,
                    signatureIsValid: true
                )
            ),
            "rejects the right bundle identifier from the wrong team"
        )
        expect(
            !policy.accepts(
                FanClientIdentity(
                    signingIdentifier: "lt.mantas.sleepswitch",
                    teamIdentifier: "C43F5MKJF2",
                    certificateCommonName:
                        "Developer ID Application: Uncascade, MB (C43F5MKJF2)",
                    hasHardenedRuntime: false,
                    signatureIsValid: true
                )
            ),
            "rejects a client without hardened runtime"
        )
        expect(
            !policy.accepts(
                FanClientIdentity(
                    signingIdentifier: "lt.mantas.sleepswitch",
                    teamIdentifier: "C43F5MKJF2",
                    certificateCommonName:
                        "Developer ID Application: Uncascade, MB (C43F5MKJF2)",
                    hasHardenedRuntime: true,
                    signatureIsValid: false
                )
            ),
            "rejects an invalid signature"
        )
        expect(
            policy.accepts(
                FanClientIdentity(
                    signingIdentifier: "lt.mantas.sleepswitch",
                    teamIdentifier: "C43F5MKJF2",
                    certificateCommonName:
                        "Apple Development: Mantas Vilčinskas (C43F5MKJF2)",
                    hasHardenedRuntime: true,
                    signatureIsValid: true
                )
            ),
            "accepts the exact hardened development identity"
        )
        expect(
            !policy.accepts(
                FanClientIdentity(
                    signingIdentifier: "lt.mantas.sleepswitch",
                    teamIdentifier: "C43F5MKJF2",
                    certificateCommonName:
                        "Apple Distribution: Uncascade, MB (C43F5MKJF2)",
                    hasHardenedRuntime: true,
                    signatureIsValid: true
                )
            ),
            "rejects an unrelated certificate class"
        )

        let requirement =
            FanHelperConstants.applicationCodeSigningRequirement
        expect(
            requirement.contains("anchor apple generic")
                && requirement.contains("identifier \"lt.mantas.sleepswitch\"")
                && requirement.contains(
                    "certificate leaf[subject.OU] = \"C43F5MKJF2\""
                )
                && !requirement.contains(" or "),
            "uses an exact OS-enforced client requirement"
        )
    }

    private static func testSecureCodingRoundTrip() {
        let snapshot = FanHelperSnapshot(
            model: "Mac16,7",
            state: .cooling,
            qualification: .maximumQualified,
            aggregateTemperatureCelsius: 58,
            temperatureRecordedAt: Date(timeIntervalSince1970: 100),
            fans: [
                FanTelemetryMessage(
                    index: 0,
                    actualRPM: 5_900,
                    minimumRPM: 1_500,
                    maximumRPM: 6_000,
                    targetRPM: 6_000,
                    mode: 1
                )
            ],
            verifiedDemand: 1,
            systemControlVerified: false,
            leaseExpiresAt: Date(timeIntervalSince1970: 110),
            detail: nil,
            diagnosticMetadata: "fixture-known=true"
        )
        let response = FanHelperResponse(
            succeeded: true,
            errorCode: .none,
            leaseToken: UUID(),
            snapshot: snapshot,
            message: nil
        )

        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: response,
                requiringSecureCoding: true
            )
            let decoded = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: FanHelperResponse.self,
                from: data
            )
            expect(decoded?.succeeded == true, "securely decodes helper responses")
            expect(decoded?.snapshot.model == "Mac16,7", "preserves the model")
            expect(decoded?.snapshot.fans.count == 1, "preserves fan feedback")
            expect(
                decoded?.snapshot.optionalVerifiedDemand == 1,
                "preserves verified normalized demand"
            )
            expect(
                decoded?.snapshot.diagnosticMetadata
                    == "fixture-known=true",
                "preserves fixed read-only diagnostic metadata"
            )
        } catch {
            fatalError("Test failed: secure helper coding returned \(error)")
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("Test failed: \(message)")
        }
    }
}
