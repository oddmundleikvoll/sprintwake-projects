import Foundation

public enum ConversationSource: String, CaseIterable, Sendable { case github, slack }

public struct SlackIdentity: Codable, Sendable, Equatable {
    public let teamID: String
    public let teamName: String
    public let userID: String
    public let userName: String
    public init(teamID: String, teamName: String, userID: String, userName: String) {
        self.teamID = teamID; self.teamName = teamName; self.userID = userID; self.userName = userName
    }
}

public struct SlackChannel: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let isPrivate: Bool
    public let isMember: Bool
    public let isArchived: Bool
    public init(id: String, name: String, isPrivate: Bool = false, isMember: Bool = true, isArchived: Bool = false) {
        self.id = id; self.name = name; self.isPrivate = isPrivate; self.isMember = isMember; self.isArchived = isArchived
    }
}

public struct SlackMessage: Identifiable, Sendable, Equatable {
    public let id: String
    public let userID: String?
    public let displayName: String?
    public let text: String
    public let replyCount: Int
    public let isEdited: Bool
    public var createdAt: Date? { Double(id).map(Date.init(timeIntervalSince1970:)) }
    public init(id: String, userID: String? = nil, displayName: String? = nil, text: String, replyCount: Int = 0, isEdited: Bool = false) {
        self.id = id; self.userID = userID; self.displayName = displayName; self.text = text
        self.replyCount = replyCount; self.isEdited = isEdited
    }
}

public struct SlackHistoryPage: Sendable, Equatable {
    public let messages: [SlackMessage]
    public let nextCursor: String?
    public let hasMore: Bool
    public init(messages: [SlackMessage], nextCursor: String? = nil, hasMore: Bool = false) {
        self.messages = messages; self.nextCursor = nextCursor; self.hasMore = hasMore
    }
}

public protocol SlackAPI: Sendable {
    func identity() async throws -> SlackIdentity
    func channels(includePrivate: Bool) async throws -> [SlackChannel]
    func history(channelID: String, cursor: String?) async throws -> SlackHistoryPage
    func postMessage(channelID: String, text: String) async throws -> SlackMessage
    func userName(id: String) async throws -> String
}

public enum SlackError: Error, LocalizedError, Sendable, Equatable {
    case unauthenticated
    case rateLimited(retryAfter: TimeInterval)
    case permissionDenied
    case invalidChannel
    case deliveryUnconfirmed
    case cancelled
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .unauthenticated: L10n.core("Your Slack connection expired or was revoked. Connect Slack again.")
        case .rateLimited: L10n.core("Slack is limiting requests. Wait before refreshing again.")
        case .permissionDenied: L10n.core("Slack did not grant the required permission. Check channel access and workspace app approval.")
        case .invalidChannel: L10n.core("This Slack channel is unavailable. Choose another channel or check your membership.")
        case .deliveryUnconfirmed: L10n.core("Slack may have received the message, but delivery could not be confirmed. Check the channel before sending it again.")
        case .cancelled: L10n.core("Slack sign-in was cancelled.")
        case .message(let message): message
        }
    }
}

public struct SlackCredential: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let refreshExpiresAt: Date?
    public let clientID: String
    public let teamID: String
    public let teamName: String
    public let userID: String
    public let scopes: Set<String>
    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
                refreshExpiresAt: Date? = nil, clientID: String, teamID: String, teamName: String,
                userID: String, scopes: Set<String>) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.refreshExpiresAt = refreshExpiresAt; self.clientID = clientID; self.teamID = teamID
        self.teamName = teamName; self.userID = userID; self.scopes = scopes
    }
}

public struct SlackAuthorization: Sendable, Equatable {
    public static let redirectURI = "sprintwake-slack://oauth/callback"
    public let url: URL
    public let state: String
    public let codeVerifier: String
    public let clientID: String
    public let redirectURI: String
    public let expiresAt: Date
    public init(url: URL, state: String, codeVerifier: String, clientID: String, redirectURI: String, expiresAt: Date) {
        self.url = url; self.state = state; self.codeVerifier = codeVerifier; self.clientID = clientID
        self.redirectURI = redirectURI; self.expiresAt = expiresAt
    }
}

public protocol SlackOAuthAuthenticating: Sendable {
    func authorization(clientID: String, includePrivateChannels: Bool) throws -> SlackAuthorization
    func exchange(_ authorization: SlackAuthorization, callback: URL) async throws -> SlackCredential
    func refresh(_ credential: SlackCredential) async throws -> SlackCredential
}

public protocol SlackCredentialStorage: Sendable {
    func load() throws -> SlackCredential?
    func save(_ credential: SlackCredential) throws
    func delete() throws
}
