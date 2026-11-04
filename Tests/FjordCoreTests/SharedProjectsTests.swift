import Foundation
import Testing
@testable import FjordCore

private let sharedOwner = ProjectOwner(login: "colleague", kind: .user)

private func sharedFixture(_ id: String = "shared", owner: ProjectOwner = sharedOwner, number: Int = 1,
                           isPublic: Bool = false, canUpdate: Bool = false) -> ProjectSnapshot {
    let kind = owner.kind == .user ? "users" : "orgs"
    let project = ProjectSummary(id: id, number: number, title: id,
                                url: URL(string: "https://github.com/\(kind)/\(owner.login)/projects/\(number)")!,
                                isPublic: isPublic, viewerCanUpdate: canUpdate)
    return ProjectSnapshot(project: project, canUpdate: canUpdate, fields: [], items: [])
}

@MainActor
struct SharedProjectsTests {
    private func preferences() -> UserDefaults { UserDefaults(suiteName: "Fjord.shared.tests.\(UUID())")! }
    private func model(_ api: WorkspaceAPI, preferences: UserDefaults? = nil, storage: MemoryStorage = MemoryStorage()) -> AppModel {
        AppModel(storage: storage, oauth: MockOAuth(), preferences: preferences ?? self.preferences(), makeAPI: { _ in api })
    }

    @Test func discoversVerifiedPrivateWritableAndOrganizationBoardsWithoutPublicNoise() async throws {
        let org = ProjectOwner(login: "team", kind: .organization)
        let api = WorkspaceAPI(data: [fixtureSnapshot(), sharedFixture(),
                                      sharedFixture("public-write", number: 2, isPublic: true, canUpdate: true),
                                      sharedFixture("public-read", number: 3, isPublic: true),
                                      sharedFixture("team-board", owner: org, isPublic: true)])
        await api.configureDiscovery(owners: [sharedOwner, sharedOwner], organizations: [org])
        let subject = model(api)
        await subject.signIn(token: "fixture")
        #expect(Set(subject.sharedProjects.map(\.id)) == ["shared", "public-write", "team-board"])
        #expect(subject.unseenSharedProjectIDs.count == 3)
        #expect(subject.selectedProjectID == "project")
        #expect(subject.projects.map(\.id) == ["project"])
        #expect(subject.owners.contains(org))
        #expect(await api.writes() == 0)
    }

    @Test func discoversAndOpensSharedBoardWhenTheViewerOwnsNoProjects() async throws {
        let api = WorkspaceAPI(data: [sharedFixture(canUpdate: true)])
        await api.configureDiscovery(owners: [sharedOwner])
        let subject = model(api)
        await subject.signIn(token: "fixture")
        #expect(subject.snapshot == nil)
        let project = try #require(subject.sharedProjects.first)
        #expect(await subject.openProject(url: project.url.absoluteString))
        #expect(subject.selectedOwner == sharedOwner)
        #expect(subject.snapshot?.project.id == "shared")
        #expect(subject.canWrite)
        #expect(subject.unseenSharedProjectIDs.isEmpty)
    }

    @Test func laterSharesAppearAndRevokedAccessDisappearsWithoutChangingTheBoard() async throws {
        let api = WorkspaceAPI()
        await api.configureDiscovery(owners: [sharedOwner])
        let subject = model(api)
        await subject.signIn(token: "fixture")
        let initial = subject.snapshot
        await api.replaceProjects([fixtureSnapshot(), sharedFixture()])
        await subject.refreshSharedProjects(force: true)
        #expect(subject.sharedProjects.map(\.id) == ["shared"])
        #expect(subject.unseenSharedProjectIDs == ["shared"])
        #expect(subject.snapshot == initial)
        await api.replaceProjects([fixtureSnapshot()])
        await subject.refreshSharedProjects(force: true)
        #expect(subject.sharedProjects.isEmpty)
        #expect(subject.unseenSharedProjectIDs.isEmpty)
        #expect(subject.snapshot == initial)
    }

