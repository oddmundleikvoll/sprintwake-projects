import Foundation
import Testing
@testable import FjordCore

private actor Intervals {
    var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}

struct AuthenticationTests {
    @Test func privateRepositoryLoginRequestsRepoExplicitly() async throws {
        let transport = MockTransport { request, _ in
            let fields = URLComponents(string: "https://fixture.test/?" + (String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""))?.queryItems
            let scope = fields?.first(where: { $0.name == "scope" })?.value?.split(separator: " ").map(String.init)
            #expect(Set(scope ?? []) == ["read:user", "read:org", "project", "repo"])
            return jsonResponse(#"{"device_code":"fixture-device","user_code":"TEST-CODE","expires_in":900}"#)
        }
        _ = try await DeviceOAuthClient(transport: transport).begin(clientID: "public", includePrivateRepositories: true)
    }

    @Test func deviceFlowRespectsSlowDownAndNeverSendsAClientSecret() async throws {
        let intervals = Intervals()
        let transport = MockTransport { request, index in
            let text = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            #expect(!text.contains("client_secret"))
            switch index {
            case 1:
                #expect(request.url?.path == "/login/device/code")
                #expect(text.contains("project")); #expect(text.contains("public_repo"))
                return jsonResponse(#"{"device_code":"test-device-code","user_code":"TEST-CODE","expires_in":900,"interval":5}"#)
            case 2: return jsonResponse(#"{"error":"authorization_pending"}"#)
            case 3: return jsonResponse(#"{"error":"slow_down"}"#)
            case 4: return jsonResponse(#"{"access_token":"fixture-only","expires_in":28800,"refresh_token":"fixture-refresh","refresh_token_expires_in":15552000}"#)
            default: throw FjordError.message("Too many polls")
            }
        }
        let now = Date()
        let oauth = DeviceOAuthClient(transport: transport, now: { now }, sleep: { await intervals.record($0) })
        let challenge = try await oauth.begin(clientID: "public-client", includePrivateRepositories: false)
        let credential = try await oauth.poll(challenge)
        #expect(await intervals.values == [5, 5, 10])
        #expect(credential.accessToken == "fixture-only")
        #expect(credential.expiresAt == now.addingTimeInterval(28800))
        #expect(credential.clientID == "public-client")
    }

    @Test func expiredDeviceCodeDoesNotPoll() async throws {
        let transport = MockTransport { _, _ in throw FjordError.message("Must not send") }
        let oauth = DeviceOAuthClient(transport: transport)
        await #expect(throws: Error.self) {
            try await oauth.poll(DeviceChallenge(deviceCode: "expired-fixture", userCode: "TEST", expiresAt: .distantPast, interval: 5, clientID: "public"))
        }
        #expect(await transport.requests().isEmpty)
    }

    @Test func credentialsRestoreAndRefreshAtomically() async throws {
        let old = Credential(accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: .distantPast, clientID: "public")
        let fresh = Credential(accessToken: "fixture-new", refreshToken: "fixture-next", expiresAt: .distantFuture, clientID: "public")
        let storage = MemoryStorage(old)
        let session = CredentialSession(storage: storage, oauth: MockOAuth(refreshHandler: { _ in fresh }))
        #expect(try await session.restore())
        #expect(try await session.accessToken() == "fixture-new")
        #expect(try storage.load() == fresh)
        #expect(storage.saveCount() == 1)
        let nextLaunch = CredentialSession(storage: storage, oauth: MockOAuth())
        #expect(try await nextLaunch.restore())
        #expect(try await nextLaunch.accessToken() == "fixture-new")
    }

    @Test func logoutDuringRefreshCannotResurrectSession() async throws {
        let gate = Gate()
        let old = Credential(accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: .distantPast, clientID: "public")
        let storage = MemoryStorage(old)
        let session = CredentialSession(storage: storage, oauth: MockOAuth(refreshHandler: { _ in
            await gate.wait()
            return Credential(accessToken: "fixture-new", expiresAt: .distantFuture)
        }))
        _ = try await session.restore()
        let request = Task { try await session.accessToken() }
        await gate.waitUntilRequested()
        try await session.clear()
        await gate.open()
        await #expect(throws: Error.self) { try await request.value }
        #expect(try storage.load() == nil)
        #expect(storage.saveCount() == 0)
    }

    @Test func temporaryRefreshFailurePreservesStoredCredential() async throws {
        let credential = Credential(accessToken: "fixture-old", refreshToken: "fixture-refresh", expiresAt: .distantPast, clientID: "public")
        let storage = MemoryStorage(credential)
        let session = CredentialSession(storage: storage, oauth: MockOAuth(refreshHandler: { _ in throw FjordError.http(503, "offline") }))
        _ = try await session.restore()
        await #expect(throws: Error.self) { try await session.accessToken() }
        #expect(try storage.load() == credential)
    }
}

struct KeychainTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FJORD_KEYCHAIN_TEST"] == "1"))
    func isolatedKeychainRoundTrip() throws {
        let storage = KeychainCredentialStorage(service: "no.oddmund.Fjord.tests.\(UUID().uuidString)")
        defer { try? storage.delete() }
        let original = Credential(accessToken: "fixture-not-a-github-token")
        #expect(try storage.load() == nil)
        try storage.save(original)
        #expect(try storage.load() == original)
        let updated = Credential(accessToken: "fixture-updated-not-a-github-token")
        try storage.save(updated)
        #expect(try storage.load() == updated)
        try storage.delete()
        #expect(try storage.load() == nil)
    }
}
