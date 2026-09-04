import Foundation

enum RemoteWorkAttentionTests {
    static func run() {
        expect(CompanionWorkAttentionPolicy.kind(for: .rateLimited) == .required, "rate limits need attention")
        expect(CompanionWorkAttentionPolicy.kind(for: .failed) == .required, "failures need attention")
        expect(CompanionWorkAttentionPolicy.kind(for: .finished) == .useful, "finished work is useful attention")
        expect(CompanionWorkAttentionPolicy.kind(for: .reviewReady) == .useful, "review-ready work is useful attention")
        expect(CompanionWorkAttentionPolicy.kind(for: .waiting) == nil, "waiting work does not interrupt")
        expect(CompanionWorkAttentionPolicy.kind(for: .unknown) == nil, "unknown work does not interrupt")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Test failed: \(message)") }
    }
}
