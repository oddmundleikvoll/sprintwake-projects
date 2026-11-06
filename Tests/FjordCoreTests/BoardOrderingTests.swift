import Foundation
import Testing
@testable import FjordCore

struct BoardPositionAPITests {
    @Test func columnChangeRequiresTheConfirmedProjectItem() async {
        for optionID: String? in ["done", nil] {
            for payload in ["null", #"{"projectV2Item":{"id":"wrong-item"}}"#, #"{"projectV2Item":null}"#] {
                let operation = optionID == nil ? "clearProjectV2ItemFieldValue" : "updateProjectV2ItemFieldValue"
                let response = "{\"data\":{\"\(operation)\":\(payload)}}"
                let api = GitHubClient(token: "fixture", transport: MockTransport { _, _ in jsonResponse(response) })
                await #expect(throws: Error.self) {
                    try await api.setSelection(projectID: "project", itemID: "item", fieldID: "field", optionID: optionID)
                }
            }
        }
    }

    @Test func positionUsesProjectItemIDsAndNullForTop() async throws {
        let transport = MockTransport { request, index in
            let payload = try body(request)
            let query = try #require(payload["query"] as? String)
            let variables = try #require(payload["variables"] as? [String: Any])
            #expect(query.contains("updateProjectV2ItemPosition"))
            #expect(query.contains("afterId: $after"))
            #expect(query.contains("items(first: 1) { totalCount }"))
            #expect(variables["project"] as? String == "project")
            #expect(variables["item"] as? String == "project-item")
            if index == 1 { #expect(variables["after"] as? String == "predecessor") }
            else { #expect(variables["after"] is NSNull) }
            return jsonResponse(#"{"data":{"updateProjectV2ItemPosition":{"items":{"totalCount":4}}}}"#)
        }
        let api = GitHubClient(token: "fixture", transport: transport)
        try await api.moveItem(projectID: "project", itemID: "project-item", afterID: "predecessor")
        try await api.moveItem(projectID: "project", itemID: "project-item", afterID: nil)
        #expect(await transport.requests().count == 2)
    }

    @Test func positionRejectsGraphQLErrorsAndUnconfirmedPayloads() async {
        for response in [#"{"data":{"updateProjectV2ItemPosition":null},"errors":[{"message":"Forbidden"}]}"#,
                         #"{"data":{"updateProjectV2ItemPosition":null}}"#,
                         #"{"data":{}}"#] {
            let api = GitHubClient(token: "fixture", transport: MockTransport { _, _ in jsonResponse(response) })
            await #expect(throws: Error.self) { try await api.moveItem(projectID: "p", itemID: "i", afterID: nil) }
        }
    }
}

@MainActor struct BoardOrderingTests {
    private func model(_ api: WorkspaceAPI, preferences: UserDefaults? = nil) -> AppModel {
        AppModel(storage: MemoryStorage(), oauth: MockOAuth(),
                 preferences: preferences ?? UserDefaults(suiteName: "Fjord.order.tests.\(UUID())")!, makeAPI: { _ in api })
    }

    private func snapshot(canUpdate: Bool = true) -> ProjectSnapshot {
        let base = fixtureSnapshot(canUpdate: canUpdate)
        return ProjectSnapshot(project: base.project, canUpdate: canUpdate, fields: base.fields, items: [
            ProjectItem(id: "a", contentID: "a-content", kind: .draft, title: "A", selections: ["status": "todo"]),
            ProjectItem(id: "hidden", contentID: nil, kind: .redacted, title: "Hidden", selections: ["status": "todo"]),
            ProjectItem(id: "b", contentID: "b-content", kind: .issue, title: "B", selections: ["status": "done"]),
            ProjectItem(id: "c", contentID: "c-content", kind: .draft, title: "C", selections: ["status": "todo"])
        ])
    }

    @Test func reordersWithinColumnAndRefreshKeepsConfirmedOrder() async throws {
        let api = WorkspaceAPI(data: [snapshot()]), subject = model(api)
        await subject.signIn(token: "fixture")
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "c", optionID: "todo", targetItemID: "a", before: true))
        #expect(subject.boardColumns(items: subject.snapshot!.items)[0].items.map(\.id) == ["c", "a", "hidden"])
        #expect(try #require(await api.positions().first).afterID == nil)
        #expect(await api.writes() == 1)
        await subject.refresh()
        #expect(subject.snapshot?.items.map(\.id) == ["c", "a", "hidden", "b"])
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "c", optionID: "todo"))
        #expect(subject.boardColumns(items: subject.snapshot!.items)[0].items.map(\.id) == ["a", "hidden", "c"])
        #expect(try #require(await api.positions().last).afterID == "hidden")
    }

    @Test func crossColumnDropUsesFullColumnOrderIncludingFilteredCards() async throws {
        let api = WorkspaceAPI(data: [snapshot()]), subject = model(api)
        await subject.signIn(token: "fixture")
        // A UI search may show only C; the predecessor must still come from the full column.
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "b", optionID: "todo", targetItemID: "c", before: true))
        #expect(try #require(await api.positions().first).afterID == "hidden")
        #expect(subject.boardColumns(items: subject.snapshot!.items)[0].items.map(\.id) == ["a", "hidden", "b", "c"])
        #expect(subject.snapshot?.items.first { $0.id == "b" }?.selections["status"] == "todo")
        #expect(await api.writes() == 2)
    }

    @Test func emptyAndUnassignedColumnsAndUngroupedTasksSupportMoves() async throws {
        let api = WorkspaceAPI(data: [snapshot()]), subject = model(api)
        await subject.signIn(token: "fixture")
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "b", optionID: nil))
        #expect(subject.snapshot?.items.first?.id == "b")
        #expect(subject.snapshot?.items.first?.selections["status"] == nil)
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "a", optionID: "done"))
        #expect(subject.boardColumns(items: subject.snapshot!.items).last?.items.map(\.id) == ["a"])
        let base = snapshot()
        let ungroupedAPI = WorkspaceAPI(data: [ProjectSnapshot(project: base.project, canUpdate: true, fields: [], items: base.items)])
        let ungrouped = model(ungroupedAPI)
        await ungrouped.signIn(token: "fixture")
        #expect(await ungrouped.moveItem(projectID: "project", fieldID: nil, itemID: "a", optionID: nil, targetItemID: "c"))
        #expect(ungrouped.snapshot?.items.last?.id == "a")
    }

    @Test func invalidStaleReadOnlyAndUnchangedMovesDoNotWrite() async {
        let api = WorkspaceAPI(data: [snapshot()]), subject = model(api)
        await subject.signIn(token: "fixture")
        #expect(await subject.moveItem(projectID: "stale", fieldID: "status", itemID: "a", optionID: "done") == false)
        #expect(await subject.moveItem(projectID: "project", fieldID: "other-field", itemID: "a", optionID: "done") == false)
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "missing", optionID: "done") == false)
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "a", optionID: "removed") == false)
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "a", optionID: "todo", targetItemID: "b") == false)
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "a", optionID: "todo", targetItemID: "a") == false)
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "c", optionID: "todo"))
        #expect(await api.writes() == 0)
        let readonlyAPI = WorkspaceAPI(data: [snapshot(canUpdate: false)]), readonly = model(readonlyAPI)
        await readonly.signIn(token: "fixture")
        #expect(await readonly.moveItem(projectID: "project", fieldID: "status", itemID: "a", optionID: "done") == false)
        #expect(await readonlyAPI.writes() == 0)
    }

    @Test func failuresPreserveConfirmedStatusAndDoNotClaimUnconfirmedOrder() async {
        let api = WorkspaceAPI(data: [snapshot()]), subject = model(api)
        await subject.signIn(token: "fixture")
        await api.configurePosition(error: .http(503, "offline"))
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "a", optionID: "done") == false)
        #expect(subject.snapshot?.items.map(\.id) == ["a", "hidden", "b", "c"])
        #expect(subject.snapshot?.items.first?.selections["status"] == "done")
        #expect(subject.notice == L10n.core("The task moved to the column, but its order could not be confirmed. Refresh before moving it again."))
        #expect(subject.user != nil && !subject.isMutating)
        await api.configure(writeError: .http(403, "denied"))
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "c", optionID: "done") == false)
        #expect(await api.positions().count == 1)
        #expect(subject.snapshot?.items.last?.selections["status"] == "todo")
    }

    @Test func confirmedOrderSurvivesFailedReload() async {
        let api = WorkspaceAPI(data: [snapshot()]), subject = model(api)
        await subject.signIn(token: "fixture")
        await api.configure(failReadsAfterWrite: true)
        #expect(await subject.moveItem(projectID: "project", fieldID: "status", itemID: "c", optionID: "todo", targetItemID: "a", before: true))
        #expect(subject.snapshot?.items.first?.id == "c")
        #expect(subject.notice != nil)
        #expect(await api.writes() == 1)
    }

    @Test func logoutBetweenWritesStopsFurtherRequestsAndLateResultsStayDiscarded() async {
        for duringStatus in [true, false] {
            let gate = Gate(), api = WorkspaceAPI(data: [snapshot()]), subject = model(api)
            await subject.signIn(token: "fixture")
            await api.configurePosition(gate: duringStatus ? nil : gate, selectionGate: duringStatus ? gate : nil)
            let move = Task { await subject.moveItem(projectID: "project", fieldID: "status", itemID: "a", optionID: "done") }
            await gate.waitUntilRequested()
            #expect(subject.isMutating)
            let dragID = subject.boardDragID
            await subject.logout()
            await gate.open()
            _ = await move.value
            #expect(subject.snapshot == nil && subject.user == nil && !subject.isMutating)
            #expect(subject.notice == nil && subject.columnOrder.isEmpty)
            #expect(subject.boardDragID != dragID)
            #expect(await api.positions().count == (duringStatus ? 0 : 1))
        }
    }

    @Test func columnLayoutIsLocalPersistentAndScopedToAccountProjectAndField() async throws {
        let base = snapshot(canUpdate: false)
        let priority = SelectField(id: "priority", name: "Priority", options: [SelectOption(id: "high", name: "High"), SelectOption(id: "low", name: "Low")])
        let data = ProjectSnapshot(project: base.project, canUpdate: false, fields: base.fields + [priority], items: base.items)
        let api = WorkspaceAPI(data: [data, fixtureSnapshot(id: "second")])
        let preferences = UserDefaults(suiteName: "Fjord.order.tests.\(UUID())")!, subject = model(api, preferences: preferences)
        await subject.signIn(token: "fixture")
        #expect(subject.moveColumn(projectID: "project", fieldID: "status", columnID: "done", targetID: "todo", before: true))
        #expect(subject.boardColumns(items: base.items).map(\.id) == ["done", "todo"])
        #expect(subject.selectedField?.options.map(\.id) == ["todo", "done"])
        #expect(await api.writes() == 0)
        subject.setGrouping("priority")
        #expect(subject.boardColumns(items: base.items).suffix(2).map(\.id) == ["high", "low"])
        #expect(!subject.moveColumn(projectID: "project", fieldID: "status", columnID: "done", targetID: "todo", before: true))
        subject.setGrouping("status")
        await subject.selectProject(try #require(subject.projects.first { $0.id == "second" }))
        #expect(subject.columnOrder.isEmpty)
        let restored = model(api, preferences: preferences)
        await restored.signIn(token: "fixture")
        await restored.selectProject(data.project)
        #expect(restored.columnOrder == ["done", "todo"])
        await restored.logout()
        await api.changeProfileLogin("other", nodeID: "other-id")
        await restored.signIn(token: "fixture")
        #expect(restored.columnOrder.isEmpty)
    }

    @Test func columnOrderToleratesRemovedNewDuplicateAndHiddenUnassignedIDs() {
        let base = snapshot()
        let field = base.fields[0]
        #expect(BoardGrouping.columns(field: field, items: base.items, order: ["removed", "done", "done", "unassigned"]).map(\.id) == ["done", "todo"])
        let unassigned = ProjectItem(id: "none", contentID: "none", kind: .draft, title: "None")
        #expect(BoardGrouping.columns(field: field, items: base.items + [unassigned], order: ["done", "unassigned", "todo"]).map(\.id) == ["done", "unassigned", "todo"])
        #expect(BoardOrdering.moving(base.items, itemID: "a", afterID: "a") == base.items)
        #expect(BoardOrdering.moving(base.items, itemID: "a", afterID: "missing") == base.items)
    }

    @Test func demoReordersTasksAndColumnsWithoutPersistingLayoutAndKeepsMessagesChronological() async throws {
        let preferences = UserDefaults(suiteName: "Fjord.order.tests.\(UUID())")!, subject = model(WorkspaceAPI(), preferences: preferences)
        await subject.startDemo()
        let saved = preferences.dictionaryRepresentation()
        #expect(subject.moveColumn(projectID: "demo-project", fieldID: "demo-status", columnID: "done", targetID: "todo", before: true))
        #expect(preferences.dictionaryRepresentation() as NSDictionary == saved as NSDictionary)
        #expect(await subject.moveItem(projectID: "demo-project", fieldID: "demo-status", itemID: "demo-6", optionID: "todo", targetItemID: "demo-1", before: true))
        await subject.refresh()
        #expect(subject.boardColumns(items: subject.snapshot!.items).first { $0.id == "todo" }?.items.map(\.id) == ["demo-6", "demo-1", "demo-4"])
        #expect(await subject.moveItem(projectID: "demo-project", fieldID: "demo-status", itemID: "demo-chat-2", optionID: "chat", targetItemID: "demo-chat-1", before: true))
        #expect(subject.snapshot?.items.filter { $0.selections["demo-status"] == "chat" }.map(\.id) == ["demo-chat-1", "demo-chat-2"])
        await subject.logout()
        await subject.startDemo()
        #expect(subject.columnOrder.isEmpty)
    }
}
