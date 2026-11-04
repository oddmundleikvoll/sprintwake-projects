import Foundation
import Observation

public struct SlackChatContext: Hashable, Sendable {
    public let accountID: String?
    public let projectID: String?
    public let isDemo: Bool
    public init(accountID: String?, projectID: String?, isDemo: Bool) {
        self.accountID = accountID; self.projectID = projectID; self.isDemo = isDemo
    }
}

public enum SlackSendOutcome: Sendable { case sent, failed, uncertain }

private struct SlackChannelBinding: Codable {
    let teamID: String
    let userID: String
    let channel: SlackChannel
}

/// Slack permissions and credentials are independent of GitHub project permissions.
@MainActor @Observable
public final class SlackChatModel {
    public private(set) var context = SlackChatContext(accountID: nil, projectID: nil, isDemo: false)
    public private(set) var source = ConversationSource.github
    public private(set) var identity: SlackIdentity?
    public private(set) var channels: [SlackChannel] = []
    public private(set) var channel: SlackChannel?
    public private(set) var messages: [SlackMessage] = []
    public private(set) var userNames: [String: String] = [:]
    public private(set) var isRestoring = false
    public private(set) var isAuthenticating = false
    public private(set) var isLoadingChannels = false
    public private(set) var isLoadingMessages = false
    public private(set) var isSending = false
    public private(set) var canRetryRestore = false
    public private(set) var lastSync: Date?
    public private(set) var retryAfter: Date?
    public private(set) var deliveryNeedsReview = false
    public private(set) var nextCursor: String?
    public var errorMessage: String?
    public var notice: String?

    private let preferences: UserDefaults
    private let oauth: any SlackOAuthAuthenticating
    private let storageForAccount: @Sendable (String) -> any SlackCredentialStorage
    private let makeAPI: @Sendable (String) -> any SlackAPI
    private let now: @Sendable () -> Date
    private var session: SlackCredentialSession?
    private var scopes: Set<String> = []
    private var sessionGeneration = UUID()
    private var channelGeneration = UUID()
    private var messageGeneration = UUID()
    private var authGeneration = UUID()
    private var pendingAuthorization: SlackAuthorization?
    private var demoAPI: DemoSlackAPI?
    private var demoSources: [String: ConversationSource] = [:]
    private var demoBindings: [String: SlackChannelBinding] = [:]
    private var loadedOlder = false
    private var hasLoadedChannels = false
    private var seenCursors: Set<String> = []
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var authTask: Task<Void, Never>?