    @Test func failedOwnerCheckKeepsThePreviousCatalogAndSessionThenRecovers() async throws {
        let api = WorkspaceAPI(data: [fixtureSnapshot(), sharedFixture()]), storage = MemoryStorage()
        await api.configureDiscovery(owners: [sharedOwner])
        let subject = model(api, storage: storage)
        await subject.signIn(token: "fixture")
        await api.configureDiscovery(owners: [sharedOwner], failures: [sharedOwner.id: .http(403, "No permission")])
        await subject.refreshSharedProjects(force: true)
        #expect(subject.sharedProjects.map(\.id) == ["shared"])
        #expect(subject.sharedProjectsError != nil)
        #expect(subject.user != nil && subject.snapshot != nil)
        #expect(try storage.load() != nil)
        await api.configureDiscovery(owners: [sharedOwner])
        await subject.refreshSharedProjects(force: true)
        #expect(subject.sharedProjectsError == nil)
    }

    @Test func repositoryLookupFailureStillChecksPreviouslyDiscoveredOwners() async throws {
        let api = WorkspaceAPI(data: [fixtureSnapshot(), sharedFixture()])
        await api.configureDiscovery(owners: [sharedOwner])
        let subject = model(api)
        await subject.signIn(token: "fixture")
        await api.configureDiscovery(owners: [], repositoryError: .http(503, "offline"))
        await api.replaceProjects([fixtureSnapshot(), sharedFixture("renamed", number: 2)])
        await subject.refreshSharedProjects(force: true)
        #expect(subject.sharedProjects.map(\.id) == ["renamed"])
        #expect(subject.sharedProjectsError != nil)
        #expect(subject.user != nil)
    }

    @Test func temporaryMembershipLookupFailureKeepsKnownOrganizationBoards() async throws {
        let org = ProjectOwner(login: "team", kind: .organization)
        let api = WorkspaceAPI(data: [fixtureSnapshot(), sharedFixture("team-board", owner: org, isPublic: true)])
        await api.configureDiscovery(owners: [], organizations: [org])
        let subject = model(api)
        await subject.signIn(token: "fixture")
        await api.configureDiscovery(owners: [], organizationError: .http(503, "offline"))
        await subject.refreshSharedProjects(force: true)
        #expect(subject.sharedProjects.map(\.id) == ["team-board"])
        #expect(subject.sharedProjectsError != nil)
        await api.configureDiscovery(owners: [], organizations: [])
        await subject.refreshSharedProjects(force: true)
        #expect(subject.sharedProjects.isEmpty)
        #expect(subject.sharedProjectsError == nil)
    }

    @Test func logoutDuringDiscoveryCannotRestorePrivateCatalogData() async throws {
        let gate = Gate(), api = WorkspaceAPI(data: [fixtureSnapshot(), sharedFixture()])
        await api.configureDiscovery(owners: [sharedOwner], gate: gate, gatedOwner: sharedOwner.id)
        let subject = model(api)
        let login = Task { await subject.signIn(token: "fixture") }
        await gate.waitUntilRequested()
        await subject.logout()
        await gate.open(); await login.value
        #expect(subject.user == nil)
        #expect(subject.sharedProjects.isEmpty)
        #expect(subject.unseenSharedProjectIDs.isEmpty)
        #expect(!subject.isLoadingSharedProjects)
    }

    @Test func changingBoardDuringDiscoveryPreservesTheNewSelection() async throws {
        let api = WorkspaceAPI(data: [fixtureSnapshot(), fixtureSnapshot(id: "second"), sharedFixture()])
        await api.configureDiscovery(owners: [])
        let subject = model(api)
        await subject.signIn(token: "fixture")
        let gate = Gate()
        await api.configureDiscovery(owners: [sharedOwner], gate: gate, gatedOwner: sharedOwner.id)
        let refresh = Task { await subject.refreshSharedProjects(force: true) }
        await gate.waitUntilRequested()
        await subject.selectProject(fixtureSnapshot(id: "second").project)
        await gate.open(); await refresh.value
        #expect(subject.selectedProjectID == "second")
        #expect(subject.snapshot?.project.id == "second")
        #expect(subject.sharedProjects.map(\.id) == ["shared"])
    }

