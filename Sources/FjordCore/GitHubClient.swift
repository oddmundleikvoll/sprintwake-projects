import Foundation

public struct GitHubClient: ProjectsAPI {
    private let token: String
    private let transport: any HTTPTransport
    public init(token: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.token = token; self.transport = transport
    }

    public func currentUser() async throws -> GitHubUser {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        authorize(&request)
        let response = try await transport.send(request)
        try checkResponse(response)
        return try JSONDecoder().decode(GitHubUser.self, from: response.data)
    }

    public func organizations() async throws -> [ProjectOwner] {
        var result: [ProjectOwner] = []
        var cursor: String?
        repeat {
            let data: OrganizationsData = try await graphQL("""
            query($after: String) {
              viewer { organizations(first: 100, after: $after) {
                nodes { login } pageInfo { hasNextPage endCursor }
              } }
            }
            """, ["after": value(cursor)])
            result += data.viewer.organizations.nodes.compactMap { $0 }.map { ProjectOwner(login: $0.login, kind: .organization) }
            cursor = try nextCursor(data.viewer.organizations.pageInfo, previous: cursor)
        } while cursor != nil
        return result
    }

    public func projects(owner: ProjectOwner) async throws -> [ProjectSummary] {
        var result: [ProjectSummary] = []
        var cursor: String?
        repeat {
            try Task.checkCancellation()
            let data: OwnerData = try await graphQL("""
            query($login: String!, $after: String) {
              \(owner.kind.rawValue)(login: $login) {
                projectsV2(first: 100, after: $after) {
                  nodes { id number title url closed public viewerCanUpdate } pageInfo { hasNextPage endCursor }
                }
              }
            }
            """, ["login": .string(owner.login), "after": value(cursor)])
            guard let page = data.owner?.projectsV2 else { throw noAccess() }
            result += page.nodes.compactMap { $0 }
            cursor = try nextCursor(page.pageInfo, previous: cursor)
        } while cursor != nil
        return result.sorted { $0.closed == $1.closed ? $0.number > $1.number : !$0.closed }
    }

