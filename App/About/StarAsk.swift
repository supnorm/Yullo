import Foundation

// About's one quiet "Star on GitHub" link.
enum StarAsk {
    // When true, About shows the link to the repository. On only once the
    // repository is public, together with the site's link.
    static let repositoryIsPublic = true
    // Keep this the only copy of the address.
    static let repository = URL(string: "https://github.com/supnorm/Yullo")!
}
