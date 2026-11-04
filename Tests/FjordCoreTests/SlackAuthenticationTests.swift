import Foundation
import CryptoKit
import Testing
@testable import FjordCore

private final class SlackMemoryStorage: SlackCredentialStorage, @unchecked Sendable {
    let lock = NSLock(); var value: SlackCredential?
    init(value: SlackCredential? = nil) { self.value = value }
    func load() throws -> SlackCredential? { lock.withLock { value } }
    func save(_ value: SlackCredential) throws { lock.withLock { self.value = value } }
    func delete() throws { lock.withLock { value = nil } }
}

private struct SlackMockOAuth: SlackOAuthAuthenticating {
    let handler: @Sendable (SlackCredential) async throws -> SlackCredential
    func authorization(clientID: String, includePrivateChannels: Bool) throws -> SlackAuthorization { fatalError() }
    func exchange(_ authorization: SlackAuthorization, callback: URL) async throws -> SlackCredential { fatalError() }
    func refresh(_ credential: SlackCredential) async throws -> SlackCredential { try await handler(credential) }
}

@Test("Slack authorization uses PKCE and user scopes")
func slackAuthorizationUsesPKCE() throws {
    let client = SlackOAuthClient(now: { Date(timeIntervalSince1970: 100) })
    let authorization = try client.authorization(clientID: "123.abc", includePrivateChannels: true)
    let components = try #require(URLComponents(url: authorization.url, resolvingAgainstBaseURL: false))
    let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
    #expect(values["code_challenge_method"] == "S256")
    let challenge = Data(SHA256.hash(data: Data(authorization.codeVerifier.utf8))).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    #expect(values["code_challenge"] == challenge)
    #expect(values["scope"] == nil)
    #expect(values["redirect_uri"] == SlackAuthorization.redirectURI)
    #expect(values["user_scope"] == "channels:read,channels:history,users:read,chat:write,groups:read,groups:history")
    #expect(authorization.state.count >= 40)
    #expect(authorization.codeVerifier.count >= 40)
    #expect(!authorization.url.absoluteString.contains("client_secret"))
}

@Test("Invalid Slack callbacks never make an HTTP request")
func slackCallbackValidation() async throws {
    let transport = MockTransport { _, _ in Issue.record("unexpected HTTP request"); return jsonResponse("{}") }
    let client = SlackOAuthClient(transport: transport, now: { Date(timeIntervalSince1970: 100) })
    let auth = try client.authorization(clientID: "abc", includePrivateChannels: false)
    await #expect(throws: SlackError.self) { try await client.exchange(auth, callback: URL(string: "https://oauth/callback?state=x&code=one")!) }
    for query in ["state=\(auth.state)&state=\(auth.state)&code=one", "state=\(auth.state)&state&code=one",
                  "state=\(auth.state)&code=one&code", "state=wrong&code=one", "state=\(auth.state)&code=one&error=access_denied"] {
        await #expect(throws: SlackError.self) { try await client.exchange(auth, callback: URL(string: "sprintwake-slack://oauth/callback?\(query)")!) }
    }
    let expired = SlackAuthorization(url: auth.url, state: auth.state, codeVerifier: auth.codeVerifier, clientID: auth.clientID,
                                     redirectURI: auth.redirectURI, expiresAt: Date(timeIntervalSince1970: 99))
    await #expect(throws: SlackError.self) { try await client.exchange(expired, callback: URL(string: "\(auth.redirectURI)?state=\(auth.state)&code=one")!) }
    #expect(await transport.requests().isEmpty)
}

@Test("Slack exchange accepts the user token response")
func slackExchangeParsesUserResponse() async throws {
    let transport = MockTransport { request, _ in
        #expect(request.url?.absoluteString == "https://slack.com/api/oauth.v2.access")
        let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(form.contains("code_verifier=")); #expect(!form.contains("client_secret"))
        return jsonResponse("{\"ok\":true,\"team\":{\"id\":\"T1\",\"name\":\"Acme\"},\"authed_user\":{\"id\":\"U1\",\"access_token\":\"xoxp-test\",\"token_type\":\"user\",\"scope\":\"channels:read,channels:history,users:read,chat:write\",\"expires_in\":3600,\"refresh_token\":\"refresh-test\",\"refresh_token_expires_in\":2592000}}")
    }
    let now = Date(timeIntervalSince1970: 100); let client = SlackOAuthClient(transport: transport, now: { now })
    let auth = try client.authorization(clientID: "abc", includePrivateChannels: false)
    var callbackParts = URLComponents(string: SlackAuthorization.redirectURI)!
    callbackParts.queryItems = [URLQueryItem(name: "state", value: auth.state), URLQueryItem(name: "code", value: "one")]
    let callback = callbackParts.url!
    let credential = try await client.exchange(auth, callback: callback)
    #expect(credential.accessToken == "xoxp-test"); #expect(credential.userID == "U1"); #expect(credential.teamID == "T1")
    #expect(credential.expiresAt == now.addingTimeInterval(3600))
    #expect(credential.refreshExpiresAt == now.addingTimeInterval(2592000))
}

