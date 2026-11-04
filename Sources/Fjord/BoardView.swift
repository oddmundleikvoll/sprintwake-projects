import SwiftUI
import FjordCore

struct BoardView: View {
    @Bindable var model: AppModel
    @Environment(SlackChatModel.self) private var slack
    let items: [ProjectItem]
    let onOpen: (ProjectItem) -> Void
    let onCreate: (ItemPlacement?) -> Void
    let onColumns: () -> Void
    let onDeleteColumn: (SelectOption) -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    if slack.source == .slack {
                        SlackChatView(compact: true).frame(width: 330)
                            .background(WorkspaceStyle.column, in: RoundedRectangle(cornerRadius: 18))
                            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(WorkspaceStyle.border, lineWidth: 0.75).allowsHitTesting(false) }
                    }
                    if let field = model.selectedField {
                        ForEach(BoardGrouping.columns(field: field, items: items)) { column in
                            BoardColumnView(model: model, title: column.title, option: column.option, fieldID: field.id,
                                            items: column.items, onOpen: onOpen, onCreate: onCreate,
                                            onColumns: onColumns, onDelete: { if let option = column.option { onDeleteColumn(option) } })
                        }
                        Button(action: onColumns) { Label(L10n.ui("New column"), systemImage: "plus") }
                            .buttonStyle(.borderless).padding(14)
                            .background(WorkspaceStyle.column, in: RoundedRectangle(cornerRadius: 12)).disabled(!model.canWrite)
                    } else {
                        BoardColumnView(model: model, title: L10n.ui("Tasks"), option: nil, fieldID: nil, items: items,
                                        onOpen: onOpen, onCreate: onCreate, onColumns: onColumns, onDelete: {})
                    }
                }.padding(20).frame(height: max(240, geometry.size.height - 12), alignment: .topLeading)
            }
        }.background(WorkspaceStyle.canvas)
    }
}

private struct BoardColumnView: View {
    @Bindable var model: AppModel
    let title: String
    let option: SelectOption?
    let fieldID: String?
    let items: [ProjectItem]
    let onOpen: (ProjectItem) -> Void
    let onCreate: (ItemPlacement?) -> Void
    let onColumns: () -> Void
    let onDelete: () -> Void
    @ViewState private var targeted = false
    private var conversation: Bool { option != nil && option?.id == model.conversationOptionID }
    private var placement: ItemPlacement? {
        guard let fieldID, let option else { return nil }
        return ItemPlacement(fieldID: fieldID, optionID: option.id)
    }
    private var messages: [ProjectItem] { sortedMessages(items.filter { $0.kind == .draft }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(option?.swiftUIColor ?? .secondary).frame(width: 9, height: 9)
                    .padding(5).background((option?.swiftUIColor ?? .secondary).opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                Text(title).font(.headline).lineLimit(1)
                Text(items.count, format: .number).font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(WorkspaceStyle.surface, in: Capsule())
                Spacer(minLength: 4)
                Button { onCreate(placement) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help(L10n.ui("Create a task in %@", title)).accessibilityLabel(L10n.ui("New task in %@", title)).disabled(!model.canWrite)
                if let option {
                    Menu {
                        Button(L10n.ui("New issue or draft"), systemImage: "plus") { onCreate(placement) }.disabled(!model.canWrite)
                        if !conversation {
                            Button(L10n.ui("Use as conversation column"), systemImage: "bubble.left.and.bubble.right") { model.setConversationOption(option.id) }
                        }
                        Button(L10n.ui("Manage columns …"), systemImage: "slider.horizontal.3", action: onColumns)
                        Divider()
                        Button(L10n.ui("Delete column …"), systemImage: "trash", role: .destructive, action: onDelete).disabled(!model.canWrite)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help(L10n.ui("Options for %@", title))
                }
            }.padding(.horizontal, 14).padding(.vertical, 16)
            if option == nil, fieldID != nil {
                Text(L10n.ui("Tasks without a selected GitHub value.")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider().padding(.horizontal, 10)
            if conversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if items.isEmpty { Text(L10n.ui("Start the conversation below.")).font(.callout).foregroundStyle(.secondary).padding(.top, 18) }
                            ForEach(messages) { item in
                                MessageBubble(item: item, mine: item.authorLogin == model.user?.login, compact: true, onOpen: { onOpen(item) }).id(item.id)
                            }
                            ForEach(items.filter { $0.kind != .draft }) { item in ItemCard(model: model, item: item, onOpen: { onOpen(item) }).draggable(item.id) }
                        }.padding(10)
                    }.defaultScrollAnchor(.bottom)
                        .onChange(of: messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
                }
                if let option, let projectID = model.selectedProjectID {
                    Divider().padding(.horizontal, 10)
                    MessageComposer(model: model, projectID: projectID, optionID: option.id, compact: true).padding(10)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in ItemCard(model: model, item: item, onOpen: { onOpen(item) }).draggable(item.id) }
                        if items.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "tray").font(.title2).accessibilityHidden(true)
                                Text(L10n.ui("No tasks")).font(.callout)
                            }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 28)
                        }
                    }.padding(10)
                }
            }
        }.frame(width: conversation ? 340 : 292).frame(maxHeight: .infinity, alignment: .topLeading)
            .background(WorkspaceStyle.column, in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(targeted ? WorkspaceStyle.accent : WorkspaceStyle.border, lineWidth: targeted ? 2 : 0.75).allowsHitTesting(false) }
            .dropDestination(for: String.self) { values, _ in
                guard model.canWrite, fieldID != nil, values.count == 1,
                      let id = values.first, model.snapshot?.items.contains(where: { $0.id == id }) == true else { return false }
                Task { await model.changeStatus(itemID: id, optionID: option?.id) }
                return true
            } isTargeted: { targeted = $0 }
    }
}

