import Foundation
import Testing
@testable import FjordCore

@MainActor
struct WorkspaceManagementTests {
    private func model(_ api: WorkspaceAPI, preferences: UserDefaults? = nil) -> AppModel {
        AppModel(storage: MemoryStorage(), oauth: MockOAuth(),
                 preferences: preferences ?? UserDefaults(suiteName: "Fjord.tests.\(UUID())")!, makeAPI: { _ in api })
    }

    @Test func columnCreationCapturesPlacementRepositoryAndAssignees() async throws {
        let api = WorkspaceAPI()
        let subject = self.model(api)
        await subject.signIn(token: "fixture")
        let placement = ItemPlacement(fieldID: "status", optionID: "done")
        #expect(await subject.createItem(projectID: "project", request: NewItemRequest(title: "  New issue  ", body: "Body", repositoryID: "repo", assigneeIDs: ["person"], placement: placement)))
        let request = try #require(await api.requestsCreated().first)
        #expect(request.title == "New issue")
        #expect(request.body == "Body")
        #expect(request.repositoryID == "repo")
        #expect(request.assigneeIDs == ["person"])
        #expect(request.placement == placement)
    }

    @Test func removedColumnAndReadOnlyProjectNeverCreateIssues() async throws {
        let api = WorkspaceAPI(), subject = model(api)
        await subject.signIn(token: "fixture")
        #expect(await subject.createItem(projectID: "project", request: NewItemRequest(title: "New", placement: ItemPlacement(fieldID: "status", optionID: "removed"))) == false)
        #expect(await api.writes() == 0)
        let readOnlyAPI = WorkspaceAPI(data: [fixtureSnapshot(canUpdate: false)]), readOnly = model(readOnlyAPI)
        await readOnly.signIn(token: "fixture")
        #expect(await readOnly.createItem(projectID: "project", request: NewItemRequest(title: "New", repositoryID: "repo")) == false)
        #expect(await readOnlyAPI.writes() == 0)
    }

    @Test func createdIssueKeepsWarningAndLinkWhenPlacementOrReloadFails() async throws {
        let api = WorkspaceAPI(), subject = model(api)
        await subject.signIn(token: "fixture")
        await api.configure(failReadsAfterWrite: true)
        await api.setCreationWarning("Issue created, but placement is unconfirmed.")
        #expect(await subject.createItem(projectID: "project", request: NewItemRequest(title: "New", repositoryID: "repo")))
        #expect(await api.writes() == 1)
        #expect(subject.notice == "Issue created, but placement is unconfirmed.")
        #expect(subject.noticeURL?.absoluteString == "https://github.com/tester/app/issues/1")
    }

    @Test func logoutDuringCreationDiscardsLateWarningsAndPrivateLinks() async throws {
        let gate = Gate()
        let gatedAPI = WorkspaceAPI(creationGate: gate), subject = model(gatedAPI)
        await subject.signIn(token: "fixture")
        await gatedAPI.setCreationWarning("Created on GitHub")
        let creation = Task { await subject.createItem(projectID: "project", request: NewItemRequest(title: "New", repositoryID: "repo")) }
        await gate.waitUntilRequested()
        await subject.logout()
        await gate.open()
        #expect(await creation.value)
        #expect(subject.user == nil && subject.snapshot == nil)
        #expect(subject.notice == nil && subject.noticeURL == nil)
        #expect(!subject.isMutating)
    }

    @Test func creatingProjectInvalidatesAnOlderProjectLoad() async throws {
        let gate = Gate()
        let api = WorkspaceAPI(data: [fixtureSnapshot(id: "old")], gate: gate, gatedProject: "old"), subject = model(api)
        let login = Task { await subject.signIn(token: "fixture") }
        await gate.waitUntilRequested()
        let owner = try #require(subject.owners.first)
        #expect(await subject.createProject(owner: owner, title: "Roadmap"))
        #expect(subject.snapshot?.project.title == "Roadmap")
        await gate.open(); await login.value
        #expect(subject.selectedProjectID == "created-project")
        #expect(subject.snapshot?.project.id == "created-project")
        #expect(!subject.isMutating && !subject.isLoadingProject)
    }

