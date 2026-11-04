import Foundation
import Observation

@MainActor @Observable
public final class AppModel {
    public private(set) var user: GitHubUser?
    public private(set) var owners: [ProjectOwner] = []
    public private(set) var selectedOwner: ProjectOwner?
    public private(set) var projects: [ProjectSummary] = []
    public private(set) var sharedProjects: [ProjectSummary] = []
    public private(set) var unseenSharedProjectIDs = Set<String>()
    public private(set) var isLoadingSharedProjects = false
    public private(set) var isCheckingMoreSharedProjects = false
    public private(set) var sharedProjectsError: String?
    public private(set) var selectedProjectID: String?
    public private(set) var snapshot: ProjectSnapshot?
    public private(set) var selectedFieldID: String?
    public private(set) var conversationOptionID: String?
    public private(set) var challenge: DeviceChallenge?
    public private(set) var isRestoring = true
    public private(set) var isAuthenticating = false
    public private(set) var hasSavedSession = false
    public private(set) var isLoadingProjects = false
    public private(set) var isLoadingProject = false
    public private(set) var isMutating = false
    public private(set) var isDemo = false
    public private(set) var lastSync: Date?
    public var errorMessage: String?
    public var notice: String?
    public var noticeURL: URL?

    private let session: CredentialSession
    private let oauth: any OAuthAuthenticating
    private let makeAPI: @Sendable (String) -> any ProjectsAPI
    private let preferences: UserDefaults
    private var demoAPI: DemoProjectsAPI?
    private var sessionGeneration = UUID()
    private var ownerGeneration = UUID()
    private var projectGeneration = UUID()
    private var projectOpeningGeneration = UUID()
    private var mutationGeneration = UUID()
    private var sharedProjectsGeneration = UUID()
    private var lastSharedProjectsAttempt: Date?
    private var collaboratingOwnersCache: [ProjectOwner]?
    private var collaboratingOwnersSync: Date?
    private var sharedOrganizationCache: [ProjectOwner] = []
    private var checkedSharedOwnerIDs = Set<String>()
    private var lastCheckedSharedOwnerID: String?
    private var sharedProjectsRetryAfter: Date?
    @ObservationIgnored private var sharedDiscoveryTask: Task<SharedProjectDiscovery, Error>?
    private var demoLinkedURLs: [String] = []
    private var demoSeenSharedIDs = Set<String>()
    @ObservationIgnored private var authTask: Task<Void, Never>?
    private var hasStarted = false

    public init(storage: any CredentialStorage = KeychainCredentialStorage(),
                oauth: any OAuthAuthenticating = DeviceOAuthClient(),
                preferences: UserDefaults = .standard,
                makeAPI: @escaping @Sendable (String) -> any ProjectsAPI = { GitHubClient(token: $0) }) {
        self.oauth = oauth; self.session = CredentialSession(storage: storage, oauth: oauth)
        self.preferences = preferences; self.makeAPI = makeAPI
    }

    public var selectedField: SelectField? { snapshot?.fields.first { $0.id == selectedFieldID } }
    public var canWrite: Bool { snapshot?.canUpdate == true && !isMutating && !isLoadingProject && !isAuthenticating }
    public var inaccessibleItemCount: Int { snapshot?.items.filter { $0.kind == .redacted }.count ?? 0 }
    public var conversationOption: SelectOption? { selectedField?.options.first { $0.id == conversationOptionID } }

