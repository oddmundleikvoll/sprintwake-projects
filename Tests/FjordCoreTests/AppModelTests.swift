import Foundation
import Testing
@testable import FjordCore

@MainActor
struct AppModelTests {
    private func model(api: WorkspaceAPI, storage: MemoryStorage = MemoryStorage()) -> AppModel {
        let preferences = UserDefaults(suiteName: "Fjord.tests.\(UUID().uuidString)")!
        return AppModel(storage: storage, oauth: MockOAuth(), preferences: preferences, makeAPI: { _ in api })
    }

    @Test func oldProjectResponseCannotReplaceNewSelection() async throws {
        let gate = Gate()
        let api = WorkspaceAPI(data: [fixtureSnapshot(id: "first"), fixtureSnapshot(id: "second")], gate: gate, gatedProject: "first")
        let model = model(api: api)
        let login = Task { await model.signIn(token: "fixture") }
        await gate.waitUntilRequested()
        await model.selectProject(fixtureSnapshot(id: "second").project)
        #expect(model.snapshot?.project.id == "second")
        await gate.open(); await login.value
        #expect(model.snapshot?.project.id == "second")
        #expect(model.selectedProjectID == "second")
    }

    @Test func logoutDuringProjectLoadDiscardsLateResults() async throws {
        let gate = Gate(), storage = MemoryStorage()
        let api = WorkspaceAPI(gate: gate, gatedProject: "project")
        let model = model(api: api, storage: storage)
        let login = Task { await model.signIn(token: "fixture") }
        await gate.waitUntilRequested()
        await model.logout()
        await gate.open(); await login.value
        #expect(model.user == nil)
        #expect(model.snapshot == nil)
        #expect(try storage.load() == nil)
    }

    @Test func restorePreservesSessionWhenOfflineAndClearsRevokedSession() async throws {
        let credential = Credential(accessToken: "fixture")
        let api = WorkspaceAPI(), storage = MemoryStorage(credential)
        await api.configure(profileError: .http(503, "offline"))
        let model = model(api: api, storage: storage)
        await model.start()
        #expect(model.user == nil)
        #expect(model.hasSavedSession)
        #expect(try storage.load() == credential)
        await api.configure(profileError: .unauthenticated)
        await model.restoreSession()
        #expect(!model.hasSavedSession)
        #expect(try storage.load() == nil)
    }

    @Test func failedStatusMutationDoesNotPretendToSave() async throws {
        let api = WorkspaceAPI()
        let model = model(api: api)
        await model.signIn(token: "fixture")
        await api.configure(writeError: .http(403, "No permission"))
        #expect(await model.changeStatus(itemID: "item", optionID: "done") == false)
        #expect(model.snapshot?.items[0].selections["status"] == "todo")
        #expect(model.errorMessage?.contains("No permission") == true)
    }

    @Test func successfulDraftCreationIsNotRetriedWhenReloadFails() async throws {
        let api = WorkspaceAPI()
        let model = model(api: api)
        await model.signIn(token: "fixture")
        await api.configure(failReadsAfterWrite: true)
        #expect(await model.createDraft(projectID: "project", title: "New", body: "Message"))
        #expect(await api.writes() == 1)
        #expect(model.notice == L10n.core("The change was saved on GitHub. The view could not be refreshed; try Refresh."))
    }

    @Test func readOnlyProjectNeverSendsMutation() async throws {
        let api = WorkspaceAPI(data: [fixtureSnapshot(canUpdate: false)])
        let model = model(api: api)
        await model.signIn(token: "fixture")
        #expect(await model.changeStatus(itemID: "item", optionID: "done") == false)
        #expect(await api.writes() == 0)
    }

    @Test func editingConflictDoesNotOverwriteAnotherUsersText() async throws {
        let api = WorkspaceAPI()
        let model = model(api: api)
        await model.signIn(token: "fixture")
        let original = try #require(model.snapshot?.items.first)
        await api.changeTitle("Someone else's edit")
        #expect(await model.saveItem(projectID: "project", original: original, title: "My edit", body: "") == false)
        #expect(await api.writes() == 0)
        #expect(model.errorMessage == L10n.core("The item changed on GitHub while you were editing. Close the editor and refresh before trying again."))
    }