    @Test func createdProjectIsNotReportedAsFailedWhenReloadFails() async throws {
        let api = WorkspaceAPI(), subject = model(api)
        await subject.signIn(token: "fixture")
        await api.configure(failReadsAfterWrite: true)
        #expect(await subject.createProject(owner: try #require(subject.selectedOwner), title: "Roadmap"))
        #expect(subject.projects.contains { $0.title == "Roadmap" })
        #expect(subject.notice == L10n.core("The project was created on GitHub. Select it in the list to try loading it again."))
        #expect(await api.writes() == 1)
    }

    @Test func deletingProjectRequiresExactConfirmationAndSelectsAnotherProject() async throws {
        let api = WorkspaceAPI(data: [fixtureSnapshot(id: "first"), fixtureSnapshot(id: "second")]), subject = model(api)
        await subject.signIn(token: "fixture")
        #expect(await subject.deleteProject(projectID: "first", confirmationTitle: "wrong") == false)
        #expect(await api.writes() == 0)
        #expect(await subject.deleteProject(projectID: "first", confirmationTitle: "first"))
        #expect(subject.projects.map(\.id) == ["second"])
        #expect(subject.snapshot?.project.id == "second")
        #expect(!subject.isMutating)
    }

    @Test func failedProjectDeletionPreservesTheProject() async throws {
        let api = WorkspaceAPI(), subject = model(api)
        await subject.signIn(token: "fixture")
        await api.configure(writeError: .http(403, "Admin required"))
        #expect(await subject.deleteProject(projectID: "project", confirmationTitle: "project") == false)
        #expect(subject.projects.map(\.id) == ["project"])
        #expect(subject.snapshot?.project.id == "project")
        #expect(!subject.isMutating)
    }

    @Test func assignmentRespectsContentAndProjectPermissions() async throws {
        let snapshot = fixtureSnapshot(), person = AssignableUser(id: "person", login: "person")
        let readonlyItem = ProjectItem(id: "locked", contentID: "locked-content", kind: .issue, title: "Locked", canEditContent: false)
        let hidden = ProjectItem(id: "hidden", contentID: nil, kind: .redacted, title: "Hidden")
        let api = WorkspaceAPI(data: [ProjectSnapshot(project: snapshot.project, canUpdate: true, fields: snapshot.fields, items: snapshot.items + [readonlyItem, hidden])]), subject = model(api)
        await subject.signIn(token: "fixture")
        #expect(await subject.changeAssignee(projectID: "project", itemID: "locked", person: person, assigned: true) == false)
        #expect(await subject.changeAssignee(projectID: "project", itemID: "hidden", person: person, assigned: true) == false)
        #expect(await subject.changeAssignee(projectID: "another", itemID: "item", person: person, assigned: true) == false)
        #expect(await api.writes() == 0)
        #expect(await subject.changeAssignee(projectID: "project", itemID: "item", person: person, assigned: true))
        #expect(await api.writes() == 1)
    }

    @Test func conversationSelectionIsRememberedForEachGroupingField() async throws {
        let base = fixtureSnapshot()
        let other = SelectField(id: "priority", name: "Priority", options: [SelectOption(id: "high", name: "High")])
        let api = WorkspaceAPI(data: [ProjectSnapshot(project: base.project, canUpdate: true, fields: base.fields + [other], items: base.items)])
        let preferences = UserDefaults(suiteName: "Fjord.tests.\(UUID())")!, subject = model(api, preferences: preferences)
        await subject.signIn(token: "fixture")
        subject.setConversationOption("done")
        subject.setGrouping("priority")
        #expect(subject.conversationOptionID == nil)
        subject.setConversationOption("high")
        subject.setGrouping("status")
        #expect(subject.conversationOptionID == "done")
        let restored = model(api, preferences: preferences)
        await restored.signIn(token: "fixture")
        #expect(restored.conversationOptionID == "done")
        restored.setGrouping("priority")
        #expect(restored.conversationOptionID == "high")
    }