    @Test func linksAndSharedSelectionSurviveRestartAndFindFurtherSharesFromThatOwner() async throws {
        let prefs = preferences(), api = WorkspaceAPI(data: [fixtureSnapshot(), sharedFixture(isPublic: true)])
        await api.configureDiscovery(owners: [])
        let first = model(api, preferences: prefs)
        await first.signIn(token: "fixture")
        #expect(first.sharedProjects.isEmpty)
        #expect(await first.openProject(url: "https://github.com/users/colleague/projects/1/views/2?invitation=fixture-only"))
        let links = try #require(prefs.stringArray(forKey: "sharedProjects.user-id.urls"))
        #expect(links == ["https://github.com/users/colleague/projects/1"])
        await api.replaceProjects([fixtureSnapshot(), sharedFixture(isPublic: true), sharedFixture("new-share", number: 2)])
        let restored = model(api, preferences: prefs)
        await restored.signIn(token: "fixture")
        #expect(restored.snapshot?.project.id == "shared")
        #expect(Set(restored.sharedProjects.map(\.id)) == ["shared", "new-share"])
        #expect(restored.unseenSharedProjectIDs == ["new-share"])
        #expect(restored.sharedProjectsError == nil)
    }

    @Test func savedLinksAndNewBadgesAreIsolatedBetweenGitHubAccounts() async throws {
        let prefs = preferences(), api = WorkspaceAPI(data: [fixtureSnapshot(), sharedFixture()])
        await api.configureDiscovery(owners: [sharedOwner])
        let first = model(api, preferences: prefs)
        await first.signIn(token: "fixture-first")
        #expect(await first.openProject(url: "https://github.com/users/colleague/projects/1"))
        await first.logout()
        let otherAPI = WorkspaceAPI(data: [])
        await otherAPI.changeProfileLogin("other", nodeID: "other-id")
        await otherAPI.configureDiscovery(owners: [])
        let other = model(otherAPI, preferences: prefs)
        await other.signIn(token: "fixture-other")
        #expect(other.sharedProjects.isEmpty)
        #expect(other.selectedProjectID == nil)
        #expect(!prefs.dictionaryRepresentation().values.contains { String(describing: $0).contains("fixture-first") })
    }

    @Test func revokedCredentialClearsDiscoveryAndSavedSession() async throws {
        let api = WorkspaceAPI(data: [fixtureSnapshot(), sharedFixture()]), storage = MemoryStorage()
        await api.configureDiscovery(owners: [sharedOwner])
        let subject = model(api, storage: storage)
        await subject.signIn(token: "fixture")
        await api.configureDiscovery(owners: [], repositoryError: .unauthenticated)
        await subject.refreshSharedProjects(force: true)
        #expect(subject.user == nil)
        #expect(subject.sharedProjects.isEmpty)
        #expect(try storage.load() == nil)
    }

    @Test func periodicChecksAreThrottledButManualRefreshCanFindNewOwners() async throws {
        let api = WorkspaceAPI()
        await api.configureDiscovery(owners: [])
        let subject = model(api)
        await subject.signIn(token: "fixture")
        await subject.refreshSharedProjects()
        #expect(await api.discoveryCount() == 1)
        await api.replaceProjects([fixtureSnapshot(), sharedFixture()])
        await api.configureDiscovery(owners: [sharedOwner])
        await subject.refreshWorkspace()
        #expect(await api.discoveryCount() == 2)
        #expect(subject.sharedProjects.map(\.id) == ["shared"])
    }

    @Test func demoDiscoversSharedBoardWithoutUsingLiveClientsOrPersistingLinks() async throws {
        let prefs = preferences()
        let subject = AppModel(storage: MemoryStorage(), oauth: MockOAuth(), preferences: prefs,
                               makeAPI: { _ in Issue.record("Demo requested a live API"); return WorkspaceAPI() })
        await subject.startDemo()
        let project = try #require(subject.sharedProjects.first)
        #expect(project.owner?.login == "maren")
        #expect(await subject.openProject(url: project.url.absoluteString))
        #expect(subject.snapshot?.project.id == project.id)
        #expect(!prefs.dictionaryRepresentation().keys.contains { $0.hasPrefix("sharedProjects.") })
    }

