import Foundation

enum LocalPreviewEndpointTests {
    static func run() {
        do {
            let endpoint = try LocalPreviewEndpoint.register("http://localhost:3000/dashboard?demo=1")
            expect(endpoint.url.host == "localhost", "keeps an explicit loopback preview URL")
        } catch { expect(false, "accepts a loopback preview URL") }
        for rawURL in ["http://192.168.1.9:3000", "https://example.com:443", "http://localhost"] {
            do {
                _ = try LocalPreviewEndpoint.register(rawURL)
                expect(false, "rejects non-local or unbounded preview source")
            } catch { expect(true, "rejects non-local or unbounded preview source") }
        }
    }
}