    @Test func demoSupportsProjectIssueAssignmentColumnAndInlineConversationLifecycle() async throws {
        let subject = model(WorkspaceAPI())
        await subject.startDemo()
        let projectID = try #require(subject.selectedProjectID), field = try #require(subject.selectedField)
        #expect(BoardGrouping.columns(field: field, items: subject.snapshot!.items).allSatisfy { $0.option != nil })
        let chatID = try #require(subject.conversationOptionID)
        #expect(await subject.sendMessage(projectID: projectID, optionID: chatID, text: "Direkte fra tavlen"))
        let message = try #require(subject.snapshot?.items.first { $0.body == "Direkte fra tavlen" })
        #expect(message.selections[field.id] == chatID)
        #expect(message.assigneeLogins == ["demo"])
        #expect(await subject.addColumn(projectID: projectID, name: "Review"))
        let optionID = try #require(subject.selectedField?.options.first { $0.name == "Review" }?.id)
        let people = await subject.assignmentCandidates(projectID: projectID, repository: "demo/Fjord")
        let person = try #require(people.first { $0.login == "maren" })
        let repository = try #require(await subject.loadRepositories(projectID: projectID).first)
        #expect(await subject.createItem(projectID: projectID, request: NewItemRequest(title: "Test issue", repositoryID: repository.id, assigneeIDs: [person.id], placement: ItemPlacement(fieldID: field.id, optionID: optionID))))
        let issue = try #require(subject.snapshot?.items.first { $0.title == "Test issue" })
        #expect(issue.kind == .issue && issue.assigneeLogins == ["maren"])
        #expect(issue.selections[field.id] == optionID)
        #expect(await subject.changeAssignee(projectID: projectID, itemID: issue.id, person: person, assigned: false))
        #expect(subject.snapshot?.items.first { $0.id == issue.id }?.assigneeLogins == [])
        #expect(await subject.deleteColumn(projectID: projectID, optionID: optionID))
        #expect(subject.snapshot?.items.first { $0.id == issue.id }?.selections[field.id] == nil)
        #expect(await subject.createProject(owner: try #require(subject.selectedOwner), title: "Disposable"))
        let createdID = try #require(subject.selectedProjectID)
        #expect(await subject.deleteProject(projectID: createdID, confirmationTitle: "Disposable"))
        #expect(subject.selectedProjectID == projectID)
    }
}

struct BoardGroupingTests {
    @Test func emptyUnassignedColumnIsHiddenButEmptyStatusColumnsRemain() {
        let snapshot = fixtureSnapshot(), field = snapshot.fields[0]
        let columns = BoardGrouping.columns(field: field, items: snapshot.items)
        #expect(columns.map(\.title) == ["Todo", "Done"])
        #expect(columns[1].items.isEmpty)
    }

    @Test func missingAndUnknownStatusAreVisibleAndEveryItemAppearsOnce() {
        let snapshot = fixtureSnapshot(), field = snapshot.fields[0]
        let items = snapshot.items + [ProjectItem(id: "missing", contentID: "draft-missing", kind: .draft, title: "Missing"), ProjectItem(id: "unknown", contentID: "draft-unknown", kind: .draft, title: "Unknown", selections: ["status": "removed-option"])]
        let columns = BoardGrouping.columns(field: field, items: items)
        #expect(columns[0].title == L10n.core("Missing status"))
        #expect(columns[0].items.map(\.id) == ["missing", "unknown"])
        #expect(Set(columns.flatMap(\.items).map(\.id)) == Set(items.map(\.id)))
        #expect(columns.flatMap(\.items).count == items.count)
    }
}