    @Test func slowerProjectLinkCannotOverrideTheLatestProjectOpen() async throws {
        let api = WorkspaceAPI(data: [fixtureSnapshot(), sharedFixture()])
        await api.configureDiscovery(owners: [sharedOwner])
        let subject = model(api)
        await subject.signIn(token: "fixture")
        let gate = Gate()
        await api.configureResolveGate(gate, owner: sharedOwner.id)
        let old = Task { await subject.openProject(url: "https://github.com/users/colleague/projects/1") }
        await gate.waitUntilRequested()
        #expect(await subject.openProject(url: "https://github.com/users/tester/projects/1"))
        await gate.open()
        #expect(await old.value == false)
        #expect(subject.snapshot?.project.id == "project")
        #expect(subject.selectedOwner?.login == "tester")
    }

    @Test func discoveryStartedBeforeDeletionCannotBringTheDeletedBoardBack() async throws {
        let api = WorkspaceAPI(data: [fixtureSnapshot(), sharedFixture(canUpdate: true)])
        await api.configureDiscovery(owners: [sharedOwner])
        let subject = model(api)
        await subject.signIn(token: "fixture")
        #expect(await subject.openProject(url: "https://github.com/users/colleague/projects/1"))
        let gate = Gate()
        await api.configureDiscovery(owners: [sharedOwner], gate: gate, gatedOwner: sharedOwner.id)
        let read = Task { await subject.refreshSharedProjects(force: true) }
        await gate.waitUntilRequested()
        #expect(await subject.deleteProject(projectID: "shared", confirmationTitle: "shared"))
        await gate.open(); await read.value
        #expect(subject.sharedProjects.isEmpty)
        #expect(!subject.isLoadingSharedProjects)
    }

    @Test func largeAccountsRotateBoundedBatchesWithoutDroppingUnscannedProjects() async throws {
        let owners = (0..<85).map { ProjectOwner(login: String(format: "colleague%03d", $0), kind: .user) }
        let api = WorkspaceAPI(data: [fixtureSnapshot()] + owners.map { sharedFixture($0.login, owner: $0) })
        await api.configureDiscovery(owners: owners)
        let subject = model(api)
        await subject.signIn(token: "fixture")
        #expect(subject.sharedProjects.count == SharedProjectDiscovery.ownersPerPass)
        #expect(subject.isCheckingMoreSharedProjects)
        for _ in 0..<4 {
            let before = await api.queriedOwners().count
            await subject.refreshSharedProjects(force: true)
            #expect(await api.queriedOwners().count - before == SharedProjectDiscovery.ownersPerPass)
        }
        #expect(subject.sharedProjects.count == 85)
        #expect(!subject.isCheckingMoreSharedProjects)
        await subject.refreshSharedProjects(force: true)
        #expect(subject.sharedProjects.count == 85)
        #expect(subject.selectedProjectID == "project")
    }

    @Test func rateLimitStopsFanOutAndBlocksEvenManualRetriesUntilReset() async throws {
        let a = ProjectOwner(login: "a", kind: .user), b = ProjectOwner(login: "b", kind: .user)
        let api = WorkspaceAPI(data: [fixtureSnapshot(), sharedFixture("a", owner: a), sharedFixture("b", owner: b)])
        await api.configureDiscovery(owners: [a, b], failures: [a.id: .rateLimited(Date().addingTimeInterval(3600))])
        let subject = model(api)
        await subject.signIn(token: "fixture")
        let queries = await api.queriedOwners()
        #expect(queries.contains(a.id))
        #expect(!queries.contains(b.id))
        #expect(subject.sharedProjectsError == FjordError.rateLimited(nil).localizedDescription)
        await subject.refreshSharedProjects(force: true)
        #expect(await api.queriedOwners() == queries)
        #expect(subject.user != nil && subject.snapshot != nil)
    }

    @Test func logoutCancelsDiscoveryBeforeItRequestsAnotherOwner() async throws {
        let a = ProjectOwner(login: "a", kind: .user), b = ProjectOwner(login: "b", kind: .user)
        let gate = Gate(), api = WorkspaceAPI(data: [fixtureSnapshot(), sharedFixture("a", owner: a), sharedFixture("b", owner: b)])
        await api.configureDiscovery(owners: [a, b], gate: gate, gatedOwner: a.id)
        let subject = model(api)
        let login = Task { await subject.signIn(token: "fixture") }
        await gate.waitUntilRequested()
        await subject.logout()
        await gate.open(); await login.value
        #expect(!(await api.queriedOwners()).contains(b.id))
        #expect(subject.sharedProjects.isEmpty)
        #expect(subject.user == nil)
    }
}

