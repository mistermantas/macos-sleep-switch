import Foundation

struct AppLink: Equatable {
    let title: String
    let url: URL
    let symbolName: String
}

enum AppLinks {
    static let uncascadeWebsite = AppLink(
        title: "Uncascade Website",
        url: URL(string: "https://www.uncascade.com/")!,
        symbolName: "globe"
    )
    static let uncascadeYouTube = AppLink(
        title: "Uncascade on YouTube",
        url: URL(string: "https://www.youtube.com/@uncascade")!,
        symbolName: "play.rectangle"
    )
    static let sourceCode = AppLink(
        title: "Sleep Switch on GitHub",
        url: URL(string: "https://github.com/mistermantas/macos-sleep-switch")!,
        symbolName: "chevron.left.forwardslash.chevron.right"
    )
    static let sponsor = AppLink(
        title: "Sponsor on GitHub",
        url: URL(string: "https://github.com/sponsors/mistermantas")!,
        symbolName: "heart"
    )

    static let groups: [[AppLink]] = [
        [uncascadeWebsite, uncascadeYouTube],
        [sourceCode, sponsor]
    ]
}
