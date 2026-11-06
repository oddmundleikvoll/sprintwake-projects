import Foundation

public struct BoardColumn: Identifiable, Sendable, Equatable {
    public let option: SelectOption?
    public let title: String
    public let items: [ProjectItem]
    public var id: String { option?.id ?? "unassigned" }
}

public enum BoardGrouping {
    public static func columns(field: SelectField, items: [ProjectItem], order: [String] = []) -> [BoardColumn] {
        let knownOptions = Set(field.options.map(\.id))
        let unassigned = items.filter { item in item.selections[field.id].map { !knownOptions.contains($0) } ?? true }
        var columns: [BoardColumn] = []
        if !unassigned.isEmpty {
            columns.append(BoardColumn(option: nil, title: L10n.core("Missing %@", field.name.lowercased()), items: unassigned))
        }
        columns += field.options.map { option in
            BoardColumn(option: option, title: option.name, items: items.filter { $0.selections[field.id] == option.id })
        }
        var seen = Set<String>()
        let ordered = order.filter { seen.insert($0).inserted }.compactMap { id in columns.first { $0.id == id } }
        return ordered + columns.filter { !order.contains($0.id) }
    }
}

public enum BoardOrdering {
    /// GitHub's position mutation uses a project-wide predecessor, or nil for the top.
    public static func moving(_ items: [ProjectItem], itemID: String, afterID: String?) -> [ProjectItem] {
        guard let item = items.first(where: { $0.id == itemID }), itemID != afterID,
              afterID == nil || items.contains(where: { $0.id == afterID }) else { return items }
        var result = items.filter { $0.id != itemID }
        let index = afterID.flatMap { id in result.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        result.insert(item, at: index)
        return result
    }
}
