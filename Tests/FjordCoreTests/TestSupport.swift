import Foundation
import Testing
@testable import FjordCore

actor MockTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest, Int) throws -> HTTPResponse
    private let handler: Handler
    private var calls: [URLRequest] = []
    init(_ handler: @escaping Handler) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        calls.append(request)
        return try handler(request, calls.count)
    }
    func requests() -> [URLRequest] { calls }
}

func jsonResponse(_ text: String, status: Int = 200) -> HTTPResponse { HTTPResponse(data: Data(text.utf8), status: status) }
func body(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

final class MemoryStorage: CredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credential?
    private var saves = 0
    init(_ value: Credential? = nil) { self.value = value }
    func load() throws -> Credential? { lock.withLock { value } }
    func save(_ credential: Credential) throws { lock.withLock { value = credential; saves += 1 } }
    func delete() throws { lock.withLock { value = nil } }
    func saveCount() -> Int { lock.withLock { saves } }
}

struct MockOAuth: OAuthAuthenticating {
    var beginHandler: @Sendable (String, Bool) async throws -> DeviceChallenge = { _, _ in throw FjordError.message("unused") }
    var pollHandler: @Sendable (DeviceChallenge) async throws -> Credential = { _ in throw FjordError.message("unused") }
    var refreshHandler: @Sendable (Credential) async throws -> Credential = { _ in throw FjordError.unauthenticated }
    func begin(clientID: String, includePrivateRepositories: Bool) async throws -> DeviceChallenge { try await beginHandler(clientID, includePrivateRepositories) }
    func poll(_ challenge: DeviceChallenge) async throws -> Credential { try await pollHandler(challenge) }
    func refresh(_ credential: Credential) async throws -> Credential { try await refreshHandler(credential) }
}

