import Foundation

public struct GitHubUser: Codable, Sendable, Equatable {
    public let login: String
    public let name: String?
    public let nodeID: String?
    enum CodingKeys: String, CodingKey { case login, name; case nodeID = "node_id" }
    public init(login: String, name: String? = nil, nodeID: String? = nil) { self.login = login; self.name = name; self.nodeID = nodeID }
}

public struct ProjectOwner: Identifiable, Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case user, organization }
    public let login: String
    public let kind: Kind
    public var id: String { "\(kind.rawValue):\(login)" }
    public init(login: String, kind: Kind) { self.login = login; self.kind = kind }
}

public struct ProjectReference: Sendable, Equatable {
    public let owner: ProjectOwner
    public let number: Int

    public init(url: String) throws {
        guard let url = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.port == nil else {
            throw FjordError.message(L10n.core("Use a project link on https://github.com/users/…/projects/… or /orgs/…/projects/…."))
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, ["users", "orgs"].contains(parts[0]),
              !parts[1].isEmpty, parts[2] == "projects", let number = Int(parts[3]), number > 0 else {
            throw FjordError.message(L10n.core("The link does not point to a GitHub Projects project."))
        }
        self.owner = ProjectOwner(login: parts[1], kind: parts[0] == "users" ? .user : .organization)
        self.number = number
    }
}

public struct ProjectSummary: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let number: Int
    public let title: String
    public let url: URL
    public let closed: Bool
    public let isPublic: Bool?
    public let viewerCanUpdate: Bool?
    enum CodingKeys: String, CodingKey {
        case id, number, title, url, closed, viewerCanUpdate
        case isPublic = "public"
    }
    public var owner: ProjectOwner? { try? ProjectReference(url: url.absoluteString).owner }
    public init(id: String, number: Int, title: String, url: URL, closed: Bool = false,
                isPublic: Bool? = nil, viewerCanUpdate: Bool? = nil) {
        self.id = id; self.number = number; self.title = title; self.url = url; self.closed = closed
        self.isPublic = isPublic; self.viewerCanUpdate = viewerCanUpdate
    }
}

public struct SelectOption: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let color: String?
    public let description: String?
    public init(id: String, name: String, color: String? = nil, description: String? = nil) {
        self.id = id; self.name = name; self.color = color; self.description = description
    }
}

public struct SelectField: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let options: [SelectOption]
    public init(id: String, name: String, options: [SelectOption]) { self.id = id; self.name = name; self.options = options }
}

public struct ProjectItem: Identifiable, Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case draft, issue, pullRequest, redacted }
    public let id: String
    public let contentID: String?
    public let kind: Kind
    public var title: String
    public var body: String
    public let url: URL?
    public let repository: String?
    public let number: Int?
    public let canEditContent: Bool
    public let authorLogin: String?
    public let createdAt: Date?
    public var assigneeLogins: [String]
    public var assignees: [AssignableUser]
    public var selections: [String: String]
    public init(id: String, contentID: String?, kind: Kind, title: String, body: String = "", url: URL? = nil,
                repository: String? = nil, number: Int? = nil, canEditContent: Bool = true, selections: [String: String] = [:],
                authorLogin: String? = nil, createdAt: Date? = nil, assigneeLogins: [String] = [], assignees: [AssignableUser] = []) {
        self.id = id; self.contentID = contentID; self.kind = kind; self.title = title; self.body = body
        self.url = url; self.repository = repository; self.number = number
        self.canEditContent = canEditContent; self.selections = selections
        self.authorLogin = authorLogin; self.createdAt = createdAt; self.assigneeLogins = assigneeLogins
        self.assignees = assignees
    }
    public var kindLabel: String {
        switch kind { case .draft: L10n.core("Draft"); case .issue: L10n.core("Issue"); case .pullRequest: L10n.core("Pull request"); case .redacted: L10n.core("Restricted access") }
    }
}

public enum ChatSendResult: Sendable, Equatable {
    case sent(ProjectItem)
    case placementUnconfirmed(ProjectItem, String)

    public var item: ProjectItem {
        switch self { case .sent(let item), .placementUnconfirmed(let item, _): item }
    }
}

public struct ProjectSnapshot: Sendable, Equatable {
    public let project: ProjectSummary
    public let canUpdate: Bool
    public let fields: [SelectField]
    public var items: [ProjectItem]
    public init(project: ProjectSummary, canUpdate: Bool, fields: [SelectField], items: [ProjectItem]) {
        self.project = project; self.canUpdate = canUpdate; self.fields = fields; self.items = items
    }
}

public enum FjordError: Error, LocalizedError, Sendable, Equatable {
    case unauthenticated
    case cancelled
    case rateLimited(Date?)
    case http(Int, String)
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .unauthenticated: L10n.core("Your sign-in expired or was revoked. Sign in again.")
        case .cancelled: L10n.core("The action was cancelled.")
        case .rateLimited: L10n.core("GitHub's request limit was reached. Wait a moment before trying again.")
        case .http(let code, let message): L10n.core("GitHub returned %lld: %@", code, message)
        case .message(let message): message
        }
    }
}

public enum JSONValue: Encodable, Sendable, Equatable {
    case string(String), number(Int), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
}

public enum CollaboratorRole: String, CaseIterable, Sendable, Identifiable {
    case reader = "READER", writer = "WRITER", admin = "ADMIN"
    public var id: String { rawValue }
    public var label: String {
        switch self { case .reader: L10n.core("Reader"); case .writer: L10n.core("Can edit"); case .admin: L10n.core("Administrator") }
    }
}