    public func collaboratingOwners() async throws -> [ProjectOwner] {
        var result: [String: ProjectOwner] = [:]
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            try Task.checkCancellation()
            let data: CollaboratingOwnersData = try await graphQL("""
            query($after: String) { viewer {
              repositories(first: 100, after: $after, affiliations: [COLLABORATOR, ORGANIZATION_MEMBER]) {
                nodes { owner { __typename login } }
                pageInfo { hasNextPage endCursor }
              }
            } }
            """, ["after": value(cursor)])
            for node in data.viewer.repositories.nodes.compactMap({ $0 }) {
                let kind: ProjectOwner.Kind
                switch node.owner.__typename {
                case "User": kind = .user
                case "Organization": kind = .organization
                default: continue
                }
                let owner = ProjectOwner(login: node.owner.login, kind: kind)
                result[owner.id.lowercased()] = owner
            }
            cursor = try nextCursor(data.viewer.repositories.pageInfo, previous: cursor)
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw FjordError.message(L10n.core("GitHub returned incomplete pagination. Refresh the project and try again."))
            }
        } while cursor != nil
        return result.values.sorted { $0.login.localizedStandardCompare($1.login) == .orderedAscending }
    }

    public func resolve(_ reference: ProjectReference) async throws -> ProjectSummary {
        let data: OwnerData = try await graphQL("""
        query($login: String!, $number: Int!) {
          \(reference.owner.kind.rawValue)(login: $login) {
            projectV2(number: $number) { id number title url closed public viewerCanUpdate }
          }
        }
        """, ["login": .string(reference.owner.login), "number": .number(reference.number)])
        guard let project = data.owner?.projectV2 else { throw noAccess() }
        return project
    }

    public func snapshot(project: ProjectSummary) async throws -> ProjectSnapshot {
        var fields: [SelectField] = []
        var cursor: String?
        var metadata: MetadataNode?
        repeat {
            let data: MetadataData = try await graphQL("""
            query($id: ID!, $after: String) {
              node(id: $id) { ... on ProjectV2 {
                id number title url closed public viewerCanUpdate
                fields(first: 100, after: $after) {
                  nodes { ... on ProjectV2SingleSelectField { id name options { id name color description } } }
                  pageInfo { hasNextPage endCursor }
                }
              } }
            }
            """, ["id": .string(project.id), "after": value(cursor)])
            guard let node = data.node else { throw noAccess() }
            metadata = node
            fields += node.fields.nodes.compactMap { field in
                guard let field, let id = field.id, let name = field.name, let options = field.options else { return nil }
                return SelectField(id: id, name: name, options: options)
            }
            cursor = try nextCursor(node.fields.pageInfo, previous: cursor)
        } while cursor != nil

        var items: [ProjectItem] = []
        repeat {
            let data: ItemsData = try await graphQL("""
            query($id: ID!, $after: String) {
              node(id: $id) { ... on ProjectV2 {
                items(first: 50, after: $after, archivedStates: [NOT_ARCHIVED]) {
                  nodes {
                    id
                    content {
                      __typename
                      ... on DraftIssue { id title body createdAt creator { login } assignees(first: 50) { nodes { id login name } } }
                      ... on Issue { id title body url number createdAt author { login } viewerCanUpdate repository { nameWithOwner } assignees(first: 50) { nodes { id login name } } }
                      ... on PullRequest { id title body url number createdAt author { login } viewerCanUpdate repository { nameWithOwner } assignees(first: 50) { nodes { id login name } } }
                    }
                    fieldValues(first: 100) {
                      nodes { \(Self.selectionFragment) }
                      pageInfo { hasNextPage endCursor }
                    }
                  }
                  pageInfo { hasNextPage endCursor }
                }
              } }
            }
            """, ["id": .string(project.id), "after": value(cursor)])
            guard let page = data.node?.items else { throw noAccess() }
            for node in page.nodes.compactMap({ $0 }) {
                var values = node.fieldValues.nodes.compactMap { $0 }
                var valueCursor = try nextCursor(node.fieldValues.pageInfo, previous: nil)
                while let after = valueCursor {
                    let more: ValuesData = try await graphQL("""
                    query($id: ID!, $after: String) {
                      node(id: $id) { ... on ProjectV2Item {
                        fieldValues(first: 100, after: $after) {
                          nodes { \(Self.selectionFragment) } pageInfo { hasNextPage endCursor }
                        }
                      } }
                    }
                    """, ["id": .string(node.id), "after": .string(after)])
                    guard let page = more.node?.fieldValues else { throw noAccess() }
                    values += page.nodes.compactMap { $0 }
                    valueCursor = try nextCursor(page.pageInfo, previous: after)
                }
                let selections = values.reduce(into: [String: String]()) { result, value in
                    if let field = value.field?.id, let option = value.optionId { result[field] = option }
                }
                let content = node.content
                let kind: ProjectItem.Kind = switch content?.__typename {
                case "DraftIssue": .draft
                case "Issue": .issue
                case "PullRequest": .pullRequest
                default: .redacted
                }
                items.append(ProjectItem(
                    id: node.id, contentID: content?.id, kind: kind,
                    title: content?.title ?? L10n.core("Private or unavailable item"), body: content?.body ?? "",
                    url: content?.url, repository: content?.repository?.nameWithOwner, number: content?.number,
                    canEditContent: kind == .draft ? metadata?.viewerCanUpdate == true : content?.viewerCanUpdate == true,
                    selections: selections, authorLogin: content?.creator?.login ?? content?.author?.login,
                    createdAt: content?.createdAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                    assigneeLogins: content?.assignees?.nodes.compactMap { $0?.login } ?? [],
                    assignees: content?.assignees?.nodes.compactMap { actor in
                        guard let actor, let id = actor.id else { return nil }
                        return AssignableUser(id: id, login: actor.login, name: actor.name)
                    } ?? []
                ))
            }
            cursor = try nextCursor(page.pageInfo, previous: cursor)
        } while cursor != nil
        guard let metadata else { throw noAccess() }
        let summary = ProjectSummary(id: metadata.id, number: metadata.number, title: metadata.title, url: metadata.url,
                                     closed: metadata.closed, isPublic: metadata.isPublic, viewerCanUpdate: metadata.viewerCanUpdate)
        return ProjectSnapshot(project: summary, canUpdate: metadata.viewerCanUpdate, fields: fields, items: items)
    }

    public func setSelection(projectID: String, itemID: String, fieldID: String, optionID: String?) async throws {
        var variables: [String: JSONValue] = ["project": .string(projectID), "item": .string(itemID), "field": .string(fieldID)]
        let query: String
        if let optionID {
            variables["option"] = .string(optionID)
            query = """
            mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
              updateProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field,
                value: {singleSelectOptionId: $option}}) { projectV2Item { id } }
            }
            """
        } else {
            query = """
            mutation($project: ID!, $item: ID!, $field: ID!) {
              clearProjectV2ItemFieldValue(input: {projectId: $project, itemId: $item, fieldId: $field}) {
                projectV2Item { id }
              }
            }
            """
        }
        let _: MutationData = try await graphQL(query, variables)
    }

    public func addDraft(projectID: String, title: String, body: String) async throws {
        let _: MutationData = try await graphQL("""
        mutation($project: ID!, $title: String!, $body: String!) {
          addProjectV2DraftIssue(input: {projectId: $project, title: $title, body: $body}) { projectItem { id } }
        }
        """, ["project": .string(projectID), "title": .string(title), "body": .string(body)])
    }

    public func updateContent(item: ProjectItem, title: String, body: String) async throws {
        guard item.canEditContent, let id = item.contentID else { throw FjordError.message(L10n.core("You do not have permission to edit this item.")) }
        let operation: String
        switch item.kind {
        case .draft: operation = "updateProjectV2DraftIssue(input: {draftIssueId: $id, title: $title, body: $body}) { draftIssue { id } }"
        case .issue: operation = "updateIssue(input: {id: $id, title: $title, body: $body}) { issue { id } }"
        case .pullRequest: operation = "updatePullRequest(input: {pullRequestId: $id, title: $title, body: $body}) { pullRequest { id } }"
        case .redacted: throw FjordError.message(L10n.core("This content is not available to the current sign-in."))
        }
        let _: MutationData = try await graphQL("mutation($id: ID!, $title: String!, $body: String!) { \(operation) }",
                                               ["id": .string(id), "title": .string(title), "body": .string(body)])
    }

    private static let selectionFragment = """
    ... on ProjectV2ItemFieldSingleSelectValue { optionId field { ... on ProjectV2SingleSelectField { id } } }
    """

    public func grantAccess(projectID: String, username: String, role: CollaboratorRole) async throws {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        guard !username.isEmpty else { throw FjordError.message(L10n.core("Enter a GitHub username.")) }
        let user: UserIDData = try await graphQL("query($login: String!) { user(login: $login) { id } }", ["login": .string(username)])
        guard let id = user.user?.id else { throw FjordError.message(L10n.core("GitHub user not found.")) }
        let _: MutationData = try await graphQL("""
        mutation($project: ID!, $collaborators: [ProjectV2Collaborator!]!) {
          updateProjectV2Collaborators(input: {projectId: $project, collaborators: $collaborators}) {
            collaborators(first: 1) { totalCount }
          }
        }
        """, ["project": .string(projectID), "collaborators": .array([
            .object(["userId": .string(id), "role": .string(role.rawValue)])
        ])])
    }

    public func sendChatMessage(projectID: String, fieldID: String, optionID: String, authorID: String, text: String) async throws -> ChatSendResult {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 60_000, !authorID.isEmpty else {
            throw FjordError.message(L10n.core("The message must contain text (maximum 60,000 characters), and the author must be signed in."))
        }
        let title = String(text.prefix(100)).replacingOccurrences(of: "\n", with: " ")
        let created: DraftCreationData = try await graphQL("""
        mutation($project: ID!, $title: String!, $body: String!, $author: ID!) {
          addProjectV2DraftIssue(input: {projectId: $project, title: $title, body: $body, assigneeIds: [$author]}) {
            projectItem { id content { ... on DraftIssue {
              __typename id title body createdAt creator { login }
              assignees(first: 50) { nodes { id login name } }
            } } }
          }
        }
        """, ["project": .string(projectID), "title": .string(title), "body": .string(text), "author": .string(authorID)])
        let draft = created.addProjectV2DraftIssue.projectItem
        let content = draft.content
        var item = ProjectItem(id: draft.id, contentID: content?.id, kind: .draft,
                               title: content?.title ?? title, body: content?.body ?? text,
                               canEditContent: content?.id != nil,
                               authorLogin: content?.creator?.login,
                               createdAt: content?.createdAt.flatMap { ISO8601DateFormatter().date(from: $0) },
                               assigneeLogins: content?.assignees?.nodes.compactMap { $0?.login } ?? [],
                               assignees: content?.assignees?.nodes.compactMap { actor in
                                   guard let actor, let id = actor.id else { return nil }
                                   return AssignableUser(id: id, login: actor.login, name: actor.name)
                               } ?? [])
        do {
            try await setSelection(projectID: projectID, itemID: draft.id, fieldID: fieldID, optionID: optionID)
            item.selections[fieldID] = optionID
            return .sent(item)
        } catch {
            // Creation and placement are separate GitHub mutations. Never create the draft twice.
            return .placementUnconfirmed(item, error.localizedDescription)
        }
    }

    public func createProject(owner: ProjectOwner, title: String) async throws -> ProjectSummary {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FjordError.message(L10n.core("The project title cannot be empty.")) }
        let ownerData: OwnerIDData = try await graphQL("query($login: String!) { \(owner.kind.rawValue)(login: $login) { id } }", ["login": .string(owner.login)])
        guard let ownerID = ownerData.ownerID else { throw noAccess() }
        let data: CreateProjectData = try await graphQL("""
        mutation($owner: ID!, $title: String!) {
          createProjectV2(input: {ownerId: $owner, title: $title}) { projectV2 { id number title url closed } }
        }
        """, ["owner": .string(ownerID), "title": .string(title)])
        return data.createProjectV2.projectV2
    }

    public func deleteProject(id: String) async throws {
        guard !id.isEmpty else { throw FjordError.message(L10n.core("The project is missing an ID.")) }
        let _: MutationData = try await graphQL("mutation($id: ID!) { deleteProjectV2(input: {projectId: $id}) { projectV2 { id } } }", ["id": .string(id)])
    }

    public func repositories(projectID: String, referencedRepositories: [String]) async throws -> [RepositoryChoice] {
        var choices: [RepositoryChoice] = []
        var seen = Set<String>(); var cursor: String?
        repeat {
            let data: ProjectRepositoriesData = try await graphQL("""
            query($id: ID!, $after: String) { node(id: $id) { ... on ProjectV2 {
              repositories(first: 100, after: $after) { nodes { id nameWithOwner hasIssuesEnabled isArchived } pageInfo { hasNextPage endCursor } }
            } } }
            """, ["id": .string(projectID), "after": value(cursor)])
            guard let page = data.node?.repositories else { throw noAccess() }
            for repo in page.nodes.compactMap({ $0 }) where seen.insert(repo.nameWithOwner).inserted { choices.append(repo) }
            cursor = try nextCursor(page.pageInfo, previous: cursor)
        } while cursor != nil
        for name in referencedRepositories {
            guard !seen.contains(name) else { continue }
            if let repo = try? await repository(named: name) { choices.append(repo); seen.insert(name) }
        }
        if choices.isEmpty {
            cursor = nil
            repeat {
                let data: ViewerRepositoriesData = try await graphQL("""
                query($after: String) { viewer { repositories(first: 100, after: $after) {
                  nodes { id nameWithOwner hasIssuesEnabled isArchived } pageInfo { hasNextPage endCursor }
                } } }
                """, ["after": value(cursor)])
                for repo in data.viewer.repositories.nodes.compactMap({ $0 }) where seen.insert(repo.nameWithOwner).inserted { choices.append(repo) }
                cursor = try nextCursor(data.viewer.repositories.pageInfo, previous: cursor)
            } while cursor != nil
        }
        return choices.sorted { $0.nameWithOwner.localizedCaseInsensitiveCompare($1.nameWithOwner) == .orderedAscending }
    }

    public func repository(named nameWithOwner: String) async throws -> RepositoryChoice {
        let parts = nameWithOwner.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw FjordError.message(L10n.core("Repository must be written as owner/name.")) }
        let data: RepositoryData = try await graphQL("""
        query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id nameWithOwner hasIssuesEnabled isArchived } }
        """, ["owner": .string(String(parts[0])), "name": .string(String(parts[1]))])
        guard let repo = data.repository else { throw FjordError.message(L10n.core("Repository %@ was not found.", nameWithOwner)) }
        return repo
    }

    public func assignableUsers(repository nameWithOwner: String) async throws -> [AssignableUser] {
        let parts = nameWithOwner.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { throw FjordError.message(L10n.core("Repository must be written as owner/name.")) }
        var result: [AssignableUser] = []; var cursor: String?
        repeat {
            let data: AssignableUsersData = try await graphQL("""
            query($owner: String!, $name: String!, $after: String) { repository(owner: $owner, name: $name) {
              assignableUsers(first: 100, after: $after) { nodes { id login name } pageInfo { hasNextPage endCursor } }
            } }
            """, ["owner": .string(String(parts[0])), "name": .string(String(parts[1])), "after": value(cursor)])
            guard let page = data.repository?.assignableUsers else { throw FjordError.message(L10n.core("Repository %@ was not found.", nameWithOwner)) }
            result += page.nodes.compactMap { $0 }
            cursor = try nextCursor(page.pageInfo, previous: cursor)
        } while cursor != nil
        return result
    }

    public func findUser(login: String) async throws -> AssignableUser {
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        guard !login.isEmpty else { throw FjordError.message(L10n.core("Enter a GitHub username.")) }
        let data: AssignableUserData = try await graphQL("query($login: String!) { user(login: $login) { id login name } }", ["login": .string(login)])
        guard let user = data.user else { throw FjordError.message(L10n.core("GitHub user not found.")) }
        return user
    }

    public func createItem(projectID: String, request: NewItemRequest) async throws -> ItemCreationResult {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FjordError.message(L10n.core("The item title cannot be empty.")) }
        if let repositoryID = request.repositoryID {
            let data: IssueCreationData = try await graphQL("""
            mutation($repository: ID!, $title: String!, $body: String!, $assignees: [ID!]) {
              createIssue(input: {repositoryId: $repository, title: $title, body: $body, assigneeIds: $assignees}) { issue { id url } }
            }
            """, ["repository": .string(repositoryID), "title": .string(title), "body": .string(request.body), "assignees": request.assigneeIDs.isEmpty ? .null : .array(request.assigneeIDs.map(JSONValue.string))])
            let issue = data.createIssue.issue
            do {
                let linked: AddItemData = try await graphQL("mutation($project: ID!, $content: ID!) { addProjectV2ItemById(input: {projectId: $project, contentId: $content}) { item { id } } }", ["project": .string(projectID), "content": .string(issue.id)])
                let itemID = linked.addProjectV2ItemById.item.id
                if let placement = request.placement {
                    do { try await setSelection(projectID: projectID, itemID: itemID, fieldID: placement.fieldID, optionID: placement.optionID) }
                    catch { return ItemCreationResult(projectItemID: itemID, issueURL: issue.url, warning: L10n.core("The issue was created, but its column placement could not be confirmed: %@", error.localizedDescription)) }
                }
                return ItemCreationResult(projectItemID: itemID, issueURL: issue.url)
            } catch {
                return ItemCreationResult(projectItemID: nil, issueURL: issue.url, warning: L10n.core("The issue was created, but could not be added to the project: %@", error.localizedDescription))
            }
        }
        let variables: [String: JSONValue] = ["project": .string(projectID), "title": .string(title), "body": .string(request.body), "assignees": request.assigneeIDs.isEmpty ? .null : .array(request.assigneeIDs.map(JSONValue.string))]
        let data: DraftCreationData = try await graphQL("mutation($project: ID!, $title: String!, $body: String!, $assignees: [ID!]) { addProjectV2DraftIssue(input: {projectId: $project, title: $title, body: $body, assigneeIds: $assignees}) { projectItem { id } } }", variables)
        let itemID = data.addProjectV2DraftIssue.projectItem.id
        if let placement = request.placement {
            do { try await setSelection(projectID: projectID, itemID: itemID, fieldID: placement.fieldID, optionID: placement.optionID) }
            catch { return ItemCreationResult(projectItemID: itemID, warning: L10n.core("The draft was created, but its column placement could not be confirmed: %@", error.localizedDescription)) }
        }
        return ItemCreationResult(projectItemID: itemID)
    }

    public func changeAssignee(item: ProjectItem, user: AssignableUser, assigned: Bool) async throws {
        guard let contentID = item.contentID else { throw FjordError.message(L10n.core("The item has no editable content.")) }
        switch item.kind {
        case .issue, .pullRequest:
            let mutation = assigned ? "addAssigneesToAssignable" : "removeAssigneesFromAssignable"
            // Assignable has no id field; Issue and PullRequest expose it through Node.
            let _: MutationData = try await graphQL("mutation($id: ID!, $user: ID!) { \(mutation)(input: {assignableId: $id, assigneeIds: [$user]}) { assignable { ... on Node { id } } } }", ["id": .string(contentID), "user": .string(user.id)])
        case .draft:
            let current: DraftAssigneesData = try await graphQL("query($id: ID!) { node(id: $id) { ... on DraftIssue { assignees(first: 100) { nodes { id } } } } }", ["id": .string(contentID)])
            guard let node = current.node else { throw noAccess() }
            var ids = node.assignees.nodes.compactMap { $0?.id }
            if assigned { if !ids.contains(user.id) { ids.append(user.id) } } else { ids.removeAll { $0 == user.id } }
            let _: MutationData = try await graphQL("mutation($id: ID!, $ids: [ID!]) { updateProjectV2DraftIssue(input: {draftIssueId: $id, assigneeIds: $ids}) { draftIssue { id } } }", ["id": .string(contentID), "ids": .array(ids.map(JSONValue.string))])
        case .redacted: throw FjordError.message(L10n.core("This content is not available to the current sign-in."))
        }
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Fjord-Mac/0.1", forHTTPHeaderField: "User-Agent")
    }

    private func graphQL<T: Decodable>(_ query: String, _ variables: [String: JSONValue]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(GraphQLPayload(query: query, variables: variables))
        let response = try await transport.send(request)
        try checkResponse(response)
        let envelope = try JSONDecoder().decode(GraphQLResponse<T>.self, from: response.data)
        if let errors = envelope.errors, !errors.isEmpty {
            if errors.contains(where: { $0.type == "UNAUTHORIZED" }) { throw FjordError.unauthenticated }
            if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
                throw FjordError.rateLimited(gitHubRateLimitReset(response))
            }
            throw FjordError.message(errors.map(\.message).joined(separator: "\n"))
        }
        guard let data = envelope.data else { throw FjordError.message(L10n.core("GitHub returned no project data.")) }
        return data
    }

    private func value(_ string: String?) -> JSONValue { string.map(JSONValue.string) ?? .null }
    private func noAccess() -> FjordError { .message(L10n.core("The project was not found, or this sign-in lacks access. Check the project link and GitHub project access.")) }
    private func nextCursor(_ page: PageInfo, previous: String?) throws -> String? {
        guard page.hasNextPage else { return nil }
        guard let cursor = page.endCursor, cursor != previous else { throw FjordError.message(L10n.core("GitHub returned incomplete pagination. Refresh the project and try again.")) }
        return cursor
    }
}

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}
private struct GraphQLError: Decodable { let message: String; let type: String? }
private struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
private struct Connection<T: Decodable>: Decodable { let nodes: [T?]; let pageInfo: PageInfo }
private struct OrganizationsData: Decodable {
    struct Viewer: Decodable {
        struct Organization: Decodable { let login: String }
        let organizations: Connection<Organization>
    }
    let viewer: Viewer
}
private struct OwnerData: Decodable {
    struct Owner: Decodable { let projectsV2: Connection<ProjectSummary>?; let projectV2: ProjectSummary? }
    let user: Owner?
    let organization: Owner?
    var owner: Owner? { user ?? organization }
}
private struct CollaboratingOwnersData: Decodable {
    struct Viewer: Decodable {
        struct Repository: Decodable {
            struct Owner: Decodable { let __typename: String; let login: String }
            let owner: Owner
        }
        let repositories: Connection<Repository>
    }
    let viewer: Viewer
}
private struct MetadataData: Decodable { let node: MetadataNode? }
private struct MetadataNode: Decodable {
    let id: String; let number: Int; let title: String; let url: URL; let closed: Bool; let viewerCanUpdate: Bool
    let isPublic: Bool?
    let fields: Connection<FieldNode>
    enum CodingKeys: String, CodingKey {
        case id, number, title, url, closed, viewerCanUpdate, fields
        case isPublic = "public"
    }
}
private struct FieldNode: Decodable { let id: String?; let name: String?; let options: [SelectOption]? }
private struct ItemsData: Decodable {
    struct Node: Decodable { let items: Connection<ItemNode> }
    let node: Node?
}
private struct ItemNode: Decodable {
    struct Content: Decodable {
        struct Repository: Decodable { let nameWithOwner: String }
        struct Actor: Decodable { let id: String?; let login: String; let name: String? }
        struct Assignees: Decodable { let nodes: [Actor?] }
        let __typename: String
        let id: String?; let title: String?; let body: String?; let url: URL?; let number: Int?
        let viewerCanUpdate: Bool?; let repository: Repository?
        let createdAt: String?; let creator: Actor?; let author: Actor?; let assignees: Assignees?
    }
    let id: String; let content: Content?; let fieldValues: Connection<SelectionNode>
}
private struct SelectionNode: Decodable {
    struct Field: Decodable { let id: String? }
    let optionId: String?; let field: Field?
}
private struct ValuesData: Decodable {
    struct Node: Decodable { let fieldValues: Connection<SelectionNode> }
    let node: Node?
}
private struct MutationData: Decodable {}
private struct GraphQLPayload: Encodable { let query: String; let variables: [String: JSONValue] }
private struct UserIDData: Decodable {
    struct User: Decodable { let id: String }
    let user: User?
}
private struct DraftCreationData: Decodable {
    struct Payload: Decodable {
        struct Item: Decodable { let id: String; let content: ItemNode.Content? }
        let projectItem: Item
    }
    let addProjectV2DraftIssue: Payload
}