    public init(preferences: UserDefaults = .standard,
                oauth: any SlackOAuthAuthenticating = SlackOAuthClient(),
                storageForAccount: @escaping @Sendable (String) -> any SlackCredentialStorage = { SlackKeychainCredentialStorage(account: $0) },
                makeAPI: @escaping @Sendable (String) -> any SlackAPI = { SlackClient(token: $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.preferences = preferences; self.oauth = oauth; self.storageForAccount = storageForAccount
        self.makeAPI = makeAPI; self.now = now
    }

    public var isConnected: Bool { identity != nil }
    public var includePrivateChannels: Bool { context.isDemo || scopes.contains("groups:read") }
    public var canSend: Bool {
        identity != nil && channel?.isMember == true && channel?.isArchived == false
        && scopes.contains("chat:write") && !isSending && !isAuthenticating && !deliveryNeedsReview
        && !(retryAfter.map { $0 > now() } ?? false)
    }
    public var channelURL: URL? {
        guard let teamID = identity?.teamID, let channelID = channel?.id,
              Self.validID(teamID), Self.validID(channelID) else { return nil }
        return URL(string: "https://app.slack.com/client/\(teamID)/\(channelID)")
    }
    public func messageURL(_ message: SlackMessage) -> URL? {
        guard var components = channelURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        components.queryItems = [URLQueryItem(name: "thread_ts", value: message.id), URLQueryItem(name: "cid", value: channel?.id)]
        return components.url
    }

    /// Called synchronously when the GitHub account/project changes; stale data disappears immediately.
    @discardableResult public func updateContext(_ next: SlackChatContext) -> Task<Void, Never>? {
        guard next != context else { return nil }
        let accountChanged = next.accountID != context.accountID || next.isDemo != context.isDemo
        context = next
        clearChannel()
        source = storedSource()
        errorMessage = nil; notice = nil
        if accountChanged {
            cancelAuthorization()
            restoreTask?.cancel(); restoreTask = nil
            sessionGeneration = UUID()
            identity = nil; scopes = []; channels = []; userNames = [:]; session = nil; demoAPI = nil; hasLoadedChannels = false
            isRestoring = false; isLoadingChannels = false; canRetryRestore = false; retryAfter = nil
            guard let accountID = next.accountID else { return nil }
            if next.isDemo {
                let demo = DemoSlackAPI(); demoAPI = demo
                identity = DemoSlackAPI.demoIdentity
                scopes = ["channels:read", "channels:history", "groups:read", "groups:history", "users:read", "chat:write"]
                applyBinding()
                restoreTask = Task { await self.loadChannels() }
            } else {
                session = SlackCredentialSession(storage: storageForAccount(accountID), oauth: oauth, now: now)
                let expected = sessionGeneration
                restoreTask = Task { await self.restore(expected: expected) }
            }
            return restoreTask
        } else if identity != nil {
            applyBinding()
            if source == .slack { selectionTask = Task { await self.refresh() } }
            return selectionTask
        }
        return nil
    }

    public func setSource(_ value: ConversationSource) {
        guard context.projectID != nil, context.accountID != nil else { return }
        source = value
        if context.isDemo { demoSources[projectKey] = value }
        else { preferences.set(value.rawValue, forKey: "slack.source.\(projectKey)") }
        if value == .slack, messages.isEmpty { selectionTask = Task { await self.refresh() } }
    }

    @discardableResult public func chooseChannel(_ id: String?) -> Task<Void, Never>? {
        guard let identity, context.projectID != nil else { return nil }
        clearChannel()
        guard let id, let selected = channels.first(where: { $0.id == id && !$0.isArchived }) else {
            if context.isDemo { demoBindings.removeValue(forKey: projectKey) }
            else { preferences.removeObject(forKey: "slack.channel.\(projectKey)") }
            return nil
        }
        channel = selected
        let binding = SlackChannelBinding(teamID: identity.teamID, userID: identity.userID, channel: selected)
        if context.isDemo { demoBindings[projectKey] = binding }
        else if let data = try? JSONEncoder().encode(binding) { preferences.set(data, forKey: "slack.channel.\(projectKey)") }
        setSource(.slack)
        return selectionTask
    }

    public func retryRestore() async { await restore(expected: sessionGeneration) }

    private func restore(expected: UUID) async {
        guard !context.isDemo, let session, context.accountID != nil, !isRestoring else { return }
        isRestoring = true; canRetryRestore = false; errorMessage = nil
        defer { if expected == sessionGeneration { isRestoring = false } }
        do {
            guard try await session.restore() else { return }
            let credential = try await session.current()
            let profile = try await makeAPI(credential.accessToken).identity()
            guard expected == sessionGeneration, !Task.isCancelled else { return }
            try verify(profile, credential: credential)
            identity = profile; scopes = credential.scopes; applyBinding()
            await loadChannels()
        } catch {
            guard expected == sessionGeneration, !Task.isCancelled else { return }
            canRetryRestore = true
            await handle(error, expected: expected)
        }
    }

    public func beginAuthorization(clientID: String, includePrivateChannels: Bool) -> SlackAuthorization? {
        guard context.accountID != nil, !context.isDemo, !isAuthenticating, !isRestoring else { return nil }
        do {
            let authorization = try oauth.authorization(clientID: clientID, includePrivateChannels: includePrivateChannels)
            authGeneration = UUID(); pendingAuthorization = authorization; isAuthenticating = true
            errorMessage = nil; notice = nil
            return authorization
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    @discardableResult public func completeAuthorization(_ authorization: SlackAuthorization, callback: URL) -> Task<Void, Never>? {
        guard pendingAuthorization == authorization, isAuthenticating, let session else { return nil }
        let expected = sessionGeneration, authID = authGeneration
        // Consume the callback once, including when exchanging it fails.
        pendingAuthorization = nil
        let task = Task {
            defer { if authID == self.authGeneration { self.isAuthenticating = false } }
            do {
                let credential = try await self.oauth.exchange(authorization, callback: callback)
                try Task.checkCancellation()
                let profile = try await self.makeAPI(credential.accessToken).identity()
                try Task.checkCancellation()
                guard expected == self.sessionGeneration, authID == self.authGeneration else { return }
                try self.verify(profile, credential: credential)
                try await session.activate(credential)
                guard expected == self.sessionGeneration, authID == self.authGeneration else { return }
                self.restoreTask?.cancel(); self.selectionTask?.cancel()
                self.sessionGeneration = UUID(); self.clearChannel()
                self.identity = profile; self.scopes = credential.scopes; self.channels = []; self.userNames = [:]; self.hasLoadedChannels = false
                self.isRestoring = false; self.isLoadingChannels = false; self.canRetryRestore = false; self.retryAfter = nil
                self.isAuthenticating = false; self.applyBinding()
                await self.loadChannels()
            } catch {
                guard expected == self.sessionGeneration, authID == self.authGeneration, !Task.isCancelled else { return }
                // A rejected replacement never deletes a working Slack credential.
                self.errorMessage = error.localizedDescription
            }
        }
        authTask = task
        return task
    }

    public func cancelAuthorization() {
        authTask?.cancel(); authTask = nil
        authGeneration = UUID(); pendingAuthorization = nil; isAuthenticating = false
    }

    public func disconnect() async {
        cancelAuthorization(); restoreTask?.cancel(); selectionTask?.cancel()
        let session = session, previousIdentity = identity
        sessionGeneration = UUID(); let expected = sessionGeneration
        clearChannel(); identity = nil; channels = []; userNames = [:]
        isRestoring = false; isLoadingChannels = false; canRetryRestore = false
        if context.isDemo { demoBindings.removeAll(); demoSources.removeAll(); source = .github; return }
        do {
            try await session?.clear()
            guard expected == sessionGeneration else { return }
            scopes = []; notice = L10n.core("Slack was disconnected on this Mac."); errorMessage = nil
        } catch {
            guard expected == sessionGeneration else { return }
            identity = previousIdentity; applyBinding(); errorMessage = error.localizedDescription
        }
    }

    public func loadChannels() async {
        guard identity != nil, !isLoadingChannels, requestsAllowed else { return }
        let expected = sessionGeneration
        isLoadingChannels = true
        defer { if expected == sessionGeneration { isLoadingChannels = false } }
        do {
            let api = try await client()
            let result = try await api.channels(includePrivate: includePrivateChannels)
            guard expected == sessionGeneration, !Task.isCancelled else { return }
            channels = result.filter { !$0.isArchived }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            hasLoadedChannels = true
            applyBinding()
            if source == .slack, channel != nil { await refresh() }
        } catch { await handle(error, expected: expected) }
    }

    public func refresh() async { await loadMessages(older: false) }
    public func loadOlder() async { await loadMessages(older: true) }

    private func loadMessages(older: Bool) async {
        guard let channel, identity != nil, !isLoadingMessages, !isAuthenticating, requestsAllowed else { return }
        let cursor = older ? nextCursor : nil
        if older && cursor == nil { return }
        let expected = sessionGeneration, selection = channelGeneration
        let messagesAtStart = messageGeneration
        isLoadingMessages = true
        defer { if expected == sessionGeneration, selection == channelGeneration { isLoadingMessages = false } }
        do {
            let api = try await client()
            let page = try await api.history(channelID: channel.id, cursor: cursor)
            guard expected == sessionGeneration, selection == channelGeneration, !Task.isCancelled else { return }
            // A history request started before a confirmed send must not erase it.
            guard messagesAtStart == messageGeneration else { return }
            if older, let next = page.nextCursor, next == cursor || seenCursors.contains(next) {
                throw SlackError.message(L10n.core("Slack returned incomplete pagination. Refresh the channel and try again."))
            }
            if older {
                if let cursor { seenCursors.insert(cursor) }
                loadedOlder = true; merge(page.messages)
                nextCursor = page.nextCursor
            } else {
                if !page.hasMore { messages = []; nextCursor = nil; loadedOlder = false; seenCursors = [] }
                else if let oldest = page.messages.map(\.id).min(by: Self.timestampLess) {
                    // Replace the refreshed time window so edits/deletions do not linger.
                    messages.removeAll { !Self.timestampLess($0.id, oldest) }
                }
                merge(page.messages)
                if !loadedOlder { nextCursor = page.nextCursor; seenCursors = [] }
            }
            lastSync = now(); errorMessage = nil; retryAfter = nil
            await resolveAuthors(api: api, expected: expected, selection: selection)
        } catch { await handle(error, expected: expected, selection: selection) }
    }

    public func send(_ text: String) async -> SlackSendOutcome {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, let channel, !text.isEmpty, text.count <= 4_000 else { return .failed }
        let expected = sessionGeneration, selection = channelGeneration
        isSending = true; errorMessage = nil; notice = nil
        defer { if expected == sessionGeneration, selection == channelGeneration { isSending = false } }
        do {
            let api = try await client()
            let message = try await api.postMessage(channelID: channel.id, text: text)
            guard expected == sessionGeneration, selection == channelGeneration else { return .sent }
            messageGeneration = UUID()
            merge([message]); lastSync = now()
            // The confirmed message is enough; a failed later refresh must not invite a duplicate send.
            return .sent
        } catch {
            guard expected == sessionGeneration, selection == channelGeneration else { return .failed }
            if (error as? SlackError) == .deliveryUnconfirmed {
                deliveryNeedsReview = true; notice = SlackError.deliveryUnconfirmed.localizedDescription
                return .uncertain
            }
            await handle(error, expected: expected, selection: selection)
            return .failed
        }
    }

    public func acknowledgeUnconfirmedDelivery() { deliveryNeedsReview = false; notice = nil }

    private func resolveAuthors(api: any SlackAPI, expected: UUID, selection: UUID) async {
        let ids = Set(messages.compactMap(\.userID)).filter { userNames[$0] == nil }.sorted().prefix(30)
        for id in ids {
            guard !Task.isCancelled, expected == sessionGeneration, selection == channelGeneration else { return }
            do {
                let name = try await api.userName(id: id)
                guard expected == sessionGeneration, selection == channelGeneration else { return }
                userNames[id] = name
            } catch {
                // Profile names are optional, but their rate limit applies to the
                // connection too. Stop enrichment rather than retrying every author.
                if case .rateLimited = error as? SlackError { await handle(error, expected: expected, selection: selection) }
                else if (error as? SlackError) == .unauthenticated { await handle(error, expected: expected, selection: selection) }
                return
            }
        }
    }

    private var requestsAllowed: Bool { !(retryAfter.map { $0 > now() } ?? false) }
    private var projectKey: String { "\(context.accountID ?? "").\(context.projectID ?? "")" }
    private func storedSource() -> ConversationSource {
        guard context.projectID != nil else { return .github }
        if context.isDemo { return demoSources[projectKey] ?? .github }
        return preferences.string(forKey: "slack.source.\(projectKey)").flatMap(ConversationSource.init(rawValue:)) ?? .github
    }
    private func applyBinding() {
        guard let identity, context.projectID != nil else { channel = nil; return }
        let binding: SlackChannelBinding?
        if context.isDemo { binding = demoBindings[projectKey] }
        else { binding = preferences.data(forKey: "slack.channel.\(projectKey)").flatMap { try? JSONDecoder().decode(SlackChannelBinding.self, from: $0) } }
        guard let binding, binding.teamID == identity.teamID, binding.userID == identity.userID else { channel = nil; return }
        if let current = channels.first(where: { $0.id == binding.channel.id }) { channel = current }
        else if hasLoadedChannels {
            clearChannel()
            if context.isDemo { demoBindings.removeValue(forKey: projectKey) }
            else { preferences.removeObject(forKey: "slack.channel.\(projectKey)") }
        } else { channel = binding.channel }
    }
    private func clearChannel() {
        selectionTask?.cancel(); selectionTask = nil
        channelGeneration = UUID(); channel = nil; messages = []; nextCursor = nil
        seenCursors = []; loadedOlder = false; isLoadingMessages = false; isSending = false
        deliveryNeedsReview = false; lastSync = nil; errorMessage = nil; notice = nil
    }
    private func merge(_ items: [SlackMessage]) {
        var byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        for item in items { byID[item.id] = item }
        messages = byID.values.sorted { Self.timestampLess($0.id, $1.id) }
    }
    private static func timestampLess(_ left: String, _ right: String) -> Bool {
        let lhs = Decimal(string: left, locale: Locale(identifier: "en_US_POSIX")) ?? 0
        let rhs = Decimal(string: right, locale: Locale(identifier: "en_US_POSIX")) ?? 0
        return lhs == rhs ? left < right : lhs < rhs
    }
    private func client() async throws -> any SlackAPI {
        if context.isDemo, let demoAPI { return demoAPI }
        guard let session else { throw SlackError.unauthenticated }
        return makeAPI(try await session.current().accessToken)
    }
    private func verify(_ profile: SlackIdentity, credential: SlackCredential) throws {
        guard profile.teamID == credential.teamID, profile.userID == credential.userID else {
            throw SlackError.message(L10n.core("Slack returned a different account or workspace. The previous connection was kept."))
        }
    }
    private func handle(_ error: Error, expected: UUID, selection: UUID? = nil) async {
        guard expected == sessionGeneration, selection.map({ $0 == channelGeneration }) ?? true,
              !(error is CancellationError), (error as? SlackError) != .cancelled else { return }
        if case .rateLimited(let interval) = error as? SlackError { retryAfter = now().addingTimeInterval(max(1, interval)) }
        if (error as? SlackError) == .unauthenticated {
            do { try await session?.clear() }
            catch { errorMessage = error.localizedDescription; return }
            guard expected == sessionGeneration else { return }
            cancelAuthorization(); sessionGeneration = UUID(); clearChannel()
            identity = nil; channels = []; scopes = []; isLoadingChannels = false; isRestoring = false; canRetryRestore = false
        }
        errorMessage = error.localizedDescription
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }
}