    public func setConversationOption(_ id: String) {
        guard selectedField?.options.contains(where: { $0.id == id }) == true, let projectID = selectedProjectID else { return }
        conversationOptionID = id
        preferences.set(id, forKey: conversationPreference(projectID))
    }

    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await restoreSession()
    }

    public func restoreSession() async {
        let expected = sessionGeneration
        isRestoring = true; errorMessage = nil
        defer { if expected == sessionGeneration { isRestoring = false } }
        do {
            let found = try await session.restore()
            guard expected == sessionGeneration else { return }
            hasSavedSession = found
            guard found else { return }
            let api = try await client()
            let profile = try await api.currentUser()
            guard expected == sessionGeneration else { return }
            user = profile
            isRestoring = false
            await loadInitialProjects(profile: profile)
        } catch { await handle(error, session: expected) }
    }

    public func beginOAuth(clientID: String, includePrivateRepositories: Bool) {
        guard !isAuthenticating, !isDemo, !isMutating else { return }
        errorMessage = nil; notice = nil; isAuthenticating = true
        let expected = sessionGeneration
        authTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if expected == self.sessionGeneration { self.isAuthenticating = false; self.challenge = nil }
            }
            do {
                let code = try await self.oauth.begin(clientID: clientID, includePrivateRepositories: includePrivateRepositories)
                try Task.checkCancellation()
                guard expected == self.sessionGeneration else { return }
                self.challenge = code
                let credential = try await self.oauth.poll(code)
                try Task.checkCancellation()
                try await self.finishLogin(credential, expected: expected)
            } catch {
                if !Task.isCancelled, expected == self.sessionGeneration { self.errorMessage = error.localizedDescription }
            }
        }
    }

    public func cancelOAuth() {
        authTask?.cancel(); authTask = nil
        sessionGeneration = UUID()
        challenge = nil; isAuthenticating = false
        invalidateSharedProjectReads()
    }

    public func signIn(token: String) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !isAuthenticating, user == nil else { return }
        let expected = sessionGeneration
        isAuthenticating = true; errorMessage = nil
        defer { if expected == sessionGeneration { isAuthenticating = false } }
        do { try await finishLogin(Credential(accessToken: token), expected: expected) }
        catch { if expected == sessionGeneration { errorMessage = error.localizedDescription } }
    }

    private func finishLogin(_ credential: Credential, expected: UUID) async throws {
        let profile = try await makeAPI(credential.accessToken).currentUser()
        try Task.checkCancellation()
        guard expected == sessionGeneration else { return }
        let replacingSession = user != nil
        if let user, user.login.caseInsensitiveCompare(profile.login) != .orderedSame {
            throw FjordError.message(L10n.core("Authorize access with the same GitHub account you are signed in with. Your existing sign-in was kept."))
        }
        try await session.activate(credential)
        guard expected == sessionGeneration else { return }
        hasSavedSession = true; user = profile; isRestoring = false
        isAuthenticating = false; challenge = nil
        if replacingSession {
            // Discard reads made with the old token, retaining the selected shared project.
            sessionGeneration = UUID(); ownerGeneration = UUID(); projectGeneration = UUID()
            isLoadingProject = false; isLoadingProjects = false
            invalidateSharedProjectReads()
            await refresh()
            await refreshSharedProjects(force: true)
            return
        }
        await loadInitialProjects(profile: profile)
    }

    public func logout() async {
        invalidateSharedProjectReads()
        do {
            if !isDemo { try await session.clear() }
            cancelOAuth()
            ownerGeneration = UUID(); projectGeneration = UUID()
            let leavingDemo = isDemo
            user = nil; owners = []; selectedOwner = nil; projects = []; selectedProjectID = nil
            clearSharedProjects()
            snapshot = nil; selectedFieldID = nil; conversationOptionID = nil; lastSync = nil; isDemo = false; demoAPI = nil
            if !leavingDemo { hasSavedSession = false }
            isLoadingProject = false; isLoadingProjects = false; isMutating = false; isRestoring = false
            errorMessage = nil; notice = nil; noticeURL = nil
        } catch { errorMessage = error.localizedDescription }
    }

    public func startDemo() async {
        guard user == nil, !isAuthenticating else { return }
        sessionGeneration = UUID()
        demoAPI = DemoProjectsAPI(); isDemo = true; isRestoring = false; errorMessage = nil
        user = GitHubUser(login: "demo", name: "Demo workspace", nodeID: "demo-user")
        await loadInitialProjects(profile: user!)
    }

    private func loadInitialProjects(profile: GitHubUser) async {
        let expected = sessionGeneration
        let personal = ProjectOwner(login: profile.login, kind: .user)
        let savedSharedSelection = isDemo ? nil : preferences.string(forKey: sharedPreference("selection"))
        owners = [personal]
        await selectOwner(personal)
        guard expected == sessionGeneration else { return }
        let initialSelection = projectGeneration
        await refreshSharedProjects(force: true)
        guard expected == sessionGeneration, initialSelection == projectGeneration, !isDemo,
              let saved = savedSharedSelection,
              let project = sharedProjects.first(where: { $0.id == saved }) else { return }
        _ = await openProject(url: project.url.absoluteString)
    }

    /// Refresh discovery independently of board selection. An empty personal
    /// project list must not prevent another owner's shared board appearing.
    public func refreshSharedProjects(force: Bool = false) async {
        guard let user, !isAuthenticating, !isMutating, !isLoadingSharedProjects else { return }
        if sharedProjectsRetryAfter.map({ $0 > Date() }) == true { return }
        if !force, let lastSharedProjectsAttempt, Date().timeIntervalSince(lastSharedProjectsAttempt) < 60 { return }
        let expected = sessionGeneration, generation = UUID(), mutation = mutationGeneration
        sharedProjectsGeneration = generation; isLoadingSharedProjects = true
        lastSharedProjectsAttempt = Date()
        defer {
            if expected == sessionGeneration, generation == sharedProjectsGeneration {
                isLoadingSharedProjects = false; sharedDiscoveryTask = nil
            }
        }
        do {
            let api = try await client()
            guard expected == sessionGeneration, generation == sharedProjectsGeneration else { return }
            let cached = !force && collaboratingOwnersSync.map({ Date().timeIntervalSince($0) < 600 }) == true
                ? collaboratingOwnersCache : nil
            let known = owners + sharedProjects.compactMap(\.owner), organizations = sharedOrganizationCache
            let links = linkedSharedURLs, afterOwner = lastCheckedSharedOwnerID
            let work = Task {
                try await SharedProjectDiscovery.load(api: api, viewerLogin: user.login,
                    knownOwners: known, knownOrganizations: organizations, linkedURLs: links,
                    cachedCollaboratingOwners: cached, afterOwnerID: afterOwner)
            }
            sharedDiscoveryTask = work
            let result = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            guard expected == sessionGeneration, generation == sharedProjectsGeneration,
                  mutation == mutationGeneration, !isMutating, !Task.isCancelled else { return }
            if let discovered = result.collaboratingOwners {
                collaboratingOwnersCache = discovered; collaboratingOwnersSync = Date()
            }
            sharedOrganizationCache = result.organizations
            lastCheckedSharedOwnerID = result.lastCheckedOwnerID
            checkedSharedOwnerIDs.formIntersection(result.candidateOwnerIDs)
            checkedSharedOwnerIDs.formUnion(result.checkedOwnerIDs)
            isCheckingMoreSharedProjects = !result.candidateOwnerIDs.subtracting(checkedSharedOwnerIDs).isEmpty
            for owner in result.organizations where !owners.contains(where: { $0.id.lowercased() == owner.id.lowercased() }) {
                owners.append(owner)
            }
            var byID = Dictionary(result.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for old in sharedProjects {
                let ownerID = old.owner?.id.lowercased() ?? ""
                if !result.checkedOwnerIDs.contains(ownerID) || result.failedOwnerIDs.contains(ownerID) { byID[old.id] = old }
            }
            sharedProjects = byID.values.sorted(by: SharedProjectDiscovery.order)
            unseenSharedProjectIDs = Set(sharedProjects.map(\.id)).subtracting(seenSharedIDs)
            sharedProjectsError = result.isIncomplete
                ? L10n.core("Some shared projects could not be checked. Previously loaded projects are kept. Try refreshing again.") : nil
        } catch {
            guard expected == sessionGeneration, generation == sharedProjectsGeneration else { return }
            if (error as? FjordError) == .unauthenticated { await handle(error, session: expected) }
            else if case .rateLimited(let reset) = error as? FjordError {
                sharedProjectsRetryAfter = max(Date().addingTimeInterval(60), reset ?? Date().addingTimeInterval(60))
                sharedProjectsError = error.localizedDescription
            }
            else if !(error is CancellationError), (error as? FjordError) != .cancelled {
                sharedProjectsError = L10n.core("Shared projects could not be checked. Your sign-in and current project were kept. Try refreshing again.")
            }
        }
    }

    public func refreshWorkspace() async {
        await refresh()
        await refreshSharedProjects(force: true)
    }

    public func selectOwner(_ owner: ProjectOwner) async {
        guard user != nil, !isMutating else { return }
        let sessionID = sessionGeneration
        let generation = UUID(); ownerGeneration = generation
        projectGeneration = UUID()
        selectedOwner = owner; projects = []; selectedProjectID = nil; snapshot = nil
        selectedFieldID = nil; conversationOptionID = nil; lastSync = nil; isLoadingProject = false
        isLoadingProjects = true; errorMessage = nil; notice = nil
        defer { if ownerGeneration == generation { isLoadingProjects = false } }
        do {
            let result = try await client().projects(owner: owner)
            guard sessionID == sessionGeneration, ownerGeneration == generation else { return }
            projects = result
            let savedID = preferences.string(forKey: projectPreference(owner))
            if let project = result.first(where: { $0.id == savedID }) ?? result.first {
                await selectProject(project)
            }
        } catch { await handle(error, session: sessionID, owner: generation) }
    }

    public func reloadProjects() async {
        guard let owner = selectedOwner else { return }
        await selectOwner(owner)
        await refreshSharedProjects(force: true)
    }

    public func selectProject(_ project: ProjectSummary) async {
        guard user != nil, !isMutating else { return }
        let expected = sessionGeneration
        let generation = UUID(); projectGeneration = generation
        selectedProjectID = project.id; snapshot = nil; selectedFieldID = nil; conversationOptionID = nil; lastSync = nil
        isLoadingProject = true; errorMessage = nil; notice = nil
        defer { if generation == projectGeneration { isLoadingProject = false } }
        do {
            let loaded = try await client().snapshot(project: project)
            guard expected == sessionGeneration, generation == projectGeneration else { return }
            apply(loaded)
            if let owner = selectedOwner { preferences.set(project.id, forKey: projectPreference(owner)) }
            rememberSharedProject(loaded.project)
            if !isDemo, loaded.project.owner?.login.caseInsensitiveCompare(user?.login ?? "") == .orderedSame {
                preferences.removeObject(forKey: sharedPreference("selection"))
            }
        } catch { await handle(error, session: expected, project: generation) }
    }

    @discardableResult public func openProject(url: String) async -> Bool {
        guard user != nil, !isMutating else { return false }
        let expected = sessionGeneration, selection = projectGeneration, mutation = mutationGeneration
        let request = UUID(); projectOpeningGeneration = request
        do {
            let reference = try ProjectReference(url: url)
            let project = try await client().resolve(reference)
            guard expected == sessionGeneration, selection == projectGeneration,
                  request == projectOpeningGeneration, mutation == mutationGeneration, !isMutating else { return false }
            ownerGeneration = UUID()
            let changingOwner = selectedOwner?.id.lowercased() != reference.owner.id.lowercased()
            selectedOwner = reference.owner
            if !owners.contains(reference.owner) { owners.append(reference.owner) }
            if changingOwner { projects = [project] }
            else if !projects.contains(where: { $0.id == project.id }) { projects.append(project) }
            isLoadingProjects = false
            await selectProject(project)
            return expected == sessionGeneration && snapshot?.project.id == project.id
        } catch {
            guard request == projectOpeningGeneration, selection == projectGeneration else { return false }
            await handle(error, session: expected); return false
        }
    }

    public func setGrouping(_ id: String) {
        guard snapshot?.fields.contains(where: { $0.id == id }) == true else { return }
        selectedFieldID = id
        if let id = snapshot?.project.id { preferences.set(selectedFieldID, forKey: "field.\(id)") }
        restoreConversationOption()
    }

    public func refresh() async {
        guard let project = snapshot?.project ?? projects.first(where: { $0.id == selectedProjectID }),
              !isMutating, !isLoadingProject, !isLoadingProjects, !isAuthenticating else { return }
        let expected = sessionGeneration, generation = projectGeneration
        isLoadingProject = true
        defer { if generation == projectGeneration { isLoadingProject = false } }
        do {
            let loaded = try await client().snapshot(project: project)
            guard expected == sessionGeneration, generation == projectGeneration else { return }
            apply(loaded); errorMessage = nil
        } catch { await handle(error, session: expected, project: generation) }
    }

    @discardableResult public func changeStatus(itemID: String, optionID: String?) async -> Bool {
        guard let snapshot, let field = selectedField, let item = snapshot.items.first(where: { $0.id == itemID }),
              optionID == nil || field.options.contains(where: { $0.id == optionID }) else { return false }
        if item.selections[field.id] == optionID { return true }
        return await mutate(projectID: snapshot.project.id, operation: { api in
            try await api.setSelection(projectID: snapshot.project.id, itemID: itemID, fieldID: field.id, optionID: optionID)
        }, confirmed: {
            guard let index = self.snapshot?.items.firstIndex(where: { $0.id == itemID }) else { return }
            self.snapshot?.items[index].selections[field.id] = optionID
        })
    }

    @discardableResult public func saveItem(projectID: String, original: ProjectItem, title: String, body: String) async -> Bool {
        guard let summary = snapshot?.project, summary.id == projectID, original.canEditContent else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { errorMessage = L10n.core("The item must have a title."); return false }
        return await mutate(projectID: projectID, operation: { api in
            let fresh = try await api.snapshot(project: summary)
            guard let current = fresh.items.first(where: { $0.id == original.id }),
                  current.title == original.title, current.body == original.body else {
                throw FjordError.message(L10n.core("The item changed on GitHub while you were editing. Close the editor and refresh before trying again."))
            }
            try await api.updateContent(item: current, title: title, body: body)
        }, confirmed: {
            guard let index = self.snapshot?.items.firstIndex(where: { $0.id == original.id }) else { return }
            self.snapshot?.items[index].title = title; self.snapshot?.items[index].body = body
        })
    }

    @discardableResult public func createDraft(projectID: String, title: String, body: String) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { errorMessage = L10n.core("The item must have a title."); return false }
        return await mutate(projectID: projectID, operation: { try await $0.addDraft(projectID: projectID, title: title, body: body) })
    }

    @discardableResult public func createItem(projectID: String, request: NewItemRequest) async -> Bool {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { errorMessage = L10n.core("The item must have a title."); return false }
        if let placement = request.placement {
            guard snapshot?.project.id == projectID,
                  snapshot?.fields.contains(where: { $0.id == placement.fieldID && $0.options.contains(where: { $0.id == placement.optionID }) }) == true else {
                errorMessage = L10n.core("The column changed or was removed. Refresh the project before creating the item.")
                return false
            }
        }
        let input = NewItemRequest(title: title, body: request.body, repositoryID: request.repositoryID,
                                   assigneeIDs: request.assigneeIDs, placement: request.placement)
        let expected = sessionGeneration, generation = projectGeneration
        var result: ItemCreationResult?
        let success = await mutate(projectID: projectID, operation: { result = try await $0.createItem(projectID: projectID, request: input) })
        if success, expected == sessionGeneration, generation == projectGeneration {
            if let warning = result?.warning { notice = warning }
            if notice != nil { noticeURL = result?.issueURL }
        }
        return success
    }

    @discardableResult public func createProject(owner: ProjectOwner, title: String) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard user != nil, !isMutating, !title.isEmpty, owners.contains(owner) else { return false }
        let expected = sessionGeneration
        let operationID = UUID(); mutationGeneration = operationID
        ownerGeneration = UUID(); projectGeneration = UUID()
        isLoadingProject = false; isLoadingProjects = false
        isMutating = true; errorMessage = nil; notice = nil; noticeURL = nil
        defer { if expected == sessionGeneration, operationID == mutationGeneration { isMutating = false } }
        do {
            let api = try await client()
            guard expected == sessionGeneration else { return false }
            let created = try await api.createProject(owner: owner, title: title)
            guard expected == sessionGeneration else { return true }
            if selectedOwner == owner { projects.insert(created, at: 0) }
            else { selectedOwner = owner; projects = [created] }
            isMutating = false
            await selectProject(created)
            if expected == sessionGeneration, selectedProjectID == created.id, snapshot == nil {
                notice = L10n.core("The project was created on GitHub. Select it in the list to try loading it again.")
            }
            return true
        } catch { await handle(error, session: expected); return false }
    }

    @discardableResult public func deleteProject(projectID: String, confirmationTitle: String) async -> Bool {
        guard canWrite, let project = snapshot?.project, project.id == projectID,
              confirmationTitle == project.title else { return false }
        let expected = sessionGeneration
        let operationID = UUID(); mutationGeneration = operationID
        isMutating = true; errorMessage = nil; notice = nil; noticeURL = nil
        defer { if expected == sessionGeneration, operationID == mutationGeneration { isMutating = false } }
        do {
            let api = try await client()
            guard expected == sessionGeneration else { return false }
            try await api.deleteProject(id: projectID)
            guard expected == sessionGeneration else { return true }
            ownerGeneration = UUID(); projectGeneration = UUID()
            projects.removeAll { $0.id == projectID }
            sharedProjects.removeAll { $0.id == projectID }
            unseenSharedProjectIDs.remove(projectID)
            linkedSharedURLs = linkedSharedURLs.filter { $0 != project.url.absoluteString }
            if let owner = selectedOwner { preferences.removeObject(forKey: projectPreference(owner)) }
            snapshot = nil; selectedProjectID = nil; selectedFieldID = nil; conversationOptionID = nil; lastSync = nil
            isMutating = false
            if let next = projects.first { await selectProject(next) }
            return true
        } catch { await handle(error, session: expected); return false }
    }

    public func loadRepositories(projectID: String) async -> [RepositoryChoice] {
        guard let snapshot, snapshot.project.id == projectID else { return [] }
        let expected = sessionGeneration, generation = projectGeneration
        do {
            let names = Array(Set(snapshot.items.compactMap(\.repository))).sorted()
            let result = try await client().repositories(projectID: projectID, referencedRepositories: names)
            guard expected == sessionGeneration, generation == projectGeneration else { return [] }
            return result.filter { $0.hasIssuesEnabled && !$0.isArchived }
        } catch { await handle(error, session: expected, project: generation); return [] }
    }

    public func findRepository(named name: String, projectID: String) async -> RepositoryChoice? {
        guard selectedProjectID == projectID else { return nil }
        let expected = sessionGeneration, generation = projectGeneration
        do {
            let repository = try await client().repository(named: name)
            guard expected == sessionGeneration, generation == projectGeneration else { return nil }
            guard repository.hasIssuesEnabled, !repository.isArchived else { throw FjordError.message(L10n.core("This repository does not accept new issues.")) }
            return repository
        } catch { await handle(error, session: expected, project: generation); return nil }
    }

    public func assignmentCandidates(projectID: String, repository: String?) async -> [AssignableUser] {
        guard let snapshot, snapshot.project.id == projectID else { return [] }
        let expected = sessionGeneration, generation = projectGeneration
        var users = snapshot.items.flatMap(\.assignees)
        if let id = user?.nodeID, let login = user?.login { users.append(AssignableUser(id: id, login: login, name: user?.name)) }
        do {
            let api = try await client()
            let repositories = repository.map { [$0] } ?? Array(Set(snapshot.items.compactMap(\.repository))).sorted()
            for name in repositories { users += try await api.assignableUsers(repository: name) }
            guard expected == sessionGeneration, generation == projectGeneration else { return [] }
        } catch { await handle(error, session: expected, project: generation) }
        guard expected == sessionGeneration, generation == projectGeneration else { return [] }
        var unique: [String: AssignableUser] = [:]
        for person in users { unique[person.id] = person }
        return unique.values.sorted { $0.login.localizedCaseInsensitiveCompare($1.login) == .orderedAscending }
    }

    public func findAssignee(login: String, projectID: String) async -> AssignableUser? {
        guard selectedProjectID == projectID else { return nil }
        let expected = sessionGeneration, generation = projectGeneration
        do {
            let person = try await client().findUser(login: login)
            guard expected == sessionGeneration, generation == projectGeneration else { return nil }
            return person
        } catch { await handle(error, session: expected, project: generation); return nil }
    }

    @discardableResult public func changeAssignee(projectID: String, itemID: String, person: AssignableUser, assigned: Bool) async -> Bool {
        guard snapshot?.project.id == projectID,
              let item = snapshot?.items.first(where: { $0.id == itemID }), item.kind != .redacted,
              item.canEditContent else { return false }
        return await mutate(projectID: projectID, operation: { try await $0.changeAssignee(item: item, user: person, assigned: assigned) })
    }

    @discardableResult public func addColumn(projectID: String, name: String) async -> Bool {
        // Live option-list replacement has no compare-and-swap on GitHub. Keep
        // column creation in GitHub's own UI; only the isolated demo mutates here.
        guard isDemo, let demoAPI, let field = selectedField else {
            errorMessage = L10n.core("Add the column on GitHub, then refresh the project here.")
            return false
        }
        return await mutate(projectID: projectID, operation: { _ in try await demoAPI.addColumn(projectID: projectID, fieldID: field.id, name: name) })
    }

    @discardableResult public func deleteColumn(projectID: String, optionID: String) async -> Bool {
        guard isDemo, let demoAPI, let field = selectedField else {
            errorMessage = L10n.core("Delete the status option in the project's GitHub field settings, then refresh here.")
            return false
        }
        return await mutate(projectID: projectID, operation: { _ in try await demoAPI.deleteColumn(projectID: projectID, fieldID: field.id, optionID: optionID) })
    }

    @discardableResult public func grantAccess(projectID: String, username: String, role: CollaboratorRole) async -> Bool {
        let expected = sessionGeneration, generation = projectGeneration
        let success = await mutate(projectID: projectID, operation: { try await $0.grantAccess(projectID: projectID, username: username, role: role) })
        if success, expected == sessionGeneration, generation == projectGeneration { notice = L10n.core("Project access was updated on GitHub for @%@.", username) }
        return success
    }

    @discardableResult public func sendMessage(projectID: String, optionID: String, text: String) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 60_000 else {
            errorMessage = L10n.core("Write a message between 1 and 60,000 characters.")
            return false
        }
        guard let authorID = user?.nodeID, let field = selectedField,
              field.options.contains(where: { $0.id == optionID }) else {
            errorMessage = L10n.core("Choose a chat column and sign in with a valid GitHub account.")
            return false
        }
        let expected = sessionGeneration, generation = projectGeneration
        var result: ChatSendResult?
        let success = await mutate(projectID: projectID, operation: { api in
            result = try await api.sendChatMessage(projectID: projectID, fieldID: field.id, optionID: optionID, authorID: authorID, text: text)
        }, confirmed: {
            guard let item = result?.item else { return }
            self.snapshot?.items.removeAll { $0.id == item.id }
            self.snapshot?.items.append(item)
            self.lastSync = Date()
        }, reload: false)
        if success, expected == sessionGeneration, generation == projectGeneration, case .placementUnconfirmed(_, let explanation) = result {
            notice = L10n.core("The message was created and assigned to you, but its placement could not be confirmed. Check chat and drafts without a status; do not send it again. %@", explanation)
            await refresh()
        }
        return success
    }

    private func mutate(projectID: String, operation: (any ProjectsAPI) async throws -> Void,
                        confirmed: () -> Void = {}, reload: Bool = true) async -> Bool {
        guard canWrite, let summary = snapshot?.project, summary.id == projectID else { return false }
        let expected = sessionGeneration, generation = projectGeneration
        let operationID = UUID(); mutationGeneration = operationID
        isMutating = true; errorMessage = nil; notice = nil; noticeURL = nil
        defer { if expected == sessionGeneration, operationID == mutationGeneration { isMutating = false } }
        do {
            let api = try await client()
            guard expected == sessionGeneration, generation == projectGeneration else { return false }
            try await operation(api)
            guard expected == sessionGeneration, generation == projectGeneration else { return true }
            confirmed()
            guard reload else { return true }
            do {
                let loaded = try await api.snapshot(project: summary)
                guard expected == sessionGeneration, generation == projectGeneration else { return true }
                apply(loaded)
            } catch {
                // The write succeeded. Do not report it as failed and invite a duplicate retry.
                guard expected == sessionGeneration, generation == projectGeneration else { return true }
                notice = L10n.core("The change was saved on GitHub. The view could not be refreshed; try Refresh.")
                await handle(error, session: expected, project: generation)
            }
            return true
        } catch {
            await handle(error, session: expected, project: generation)
            return false
        }
    }

    private func apply(_ loaded: ProjectSnapshot) {
        snapshot = loaded; lastSync = Date()
        if !loaded.fields.contains(where: { $0.id == selectedFieldID }) {
            let saved = preferences.string(forKey: "field.\(loaded.project.id)")
            selectedFieldID = loaded.fields.first(where: { $0.id == saved })?.id
                ?? loaded.fields.first(where: { $0.name.lowercased() == "status" })?.id ?? loaded.fields.first?.id
        }
        if let index = projects.firstIndex(where: { $0.id == loaded.project.id }) { projects[index] = loaded.project }
        if let index = sharedProjects.firstIndex(where: { $0.id == loaded.project.id }) { sharedProjects[index] = loaded.project }
        restoreConversationOption()
    }

    private func conversationPreference(_ projectID: String) -> String { "chatColumn.\(projectID).\(selectedFieldID ?? "")" }
    private func restoreConversationOption() {
        guard let field = selectedField, let projectID = selectedProjectID else { conversationOptionID = nil; return }
        let stored = preferences.string(forKey: conversationPreference(projectID))
            ?? preferences.string(forKey: "chatColumn.\(projectID)")
        conversationOptionID = field.options.first(where: { $0.id == stored })?.id
            ?? field.options.first(where: { ["samtale", "chat"].contains($0.name.lowercased()) })?.id
    }

    private func projectPreference(_ owner: ProjectOwner) -> String { "project.\(user?.login ?? "").\(owner.id)" }

    private func sharedPreference(_ name: String) -> String { "sharedProjects.\(user?.nodeID ?? user?.login.lowercased() ?? "").\(name)" }
    private var linkedSharedURLs: [String] {
        get { isDemo ? demoLinkedURLs : preferences.stringArray(forKey: sharedPreference("urls")) ?? [] }
        set {
            if isDemo { demoLinkedURLs = newValue }
            else { preferences.set(newValue, forKey: sharedPreference("urls")) }
        }
    }
    private var seenSharedIDs: Set<String> {
        get { isDemo ? demoSeenSharedIDs : Set(preferences.stringArray(forKey: sharedPreference("seen")) ?? []) }
        set {
            if isDemo { demoSeenSharedIDs = newValue }
            else { preferences.set(newValue.sorted(), forKey: sharedPreference("seen")) }
        }
    }
    private func rememberSharedProject(_ project: ProjectSummary) {
        guard let owner = project.owner, let user,
              owner.kind != .user || owner.login.caseInsensitiveCompare(user.login) != .orderedSame else { return }
        invalidateSharedProjectReads()
        var projects = Dictionary(sharedProjects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        projects[project.id] = project
        sharedProjects = projects.values.sorted(by: SharedProjectDiscovery.order)
        // Persist canonical project links, never invitation queries or credentials.
        let category = owner.kind == .user ? "users" : "orgs"
        let canonical = "https://github.com/\(category)/\(owner.login)/projects/\(project.number)"
        linkedSharedURLs = Array(Set(linkedSharedURLs + [canonical])).sorted()
        seenSharedIDs.insert(project.id)
        unseenSharedProjectIDs.remove(project.id)
        if !isDemo { preferences.set(project.id, forKey: sharedPreference("selection")) }
    }
    private func invalidateSharedProjectReads() {
        sharedDiscoveryTask?.cancel(); sharedDiscoveryTask = nil
        sharedProjectsGeneration = UUID(); isLoadingSharedProjects = false
        lastSharedProjectsAttempt = nil; collaboratingOwnersCache = nil; collaboratingOwnersSync = nil
    }
    private func clearSharedProjects() {
        invalidateSharedProjectReads()
        sharedProjects = []; unseenSharedProjectIDs = []; sharedProjectsError = nil
        sharedOrganizationCache = []
        checkedSharedOwnerIDs = []; lastCheckedSharedOwnerID = nil
        isCheckingMoreSharedProjects = false; sharedProjectsRetryAfter = nil
        demoLinkedURLs = []; demoSeenSharedIDs = []
    }
    private func client() async throws -> any ProjectsAPI {
        if let demoAPI { return demoAPI }
        return makeAPI(try await session.accessToken())
    }

    private func handle(_ error: Error, session expected: UUID, owner: UUID? = nil, project: UUID? = nil) async {
        guard expected == sessionGeneration, owner.map({ $0 == ownerGeneration }) ?? true,
              project.map({ $0 == projectGeneration }) ?? true else { return }
        if error is CancellationError || (error as? FjordError) == .cancelled { return }
        if (error as? FjordError) == .unauthenticated {
            do { try await session.clear() }
            catch { errorMessage = L10n.core("The sign-in is invalid, and the Keychain entry could not be cleared: %@", error.localizedDescription); return }
            guard expected == sessionGeneration else { return }
            cancelOAuth(); ownerGeneration = UUID(); projectGeneration = UUID()
            user = nil; snapshot = nil; projects = []; owners = []; selectedOwner = nil; selectedProjectID = nil
            clearSharedProjects()
            selectedFieldID = nil; conversationOptionID = nil; hasSavedSession = false; isRestoring = false
            isLoadingProjects = false; isLoadingProject = false; isMutating = false
        }
        errorMessage = error.localizedDescription
    }
}
