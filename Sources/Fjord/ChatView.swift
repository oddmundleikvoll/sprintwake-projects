import SwiftUI
import FjordCore

struct ChatView: View {
    @Bindable var model: AppModel
    let projectID: String
    let onOpen: (ProjectItem) -> Void
    private var messages: [ProjectItem] {
        guard let field = model.selectedField, let option = model.conversationOption else { return [] }
        return sortedMessages((model.snapshot?.items ?? []).filter { $0.kind == .draft && $0.selections[field.id] == option.id })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.ui("Project conversation"), systemImage: "bubble.left.and.bubble.right").font(.headline)
                    Text(L10n.ui("Messages are drafts assigned to their sender. Everyone with project access can read them."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let field = model.selectedField {
                    Picker(L10n.ui("Conversation column"), selection: Binding(get: { model.conversationOptionID ?? "" }, set: { model.setConversationOption($0) })) {
                        Text(L10n.ui("Choose column")).tag("")
                        ForEach(field.options) { Text($0.name).tag($0.id) }
                    }.fixedSize().disabled(model.isMutating)
                }
            }.padding(16)
            Divider()
            if let option = model.conversationOption {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            if messages.isEmpty { ContentUnavailableView(L10n.ui("Start conversation"), systemImage: "bubble.left", description: Text(L10n.ui("The first message will be a draft in “%@”.", option.name))) }
                            ForEach(messages) { item in MessageBubble(item: item, mine: item.authorLogin == model.user?.login, compact: false, onOpen: { onOpen(item) }).id(item.id) }
                        }.padding(22).frame(maxWidth: 850).frame(maxWidth: .infinity)
                    }.defaultScrollAnchor(.bottom)
                        .onChange(of: messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
                }
                Divider()
                MessageComposer(model: model, projectID: projectID, optionID: option.id, compact: false).padding(16)
            } else {
                ContentUnavailableView {
                    Label(L10n.ui("Choose a conversation column"), systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(L10n.ui("Use the menu above, or add a “Conversation” column from the board. You can also write messages directly in the column."))
                }
            }
        }.background(WorkspaceStyle.canvas)
    }
}

struct MessageComposer: View {
    @Bindable var model: AppModel
    let projectID: String
    let optionID: String
    let compact: Bool
    @ViewState private var message = ""
    @ViewState private var sending = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if message.isEmpty { Text(L10n.ui("Write a message …")).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 8).allowsHitTesting(false) }
                TextEditor(text: $message).font(.body).scrollContentBackground(.hidden)
                    .padding(4).frame(height: compact ? 66 : 74).accessibilityLabel(L10n.ui("Message"))
                    .disabled(sending || !model.canWrite)
            }
            .workspaceSurface(radius: 12)
            HStack {
                Text(L10n.ui("Assigned to you")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    let text = message
                    sending = true
                    Task {
                        let success = await model.sendMessage(projectID: projectID, optionID: optionID, text: text)
                        sending = false
                        if success { message = "" }
                    }
                } label: { Label((sending ? L10n.ui("Sending …") : L10n.ui("Send")), systemImage: "arrow.up") }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || !model.canWrite || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.count > 60_000)
            }
        }
        .protectUpdateDraft(isDirty: !message.isEmpty)
    }
}

struct MessageBubble: View {
    let item: ProjectItem
    let mine: Bool
    let compact: Bool
    let onOpen: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if mine { Spacer(minLength: compact ? 12 : 60) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(item.authorLogin.map { "@\($0)" } ?? L10n.ui("Unknown sender")).font(.caption.weight(.semibold)).foregroundStyle(WorkspaceStyle.accent).lineLimit(1)
                    Spacer(minLength: 0)
                    Button(action: onOpen) { Image(systemName: "ellipsis") }.buttonStyle(.plain).help(L10n.ui("Open draft"))
                }
                Text(item.body.isEmpty ? item.title : item.body).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let date = item.createdAt { Text(date, format: .dateTime.day().month().hour().minute()).font(.caption2).foregroundStyle(.secondary) }
            }.padding(compact ? 11 : 14).frame(maxWidth: compact ? .infinity : 570, alignment: .leading)
                .background(mine ? WorkspaceStyle.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
                .workspaceSurface()
            if !mine { Spacer(minLength: compact ? 12 : 60) }
        }.frame(maxWidth: .infinity)
    }
}

func sortedMessages(_ items: [ProjectItem]) -> [ProjectItem] {
    items.sorted {
        if $0.createdAt == $1.createdAt { return $0.id < $1.id }
        return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
    }
}
