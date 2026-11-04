import Foundation

/// Never touches real credentials or Slack. Used only in the isolated local demo.
public actor DemoSlackAPI: SlackAPI {
    public static let demoIdentity = SlackIdentity(teamID: "TDEMO", teamName: "Sprintwake Demo", userID: "UDEMO", userName: "demo")
    private var data: [String: [SlackMessage]] = [
        "CPROJECT": [SlackMessage(id: "1793781000.000001", userID: "UMAREN", displayName: "Maren", text: "Welcome! This is a local Slack demo. Messages stay on this Mac."),
                     SlackMessage(id: "1793781060.000001", userID: "UDEMO", text: "We can keep the project board and conversation together.")],
        "CGENERAL": [SlackMessage(id: "1793781120.000001", userID: "UMAREN", text: "A separate channel for general discussion.")],
        "CPLANNING": []
    ]
    public init() {}
    public func identity() async throws -> SlackIdentity { Self.demoIdentity }
    public func channels(includePrivate: Bool) async throws -> [SlackChannel] {
        [SlackChannel(id: "CPROJECT", name: "project"), SlackChannel(id: "CGENERAL", name: "general")]
        + (includePrivate ? [SlackChannel(id: "CPLANNING", name: "planning", isPrivate: true)] : [])
    }
    public func history(channelID: String, cursor: String?) async throws -> SlackHistoryPage {
        guard let messages = data[channelID] else { throw SlackError.invalidChannel }
        return SlackHistoryPage(messages: messages)
    }
    public func postMessage(channelID: String, text: String) async throws -> SlackMessage {
        guard data[channelID] != nil else { throw SlackError.invalidChannel }
        let message = SlackMessage(id: String(format: "%.6f", Date().timeIntervalSince1970), userID: "UDEMO", text: text)
        data[channelID]?.append(message)
        return message
    }
    public func userName(id: String) async throws -> String { id == "UMAREN" ? "Maren" : "demo" }
}
