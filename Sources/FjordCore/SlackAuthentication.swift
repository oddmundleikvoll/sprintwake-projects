import Foundation
import CryptoKit
import Security

/// The public-client OAuth flow used by the macOS Slack integration.
public struct SlackOAuthClient: SlackOAuthAuthenticating {
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(transport: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    public func authorization(clientID: String, includePrivateChannels: Bool) throws -> SlackAuthorization {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeClientID(clientID) else {
            throw SlackError.message(L10n.core("Enter a valid public Slack Client ID first."))
        }
        let state = try randomURLSafe(bytes: 32)
        let verifier = try randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents(string: "https://slack.com/oauth/v2/authorize")!
        var scopes = ["channels:read", "channels:history", "users:read", "chat:write"]
        if includePrivateChannels { scopes += ["groups:read", "groups:history"] }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "user_scope", value: scopes.joined(separator: ",")),
            URLQueryItem(name: "redirect_uri", value: SlackAuthorization.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return SlackAuthorization(url: components.url!, state: state, codeVerifier: verifier,
                                  clientID: clientID, redirectURI: SlackAuthorization.redirectURI,
                                  expiresAt: now().addingTimeInterval(600))
    }

    public func exchange(_ authorization: SlackAuthorization, callback: URL) async throws -> SlackCredential {
        guard now() < authorization.expiresAt, authorization.redirectURI == SlackAuthorization.redirectURI,
              !authorization.clientID.isEmpty, !authorization.state.isEmpty, !authorization.codeVerifier.isEmpty else { throw invalidCallback() }
        guard let callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              callbackComponents.scheme == "sprintwake-slack", callbackComponents.host == "oauth",
              callbackComponents.path == "/callback", callbackComponents.port == nil,
              callbackComponents.user == nil, callbackComponents.password == nil,
              callbackComponents.fragment == nil else { throw invalidCallback() }
        let items = callbackComponents.queryItems ?? []
        let stateItems = items.filter { $0.name == "state" }
        let codeItems = items.filter { $0.name == "code" }
        guard !items.contains(where: { $0.name == "error" }), stateItems.count == 1, codeItems.count == 1,
              let state = stateItems[0].value, let code = codeItems[0].value,
              !code.isEmpty, state == authorization.state else {
            throw invalidCallback()
        }
        let response = try await request(fields: [
            "client_id": authorization.clientID, "code": code,
            "code_verifier": authorization.codeVerifier, "redirect_uri": authorization.redirectURI
        ])
        return try credential(from: response, clientID: authorization.clientID)
    }

    public func refresh(_ credential: SlackCredential) async throws -> SlackCredential {
        guard let refreshToken = credential.refreshToken,
              credential.refreshExpiresAt.map({ $0 > now() }) ?? true else { throw SlackError.unauthenticated }
        let response = try await request(fields: [
            "client_id": credential.clientID, "grant_type": "refresh_token", "refresh_token": refreshToken
        ])
        let nested = response.authed_user
        let tokenType = response.token_type ?? nested?.token_type
        guard tokenType == "user", let access = response.access_token ?? nested?.access_token, !access.isEmpty else { throw SlackError.unauthenticated }
        if let team = response.team?.id, team != credential.teamID { throw invalidResponse() }
        if let user = nested?.user_id ?? nested?.id, user != credential.userID { throw invalidResponse() }
        let rotatedRefresh = response.refresh_token ?? nested?.refresh_token
        let refreshLifetime = response.refresh_token_expires_in ?? nested?.refresh_token_expires_in
        let refreshExpiry = refreshLifetime.flatMap { validExpiry($0) }.map { now().addingTimeInterval($0) }
            ?? (rotatedRefresh != nil ? now().addingTimeInterval(30 * 24 * 60 * 60) : credential.refreshExpiresAt)
        let scopes = (response.scope ?? nested?.scope).map(parseScopes) ?? credential.scopes
        let expiry = response.expires_in ?? nested?.expires_in
        guard let expiry, let lifetime = validExpiry(expiry), let rotatedRefresh, !rotatedRefresh.isEmpty else { throw invalidResponse() }
        return SlackCredential(accessToken: access, refreshToken: response.refresh_token ?? nested?.refresh_token ?? refreshToken,
                               expiresAt: now().addingTimeInterval(lifetime),
                               refreshExpiresAt: refreshExpiry, clientID: credential.clientID,
                               teamID: credential.teamID, teamName: response.team?.name ?? credential.teamName,
                               userID: credential.userID, scopes: scopes)
    }

    private func credential(from response: SlackOAuthResponse, clientID: String) throws -> SlackCredential {
        guard let user = response.authed_user, let token = user.access_token, !token.isEmpty,
              user.token_type == "user", let team = response.team,
              !team.id.isEmpty, let userID = user.user_id ?? user.id, !userID.isEmpty,
              let refresh = user.refresh_token, !refresh.isEmpty,
              let expires = user.expires_in, let lifetime = validExpiry(expires) else { throw invalidResponse() }
        let scopes = parseScopes(user.scope ?? response.scope ?? "")
        guard !scopes.isEmpty else { throw invalidResponse() }
        return SlackCredential(accessToken: token, refreshToken: refresh,
                               expiresAt: now().addingTimeInterval(lifetime),
                               refreshExpiresAt: user.refresh_token_expires_in.flatMap(validExpiry).map { now().addingTimeInterval($0) }
                                   ?? (user.refresh_token != nil ? now().addingTimeInterval(30 * 24 * 60 * 60) : nil),
                               clientID: clientID, teamID: team.id, teamName: team.name ?? "",
                               userID: userID, scopes: scopes)
    }

    private func request(fields: [String: String]) async throws -> SlackOAuthResponse {
        var request = URLRequest(url: URL(string: "https://slack.com/api/oauth.v2.access")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Sprintwake Projects/0.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = formEncoded(fields).data(using: .utf8)
        let response: HTTPResponse
        do { response = try await transport.send(request) }
        catch { throw SlackError.message(L10n.core("Slack sign-in could not be completed. Try again.")) }
        let payload = try? JSONDecoder().decode(SlackOAuthResponse.self, from: response.data)
        if response.status == 429 { throw SlackError.rateLimited(retryAfter: retryAfter(response.headers)) }
        if response.status == 401 { throw SlackError.unauthenticated }
        if response.status == 403 { throw SlackError.permissionDenied }
        if let error = payload?.error, error != "" { throw apiError(error) }
        guard (200..<300).contains(response.status), let payload, payload.ok == true else { throw SlackError.message(L10n.core("Slack sign-in could not be completed. Try again.")) }
        return payload
    }

    private func apiError(_ code: String) -> SlackError {
        switch code.lowercased() {
        case "invalid_auth", "token_revoked", "token_expired", "refresh_invalid", "invalid_refresh_token", "invalid_grant", "bad_refresh_token": return .unauthenticated
        case "missing_scope", "not_allowed", "access_denied": return .permissionDenied
        default: return .message(L10n.core("Slack sign-in could not be completed. Try again."))
        }
    }
    private func retryAfter(_ headers: [String: String]) -> TimeInterval {
        let value = headers.first { $0.key.lowercased() == "retry-after" }.map { Double($0.value) ?? 60 } ?? 60
        return value.isFinite && value > 0 ? value : 60
    }
    private func validExpiry(_ value: TimeInterval) -> TimeInterval? { value.isFinite && value > 0 ? value : nil }
    private func formEncoded(_ fields: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.sorted { $0.key < $1.key }.map { key, value in
            let encode: (String) -> String = { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
            return "\(encode(key))=\(encode(value))"
        }.joined(separator: "&")
    }
    private func parseScopes(_ value: String) -> Set<String> { Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) }
    private func isSafeClientID(_ value: String) -> Bool { !value.isEmpty && value.count <= 200 && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) } }
    private func randomURLSafe(bytes: Int) throws -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        guard status == errSecSuccess else { throw SlackError.message(L10n.core("Could not prepare Slack sign-in securely.")) }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func invalidCallback() -> SlackError { .message(L10n.core("The Slack sign-in callback was invalid. Start again.")) }
    private func invalidResponse() -> SlackError { .message(L10n.core("Slack returned an incomplete sign-in response.")) }
}

