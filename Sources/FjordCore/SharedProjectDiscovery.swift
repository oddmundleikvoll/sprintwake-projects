import Foundation

/// Repository membership supplies candidate owners only. Every visible project
/// must also be returned by GitHub's project API for the current credential.
struct SharedProjectDiscovery: Sendable {
    static let ownersPerPass = 20
    var projects: [ProjectSummary] = []
    var organizations: [ProjectOwner] = []
    var collaboratingOwners: [ProjectOwner]?
    var failedOwnerIDs = Set<String>()
    var isIncomplete = false
    var candidateOwnerIDs = Set<String>()
    var checkedOwnerIDs = Set<String>()
    var lastCheckedOwnerID: String?

    static func load(api: any ProjectsAPI, viewerLogin: String, knownOwners: [ProjectOwner],
                     knownOrganizations: [ProjectOwner], linkedURLs: [String],
                     cachedCollaboratingOwners: [ProjectOwner]?, afterOwnerID: String?) async throws -> Self {
        var result = Self()
        result.organizations = knownOrganizations
        var candidates = knownOwners
        try Task.checkCancellation()
        do {
            result.organizations = try await api.organizations()
        } catch {
            try propagateSessionFailure(error)
            result.isIncomplete = true
        }
        candidates += result.organizations
        if let cachedCollaboratingOwners { candidates += cachedCollaboratingOwners }
        else {
            do {
                try Task.checkCancellation()
                let owners = try await api.collaboratingOwners()
                result.collaboratingOwners = owners
                candidates += owners
            } catch {
                try propagateSessionFailure(error)
                result.isIncomplete = true
            }
        }
        let linked = linkedURLs.compactMap { try? ProjectReference(url: $0) }
        candidates += linked.map(\.owner)
        let members = Set(result.organizations.map { $0.id.lowercased() })
        let unique = Dictionary(candidates.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var projects: [String: ProjectSummary] = [:]
        let ordered = unique.values.filter {
            $0.kind != .user || $0.login.caseInsensitiveCompare(viewerLogin) != .orderedSame
        }.sorted { $0.id.lowercased() < $1.id.lowercased() }
        result.candidateOwnerIDs = Set(ordered.map { $0.id.lowercased() })
        let start = afterOwnerID.flatMap { previous in ordered.firstIndex { $0.id.lowercased() > previous } } ?? 0
        for offset in 0..<min(ownersPerPass, ordered.count) {
            let owner = ordered[(start + offset) % ordered.count]
            try Task.checkCancellation()
            result.checkedOwnerIDs.insert(owner.id.lowercased())
            result.lastCheckedOwnerID = owner.id.lowercased()
            do {
                for project in try await api.projects(owner: owner) {
                    guard project.owner?.id.lowercased() == owner.id.lowercased() else { continue }
                    let explicitlyOpened = linked.contains {
                        $0.owner.id.lowercased() == owner.id.lowercased() && $0.number == project.number
                    }
                    // Mere visibility of somebody's public board is not a share.
                    if project.isPublic == false || project.viewerCanUpdate == true
                        || members.contains(owner.id.lowercased()) || explicitlyOpened {
                        projects[project.id] = project
                    }
                }
            } catch {
                try propagateSessionFailure(error)
                result.failedOwnerIDs.insert(owner.id.lowercased())
                result.isIncomplete = true
            }
        }
        result.projects = projects.values.sorted(by: order)
        return result
    }

    static func order(_ left: ProjectSummary, _ right: ProjectSummary) -> Bool {
        if left.closed != right.closed { return !left.closed }
        let lhs = left.owner?.id.lowercased() ?? "", rhs = right.owner?.id.lowercased() ?? ""
        if lhs != rhs { return lhs < rhs }
        if left.number != right.number { return left.number > right.number }
        return left.id < right.id
    }

    private static func propagateSessionFailure(_ error: Error) throws {
        if case .rateLimited = error as? FjordError { throw error }
        if error is CancellationError || (error as? FjordError) == .cancelled
            || (error as? FjordError) == .unauthenticated { throw error }
    }
}
