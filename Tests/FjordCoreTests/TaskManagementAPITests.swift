import Foundation
import Testing
@testable import FjordCore

struct TaskManagementAPITests {
    @Test func inaccessibleDraftNeverSendsAnEmptyAssigneeReplacement() async throws {
        let transport = MockTransport { _, _ in jsonResponse(#"{"data":{"node":null}}"#) }
        let client = GitHubClient(token: "fixture", transport: transport)
        let item = ProjectItem(id: "item", contentID: "draft", kind: .draft, title: "Hidden draft")
        await #expect(throws: FjordError.self) {
            try await client.changeAssignee(item: item, user: AssignableUser(id: "u1", login: "one"), assigned: true)
        }
        #expect(await transport.requests().count == 1)
    }

    @Test func issueLinkFailureRetainsCreatedURLAndNeverCreatesAgain() async throws {
        let transport = MockTransport { request, index in
            let payload = try body(request), query = try #require(payload["query"] as? String)
            if index == 1 {
                #expect(query.contains("createIssue"))
                let vars = try #require(payload["variables"] as? [String: Any])
                #expect(vars["assignees"] as? [String] == ["u1"])
                return jsonResponse(#"{"data":{"createIssue":{"issue":{"id":"issue-1","url":"https://github.com/acme/one/issues/1"}}}}"#)
            }
            #expect(query.contains("addProjectV2ItemById"))
            throw FjordError.http(403, "No project access")
        }
        let client = GitHubClient(token: "fixture", transport: transport)
        let result = try await client.createItem(projectID: "p1", request: NewItemRequest(title: "Issue", repositoryID: "r1", assigneeIDs: ["u1"]))
        #expect(result.projectItemID == nil)
        #expect(result.issueURL?.absoluteString == "https://github.com/acme/one/issues/1")
        #expect(result.warning == L10n.core("The issue was created, but could not be added to the project: %@", L10n.core("GitHub returned %lld: %@", 403, "No project access")))
        #expect(await transport.requests().count == 2)
    }

    @Test func issueAssignmentUsesOnlyTheSelectedUserWithAtomicAddAndRemove() async throws {
        let transport = MockTransport { request, index in
            let payload = try body(request), query = try #require(payload["query"] as? String)
            #expect(query.contains(index == 1 ? "addAssigneesToAssignable" : "removeAssigneesFromAssignable"))
            let vars = try #require(payload["variables"] as? [String: Any])
            #expect(vars["id"] as? String == "issue-content")
            #expect(vars["user"] as? String == "u1")
            return jsonResponse(#"{"data":{}}"#)
        }
        let client = GitHubClient(token: "fixture", transport: transport)
        let issue = ProjectItem(id: "item", contentID: "issue-content", kind: .issue, title: "Issue", assigneeLogins: ["someone-else"])
        let user = AssignableUser(id: "u1", login: "one")
        try await client.changeAssignee(item: issue, user: user, assigned: true)
        try await client.changeAssignee(item: issue, user: user, assigned: false)
        #expect(await transport.requests().count == 2)
    }

    @Test func createsAndDeletesProjectWithOwnerNodeID() async throws {
        let transport = MockTransport { request, index in
            let payload = try body(request)
            let variables = try #require(payload["variables"] as? [String: Any])
            if index == 1 {
                #expect(variables["login"] as? String == "acme")
                return jsonResponse(#"{"data":{"organization":{"id":"org-id"}}}"#)
            }
            if index == 2 {
                #expect(variables["owner"] as? String == "org-id")
                return jsonResponse(#"{"data":{"createProjectV2":{"projectV2":{"id":"p1","number":4,"title":"Roadmap","url":"https://github.com/orgs/acme/projects/4","closed":false}}}}"#)
            }
            #expect(variables["id"] as? String == "p1")
            return jsonResponse(#"{"data":{"deleteProjectV2":{"projectV2":{"id":"p1"}}}}"#)
        }
        let client = GitHubClient(token: "fixture", transport: transport)
        let project = try await client.createProject(owner: ProjectOwner(login: "acme", kind: .organization), title: "Roadmap")
        #expect(project.id == "p1")
        try await client.deleteProject(id: project.id)
    }

    @Test func paginatesRepositoriesAndAssignableUsers() async throws {
        let transport = MockTransport { _, index in
            switch index {
            case 1: return jsonResponse(#"{"data":{"node":{"repositories":{"nodes":[{"id":"r1","nameWithOwner":"acme/one","hasIssuesEnabled":true,"isArchived":false}],"pageInfo":{"hasNextPage":true,"endCursor":"r-next"}}}}}"#)
            case 2: return jsonResponse(#"{"data":{"node":{"repositories":{"nodes":[{"id":"r2","nameWithOwner":"acme/two","hasIssuesEnabled":true,"isArchived":false}],"pageInfo":{"hasNextPage":false}}}}}"#)
            case 3: return jsonResponse(#"{"data":{"repository":{"assignableUsers":{"nodes":[{"id":"u1","login":"one","name":"One"}],"pageInfo":{"hasNextPage":true,"endCursor":"u-next"}}}}}"#)
            default: return jsonResponse(#"{"data":{"repository":{"assignableUsers":{"nodes":[{"id":"u2","login":"two","name":null}],"pageInfo":{"hasNextPage":false}}}}}"#)
            }
        }
        let client = GitHubClient(token: "fixture", transport: transport)
        let repos = try await client.repositories(projectID: "p1", referencedRepositories: [])
        #expect(repos.map(\.nameWithOwner) == ["acme/one", "acme/two"])
        let users = try await client.assignableUsers(repository: "acme/one")
        #expect(users.map(\.login) == ["one", "two"])
    }

    @Test func issueCreationReturnsWarningAfterPlacementFailureAndDraftAssigneeMergeIsAdditive() async throws {
        let transport = MockTransport { request, index in
            let payload = try body(request)
            let query = try #require(payload["query"] as? String)
            if index == 1 {
                #expect(query.contains("createIssue"))
                return jsonResponse(#"{"data":{"createIssue":{"issue":{"id":"issue-1","url":"https://github.com/acme/one/issues/1"}}}}"#)
            }
            if index == 2 { return jsonResponse(#"{"data":{"addProjectV2ItemById":{"item":{"id":"item-1"}}}}"#) }
            if index == 3 { return jsonResponse(#"{"data":{},"errors":[{"message":"No status access","type":"FORBIDDEN"}]}"#) }
            if index == 4 {
                #expect(query.contains("DraftIssue"))
                return jsonResponse(#"{"data":{"node":{"assignees":{"nodes":[{"id":"existing"}]}}}}"#)
            }
            #expect(query.contains("updateProjectV2DraftIssue"))
            let vars = try #require(payload["variables"] as? [String: Any])
            let ids = try #require(vars["ids"] as? [String])
            #expect(ids == ["existing", "new"])
            return jsonResponse(#"{"data":{"updateProjectV2DraftIssue":{"draftIssue":{"id":"draft-1"}}}}"#)
        }
        let client = GitHubClient(token: "fixture", transport: transport)
        let issue = try await client.createItem(projectID: "p1", request: NewItemRequest(title: "Issue", repositoryID: "repo-1", placement: ItemPlacement(fieldID: "status", optionID: "todo")))
        #expect(issue.issueURL?.absoluteString == "https://github.com/acme/one/issues/1")
        #expect(issue.warning == L10n.core("The issue was created, but its column placement could not be confirmed: %@", "No status access"))
        let draft = ProjectItem(id: "item", contentID: "draft-1", kind: .draft, title: "Draft")
        try await client.changeAssignee(item: draft, user: AssignableUser(id: "new", login: "new"), assigned: true)
    }
}