private struct SlackOAuthResponse: Decodable, Sendable {
    let ok: Bool?
    let error: String?
    let access_token: String?
    let token_type: String?
    let refresh_token: String?
    let expires_in: TimeInterval?
    let refresh_token_expires_in: TimeInterval?
    let scope: String?
    let team: SlackTeam?
    let authed_user: SlackAuthedUser?
}
private struct SlackTeam: Decodable, Sendable { let id: String; let name: String? }
private struct SlackAuthedUser: Decodable, Sendable {
    let id: String?
    let user_id: String?
    let access_token: String?
    let token_type: String?
    let refresh_token: String?
    let expires_in: TimeInterval?
    let refresh_token_expires_in: TimeInterval?
    let scope: String?
}

public struct SlackKeychainCredentialStorage: SlackCredentialStorage {
    private let account: String
    private let service: String
    public init(account: String = "slack-session", service: String = "no.oddmund.Fjord.slack") { self.account = account; self.service = service }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    public func load() throws -> SlackCredential? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }; try check(status)
        guard let data = result as? Data else { throw SlackError.message(L10n.core("The Slack sign-in could not be read from Keychain.")) }
        return try JSONDecoder().decode(SlackCredential.self, from: data)
    }
    public func save(_ credential: SlackCredential) throws {
        let data = try JSONEncoder().encode(credential); let updates: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound { var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; item[kSecAttrLabel as String] = "Sprintwake Projects Slack sign-in"; try check(SecItemAdd(item as CFDictionary, nil)) } else { try check(status) }
    }
    public func delete() throws { let status = SecItemDelete(query as CFDictionary); if status != errSecItemNotFound { try check(status) } }
    private func check(_ status: OSStatus) throws { guard status == errSecSuccess else { throw SlackError.message(L10n.core("Keychain is unavailable.")) } }
}

