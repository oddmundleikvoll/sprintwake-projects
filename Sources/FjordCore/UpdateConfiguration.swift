import Foundation

public struct UpdateConfiguration: Sendable, Equatable {
    public enum Mode: Sendable, Equatable { case localBuild, demo, ready, invalid }
    public let mode: Mode
    public let version: String
    public let build: String
    public let feedURL: URL?
    public let publicKey: String?

    /// Only distribution bundles enable updates. Tests may use an isolated app
    /// with a loopback feed; the installed app can never opt into that exception.
    public init(info: [String: Any], isDemo: Bool) {
        version = info["CFBundleShortVersionString"] as? String ?? "—"
        build = info["CFBundleVersion"] as? String ?? "—"
        let identifier = info["CFBundleIdentifier"] as? String ?? ""
        let testing = info["SprintwakeUpdateTesting"] as? Bool == true
            && identifier.hasPrefix("no.oddmund.Sprintwake.UpdateTest.")
        if isDemo && !testing {
            mode = .demo; feedURL = nil; publicKey = nil; return
        }
        guard info["SprintwakeUpdatesEnabled"] as? Bool == true else {
            mode = .localBuild; feedURL = nil; publicKey = nil; return
        }
        guard let rawURL = info["SUFeedURL"] as? String,
              let url = URL(string: rawURL), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.query == nil,
              parts.scheme == "https" || (testing && parts.scheme == "http" && ["127.0.0.1", "localhost", "[::1]"].contains(host)),
              let key = info["SUPublicEDKey"] as? String, let bytes = Data(base64Encoded: key), bytes.count == 32 else {
            mode = .invalid; feedURL = nil; publicKey = nil; return
        }
        mode = .ready; feedURL = url; publicKey = key
    }
}

/// Sparkle requests this only after installation is approved. In-flight writes
/// and authorization finish before the app is allowed to restart.
@MainActor public final class UpdateRelaunchGate {
    public private(set) var isBusy = false
    private var resume: (() -> Void)?
    public init() {}
    public func cancel() { resume = nil }
    public func postpone(_ install: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        resume = install
        return true
    }
    public func setBusy(_ value: Bool) {
        isBusy = value
        guard !value, let callback = resume else { return }
        resume = nil
        callback()
    }
}
