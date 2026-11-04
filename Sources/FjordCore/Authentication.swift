import Foundation
import Security

public struct Credential: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let refreshExpiresAt: Date?
    public let clientID: String?
    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
                refreshExpiresAt: Date? = nil, clientID: String? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
        self.refreshExpiresAt = refreshExpiresAt; self.clientID = clientID
    }
}

public struct DeviceChallenge: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let expiresAt: Date
    public let interval: TimeInterval
    public let clientID: String
    public var verificationURL: URL { URL(string: "https://github.com/login/device")! }
    public init(deviceCode: String, userCode: String, expiresAt: Date, interval: TimeInterval, clientID: String) {
        self.deviceCode = deviceCode; self.userCode = userCode; self.expiresAt = expiresAt
        self.interval = interval; self.clientID = clientID
    }
}

public protocol OAuthAuthenticating: Sendable {
    func begin(clientID: String, includePrivateRepositories: Bool) async throws -> DeviceChallenge
    func poll(_ challenge: DeviceChallenge) async throws -> Credential
    func refresh(_ credential: Credential) async throws -> Credential
}

public struct DeviceOAuthClient: OAuthAuthenticating {
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    public init(transport: any HTTPTransport = URLSessionTransport(),
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.transport = transport; self.now = now; self.sleep = sleep
    }

    public func begin(clientID: String, includePrivateRepositories: Bool) async throws -> DeviceChallenge {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw FjordError.message(L10n.core("Enter the app's public OAuth Client ID first.")) }
        let scope = "read:user read:org project \(includePrivateRepositories ? "repo" : "public_repo")"
        let response: OAuthResponse = try await request(path: "device/code", fields: ["client_id": clientID, "scope": scope])
        if let error = response.error { throw oauthError(error) }
        guard let deviceCode = response.device_code, let userCode = response.user_code,
              let expires = response.expires_in, expires > 0 else { throw invalidResponse() }
        return DeviceChallenge(deviceCode: deviceCode, userCode: userCode, expiresAt: now().addingTimeInterval(expires),
                               interval: max(response.interval ?? 5, 1), clientID: clientID)
    }

    public func poll(_ challenge: DeviceChallenge) async throws -> Credential {
        var interval = challenge.interval
        while now() < challenge.expiresAt {
            try Task.checkCancellation()
            try await sleep(interval)
            try Task.checkCancellation()
            guard now() < challenge.expiresAt else { break }
            let response: OAuthResponse = try await request(path: "oauth/access_token", fields: [
                "client_id": challenge.clientID, "device_code": challenge.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            switch response.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5; continue
            case .some(let error): throw oauthError(error)
            case .none: return try credential(from: response, clientID: challenge.clientID)
            }
        }
        throw oauthError("expired_token")
    }

    public func refresh(_ credential: Credential) async throws -> Credential {
        guard let refresh = credential.refreshToken, let clientID = credential.clientID,
              credential.refreshExpiresAt.map({ $0 > now() }) ?? true else { throw FjordError.unauthenticated }
        let response: OAuthResponse = try await request(path: "oauth/access_token", fields: [
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh
        ])
        if let error = response.error { throw oauthError(error) }
        return try self.credential(from: response, clientID: clientID)
    }

    private func credential(from response: OAuthResponse, clientID: String) throws -> Credential {
        guard let token = response.access_token, !token.isEmpty else { throw invalidResponse() }
        return Credential(accessToken: token, refreshToken: response.refresh_token,
                          expiresAt: response.expires_in.map { now().addingTimeInterval($0) },
                          refreshExpiresAt: response.refresh_token_expires_in.map { now().addingTimeInterval($0) },
                          clientID: clientID)
    }

    private func request<T: Decodable>(path: String, fields: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://github.com/login/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Fjord-Mac/0.1", forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let response = try await transport.send(request)
        try checkResponse(response)
        return try JSONDecoder().decode(T.self, from: response.data)
    }

    private func invalidResponse() -> FjordError { .message(L10n.core("GitHub returned an incomplete sign-in response.")) }
    private func oauthError(_ code: String) -> FjordError {
        switch code {
        case "expired_token", "token_expired": .message(L10n.core("The sign-in code expired. Start sign-in again."))
        case "access_denied": .message(L10n.core("GitHub denied the sign-in. You can try again."))
        case "invalid_grant", "bad_refresh_token", "invalid_refresh_token": .unauthenticated
        case "incorrect_client_credentials", "invalid_client": .message(L10n.core("GitHub does not recognize this Client ID. Check the app configuration."))
        case "device_flow_disabled", "unauthorized_client": .message(L10n.core("Device Flow is not enabled. Turn on “Enable Device Flow” in the OAuth app's GitHub settings."))
        default: .message(L10n.core("GitHub could not complete sign-in (%@). Try again.", code))
        }
    }
}

