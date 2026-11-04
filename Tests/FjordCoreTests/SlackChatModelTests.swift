import Foundation
import Testing
@testable import FjordCore

private final class ChatSlackStorage: SlackCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: SlackCredential?
    private var saves = 0
    init(_ value: SlackCredential? = chatCredential()) { credential = value }
    func load() throws -> SlackCredential? { lock.withLock { credential } }
    func save(_ value: SlackCredential) throws { lock.withLock { credential = value; saves += 1 } }
    func delete() throws { lock.withLock { credential = nil } }
    func saveCount() -> Int { lock.withLock { saves } }
}

private func chatCredential(token: String = "fixture", user: String = "U1") -> SlackCredential {
    SlackCredential(accessToken: token, clientID: "public", teamID: "T1", teamName: "Workspace", userID: user,
                    scopes: ["channels:read", "channels:history", "users:read", "chat:write"])
}

private struct ChatSlackOAuth: SlackOAuthAuthenticating {
    var result: @Sendable () async throws -> SlackCredential = { chatCredential(token: "replacement") }
    func authorization(clientID: String, includePrivateChannels: Bool) throws -> SlackAuthorization {
        SlackAuthorization(url: URL(string: "https://slack.com/oauth/v2/authorize")!, state: "fixture-state", codeVerifier: "fixture-verifier",
                           clientID: clientID, redirectURI: SlackAuthorization.redirectURI, expiresAt: .distantFuture)
    }
    func exchange(_ authorization: SlackAuthorization, callback: URL) async throws -> SlackCredential { try await result() }
    func refresh(_ credential: SlackCredential) async throws -> SlackCredential { credential }
}

private actor ChatSlackAPI: SlackAPI {
    var pages: [String: [SlackHistoryPage]] = [:]
    var profileError: SlackError?
    var readError: SlackError?
    var postError: SlackError?
    var historyCalls = 0
    var writes = 0
    var omittedChannel: String?
    var nameError: SlackError?
    var nameCalls = 0
    let gate: Gate?
    let gatedChannel: String?
    init(gate: Gate? = nil, gatedChannel: String? = nil) { self.gate = gate; self.gatedChannel = gatedChannel }
    func configure(pages: [String: [SlackHistoryPage]] = [:], profileError: SlackError? = nil, readError: SlackError? = nil, postError: SlackError? = nil) {
        self.pages = pages; self.profileError = profileError; self.readError = readError; self.postError = postError
    }
    func identity() async throws -> SlackIdentity {
        if let profileError { throw profileError }
        return SlackIdentity(teamID: "T1", teamName: "Workspace", userID: "U1", userName: "tester")
    }
    func channels(includePrivate: Bool) async throws -> [SlackChannel] {
        [SlackChannel(id: "C1", name: "project"), SlackChannel(id: "C2", name: "other"), SlackChannel(id: "C3", name: "not-joined", isMember: false)]
            .filter { $0.id != omittedChannel }
    }
    func omitChannel(_ id: String) { omittedChannel = id }
    func history(channelID: String, cursor: String?) async throws -> SlackHistoryPage {
        historyCalls += 1
        if channelID == gatedChannel { await gate?.wait() }
        if let readError { throw readError }
        if let page = pages[channelID]?.first {
            pages[channelID]?.removeFirst()
            return page
        }
        return SlackHistoryPage(messages: [SlackMessage(id: "100.000001", userID: "U1", text: channelID)])
    }
    func postMessage(channelID: String, text: String) async throws -> SlackMessage {
        writes += 1
        if let postError { throw postError }
        return SlackMessage(id: "200.000001", userID: "U1", text: text)
    }
    func userName(id: String) async throws -> String {
        nameCalls += 1
        if let nameError { throw nameError }
        return "tester"
    }
    func configureNameError(_ error: SlackError) { nameError = error }
    func profileCount() -> Int { nameCalls }
    func counts() -> (reads: Int, writes: Int) { (historyCalls, writes) }
}

@MainActor
struct SlackChatModelTests {
    private func preferences() -> UserDefaults { UserDefaults(suiteName: "Fjord.slack.tests.\(UUID())")! }
    private func context(_ project: String? = "P1", account: String? = "G1", demo: Bool = false) -> SlackChatContext {
        SlackChatContext(accountID: account, projectID: project, isDemo: demo)
    }
    private func subject(api: ChatSlackAPI, storage: ChatSlackStorage = ChatSlackStorage(), preferences: UserDefaults? = nil,
                         oauth: ChatSlackOAuth = ChatSlackOAuth()) -> SlackChatModel {
        SlackChatModel(preferences: preferences ?? self.preferences(), oauth: oauth,
                       storageForAccount: { _ in storage }, makeAPI: { _ in api })
    }

