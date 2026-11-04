import Foundation

public struct AssignableUser: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let login: String
    public let name: String?
    public init(id: String, login: String, name: String? = nil) {
        self.id = id; self.login = login; self.name = name
    }
}

public struct RepositoryChoice: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let nameWithOwner: String
    public let hasIssuesEnabled: Bool
    public let isArchived: Bool
    public init(id: String, nameWithOwner: String, hasIssuesEnabled: Bool = true, isArchived: Bool = false) {
        self.id = id; self.nameWithOwner = nameWithOwner
        self.hasIssuesEnabled = hasIssuesEnabled; self.isArchived = isArchived
    }
}

public struct ItemPlacement: Sendable, Equatable, Hashable {
    public let fieldID: String
    public let optionID: String
    public init(fieldID: String, optionID: String) { self.fieldID = fieldID; self.optionID = optionID }
}

public struct NewItemRequest: Sendable, Equatable {
    public let title: String
    public let body: String
    /// A repository creates a real issue. Nil creates a project draft.
    public let repositoryID: String?
    public let assigneeIDs: [String]
    public let placement: ItemPlacement?
    public init(title: String, body: String = "", repositoryID: String? = nil,
                assigneeIDs: [String] = [], placement: ItemPlacement? = nil) {
        self.title = title; self.body = body; self.repositoryID = repositoryID
        self.assigneeIDs = assigneeIDs; self.placement = placement
    }
}

public struct ItemCreationResult: Sendable, Equatable {
    public let projectItemID: String?
    public let issueURL: URL?
    /// A non-nil warning means the content was created; never retry creation.
    public let warning: String?
    public init(projectItemID: String?, issueURL: URL? = nil, warning: String? = nil) {
        self.projectItemID = projectItemID; self.issueURL = issueURL; self.warning = warning
    }
}