private struct OAuthResponse: Decodable {
    let device_code: String?
    let user_code: String?
    let expires_in: TimeInterval?
    let interval: TimeInterval?
    let access_token: String?
    let refresh_token: String?
    let refresh_token_expires_in: TimeInterval?
    let error: String?
}

public protocol CredentialStorage: Sendable {
    func load() throws -> Credential?
    func save(_ credential: Credential) throws
    func delete() throws
}

public struct KeychainCredentialStorage: CredentialStorage {
    private let service: String
    private let account = "github-session"
    public init(service: String = "no.oddmund.Fjord.github") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func load() throws -> Credential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw FjordError.message(L10n.core("The sign-in could not be read from Keychain.")) }
        return try JSONDecoder().decode(Credential.self, from: data)
    }
    public func save(_ credential: Credential) throws {
        let data = try JSONEncoder().encode(credential)
        let updates: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "Sprintwake Projects GitHub sign-in"
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let explanation = SecCopyErrorMessageString(status, nil) as String? ?? "Ukjent feil"
            throw FjordError.message(L10n.core("Keychain is unavailable: %@", explanation))
        }
    }
}

public actor CredentialSession {
    private let storage: any CredentialStorage
    private let oauth: any OAuthAuthenticating
    private let now: @Sendable () -> Date
    private var credential: Credential?
    private var generation = UUID()
    private var refreshTask: Task<Credential, Error>?

    public init(storage: any CredentialStorage, oauth: any OAuthAuthenticating,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.storage = storage; self.oauth = oauth; self.now = now
    }
    public func restore() throws -> Bool {
        let stored = try storage.load()
        refreshTask?.cancel(); refreshTask = nil
        credential = stored
        generation = UUID()
        return credential != nil
    }
    public func activate(_ newCredential: Credential) throws {
        try Task.checkCancellation()
        try storage.save(newCredential)
        refreshTask?.cancel(); refreshTask = nil
        credential = newCredential; generation = UUID()
    }
    public func clear() throws {
        // Retain a usable session if Keychain deletion fails; never claim sign-out succeeded.
        try storage.delete()
        refreshTask?.cancel(); refreshTask = nil
        credential = nil; generation = UUID()
    }
    public func accessToken() async throws -> String {
        guard let original = credential else { throw FjordError.unauthenticated }
        guard let expiry = original.expiresAt, expiry <= now().addingTimeInterval(60) else { return original.accessToken }
        let expected = generation
        let task: Task<Credential, Error>
        if let active = refreshTask { task = active }
        else {
            task = Task { try await oauth.refresh(original) }
            refreshTask = task
        }
        do {
            let refreshed = try await task.value
            guard generation == expected else {
                if credential == refreshed { return refreshed.accessToken }
                throw FjordError.cancelled
            }
            try storage.save(refreshed)
            credential = refreshed; generation = UUID(); refreshTask = nil
            return refreshed.accessToken
        } catch {
            if generation == expected { refreshTask = nil }
            throw error
        }
    }
}
