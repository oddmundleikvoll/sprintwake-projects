import Foundation
import Testing
@testable import FjordCore

@Suite("Slack API")
struct SlackClientTests {
    @Test func identityUsesBearerAndNoQueryToken() async throws {
        let transport = MockTransport { request, _ in
            #expect(request.url?.query == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer xoxb-test")
            return jsonResponse("{\"ok\":true,\"team_id\":\"T1\",\"team\":\"Acme\",\"user_id\":\"U1\",\"user\":\"Ada\"}")
        }
        let identity = try await SlackClient(token: "xoxb-test", transport: transport).identity()
        #expect(identity.teamName == "Acme")
        #expect(identity.userName == "Ada")
    }

    @Test func channelsPaginateAndExcludeArchived() async throws {
        let transport = MockTransport { request, count in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cursor" })?.value
            if count == 1 {
                #expect(query == nil)
                return jsonResponse("{\"ok\":true,\"channels\":[{\"id\":\"C1\",\"name\":\"general\",\"is_private\":false,\"is_archived\":false},{\"id\":\"C2\",\"name\":\"old\",\"is_archived\":true}],\"response_metadata\":{\"next_cursor\":\"next\"}}")
            }
            #expect(query == "next")
            return jsonResponse("{\"ok\":true,\"channels\":[{\"id\":\"C3\",\"name\":\"ship\",\"is_private\":false,\"is_archived\":false}],\"response_metadata\":{\"next_cursor\":\"\"}}")
        }
        let channels = try await SlackClient(token: "t", transport: transport).channels(includePrivate: false)
        #expect(channels.map(\.id) == ["C1", "C3"])
    }

    @Test func repeatedCursorFailsClosed() async throws {
        let transport = MockTransport { _, _ in jsonResponse("{\"ok\":true,\"channels\":[],\"response_metadata\":{\"next_cursor\":\"same\"}}") }
        await #expect(throws: SlackError.self) { try await SlackClient(token: "t", transport: transport).channels(includePrivate: false) }
    }

    @Test func mapsRateLimitAndAuthErrors() async throws {
        let rate = MockTransport { _, _ in HTTPResponse(data: Data(), status: 429, headers: ["retry-after": "7"]) }
        await #expect(throws: SlackError.rateLimited(retryAfter: 7)) { try await SlackClient(token: "t", transport: rate).identity() }
        let auth = MockTransport { _, _ in jsonResponse("{\"ok\":false,\"error\":\"token_revoked\"}") }
        await #expect(throws: SlackError.unauthenticated) { try await SlackClient(token: "t", transport: auth).identity() }
    }

    @Test func postMessageHasSafeFlagsAndDoesNotRetry() async throws {
        let transport = MockTransport { request, count in
            #expect(count == 1)
            let json = try body(request)
            #expect(json["parse"] as? String == "none")
            #expect(json["link_names"] as? Bool == false)
            #expect(json["unfurl_links"] as? Bool == false)
            #expect(json["unfurl_media"] as? Bool == false)
            #expect(json["mrkdwn"] as? Bool == false)
            throw URLError(.timedOut)
        }
        await #expect(throws: SlackError.deliveryUnconfirmed) { try await SlackClient(token: "t", transport: transport).postMessage(channelID: "C1", text: "hello") }
        #expect(await transport.requests().count == 1)
    }

    @Test func plaintextEscapesMarkupAndWrongConfirmationIsUncertain() async throws {
        let transport = MockTransport { request, _ in
            let json = try body(request)
            #expect(json["text"] as? String == "&lt;@channel&gt; &amp; hello")
            return jsonResponse("{\"ok\":true,\"channel\":\"C-other\",\"ts\":\"1700000000.000001\",\"message\":{\"ts\":\"1700000000.000001\",\"text\":\"ok\"}}")
        }
        await #expect(throws: SlackError.deliveryUnconfirmed) {
            try await SlackClient(token: "t", transport: transport).postMessage(channelID: "C1", text: "<@channel> & hello")
        }
    }

    @Test func fatalWriteResponseIsUncertainWithoutRetry() async throws {
        let transport = MockTransport { _, count in
            #expect(count == 1)
            return jsonResponse("{\"ok\":false,\"error\":\"fatal_error\"}")
        }
        await #expect(throws: SlackError.deliveryUnconfirmed) {
            try await SlackClient(token: "t", transport: transport).postMessage(channelID: "C1", text: "hello")
        }
        #expect(await transport.requests().count == 1)
    }

    @Test func formatterDecodesSlackMarkupWithoutInterpretingUnsafeURLs() {
        let text = SlackMessageText.plainText("Hi &amp; <@U1> <#C1|general> <https://example.com|docs> <javascript:alert(1)|bad>", userNames: ["U1": "Ada"])
        #expect(text == "Hi & @Ada #general docs (https://example.com) <javascript:alert(1)|bad>")
        #expect(SlackMessageText.plainText("<#> &amp;lt; <https://example.com>") == "<#> &lt; https://example.com")
    }

    @Test func cancellationAfterSubmittingAWriteIsUncertain() async throws {
        let transport = MockTransport { _, _ in throw CancellationError() }
        await #expect(throws: SlackError.deliveryUnconfirmed) {
            try await SlackClient(token: "fixture", transport: transport).postMessage(channelID: "C1", text: "hello")
        }
        #expect(await transport.requests().count == 1)
    }

    @Test func historyKeepsThreadParentsAndOmitsReplies() async throws {
        let transport = MockTransport { _, _ in jsonResponse("""
        {"ok":true,"has_more":true,"response_metadata":{"next_cursor":"next"},"messages":[
          {"ts":"100.0","thread_ts":"100.0","text":"parent","reply_count":2},
          {"ts":"101.0","thread_ts":"100.0","text":"reply"},
          {"ts":"102.0","text":"standalone"}]}
        """) }
        let page = try await SlackClient(token: "fixture", transport: transport).history(channelID: "C1", cursor: nil)
        #expect(page.messages.map(\.text) == ["parent", "standalone"])
        #expect(page.messages.first?.replyCount == 2)
        #expect(page.nextCursor == "next")
    }
}
