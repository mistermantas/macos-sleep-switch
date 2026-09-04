import Foundation

/// A user-selected preview source. This intentionally accepts only one HTTP(S)
/// loopback origin; the preview relay must never be a general LAN or internet
/// proxy. Path/query are preserved for the registered preview landing page.
struct LocalPreviewEndpoint: Equatable {
    enum ValidationError: LocalizedError, Equatable {
        case missingURL, unsupportedScheme, missingPort, nonLoopbackHost, credentialsNotAllowed

        var errorDescription: String? {
            switch self {
            case .missingURL: "Enter a local preview URL."
            case .unsupportedScheme: "A preview must use http or https."
            case .missingPort: "A preview URL must include its local port."
            case .nonLoopbackHost: "Previews can only connect to this Mac’s loopback address."
            case .credentialsNotAllowed: "Preview URLs cannot include credentials."
            }
        }
    }

    let url: URL

    static func register(_ rawURL: String) throws -> LocalPreviewEndpoint {
        guard let components = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let url = components.url else { throw ValidationError.missingURL }
        guard ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            throw ValidationError.unsupportedScheme
        }
        guard components.port != nil else { throw ValidationError.missingPort }
        guard components.user == nil, components.password == nil else {
            throw ValidationError.credentialsNotAllowed
        }
        let host = components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard host == "localhost" || host == "127.0.0.1" || host == "::1" else {
            throw ValidationError.nonLoopbackHost
        }
        return LocalPreviewEndpoint(url: url)
    }
}
