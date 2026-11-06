import Foundation

public actor DemoProjectsAPI: ProjectsAPI {
    private var snapshots: [String: ProjectSnapshot]
    private var nextProjectNumber = 2
    private let people = [AssignableUser(id: "demo-user", login: "demo", name: "Demo user"),
                          AssignableUser(id: "demo-maren", login: "maren", name: "Maren")]
    public init() {
        let field = Self.defaultField(id: "demo-status", includeConversation: true)
        let project = ProjectSummary(id: "demo-project", number: 1, title: "Website launch", url: URL(string: "https://github.com/users/demo/projects/1")!)
        let me = AssignableUser(id: "demo-user", login: "demo", name: "Demo user")
        let maren = AssignableUser(id: "demo-maren", login: "maren", name: "Maren")
        snapshots = [project.id: ProjectSnapshot(project: project, canUpdate: true, fields: [field], items: [
            ProjectItem(id: "demo-1", contentID: "draft-1", kind: .draft, title: "Plan the launch checklist", body: "Collect the final tasks for our fictional website launch.", selections: [field.id: "todo"]),
            ProjectItem(id: "demo-2", contentID: "issue-2", kind: .issue, title: "Design the landing page", body: "Review the layout, typography and call to action.", repository: "example/website", number: 12, selections: [field.id: "doing"], assigneeLogins: ["maren"], assignees: [maren]),
            ProjectItem(id: "demo-3", contentID: "pr-3", kind: .pullRequest, title: "Add the getting started guide", repository: "example/website", number: 14, selections: [field.id: "done"], assigneeLogins: ["demo"], assignees: [me]),
            ProjectItem(id: "demo-4", contentID: "draft-4", kind: .draft, title: "Review accessibility feedback", selections: [field.id: "todo"]),
            ProjectItem(id: "demo-5", contentID: "issue-5", kind: .issue, title: "Test the signup flow", repository: "example/website", number: 15, selections: [field.id: "doing"], assigneeLogins: ["demo"], assignees: [me]),
            ProjectItem(id: "demo-6", contentID: "draft-6", kind: .draft, title: "Prepare launch announcement", selections: [field.id: "todo"]),
            ProjectItem(id: "demo-7", contentID: "issue-7", kind: .issue, title: "Set up the preview environment", repository: "example/website", number: 10, selections: [field.id: "done"], assigneeLogins: ["maren"], assignees: [maren]),
            ProjectItem(id: "demo-chat-1", contentID: "message-1", kind: .draft, title: "What should we focus on before launch?", body: "What should we focus on before launch?", selections: [field.id: "chat"], authorLogin: "maren", createdAt: Date().addingTimeInterval(-300), assigneeLogins: ["maren"], assignees: [maren]),
            ProjectItem(id: "demo-chat-2", contentID: "message-2", kind: .draft, title: "The landing page and accessibility review are next. The setup guide is ready!", body: "The landing page and accessibility review are next. The setup guide is ready!", selections: [field.id: "chat"], authorLogin: "demo", createdAt: Date().addingTimeInterval(-120), assigneeLogins: ["demo"], assignees: [me])
        ])]
        let shared = ProjectSummary(id: "demo-shared-project", number: 1, title: "Team planning",
                                    url: URL(string: "https://github.com/users/maren/projects/1")!,
                                    isPublic: false, viewerCanUpdate: true)
        snapshots[shared.id] = ProjectSnapshot(project: shared, canUpdate: true, fields: [field], items: [
            ProjectItem(id: "demo-shared-item", contentID: "shared-draft", kind: .draft,
                        title: "Plan the next team sprint", selections: [field.id: "todo"])
        ])
    }
    private static func defaultField(id: String, includeConversation: Bool = false) -> SelectField {
        var options = [SelectOption(id: "todo", name: "Todo", color: "GRAY"),
                       SelectOption(id: "doing", name: "In Progress", color: "BLUE"),
                       SelectOption(id: "done", name: "Done", color: "GREEN")]
        if includeConversation { options.append(SelectOption(id: "chat", name: "Chat", color: "PURPLE")) }
        return SelectField(id: id, name: "Status", options: options)
    }
    public func currentUser() async throws -> GitHubUser { GitHubUser(login: "demo", name: "Demo workspace", nodeID: "demo-user") }
    public func organizations() async throws -> [ProjectOwner] { [] }
    public func collaboratingOwners() async throws -> [ProjectOwner] { [ProjectOwner(login: "maren", kind: .user)] }
    public func projects(owner: ProjectOwner) async throws -> [ProjectSummary] {
        snapshots.values.map(\.project).filter { $0.owner == owner }.sorted { $0.number < $1.number }
    }
    public func resolve(_ reference: ProjectReference) async throws -> ProjectSummary {
        guard let project = snapshots.values.first(where: { $0.project.number == reference.number && $0.project.owner == reference.owner })?.project else { throw FjordError.message(L10n.core("The project does not exist in the demo.")) }
        return project
    }
    public func snapshot(project: ProjectSummary) async throws -> ProjectSnapshot { try requireProject(project.id) }
    public func createProject(owner: ProjectOwner, title: String) async throws -> ProjectSummary {
        let id = UUID().uuidString
        let project = ProjectSummary(id: id, number: nextProjectNumber, title: title, url: URL(string: "https://github.com/users/demo/projects/\(nextProjectNumber)")!)
        nextProjectNumber += 1
        snapshots[id] = ProjectSnapshot(project: project, canUpdate: true, fields: [Self.defaultField(id: "status-\(id)")], items: [])
        return project
    }
    public func deleteProject(id: String) async throws { _ = try requireProject(id); snapshots.removeValue(forKey: id) }
    public func setSelection(projectID: String, itemID: String, fieldID: String, optionID: String?) async throws {
        var data = try requireProject(projectID)
        guard let index = data.items.firstIndex(where: { $0.id == itemID }) else { throw FjordError.message(L10n.core("The item does not exist.")) }
        data.items[index].selections[fieldID] = optionID; snapshots[projectID] = data
    }
    public func moveItem(projectID: String, itemID: String, afterID: String?) async throws {
        var data = try requireProject(projectID)
        data.items = BoardOrdering.moving(data.items, itemID: itemID, afterID: afterID)
        snapshots[projectID] = data
    }
    public func addDraft(projectID: String, title: String, body: String) async throws {
        _ = try await createItem(projectID: projectID, request: NewItemRequest(title: title, body: body))
    }
    public func createItem(projectID: String, request: NewItemRequest) async throws -> ItemCreationResult {
        var data = try requireProject(projectID)
        let id = UUID().uuidString
        let assigned = people.filter { request.assigneeIDs.contains($0.id) }
        let issue = request.repositoryID != nil
        let number = data.items.count + 20
        let url = issue ? URL(string: "https://github.com/example/website/issues/\(number)") : nil
        var selections: [String: String] = [:]
        if let placement = request.placement { selections[placement.fieldID] = placement.optionID }
        data.items.append(ProjectItem(id: id, contentID: id, kind: issue ? .issue : .draft, title: request.title, body: request.body,
                                      url: url, repository: issue ? "example/website" : nil, number: issue ? number : nil,
                                      selections: selections, authorLogin: "demo", createdAt: Date(), assigneeLogins: assigned.map(\.login), assignees: assigned))
        snapshots[projectID] = data
        return ItemCreationResult(projectItemID: id, issueURL: url)
    }
    public func updateContent(item: ProjectItem, title: String, body: String) async throws {
        for id in snapshots.keys {
            guard var data = snapshots[id], let index = data.items.firstIndex(where: { $0.id == item.id }) else { continue }
            data.items[index].title = title; data.items[index].body = body; snapshots[id] = data; return
        }
        throw FjordError.message(L10n.core("The item does not exist."))
    }
    public func changeAssignee(item: ProjectItem, user: AssignableUser, assigned: Bool) async throws {
        for id in snapshots.keys {
            guard var data = snapshots[id], let index = data.items.firstIndex(where: { $0.id == item.id }) else { continue }
            data.items[index].assignees.removeAll { $0.id == user.id }
            if assigned { data.items[index].assignees.append(user) }
            data.items[index].assigneeLogins = data.items[index].assignees.map(\.login)
            snapshots[id] = data; return
        }
        throw FjordError.message(L10n.core("The item does not exist."))
    }
    public func repositories(projectID: String, referencedRepositories: [String]) async throws -> [RepositoryChoice] {
        _ = try requireProject(projectID)
        return [RepositoryChoice(id: "demo-repo", nameWithOwner: "example/website")]
    }
    public func repository(named nameWithOwner: String) async throws -> RepositoryChoice {
        guard nameWithOwner.split(separator: "/").count == 2 else { throw FjordError.message(L10n.core("Use owner/repository.")) }
        return RepositoryChoice(id: "demo-repo", nameWithOwner: nameWithOwner)
    }
    public func assignableUsers(repository nameWithOwner: String) async throws -> [AssignableUser] { people }
    public func findUser(login: String) async throws -> AssignableUser {
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !login.isEmpty else { throw FjordError.message(L10n.core("Enter a username.")) }
        return people.first(where: { $0.login == login }) ?? AssignableUser(id: "demo-\(login)", login: login)
    }
    public func addColumn(projectID: String, fieldID: String, name: String) async throws {
        let data = try requireProject(projectID)
        guard let field = data.fields.first(where: { $0.id == fieldID }) else { throw FjordError.message(L10n.core("The field does not exist.")) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !field.options.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw FjordError.message(L10n.core("Choose a new column name.")) }
        let updated = SelectField(id: field.id, name: field.name, options: field.options + [SelectOption(id: UUID().uuidString, name: name, color: "GRAY")])
        snapshots[projectID] = ProjectSnapshot(project: data.project, canUpdate: data.canUpdate, fields: data.fields.map { $0.id == fieldID ? updated : $0 }, items: data.items)
    }
    public func deleteColumn(projectID: String, fieldID: String, optionID: String) async throws {
        var data = try requireProject(projectID)
        guard let field = data.fields.first(where: { $0.id == fieldID }), field.options.contains(where: { $0.id == optionID }) else { throw FjordError.message(L10n.core("The column does not exist.")) }
        let updated = SelectField(id: field.id, name: field.name, options: field.options.filter { $0.id != optionID })
        for index in data.items.indices where data.items[index].selections[fieldID] == optionID { data.items[index].selections[fieldID] = nil }
        snapshots[projectID] = ProjectSnapshot(project: data.project, canUpdate: data.canUpdate, fields: data.fields.map { $0.id == fieldID ? updated : $0 }, items: data.items)
    }
    public func grantAccess(projectID: String, username: String, role: CollaboratorRole) async throws { throw FjordError.message(L10n.core("Participant access can only be changed while connected to GitHub.")) }
    public func sendChatMessage(projectID: String, fieldID: String, optionID: String, authorID: String, text: String) async throws -> ChatSendResult {
        let created = try await createItem(projectID: projectID, request: NewItemRequest(title: String(text.prefix(100)), body: text, assigneeIDs: [authorID], placement: ItemPlacement(fieldID: fieldID, optionID: optionID)))
        guard let item = try requireProject(projectID).items.first(where: { $0.id == created.projectItemID }) else {
            throw FjordError.message(L10n.core("The item does not exist."))
        }
        return .sent(item)
    }
    private func requireProject(_ id: String) throws -> ProjectSnapshot {
        guard let data = snapshots[id] else { throw FjordError.message(L10n.core("The project does not exist.")) }
        return data
    }
}
