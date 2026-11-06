import SwiftUI
import UniformTypeIdentifiers
import FjordCore

struct BoardItemDrag: Codable, Transferable {
    let contextID: String
    let projectID: String
    let fieldID: String?
    let itemID: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sprintwakeBoardItem)
    }
}

struct BoardColumnDrag: Codable, Transferable {
    let contextID: String
    let projectID: String
    let fieldID: String
    let columnID: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sprintwakeBoardColumn)
    }
}

private extension UTType {
    static let sprintwakeBoardItem = UTType(exportedAs: "no.oddmund.Fjord.board-item", conformingTo: .data)
    static let sprintwakeBoardColumn = UTType(exportedAs: "no.oddmund.Fjord.board-column", conformingTo: .data)
}

extension View {
    @ViewBuilder func boardItemDraggable(model: AppModel, item: ProjectItem) -> some View {
        if model.canWrite, let projectID = model.selectedProjectID {
            draggable(BoardItemDrag(contextID: model.boardDragID, projectID: projectID,
                                    fieldID: model.selectedFieldID, itemID: item.id))
        } else { self }
    }
}

/// Measures the existing card without changing its layout or keyboard controls.
struct BoardTaskCard: View {
    @Bindable var model: AppModel
    let item: ProjectItem
    let optionID: String?
    let onOpen: () -> Void
    @ViewState private var height: CGFloat = 1
    @ViewState private var targeted = false

    var body: some View {
        ItemCard(model: model, item: item, onOpen: onOpen)
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { height = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, value in height = value }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(targeted && model.canWrite ? WorkspaceStyle.accent : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .boardItemDraggable(model: model, item: item)
            .dropDestination(for: BoardItemDrag.self) { values, point in
                guard values.count == 1, let drag = values.first, accepts(drag) else { return false }
                if drag.itemID == item.id { return true }
                Task {
                    guard accepts(drag) else { return }
                    await model.moveItem(projectID: drag.projectID, fieldID: drag.fieldID, itemID: drag.itemID,
                                         optionID: optionID, targetItemID: item.id, before: point.y < height / 2)
                }
                return true
            } isTargeted: { targeted = $0 }
            .contextMenu {
                Button(L10n.ui("Move up"), systemImage: "arrow.up") { move(up: true) }.disabled(!canMove(up: true))
                Button(L10n.ui("Move down"), systemImage: "arrow.down") { move(up: false) }.disabled(!canMove(up: false))
            }
            .help(L10n.ui("Drag to reorder. Drop on the upper half of a card to place before it, or the lower half to place after it."))
    }

    private var siblings: [ProjectItem] {
        if model.selectedField == nil { return model.snapshot?.items ?? [] }
        return model.boardColumns(items: model.snapshot?.items ?? []).first { $0.option?.id == optionID }?.items ?? []
    }

    private func canMove(up: Bool) -> Bool {
        guard model.canWrite, let index = siblings.firstIndex(where: { $0.id == item.id }) else { return false }
        // Conversation drafts keep their chronological presentation.
        if optionID == model.conversationOptionID, optionID != nil {
            let tasks = siblings.filter { $0.kind != .draft }
            guard let index = tasks.firstIndex(where: { $0.id == item.id }) else { return false }
            return up ? index > 0 : index + 1 < tasks.count
        }
        return up ? index > 0 : index + 1 < siblings.count
    }

    private func move(up: Bool) {
        let tasks = optionID != nil && optionID == model.conversationOptionID ? siblings.filter { $0.kind != .draft } : siblings
        guard canMove(up: up), let index = tasks.firstIndex(where: { $0.id == item.id }), let projectID = model.selectedProjectID else { return }
        let fieldID = model.selectedFieldID, contextID = model.boardDragID, target = tasks[index + (up ? -1 : 1)].id
        Task {
            guard contextID == model.boardDragID else { return }
            await model.moveItem(projectID: projectID, fieldID: fieldID, itemID: item.id,
                                 optionID: optionID, targetItemID: target, before: up)
        }
    }

    private func accepts(_ drag: BoardItemDrag) -> Bool {
        model.canWrite && drag.contextID == model.boardDragID && drag.projectID == model.selectedProjectID && drag.fieldID == model.selectedFieldID
    }
}