struct ItemCard: View {
    @Bindable var model: AppModel
    let item: ProjectItem
    let onOpen: () -> Void
    @ViewState private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onOpen) {
                Text(item.title).font(.system(size: 14, weight: .semibold)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 5) {
                Image(systemName: item.kind.symbol).foregroundStyle(WorkspaceStyle.accent)
                Text(item.repository.map { "\($0)\(item.number.map { " #\($0)" } ?? "")" } ?? item.kindLabel).lineLimit(1)
            }.font(.caption).foregroundStyle(.secondary)
            Divider().opacity(0.6)
            AssignmentButton(model: model, item: item)
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .workspaceSurface(emphasized: hovered)
            .onHover { hovered = $0 }
    }
}

struct ItemListView: View {
    @Bindable var model: AppModel
    let items: [ProjectItem]
    let onOpen: (ProjectItem) -> Void
    var body: some View {
        Table(items) {
            TableColumn(L10n.ui("Task")) { item in
                Button { onOpen(item) } label: { Label(item.title, systemImage: item.kind.symbol).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(.plain).padding(.vertical, 6)
            }.width(min: 210, ideal: 360)
            TableColumn(model.selectedField?.name ?? L10n.ui("Status")) { item in StatusMenu(model: model, item: item) }.width(min: 100, ideal: 130, max: 180)
            TableColumn(L10n.ui("Assignee")) { item in AssignmentButton(model: model, item: item) }.width(min: 90, ideal: 120, max: 200)
            TableColumn(L10n.ui("Source")) { item in Text(item.repository ?? item.kindLabel).foregroundStyle(.secondary).lineLimit(1) }.width(min: 80, ideal: 140)
        }.overlay { if items.isEmpty { ContentUnavailableView(L10n.ui("No tasks"), systemImage: "tray") } }
    }
}

struct StatusMenu: View {
    @Bindable var model: AppModel
    let item: ProjectItem
    var body: some View {
        if let field = model.selectedField {
            Menu {
                Button(L10n.ui("No selected value")) { Task { await model.changeStatus(itemID: item.id, optionID: nil) } }
                ForEach(field.options) { option in Button(option.name) { Task { await model.changeStatus(itemID: item.id, optionID: option.id) } } }
            } label: { Text(field.options.first(where: { $0.id == item.selections[field.id] })?.name ?? L10n.ui("Not selected")) }.disabled(!model.canWrite)
        } else { Text("—").foregroundStyle(.secondary) }
    }
}

extension SelectOption {
    var swiftUIColor: Color {
        switch color {
        case "BLUE": .blue
        case "GREEN": .green
        case "ORANGE": .orange
        case "PINK": .pink
        case "PURPLE": .purple
        case "RED": .red
        case "YELLOW": .yellow
        default: .secondary
        }
    }
}

extension ProjectItem.Kind {
    var symbol: String {
        switch self { case .draft: "doc.text"; case .issue: "circle.dotted"; case .pullRequest: "arrow.triangle.pull"; case .redacted: "lock" }
    }
}