    @Test func channelBindingsAndSourceAreScopedToGitHubAccountAndProject() async throws {
        let api = ChatSlackAPI(), prefs = preferences(), storage = ChatSlackStorage()
        let model = subject(api: api, storage: storage, preferences: prefs)
        await model.updateContext(context())?.value
        #expect(model.source == .github)
        await model.chooseChannel("C1")?.value
        #expect(model.source == .slack)
        #expect(model.messages.first?.text == "C1")
        await model.updateContext(context("P2"))?.value
        #expect(model.channel == nil)
        #expect(model.messages.isEmpty)
        await model.chooseChannel("C2")?.value
        await model.updateContext(context("P1"))?.value
        #expect(model.channel?.id == "C1")
        #expect(model.source == .slack)
        await model.updateContext(context("P1", account: "G2"))?.value
        #expect(model.channel == nil)
        #expect(model.source == .github)
        #expect(storage.saveCount() == 0)
        let values = prefs.dictionaryRepresentation().values.compactMap { $0 as? Data }.compactMap { String(data: $0, encoding: .utf8) }
        #expect(!values.contains(where: { $0.contains("accessToken") || $0.contains("refreshToken") }))
    }

    @Test func lateHistoryCannotReplaceTheNewChannel() async throws {
        let gate = Gate()
        let gated = ChatSlackAPI(gate: gate, gatedChannel: "C1")
        let model = subject(api: gated)
        await model.updateContext(context())?.value
        let old = model.chooseChannel("C1")
        await gate.waitUntilRequested()
        await model.chooseChannel("C2")?.value
        await gate.open(); await old?.value
        #expect(model.channel?.id == "C2")
        #expect(model.messages.map(\.text) == ["C2"])
    }

    @Test func historyAlreadyInFlightCannotEraseAConfirmedSend() async throws {
        let gate = Gate(), api = ChatSlackAPI(gate: gate, gatedChannel: "C1")
        let model = subject(api: api)
        await model.updateContext(context())?.value
        let loading = model.chooseChannel("C1")
        await gate.waitUntilRequested()
        #expect(await model.send("Keep this message") == .sent)
        await gate.open(); await loading?.value
        #expect(model.messages.map(\.text) == ["Keep this message"])
        #expect(!model.isLoadingMessages)
        #expect(await api.counts().writes == 1)
    }

    @Test func signOutHidesSlackAndDoesNotLeakItIntoAnotherGitHubAccount() async throws {
        let first = ChatSlackStorage(), second = ChatSlackStorage(nil), api = ChatSlackAPI()
        let model = SlackChatModel(preferences: preferences(), oauth: ChatSlackOAuth(),
                                   storageForAccount: { $0 == "G1" ? first : second }, makeAPI: { _ in api })
        await model.updateContext(context())?.value
        await model.chooseChannel("C1")?.value
        model.updateContext(context(nil, account: nil))
        #expect(model.identity == nil)
        #expect(model.messages.isEmpty)
        await model.updateContext(context(account: "G2"))?.value
        #expect(model.identity == nil)
        #expect(model.channel == nil)
        #expect(try first.load() != nil) // Independent Slack connection can be restored for the same account.
    }

    @Test func refreshingChannelsRemovesAnUnavailableSavedChannel() async throws {
        let api = ChatSlackAPI(), prefs = preferences()
        let connected = subject(api: api, preferences: prefs)
        await connected.updateContext(context())?.value
        await connected.chooseChannel("C1")?.value
        await api.omitChannel("C1")
        await connected.loadChannels()
        #expect(connected.channel == nil)
        #expect(connected.messages.isEmpty)
        #expect(!connected.canSend)
        #expect(prefs.data(forKey: "slack.channel.G1.P1") == nil)
    }

    @Test func profileRateLimitsStopEnrichmentAndBlockFurtherRequestsUntilRetry() async throws {
        let api = ChatSlackAPI(), model = subject(api: api)
        await api.configure(pages: ["C1": [SlackHistoryPage(messages: [
            SlackMessage(id: "100.0", userID: "U1", text: "first"), SlackMessage(id: "200.0", userID: "U2", text: "second")
        ])]])
        await api.configureNameError(.rateLimited(retryAfter: 60))
        await model.updateContext(context())?.value
        await model.chooseChannel("C1")?.value
        #expect(await api.profileCount() == 1)
        #expect(model.retryAfter != nil)
        #expect(!model.canSend)
        await model.refresh()
        #expect(await api.counts().reads == 1)
        #expect(model.messages.count == 2)
    }

    @Test func transientErrorsPreserveTheSavedSlackConnectionButRevocationClearsIt() async throws {
        let api = ChatSlackAPI(), storage = ChatSlackStorage()
        await api.configure(profileError: .permissionDenied)
        let model = subject(api: api, storage: storage)
        await model.updateContext(context())?.value
        #expect(!model.isRestoring)
        #expect(model.canRetryRestore)
        #expect(try storage.load() != nil)
        await api.configure(profileError: .unauthenticated)
        await model.retryRestore()
        #expect(!model.isRestoring)
        #expect(model.identity == nil)
        #expect(try storage.load() == nil)
    }