@Test("Slack refresh rotates tokens without a client secret and encodes the refresh token")
func slackRefreshParsesBothResponseShapes() async throws {
    let now = Date(timeIntervalSince1970: 100)
    let original = SlackCredential(accessToken: "old", refreshToken: "r+/=&", clientID: "public", teamID: "T1", teamName: "Acme", userID: "U1", scopes: ["chat:write"])
    for nested in [true, false] {
        let transport = MockTransport { request, _ in
            let form = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(form.contains("grant_type=refresh_token"))
            #expect(form.contains("refresh_token=r%2B%2F%3D%26"))
            #expect(!form.contains("client_secret"))
            let token = "\"access_token\":\"fresh\",\"token_type\":\"user\",\"expires_in\":43200,\"refresh_token\":\"r2\",\"scope\":\"chat:write,channels:read\""
            return jsonResponse(nested ? "{\"ok\":true,\"authed_user\":{\"id\":\"U1\",\(token)}}" : "{\"ok\":true,\(token)}")
        }
        let refreshed = try await SlackOAuthClient(transport: transport, now: { now }).refresh(original)
        #expect(refreshed.accessToken == "fresh")
        #expect(refreshed.refreshToken == "r2")
        #expect(refreshed.expiresAt == now.addingTimeInterval(43200))
        #expect(refreshed.refreshExpiresAt == now.addingTimeInterval(30 * 24 * 60 * 60))
        #expect(refreshed.scopes == ["chat:write", "channels:read"])
    }
}

@Test("Slack refresh rejects changed identity, incomplete tokens, and missing success")
func slackRefreshFailsClosed() async throws {
    let credential = SlackCredential(accessToken: "old", refreshToken: "r", clientID: "public", teamID: "T1", teamName: "Team", userID: "U1", scopes: ["chat:write"])
    let token = "\"access_token\":\"fresh\",\"token_type\":\"user\",\"expires_in\":43200,\"refresh_token\":\"r2\""
    for response in ["{\"ok\":true,\(token),\"team\":{\"id\":\"T2\"}}", "{\"ok\":true,\(token),\"authed_user\":{\"id\":\"U2\"}}",
                     "{\(token)}", "{\"ok\":true,\"access_token\":\"fresh\",\"token_type\":\"user\"}"] {
        let transport = MockTransport { _, _ in jsonResponse(response) }
        await #expect(throws: SlackError.self) { try await SlackOAuthClient(transport: transport).refresh(credential) }
    }
}

@Test("Signing out during refresh cannot save or resurrect the Slack session")
func slackLogoutDuringRefresh() async throws {
    let gate = Gate(), old = expiredSlackCredential()
    let storage = SlackMemoryStorage(value: old)
    let session = SlackCredentialSession(storage: storage, oauth: SlackMockOAuth { _ in await gate.wait(); return freshSlackCredential() })
    _ = try await session.restore()
    let request = Task { try await session.current() }
    await gate.waitUntilRequested()
    try await session.clear()
    await gate.open()
    await #expect(throws: SlackError.cancelled) { try await request.value }
    #expect(try storage.load() == nil)
    await #expect(throws: SlackError.unauthenticated) { try await session.current() }
}

@Test("Cancelling a refresh waiter preserves the shared rotating token")
func slackCancelledRefreshWaiter() async throws {
    let gate = Gate(), calls = LockIsolated(0), storage = SlackMemoryStorage(value: expiredSlackCredential())
    let session = SlackCredentialSession(storage: storage, oauth: SlackMockOAuth { _ in
        calls.withLock { $0 += 1 }; await gate.wait(); return freshSlackCredential()
    })
    _ = try await session.restore()
    let cancelled = Task { try await session.current() }
    await gate.waitUntilRequested(); cancelled.cancel(); await gate.open()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try await session.current() == freshSlackCredential())
    #expect(try storage.load() == freshSlackCredential())
    #expect(calls.value == 1)
}

@Test("Temporary Slack refresh failure keeps the saved credential")
func slackTransientRefreshFailure() async throws {
    let old = expiredSlackCredential(), storage = SlackMemoryStorage(value: expiredSlackCredential())
    let session = SlackCredentialSession(storage: storage, oauth: SlackMockOAuth { _ in throw SlackError.rateLimited(retryAfter: 7) })
    _ = try await session.restore()
    await #expect(throws: SlackError.rateLimited(retryAfter: 7)) { try await session.current() }
    #expect(try storage.load() == old)
}

private func expiredSlackCredential() -> SlackCredential {
    SlackCredential(accessToken: "old", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 10), clientID: "c", teamID: "T", teamName: "Team", userID: "U", scopes: ["chat:write"])
}
private func freshSlackCredential() -> SlackCredential {
    SlackCredential(accessToken: "fresh", refreshToken: "r2", expiresAt: .distantFuture, clientID: "c", teamID: "T", teamName: "Team", userID: "U", scopes: ["chat:write"])
}

@Test("Slack session coalesces refresh and logout prevents persistence")
func slackSessionCoalescesAndClears() async throws {
    let old = SlackCredential(accessToken: "old", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 10), clientID: "c", teamID: "T", teamName: "Team", userID: "U", scopes: ["chat:write"])
    let fresh = SlackCredential(accessToken: "fresh", refreshToken: "r2", expiresAt: Date(timeIntervalSince1970: 1000), clientID: "c", teamID: "T", teamName: "Team", userID: "U", scopes: ["chat:write"])
    let storage = SlackMemoryStorage(value: old)
    let calls = LockIsolated(0)
    let oauth = SlackMockOAuth { _ in calls.withLock { $0 += 1 }; try await Task.sleep(for: .milliseconds(20)); return fresh }
    let session = SlackCredentialSession(storage: storage, oauth: oauth, now: { Date(timeIntervalSince1970: 100) })
    _ = try await session.restore()
    async let first = session.current(); async let second = session.current()
    #expect(try await first == fresh); #expect(try await second == fresh); #expect(calls.value == 1)
    try await session.clear()
    do { _ = try await session.current(); Issue.record("cleared Slack session remained usable") }
    catch let error as SlackError { #expect(error == .unauthenticated) }
    catch { Issue.record("unexpected error: \(error)") }
}

private final class LockIsolated<T>: @unchecked Sendable {
    let lock = NSLock(); var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
}