private struct OwnerIDData: Decodable {
    struct Owner: Decodable { let id: String }
    let user: Owner?
    let organization: Owner?
    var ownerID: String? { user?.id ?? organization?.id }
}
private struct CreateProjectData: Decodable {
    struct Payload: Decodable { let projectV2: ProjectSummary }
    let createProjectV2: Payload
}
private struct RepositoryData: Decodable { let repository: RepositoryChoice? }
private struct ProjectRepositoriesData: Decodable {
    struct Node: Decodable { let repositories: Connection<RepositoryChoice> }
    let node: Node?
}
private struct ViewerRepositoriesData: Decodable {
    struct Viewer: Decodable { let repositories: Connection<RepositoryChoice> }
    let viewer: Viewer
}
private struct AssignableUsersData: Decodable {
    struct Repository: Decodable { let assignableUsers: Connection<AssignableUser> }
    let repository: Repository?
}
private struct AssignableUserData: Decodable { let user: AssignableUser? }
private struct IssueCreationData: Decodable {
    struct Issue: Decodable { let id: String; let url: URL }
    struct Payload: Decodable { let issue: Issue }
    let createIssue: Payload
}
private struct AddItemData: Decodable {
    struct Item: Decodable { let id: String }
    struct Payload: Decodable { let item: Item }
    let addProjectV2ItemById: Payload
}
private struct DraftAssigneesData: Decodable {
    struct Assignee: Decodable { let id: String? }
    struct Assignees: Decodable { let nodes: [Assignee?] }
    struct Node: Decodable { let assignees: Assignees }
    let node: Node?
}