    @Test func SlackSendingUsesItsOwnPermissionsAndConfirmsOnlyOneWrite() async throws {
        let api = ChatSlackAPI(), model = subject(api: api)
        await model.updateContext(context())?.value
        await model.chooseChannel("C1")?.value
        #expect(model.canSend)
        #expect(await model.send("Hello") == .sent)
        #expect(model.messages.last?.text == "Hello")
        #expect(await api.counts().writes == 1)
        await model.chooseChannel("C3")?.value
        #expect(!model.canSend)
        #expect(await model.send("Not a member") == .failed)
        #expect(await api.counts().writes == 1)
    }

    @Test func uncertainDeliveryCannotBeRetriedUntilTheUserReviewsTheChannel() async throws {
        let api = ChatSlackAPI(), model = subject(api: api)
        await model.updateContext(context())?.value
        await model.chooseChannel("C1")?.value
        await api.configure(postError: .deliveryUnconfirmed)
        #expect(await model.send("Might already be sent") == .uncertain)
        #expect(model.deliveryNeedsReview)
        #expect(await model.send("Might already be sent") == .failed)
        #expect(await api.counts().writes == 1)
        model.acknowledgeUnconfirmedDelivery()
        #expect(model.canSend)
        await model.chooseChannel("C2")?.value
        #expect(model.notice == nil)
    }

    @Test func pagingAndRefreshKeepOlderMessagesAndRemoveDeletedRecentMessages() async throws {
        let api = ChatSlackAPI(), model = subject(api: api)
        await api.configure(pages: ["C1": [
            SlackHistoryPage(messages: [SlackMessage(id: "100.0", text: "older"), SlackMessage(id: "200.0", text: "edit me"), SlackMessage(id: "300.0", text: "delete me")], nextCursor: "older", hasMore: true),
            SlackHistoryPage(messages: [SlackMessage(id: "50.0", text: "oldest")]),
            SlackHistoryPage(messages: [SlackMessage(id: "200.0", text: "edited"), SlackMessage(id: "400.0", text: "new")], nextCursor: "older", hasMore: true)
        ]])
        await model.updateContext(context())?.value
        await model.chooseChannel("C1")?.value
        await model.loadOlder()
        await model.refresh()
        #expect(model.messages.map(\.text) == ["oldest", "older", "edited", "new"])
        #expect(model.errorMessage == nil)
    }

    @Test func cancelledAuthorizationAndWrongIdentityPreserveTheExistingCredential() async throws {
        let gate = Gate(), api = ChatSlackAPI(), storage = ChatSlackStorage()
        let model = subject(api: api, storage: storage, oauth: ChatSlackOAuth(result: {
            await gate.wait(); return chatCredential(token: "late")
        }))
        await model.updateContext(context())?.value
        let auth = try #require(model.beginAuthorization(clientID: "public", includePrivateChannels: false))
        let task = model.completeAuthorization(auth, callback: URL(string: SlackAuthorization.redirectURI)!)
        await gate.waitUntilRequested(); model.cancelAuthorization(); await gate.open(); await task?.value
        #expect(try storage.load()?.accessToken == "fixture")
        #expect(model.identity?.userID == "U1")
        #expect(storage.saveCount() == 0)
        let wrong = subject(api: api, storage: storage, oauth: ChatSlackOAuth(result: { chatCredential(token: "wrong", user: "U2") }))
        await wrong.updateContext(context())?.value
        let request = try #require(wrong.beginAuthorization(clientID: "public", includePrivateChannels: false))
        await wrong.completeAuthorization(request, callback: URL(string: SlackAuthorization.redirectURI)!)?.value
        #expect(try storage.load()?.accessToken == "fixture")
        #expect(storage.saveCount() == 0)
    }

    @Test func demoDoesNotReadAnyCredentialOrUseTheLiveAPIFactory() async throws {
        let model = SlackChatModel(preferences: preferences(), oauth: ChatSlackOAuth(), storageForAccount: { _ in
            Issue.record("Demo requested Keychain storage"); return ChatSlackStorage(nil)
        }, makeAPI: { _ in Issue.record("Demo requested live Slack API"); return ChatSlackAPI() })
        await model.updateContext(context(demo: true))?.value
        await model.chooseChannel("CPROJECT")?.value
        #expect(model.isConnected)
        #expect(await model.send("Local only") == .sent)
        #expect(model.messages.last?.text == "Local only")
        #expect(model.beginAuthorization(clientID: "public", includePrivateChannels: true) == nil)
    }
}
