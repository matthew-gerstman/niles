import Foundation

/// External links surfaced in the app (submission prep, Nov 2026).
///
/// One place for every App Store metadata URL: Guideline 5.1.1(i) requires an
/// in-app privacy policy link even with no data collected, and 1.5 wants a
/// reachable support contact. The policy page itself is being written by a
/// separate task — when it lands, only this constant changes.
enum AppLinks {
    /// Placeholder policy URL; example.com is reserved for placeholders and
    /// fails loudly (dead row) rather than pointing somewhere wrong.
    static let privacyPolicyURL = URL(string: "https://example.com/niles/privacy-policy")!

    /// Support contact. A mailto so the row works before any support site
    /// exists.
    static let supportEmail = "mattgerstman@gmail.com"
    static var supportEmailURL: URL { URL(string: "mailto:\(supportEmail)")! }
}