    @Test func liveColumnCreationNeverReplacesSharedOptionCollections() async throws {
        let api = WorkspaceAPI()
        let model = model(api: api)
        await model.signIn(token: "fixture")
        #expect(await model.addColumn(projectID: "project", name: "Samtale") == false)
        #expect(await api.writes() == 0)
        #expect(model.snapshot?.fields.first?.options.count == 2)
    }

    @Test func refreshLoadsChangesMadeOutsideTheApp() async throws {
        let api = WorkspaceAPI()
        let model = model(api: api)
        await model.signIn(token: "fixture")
        await api.changeTitle("Changed on GitHub")
        #expect(model.snapshot?.items[0].title == "Test")
        await model.refresh()
        #expect(model.snapshot?.items[0].title == "Changed on GitHub")
    }

    @Test func invalidCandidateTokenDoesNotDeleteAnExistingSavedSession() async throws {
        let original = Credential(accessToken: "fixture-existing")
        let storage = MemoryStorage(original), api = WorkspaceAPI()
        await api.configure(profileError: .http(503, "offline"))
        let model = model(api: api, storage: storage)
        await model.start()
        await api.configure(profileError: .unauthenticated)
        await model.signIn(token: "fixture-typo")
        #expect(try storage.load() == original)
        #expect(model.hasSavedSession)
        #expect(model.user == nil)
    }

    @Test func sentMessageAppearsWithoutWaitingForAFullProjectRead() async throws {
        let api = WorkspaceAPI(), subject = model(api: api)
        await subject.signIn(token: "fixture")
        await api.configure(failReadsAfterWrite: true)
        #expect(await subject.sendMessage(projectID: "project", optionID: "todo", text: "Visible immediately"))
        let item = try #require(subject.snapshot?.items.first { $0.id == "sent-message" })
        #expect(item.body == "Visible immediately")
        #expect(item.selections["status"] == "todo")
        #expect(item.authorLogin == "tester")
        #expect(subject.notice == nil)
        #expect(subject.errorMessage == nil)
        #expect(await api.writes() == 1)
    }

    @Test func failedChatSendKeepsTheConversationUnchanged() async throws {
        let api = WorkspaceAPI(), subject = model(api: api)
        await subject.signIn(token: "fixture")
        let before = subject.snapshot
        await api.configure(writeError: .http(403, "Read only"))
        #expect(await subject.sendMessage(projectID: "project", optionID: "todo", text: "Not sent") == false)
        #expect(subject.snapshot == before)
    }

    @Test func partialChatSendKeepsTheDraftAndExplainsUncertainPlacement() async throws {
        let api = WorkspaceAPI(), subject = model(api: api)
        await subject.signIn(token: "fixture")
        await api.setChatPlacementWarning("Option unavailable")
        await api.configure(failReadsAfterWrite: true)
        #expect(await subject.sendMessage(projectID: "project", optionID: "todo", text: "Created once"))
        #expect(subject.snapshot?.items.first { $0.id == "sent-message" }?.selections.isEmpty == true)
        #expect(subject.notice?.contains("Option unavailable") == true)
        #expect(await api.writes() == 1)
    }

    @Test func logoutDuringChatSendDiscardsTheConfirmedMessage() async throws {
        let gate = Gate(), api = WorkspaceAPI(creationGate: gate)
        let subject = model(api: api)
        await subject.signIn(token: "fixture")
        let send = Task { await subject.sendMessage(projectID: "project", optionID: "todo", text: "Old account") }
        await gate.waitUntilRequested()
        await subject.logout()
        await gate.open()
        _ = await send.value
        #expect(subject.user == nil)
        #expect(subject.snapshot == nil)
    }

    @Test func partialChatSendReconcilesPlacementWhenOnlyTheResponseWasLost() async throws {
        let api = WorkspaceAPI(), subject = model(api: api)
        await subject.signIn(token: "fixture")
        await api.setChatPlacementWarning("Response lost", placed: true)
        #expect(await subject.sendMessage(projectID: "project", optionID: "todo", text: "Already placed"))
        let item = try #require(subject.snapshot?.items.first { $0.id == "sent-message" })
        #expect(item.selections["status"] == "todo")
        #expect(subject.snapshot?.items.filter { $0.id == "sent-message" }.count == 1)
        #expect(await api.writes() == 1)
    }
}
