import Foundation

public struct HTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public let headers: [String: String]
    public init(data: Data, status: Int, headers: [String: String] = [:]) {
        self.data = data; self.status = status; self.headers = headers
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw FjordError.message(L10n.core("GitHub returned an invalid response.")) }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
        }
        return HTTPResponse(data: data, status: response.statusCode, headers: headers)
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // GitHub API/auth endpoints are fixed. Never forward credentials to a redirect target.
        completionHandler(nil)
    }
}

func checkResponse(_ response: HTTPResponse) throws {
    if response.status == 401 { throw FjordError.unauthenticated }
    guard (200..<300).contains(response.status) else {
        struct Message: Decodable { let message: String? }
        let message = (try? JSONDecoder().decode(Message.self, from: response.data).message) ?? L10n.core("The request could not be completed.")
        if response.status == 429 || (response.status == 403 && (response.headers["x-ratelimit-remaining"] == "0" || response.headers["retry-after"] != nil)) {
            throw FjordError.rateLimited(gitHubRateLimitReset(response))
        }
        throw FjordError.http(response.status, message)
    }
}

func gitHubRateLimitReset(_ response: HTTPResponse) -> Date? {
    let reset = response.headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    let retry = response.headers["retry-after"].flatMap(TimeInterval.init).map { Date().addingTimeInterval(max(0, $0)) }
    return [reset, retry].compactMap { $0 }.max()
}

public protocol ProjectsAPI: Sendable {
    func currentUser() async throws -> GitHubUser
    func organizations() async throws -> [ProjectOwner]
    func collaboratingOwners() async throws -> [ProjectOwner]
    func projects(owner: ProjectOwner) async throws -> [ProjectSummary]
    func resolve(_ reference: ProjectReference) async throws -> ProjectSummary
    func snapshot(project: ProjectSummary) async throws -> ProjectSnapshot
    func setSelection(projectID: String, itemID: String, fieldID: String, optionID: String?) async throws
    func moveItem(projectID: String, itemID: String, afterID: String?) async throws
    func addDraft(projectID: String, title: String, body: String) async throws
    func updateContent(item: ProjectItem, title: String, body: String) async throws
    func grantAccess(projectID: String, username: String, role: CollaboratorRole) async throws
    func sendChatMessage(projectID: String, fieldID: String, optionID: String, authorID: String, text: String) async throws -> ChatSendResult
    func createProject(owner: ProjectOwner, title: String) async throws -> ProjectSummary
    func deleteProject(id: String) async throws
    func repositories(projectID: String, referencedRepositories: [String]) async throws -> [RepositoryChoice]
    func repository(named nameWithOwner: String) async throws -> RepositoryChoice
    func assignableUsers(repository nameWithOwner: String) async throws -> [AssignableUser]
    func findUser(login: String) async throws -> AssignableUser
    func createItem(projectID: String, request: NewItemRequest) async throws -> ItemCreationResult
    func changeAssignee(item: ProjectItem, user: AssignableUser, assigned: Bool) async throws
}