struct SharedProjectAPITests {
    @Test func graphQLRateLimitErrorsRetainTheirResetTime() async throws {
        let transport = MockTransport { _, _ in
            HTTPResponse(data: Data(#"{"errors":[{"type":"RATE_LIMITED","message":"Rate limited"}]}"#.utf8),
                         status: 200, headers: ["x-ratelimit-reset": "2000000000"])
        }
        await #expect(throws: FjordError.rateLimited(Date(timeIntervalSince1970: 2_000_000_000))) {
            try await GitHubClient(token: "fixture", transport: transport).collaboratingOwners()
        }
    }

    @Test func secondaryRateLimitsHonorRetryAfter() throws {
        let before = Date()
        do {
            try checkResponse(HTTPResponse(data: Data(), status: 429, headers: ["retry-after": "120"]))
            Issue.record("Expected rate limit")
        } catch let error as FjordError {
            guard case .rateLimited(let reset) = error else { Issue.record("Expected rate limit"); return }
            #expect(try #require(reset).timeIntervalSince(before) >= 120)
        }
    }
    @Test func candidateOwnersArePaginatedDeduplicatedAndUseRepositoryAffiliations() async throws {
        let transport = MockTransport { request, index in
            let query = try #require(body(request)["query"] as? String)
            #expect(query.contains("affiliations: [COLLABORATOR, ORGANIZATION_MEMBER]"))
            let variables = try #require(body(request)["variables"] as? [String: Any])
            if index == 1 {
                #expect(variables["after"] is NSNull)
                return jsonResponse(#"{"data":{"viewer":{"repositories":{"nodes":[{"owner":{"__typename":"User","login":"colleague"}},null,{"owner":{"__typename":"Organization","login":"team"}}],"pageInfo":{"hasNextPage":true,"endCursor":"next"}}}}}"#)
            }
            #expect(variables["after"] as? String == "next")
            return jsonResponse(#"{"data":{"viewer":{"repositories":{"nodes":[{"owner":{"__typename":"User","login":"COLLEAGUE"}}],"pageInfo":{"hasNextPage":false}}}}}"#)
        }
        let owners = try await GitHubClient(token: "fixture", transport: transport).collaboratingOwners()
        #expect(Set(owners.map { $0.id.lowercased() }) == ["user:colleague", "organization:team"])
        #expect(await transport.requests().count == 2)
    }

    @Test func incompleteRepositoryPaginationFailsInsteadOfClaimingNoSharedProjects() async throws {
        let transport = MockTransport { _, _ in
            jsonResponse(#"{"data":{"viewer":{"repositories":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"same"}}}}}"#)
        }
        await #expect(throws: Error.self) { try await GitHubClient(token: "fixture", transport: transport).collaboratingOwners() }
        #expect(await transport.requests().count == 2)
    }

    @Test func projectDiscoveryReadsVisibilityAndWriteAccessAcrossEveryPage() async throws {
        let transport = MockTransport { request, index in
            let query = try #require(body(request)["query"] as? String)
            #expect(query.contains("public viewerCanUpdate"))
            if index == 1 {
                return jsonResponse(#"{"data":{"user":{"projectsV2":{"nodes":[{"id":"one","number":1,"title":"Private","url":"https://github.com/users/colleague/projects/1","closed":false,"public":false,"viewerCanUpdate":false}],"pageInfo":{"hasNextPage":true,"endCursor":"more"}}}}}"#)
            }
            #expect((try #require(body(request)["variables"] as? [String: Any]))["after"] as? String == "more")
            return jsonResponse(#"{"data":{"user":{"projectsV2":{"nodes":[{"id":"two","number":2,"title":"Writable","url":"https://github.com/users/colleague/projects/2","closed":false,"public":true,"viewerCanUpdate":true}],"pageInfo":{"hasNextPage":false}}}}}"#)
        }
        let projects = try await GitHubClient(token: "fixture", transport: transport).projects(owner: sharedOwner)
        #expect(projects.count == 2)
        #expect(projects.first { $0.id == "one" }?.isPublic == false)
        #expect(projects.first { $0.id == "two" }?.viewerCanUpdate == true)
    }
}