public actor SlackCredentialSession {
    private let storage: any SlackCredentialStorage
    private let oauth: any SlackOAuthAuthenticating
    private let now: @Sendable () -> Date
    private var credential: SlackCredential?
    private var generation = UUID()
    private var refreshTask: Task<SlackCredential, Error>?
    public init(storage: any SlackCredentialStorage, oauth: any SlackOAuthAuthenticating, now: @escaping @Sendable () -> Date = { Date() }) { self.storage = storage; self.oauth = oauth; self.now = now }
    public func restore() throws -> Bool { let value = try storage.load(); refreshTask?.cancel(); refreshTask = nil; credential = value; generation = UUID(); return value != nil }
    public func activate(_ value: SlackCredential) throws { try Task.checkCancellation(); try storage.save(value); refreshTask?.cancel(); refreshTask = nil; credential = value; generation = UUID() }
    public func clear() throws { try storage.delete(); refreshTask?.cancel(); refreshTask = nil; credential = nil; generation = UUID() }
    public func current() async throws -> SlackCredential {
        guard let original = credential else { throw SlackError.unauthenticated }
        guard let expiry = original.expiresAt, expiry <= now().addingTimeInterval(60) else { return original }
        let expected = generation; let task: Task<SlackCredential, Error>
        if let active = refreshTask { task = active } else { task = Task { try await oauth.refresh(original) }; refreshTask = task }
        do {
            let refreshed = try await task.value
            guard generation == expected else {
                if credential == refreshed { return refreshed }
                throw SlackError.cancelled
            }
            try Task.checkCancellation(); try storage.save(refreshed); credential = refreshed; generation = UUID(); refreshTask = nil; return refreshed
        }
        catch {
            // A cancelled waiter must not cancel the shared refresh or discard it;
            // another caller may still be waiting for the same rotating token.
            if !(error is CancellationError) && generation == expected { refreshTask = nil }
            throw error
        }
    }
}
