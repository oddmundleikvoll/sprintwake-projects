import Foundation

public struct BoardColumn: Identifiable, Sendable, Equatable {
    public let option: SelectOption?
    public let title: String
    public let items: [ProjectItem]
    public var id: String { option?.id ?? "unassigned" }
}

public enum BoardGrouping {
    public static func columns(field: SelectField, items: [ProjectItem]) -> [BoardColumn] {
        let knownOptions = Set(field.options.map(\.id))
        let unassigned = items.filter { item in item.selections[field.id].map { !knownOptions.contains($0) } ?? true }
        var columns: [BoardColumn] = []
        if !unassigned.isEmpty {
            columns.append(BoardColumn(option: nil, title: L10n.core("Missing %@", field.name.lowercased()), items: unassigned))
        }
        columns += field.options.map { option in
            BoardColumn(option: option, title: option.name, items: items.filter { $0.selections[field.id] == option.id })
        }
        return columns
    }
}
