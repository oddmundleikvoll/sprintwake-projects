import Foundation

public struct SlackClient: SlackAPI, Sendable {
    private let token: String
    private let transport: any HTTPTransport
    private let decoder: JSONDecoder
    private static let baseURL = URL(string: "https://slack.com/api")!

    public init(token: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.token = token
        self.transport = transport
        self.decoder = JSONDecoder()
    }

    public func identity() async throws -> SlackIdentity {
        let response: AuthResponse = try await request(path: "auth.test", parameters: [:], method: "GET", write: false)
        guard let teamID = response.teamID?.nonEmpty, let teamName = response.teamName?.nonEmpty,
              let userID = response.userID?.nonEmpty, let userName = response.userName?.nonEmpty else {
            throw SlackError.message(L10n.core("Slack returned an incomplete identity."))
        }
        return SlackIdentity(teamID: teamID, teamName: teamName, userID: userID, userName: userName)
    }

    public func channels(includePrivate: Bool) async throws -> [SlackChannel] {
        var result: [SlackChannel] = []
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            var parameters = ["exclude_archived": "true", "limit": "200", "types": includePrivate ? "public_channel,private_channel" : "public_channel"]
            if let cursor { parameters["cursor"] = cursor }
            let response: ChannelsResponse = try await request(path: "conversations.list", parameters: parameters, method: "GET", write: false)
            result += response.channels.filter { !$0.isArchived }.map { $0.model }
            let next = response.metadata?.nextCursor?.nonEmpty
            if let next {
                guard next != cursor, seen.insert(next).inserted else { throw SlackError.message(L10n.core("Slack returned a repeated pagination cursor.")) }
            }
            cursor = next
        } while cursor != nil
        var ids: Set<String> = []
        return result.filter { ids.insert($0.id).inserted }
    }

    public func history(channelID: String, cursor: String?) async throws -> SlackHistoryPage {
        guard !channelID.isEmpty else { throw SlackError.invalidChannel }
        var parameters = ["channel": channelID, "limit": "100"]
        if let cursor { parameters["cursor"] = cursor }
        let response: HistoryResponse = try await request(path: "conversations.history", parameters: parameters, method: "GET", write: false)
        let topLevel = response.messages.filter { $0.threadTS == nil || $0.threadTS == $0.ts }
        let next = response.metadata?.nextCursor?.nonEmpty
        guard !response.hasMore || next != nil else { throw SlackError.message(L10n.core("Slack returned an incomplete pagination response.")) }
        return SlackHistoryPage(messages: topLevel.compactMap(\.model), nextCursor: response.hasMore ? next : nil, hasMore: response.hasMore)
    }

    public func postMessage(channelID: String, text: String) async throws -> SlackMessage {
        guard !channelID.isEmpty else { throw SlackError.invalidChannel }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SlackError.message(L10n.core("A Slack message cannot be empty.")) }
        let safeText = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let parameters = ["channel": channelID, "text": safeText, "parse": "none", "link_names": "false", "unfurl_links": "false", "unfurl_media": "false"]
        let body: [String: Any] = ["channel": channelID, "text": safeText, "parse": "none", "link_names": false, "unfurl_links": false, "unfurl_media": false, "mrkdwn": false]
        let response: PostResponse = try await request(path: "chat.postMessage", parameters: parameters, body: body, method: "POST", write: true)
        guard response.channel == channelID, let ts = response.ts?.nonEmpty, let timestamp = Double(ts), timestamp.isFinite, timestamp > 0,
              let message = response.message?.model, message.id == ts else { throw SlackError.deliveryUnconfirmed }
        return message
    }

    public func userName(id: String) async throws -> String {
        guard !id.isEmpty else { return "" }
        let response: UserResponse = try await request(path: "users.info", parameters: ["user": id], method: "GET", write: false)
        return response.user?.displayName?.nonEmpty ?? response.user?.realName?.nonEmpty ?? response.user?.name?.nonEmpty ?? id
    }

    private func request<T: Decodable>(path: String, parameters: [String: String], body: [String: Any]? = nil, method: String, write: Bool) async throws -> T {
        var request: URLRequest
        if method == "GET" {
            var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            if !parameters.isEmpty {
                components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            }
            request = URLRequest(url: components.url!)
        } else {
            request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
            request.httpBody = try JSONSerialization.data(withJSONObject: body ?? parameters)
        }
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }

        let response: HTTPResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw write ? SlackError.deliveryUnconfirmed : SlackError.cancelled }
        catch { throw write ? SlackError.deliveryUnconfirmed : SlackError.message(L10n.core("The Slack request failed.")) }
        if response.status == 401 { throw SlackError.unauthenticated }
        if response.status == 429 { throw SlackError.rateLimited(retryAfter: retryAfter(response.headers)) }
        if response.status == 403 { throw SlackError.permissionDenied }
        if response.status >= 500 { throw write ? SlackError.deliveryUnconfirmed : SlackError.message(L10n.core("Slack is temporarily unavailable.")) }
        guard (200..<300).contains(response.status) else { throw SlackError.message(L10n.core("Slack returned an HTTP error.")) }
        do {
            let base = try decoder.decode(BaseResponse.self, from: response.data)
            guard base.ok else { throw mapError(base.error ?? "unknown_error", write: write) }
            return try decoder.decode(T.self, from: response.data)
        } catch let error as SlackError { throw error }
        catch { throw write ? SlackError.deliveryUnconfirmed : SlackError.message(L10n.core("Slack returned an invalid response.")) }
    }

    private func mapError(_ code: String, write: Bool) -> SlackError {
        switch code {
        case "invalid_auth", "token_revoked", "token_expired", "not_authed", "account_inactive", "invalid_token": return .unauthenticated
        case "ratelimited", "rate_limit", "rate_limited": return .rateLimited(retryAfter: 60)
        case "internal_error", "fatal_error", "request_timeout": return write ? .deliveryUnconfirmed : .message(L10n.core("Slack returned an error."))
        case "missing_scope", "not_allowed_token_type", "restricted_action", "team_access_not_granted", "not_in_channel": return .permissionDenied
        case "channel_not_found", "is_archived", "invalid_channel", "unavailable_channel": return .invalidChannel
        default: return .message(L10n.core("Slack rejected the request."))
        }
    }

    private func retryAfter(_ headers: [String: String]) -> TimeInterval {
        let value = headers.first { $0.key.lowercased() == "retry-after" }?.value
        guard let value, let seconds = TimeInterval(value), seconds.isFinite, seconds > 0 else { return 60 }
        return seconds
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

private struct BaseResponse: Decodable { let ok: Bool; let error: String? }
private struct Metadata: Decodable { let nextCursor: String?; enum CodingKeys: String, CodingKey { case nextCursor = "next_cursor" } }
private struct AuthResponse: Decodable { let ok: Bool; let error: String?; let teamID: String?; let teamName: String?; let userID: String?; let userName: String?; enum CodingKeys: String, CodingKey { case ok,error; case teamID = "team_id"; case teamName = "team"; case userID = "user_id"; case userName = "user" } }
private struct ChannelsResponse: Decodable { let ok: Bool; let error: String?; let channels: [ChannelDTO]; let metadata: Metadata?; enum CodingKeys: String, CodingKey { case ok,error,channels; case metadata = "response_metadata" } }
private struct HistoryResponse: Decodable { let ok: Bool; let error: String?; let messages: [MessageDTO]; let hasMore: Bool; let metadata: Metadata?; enum CodingKeys: String, CodingKey { case ok,error,messages; case hasMore = "has_more"; case metadata = "response_metadata" } }
private struct PostResponse: Decodable { let ok: Bool; let error: String?; let channel: String?; let ts: String?; let message: MessageDTO? }
private struct UserResponse: Decodable { let ok: Bool; let error: String?; let user: UserDTO? }
private struct ChannelDTO: Decodable {
    let id: String
    let name: String
    let isPrivate: Bool?
    let isMember: Bool?
    let archived: Bool?
    var isArchived: Bool { archived ?? false }
    var model: SlackChannel {
        SlackChannel(id: id, name: name, isPrivate: isPrivate ?? false, isMember: isMember ?? false, isArchived: isArchived)
    }
    enum CodingKeys: String, CodingKey {
        case id, name
        case isPrivate = "is_private", isMember = "is_member", archived = "is_archived"
    }
}
private struct UserDTO: Decodable { let name: String?; let realName: String?; let profile: Profile?; var displayName: String? { profile?.displayName }; enum CodingKeys: String, CodingKey { case name; case realName = "real_name"; case profile } }
private struct Profile: Decodable { let displayName: String?; enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
private struct MessageDTO: Decodable { let ts: String; let user: String?; let username: String?; let botID: String?; let text: String?; let replyCount: Int?; let edited: Edited?; let threadTS: String?; var model: SlackMessage? { SlackMessage(id: ts, userID: user, displayName: username ?? botID, text: text ?? "", replyCount: replyCount ?? 0, isEdited: edited != nil) }; enum CodingKeys: String, CodingKey { case ts,user,username,text; case botID = "bot_id"; case replyCount = "reply_count"; case edited; case threadTS = "thread_ts" } }
private struct Edited: Decodable { let ts: String? }
