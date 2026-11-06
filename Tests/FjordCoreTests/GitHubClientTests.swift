import Foundation
import Testing
@testable import FjordCore

struct GitHubClientTests {
    @Test func accessibleIssuesAndPRsKeepTheirContentAndOnlyNullContentIsRedacted() async throws {
        let transport = MockTransport { request, index in
            if index == 1 {
                return jsonResponse(#"{"data":{"node":{"id":"project","number":1,"title":"Project","url":"https://github.com/users/tester/projects/1","closed":false,"viewerCanUpdate":true,"fields":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}"#)
            }
            let query = try #require(body(request)["query"] as? String)
            #expect(query.contains("... on Issue"))
            #expect(query.contains("... on PullRequest"))
            return jsonResponse(#"{"data":{"node":{"items":{"nodes":[{"id":"issue","content":{"__typename":"Issue","id":"issue-content","title":"Private issue","body":"Issue body","url":"https://github.com/tester/private/issues/1","number":1,"viewerCanUpdate":true,"repository":{"nameWithOwner":"tester/private"}},"fieldValues":{"nodes":[],"pageInfo":{"hasNextPage":false}}},{"id":"pr","content":{"__typename":"PullRequest","id":"pr-content","title":"Private PR","body":"PR body","viewerCanUpdate":false},"fieldValues":{"nodes":[],"pageInfo":{"hasNextPage":false}}},{"id":"hidden","content":null,"fieldValues":{"nodes":[{"optionId":"todo","field":{"id":"status"}}],"pageInfo":{"hasNextPage":false}}}],"pageInfo":{"hasNextPage":false}}}}}"#)
        }
        let snapshot = try await GitHubClient(token: "fixture", transport: transport).snapshot(project: fixtureSnapshot().project)
        #expect(snapshot.items.map(\.kind) == [.issue, .pullRequest, .redacted])
        #expect(snapshot.items[0].title == "Private issue")
        #expect(snapshot.items[0].body == "Issue body")
        #expect(snapshot.items[0].repository == "tester/private")
        #expect(snapshot.items[0].canEditContent)
        #expect(snapshot.items[1].title == "Private PR")
        #expect(!snapshot.items[1].canEditContent)
        #expect(snapshot.items[2].selections == ["status": "todo"])
        #expect(!snapshot.items[2].canEditContent)
    }

    @Test func projectURLValidation() throws {
        let reference = try ProjectReference(url: "https://github.com/users/example/projects/42/views/1?pane=issue")
        #expect(reference.owner == ProjectOwner(login: "example", kind: .user))
        #expect(reference.number == 42)
        #expect(try ProjectReference(url: "https://github.com/orgs/example/projects/1").owner.kind == .organization)
        for bad in ["http://github.com/users/a/projects/1", "https://evil.test/users/a/projects/1", "https://github.com/a/b/issues/1", "https://github.com/users/a/projects/-1", "https://github.com@evil.test/users/a/projects/1"] {
            #expect(throws: Error.self) { try ProjectReference(url: bad) }
        }
    }

    @Test func paginatesFieldsItemsAndItemValuesWithoutLosingRedactedContent() async throws {
        let transport = MockTransport { request, index in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            let variables = try #require(body(request)["variables"] as? [String: Any])
            switch index {
            case 1, 2:
                #expect(index == 1 ? variables["after"] is NSNull : variables["after"] as? String == "fields-next")
                let fields = index == 1
                    ? #"{"nodes":[{}, {"id":"status","name":"Status","options":[{"id":"todo","name":"Todo","color":"GRAY","description":"Keep me"}]}],"pageInfo":{"hasNextPage":true,"endCursor":"fields-next"}}"#
                    : #"{"nodes":[{"id":"priority","name":"Priority","options":[{"id":"high","name":"High"}]}],"pageInfo":{"hasNextPage":false}}"#
                return jsonResponse("""
                {"data":{"node":{"id":"project","number":1,"title":"Live title","url":"https://github.com/users/tester/projects/1","closed":false,"viewerCanUpdate":true,"fields":\(fields)}}}
                """)
            case 3:
                return jsonResponse(#"{"data":{"node":{"items":{"nodes":[{"id":"draft-item","content":{"__typename":"DraftIssue","id":"draft-content","title":"Hello","body":"Full message","createdAt":"2026-11-03T12:00:00Z","creator":{"login":"tester"},"assignees":{"nodes":[{"login":"tester"}]}},"fieldValues":{"nodes":[{"optionId":"todo","field":{"id":"status"}}],"pageInfo":{"hasNextPage":true,"endCursor":"values-next"}}},{"id":"hidden-item","content":null,"fieldValues":{"nodes":[],"pageInfo":{"hasNextPage":false}}}],"pageInfo":{"hasNextPage":true,"endCursor":"items-next"}}}}}"#)
            case 4:
                #expect(variables["id"] as? String == "draft-item")
                #expect(variables["after"] as? String == "values-next")
                return jsonResponse(#"{"data":{"node":{"fieldValues":{"nodes":[{"optionId":"high","field":{"id":"priority"}}],"pageInfo":{"hasNextPage":false}}}}}"#)
            case 5:
                #expect(variables["after"] as? String == "items-next")
                return jsonResponse(#"{"data":{"node":{"items":{"nodes":[{"id":"pr-item","content":{"__typename":"PullRequest","id":"pr-content","title":"A PR","body":"","url":"https://github.com/a/b/pull/3","number":3,"viewerCanUpdate":false,"repository":{"nameWithOwner":"a/b"}},"fieldValues":{"nodes":[],"pageInfo":{"hasNextPage":false}}}],"pageInfo":{"hasNextPage":false}}}}}"#)
            default: throw FjordError.message("Unexpected request")
            }
        }
        let client = GitHubClient(token: "fixture-token", transport: transport)
        let snapshot = try await client.snapshot(project: fixtureSnapshot().project)
        #expect(snapshot.project.title == "Live title")
        #expect(snapshot.fields.count == 2)
        #expect(snapshot.items.count == 3)
        #expect(snapshot.items[0].selections == ["status": "todo", "priority": "high"])
        #expect(snapshot.items[0].authorLogin == "tester")
        #expect(snapshot.items[0].assigneeLogins == ["tester"])
        #expect(snapshot.items[0].createdAt != nil)
        #expect(snapshot.items[1].kind == .redacted)
        #expect(!snapshot.items[1].canEditContent)
        #expect(snapshot.items[2].kind == .pullRequest)
        #expect(!snapshot.items[2].canEditContent)
        #expect(await transport.requests().count == 5)
    }

    @Test func refusesPartialGraphQLErrorsAndInvalidCredentials() async throws {
        let broken = GitHubClient(token: "fixture", transport: MockTransport { _, _ in
            jsonResponse(#"{"data":{"user":null},"errors":[{"message":"Missing project scope","type":"FORBIDDEN"}]}"#)
        })
        await #expect(throws: FjordError.message("Missing project scope")) {
            try await broken.projects(owner: ProjectOwner(login: "test", kind: .user))
        }
        let revoked = GitHubClient(token: "fixture", transport: MockTransport { _, _ in jsonResponse("{}", status: 401) })
        await #expect(throws: FjordError.unauthenticated) { try await revoked.currentUser() }
    }

    @Test func updatesAndClearsUsingProjectItemIDAndFieldID() async throws {
        let transport = MockTransport { request, index in
            let payload = try body(request)
            let query = try #require(payload["query"] as? String)
            let vars = try #require(payload["variables"] as? [String: Any])
            #expect(vars["item"] as? String == "item-not-content")
            #expect(vars["field"] as? String == "status-field")
            if index == 1 {
                #expect(query.contains("updateProjectV2ItemFieldValue")); #expect(vars["option"] as? String == "done")
            } else { #expect(query.contains("clearProjectV2ItemFieldValue")); #expect(vars["option"] == nil) }
            let operation = index == 1 ? "updateProjectV2ItemFieldValue" : "clearProjectV2ItemFieldValue"
            return jsonResponse("{\"data\":{\"\(operation)\":{\"projectV2Item\":{\"id\":\"item-not-content\"}}}}")
        }
        let client = GitHubClient(token: "fixture", transport: transport)
        try await client.setSelection(projectID: "p", itemID: "item-not-content", fieldID: "status-field", optionID: "done")
        try await client.setSelection(projectID: "p", itemID: "item-not-content", fieldID: "status-field", optionID: nil)
    }

    @Test func grantsOnlyTheSpecifiedCollaboratorWithExplicitRole() async throws {
        let transport = MockTransport { request, index in
            let vars = try #require(body(request)["variables"] as? [String: Any])
            if index == 1 { #expect(vars["login"] as? String == "collaborator"); return jsonResponse(#"{"data":{"user":{"id":"target-user"}}}"#) }
            let collaborators = try #require(vars["collaborators"] as? [[String: String]])
            #expect(collaborators == [["userId": "target-user", "role": "WRITER"]])
            return jsonResponse(#"{"data":{"updateProjectV2Collaborators":{}}}"#)
        }
        try await GitHubClient(token: "fixture", transport: transport).grantAccess(projectID: "p", username: "@collaborator", role: .writer)
    }

    @Test func chatAssignsTheAuthorAndRetainsFullText() async throws {
        let text = "Hei 👋\nEn melding med flere linjer og \"anførselstegn\"."
        let transport = MockTransport { request, index in
            let vars = try #require(body(request)["variables"] as? [String: Any])
            if index == 1 {
                #expect(vars["author"] as? String == "author-id")
                #expect(vars["body"] as? String == text)
                #expect((try #require(body(request)["query"] as? String)).contains("assigneeIds: [$author]"))
                return jsonResponse(#"{"data":{"addProjectV2DraftIssue":{"projectItem":{"id":"created-item","content":{"__typename":"DraftIssue","id":"draft-id","title":"Preview","body":"Confirmed full text","createdAt":"2026-11-04T10:00:00Z","creator":{"login":"actual-author"},"assignees":{"nodes":[{"id":"author-id","login":"actual-author","name":"Author"}]}}}}}}"#)
            }
            #expect(vars["item"] as? String == "created-item")
            #expect(vars["option"] as? String == "chat-option")
            return jsonResponse(#"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"created-item"}}}}"#)
        }
        let result = try await GitHubClient(token: "fixture", transport: transport).sendChatMessage(projectID: "p", fieldID: "f", optionID: "chat-option", authorID: "author-id", text: text)
        guard case .sent(let item) = result else { Issue.record("Expected confirmed message"); return }
        #expect(item.id == "created-item")
        #expect(item.body == "Confirmed full text")
        #expect(item.contentID == "draft-id")
        #expect(item.authorLogin == "actual-author")
        #expect(item.createdAt == ISO8601DateFormatter().date(from: "2026-11-04T10:00:00Z"))
        #expect(item.assignees.map(\.id) == ["author-id"])
        #expect(item.selections["f"] == "chat-option")
    }

    @Test func chatPlacementFailureIsReportedAsCreatedRatherThanRetried() async throws {
        let transport = MockTransport { _, index in
            if index == 1 { return jsonResponse(#"{"data":{"addProjectV2DraftIssue":{"projectItem":{"id":"created"}}}}"#) }
            return jsonResponse(#"{"errors":[{"message":"Option deleted"}]}"#)
        }
        let result = try await GitHubClient(token: "fixture", transport: transport).sendChatMessage(projectID: "p", fieldID: "f", optionID: "o", authorID: "a", text: "Hello")
        guard case .placementUnconfirmed(let item, let reason) = result else { Issue.record("Expected uncertain placement"); return }
        #expect(item.id == "created")
        #expect(item.body == "Hello")
        #expect(item.authorLogin == nil)
        #expect(item.selections.isEmpty)
        #expect(reason == "Option deleted")
        #expect(await transport.requests().count == 2)
    }

    @Test func lostPlacementResponseDoesNotClaimTheDraftIsUnassigned() async throws {
        let transport = MockTransport { request, index in
            if index == 1 { return jsonResponse(#"{"data":{"addProjectV2DraftIssue":{"projectItem":{"id":"created"}}}}"#) }
            // Simulate GitHub accepting the placement while the HTTP response is lost.
            #expect((try #require(body(request)["query"] as? String)).contains("updateProjectV2ItemFieldValue"))
            throw URLError(.timedOut)
        }
        let result = try await GitHubClient(token: "fixture", transport: transport).sendChatMessage(projectID: "p", fieldID: "f", optionID: "o", authorID: "a", text: "Hello")
        guard case .placementUnconfirmed(_, let reason) = result else { Issue.record("Expected uncertain placement, not a claim that it failed"); return }
        #expect(!reason.isEmpty)
        #expect(await transport.requests().count == 2)
    }
}