actor Gate {
    private var opened = false
    private var requested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        requested = true
        observers.forEach { $0.resume() }; observers = []
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilRequested() async {
        if requested { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
}

actor WorkspaceAPI: ProjectsAPI {
    var data: [ProjectSnapshot]
    var profileError: FjordError?
    var profileLogin = "tester"
    var profileNodeID = "user-id"
    var discoveryOwners: [ProjectOwner] = []
    var discoveryOrganizations: [ProjectOwner] = []
    var discoveryOrganizationFailure: FjordError?
    var ownerFailures: [String: FjordError] = [:]
    var discoveryOwnerFailure: FjordError?
    var discoveryGate: Gate?
    var gatedOwner: String?
    var ownerFilteredProjects = false
    var discoveryLookups = 0
    var queriedOwnerIDs: [String] = []
    var resolveGate: Gate?
    var gatedResolveOwner: String?
    var writeError: FjordError?
    var failReadsAfterWrite = false
    var writeCount = 0
    var createdRequests: [NewItemRequest] = []
    var creationWarning: String?
    var chatPlacementWarning: String?
    var chatPlacedDespiteWarning = false
    var positionError: FjordError?
    var positionGate: Gate?
    var selectionGate: Gate?
    var positionRequests: [(itemID: String, afterID: String?)] = []
    let gate: Gate?
    let gatedProject: String?
    let creationGate: Gate?
    init(data: [ProjectSnapshot] = [fixtureSnapshot()], gate: Gate? = nil, gatedProject: String? = nil, creationGate: Gate? = nil) {
        self.data = data; self.gate = gate; self.gatedProject = gatedProject; self.creationGate = creationGate
    }
    func configure(profileError: FjordError? = nil, writeError: FjordError? = nil, failReadsAfterWrite: Bool = false) {
        self.profileError = profileError; self.writeError = writeError; self.failReadsAfterWrite = failReadsAfterWrite
    }
    func currentUser() async throws -> GitHubUser {
        if let profileError { throw profileError }
        return GitHubUser(login: profileLogin, nodeID: profileNodeID)
    }
    func changeProfileLogin(_ login: String, nodeID: String = "user-id") { profileLogin = login; profileNodeID = nodeID }
    func organizations() async throws -> [ProjectOwner] {
        if let discoveryOrganizationFailure { throw discoveryOrganizationFailure }
        return discoveryOrganizations
    }
    func collaboratingOwners() async throws -> [ProjectOwner] {
        discoveryLookups += 1
        if let discoveryOwnerFailure { throw discoveryOwnerFailure }
        return discoveryOwners
    }
    func projects(owner: ProjectOwner) async throws -> [ProjectSummary] {
        queriedOwnerIDs.append(owner.id.lowercased())
        let response = data.map(\.project).filter { !ownerFilteredProjects || $0.owner?.id.lowercased() == owner.id.lowercased() }
        if owner.id.lowercased() == gatedOwner?.lowercased() { await discoveryGate?.wait() }
        if let error = ownerFailures[owner.id.lowercased()] { throw error }
        return response
    }
    func resolve(_ reference: ProjectReference) async throws -> ProjectSummary {
        if reference.owner.id == gatedResolveOwner { await resolveGate?.wait() }
        if !ownerFilteredProjects { return data[0].project }
        return try #require(data.first { $0.project.owner?.id.lowercased() == reference.owner.id.lowercased() && $0.project.number == reference.number }?.project)
    }
    func configureDiscovery(owners: [ProjectOwner], organizations: [ProjectOwner] = [],
                            failures: [String: FjordError] = [:], repositoryError: FjordError? = nil,
                            organizationError: FjordError? = nil,
                            gate: Gate? = nil, gatedOwner: String? = nil) {
        discoveryOwners = owners; discoveryOrganizations = organizations; ownerFailures = failures
        discoveryOwnerFailure = repositoryError; discoveryGate = gate; self.gatedOwner = gatedOwner
        discoveryOrganizationFailure = organizationError
        ownerFilteredProjects = true
    }
    func replaceProjects(_ data: [ProjectSnapshot]) { self.data = data }
    func discoveryCount() -> Int { discoveryLookups }
    func queriedOwners() -> [String] { queriedOwnerIDs }
    func configureResolveGate(_ gate: Gate, owner: String) { resolveGate = gate; gatedResolveOwner = owner }
    func snapshot(project: ProjectSummary) async throws -> ProjectSnapshot {
        if project.id == gatedProject { await gate?.wait() }
        if failReadsAfterWrite && writeCount > 0 { throw FjordError.http(503, "offline") }
        return try #require(data.first { $0.project.id == project.id })
    }
    func setSelection(projectID: String, itemID: String, fieldID: String, optionID: String?) async throws {
        await selectionGate?.wait()
        if let writeError { throw writeError }
        writeCount += 1
        if let p = data.firstIndex(where: { $0.project.id == projectID }), let i = data[p].items.firstIndex(where: { $0.id == itemID }) {
            data[p].items[i].selections[fieldID] = optionID
        }
    }
    func configurePosition(error: FjordError? = nil, gate: Gate? = nil, selectionGate: Gate? = nil) {
        positionError = error; positionGate = gate; self.selectionGate = selectionGate
    }
    func positions() -> [(itemID: String, afterID: String?)] { positionRequests }
    func moveItem(projectID: String, itemID: String, afterID: String?) async throws {
        positionRequests.append((itemID, afterID))
        await positionGate?.wait()
        if let error = positionError ?? writeError { throw error }
        writeCount += 1
        if let index = data.firstIndex(where: { $0.project.id == projectID }) {
            data[index].items = BoardOrdering.moving(data[index].items, itemID: itemID, afterID: afterID)
        }
    }
    func addDraft(projectID: String, title: String, body: String) async throws { if let writeError { throw writeError }; writeCount += 1 }
    func updateContent(item: ProjectItem, title: String, body: String) async throws { if let writeError { throw writeError }; writeCount += 1 }
    func grantAccess(projectID: String, username: String, role: CollaboratorRole) async throws { if let writeError { throw writeError }; writeCount += 1 }
    func sendChatMessage(projectID: String, fieldID: String, optionID: String, authorID: String, text: String) async throws -> ChatSendResult {
        await creationGate?.wait()
        if let writeError { throw writeError }
        writeCount += 1
        let item = ProjectItem(id: "sent-message", contentID: "sent-draft", kind: .draft,
                               title: String(text.prefix(100)), body: text,
                               selections: chatPlacementWarning == nil ? [fieldID: optionID] : [:],
                               authorLogin: profileLogin, createdAt: Date())
        if let chatPlacementWarning {
            if chatPlacedDespiteWarning, let index = data.firstIndex(where: { $0.project.id == projectID }) {
                var placed = item
                placed.selections[fieldID] = optionID
                data[index].items.append(placed)
            }
            return .placementUnconfirmed(item, chatPlacementWarning)
        }
        return .sent(item)
    }
    func setChatPlacementWarning(_ warning: String, placed: Bool = false) {
        chatPlacementWarning = warning; chatPlacedDespiteWarning = placed
    }
    func writes() -> Int { writeCount }
    func requestsCreated() -> [NewItemRequest] { createdRequests }
    func setCreationWarning(_ warning: String) { creationWarning = warning }
    func changeTitle(_ title: String) { data[0].items[0].title = title }
    func createProject(owner: ProjectOwner, title: String) async throws -> ProjectSummary {
        if let writeError { throw writeError }; writeCount += 1
        let snapshot = fixtureSnapshot(id: "created-project")
        let project = ProjectSummary(id: snapshot.project.id, number: 2, title: title, url: snapshot.project.url)
        data.append(ProjectSnapshot(project: project, canUpdate: true, fields: snapshot.fields, items: []))
        return project
    }
    func deleteProject(id: String) async throws { if let writeError { throw writeError }; writeCount += 1; data.removeAll { $0.project.id == id } }
    func repositories(projectID: String, referencedRepositories: [String]) async throws -> [RepositoryChoice] { [RepositoryChoice(id: "repo", nameWithOwner: "tester/app")] }
    func repository(named nameWithOwner: String) async throws -> RepositoryChoice { RepositoryChoice(id: "repo", nameWithOwner: nameWithOwner) }
    func assignableUsers(repository nameWithOwner: String) async throws -> [AssignableUser] { [AssignableUser(id: "user-id", login: "tester")] }
    func findUser(login: String) async throws -> AssignableUser { AssignableUser(id: "found-user", login: login) }
    func createItem(projectID: String, request: NewItemRequest) async throws -> ItemCreationResult {
        await creationGate?.wait()
        if let writeError { throw writeError }; writeCount += 1
        createdRequests.append(request)
        return ItemCreationResult(projectItemID: "created-item", issueURL: URL(string: "https://github.com/tester/app/issues/1"), warning: creationWarning)
    }
    func changeAssignee(item: ProjectItem, user: AssignableUser, assigned: Bool) async throws { if let writeError { throw writeError }; writeCount += 1 }
}

func fixtureSnapshot(id: String = "project", canUpdate: Bool = true) -> ProjectSnapshot {
    ProjectSnapshot(project: ProjectSummary(id: id, number: 1, title: id, url: URL(string: "https://github.com/users/tester/projects/1")!),
                    canUpdate: canUpdate,
                    fields: [SelectField(id: "status", name: "Status", options: [SelectOption(id: "todo", name: "Todo"), SelectOption(id: "done", name: "Done")])],
                    items: [ProjectItem(id: "item", contentID: "draft", kind: .draft, title: "Test", selections: ["status": "todo"])])
}
