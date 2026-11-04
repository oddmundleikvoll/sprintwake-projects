import SwiftUI
import FjordCore

struct AssignmentButton: View {
    @Bindable var model: AppModel
    let item: ProjectItem
    @ViewState private var showing = false
    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 5) {
                Image(systemName: item.assigneeLogins.isEmpty ? "person.crop.circle.badge.plus" : "person.crop.circle.fill")
                Text(item.assigneeLogins.isEmpty ? L10n.ui("Assign") : item.assigneeLogins.joined(separator: ", "))
                    .lineLimit(1)
            }.font(.caption)
        }
        .buttonStyle(.borderless)
        .help(L10n.ui("Assign the task to a person"))
        .disabled(!model.canWrite || !item.canEditContent || item.kind == .redacted)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            if let projectID = model.selectedProjectID {
                AssignmentPopover(model: model, projectID: projectID, itemID: item.id, repository: item.repository)
            }
        }
    }
}

private struct AssignmentPopover: View {
    @Bindable var model: AppModel
    let projectID: String
    let itemID: String
    let repository: String?
    @ViewState private var users: [AssignableUser] = []
    @ViewState private var search = ""
    @ViewState private var loading = true
    @ViewState private var changing = false
    private var current: ProjectItem? { model.snapshot?.items.first { $0.id == itemID } }
    private var filtered: [AssignableUser] {
        users.filter { search.isEmpty || $0.login.localizedCaseInsensitiveContains(search) || ($0.name?.localizedCaseInsensitiveContains(search) ?? false) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.ui("Assign task")).font(.headline)
            TextField(L10n.ui("Search by name or GitHub username"), text: $search).textFieldStyle(.roundedBorder)
                .onSubmit { findUser() }.accessibilityLabel(L10n.ui("Search for assignee"))
            if loading { ProgressView(L10n.ui("Loading suggestions …")).controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(filtered) { person in
                        let selected = current?.assigneeLogins.contains(person.login) == true
                        Button {
                            changing = true
                            Task { _ = await model.changeAssignee(projectID: projectID, itemID: itemID, person: person, assigned: !selected); changing = false }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? .indigo : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(person.name ?? person.login).foregroundStyle(.primary)
                                    if person.name != nil { Text("@\(person.login)").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                            }.padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(changing || !model.canWrite)
                    }
                }
            }.frame(maxHeight: 230)
            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(L10n.ui("Find @%@ on GitHub", search.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))), systemImage: "magnifyingglass") { findUser() }
                    .disabled(loading || changing)
            }
            Text(L10n.ui("Suggestions from the project repositories. Search for a username when needed."))
                .font(.caption).foregroundStyle(.secondary)
            if current?.kind == .draft {
                Text(L10n.ui("For drafts: avoid changing assignees at the same time as others. GitHub replaces the full assignee list, so concurrent changes can overwrite each other."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            MessageBanner(model: model)
        }.padding(16).frame(width: 330)
            .task {
                users = await model.assignmentCandidates(projectID: projectID, repository: repository)
                loading = false
            }
    }
    private func findUser() {
        guard !loading else { return }
        loading = true
        Task {
            if let person = await model.findAssignee(login: search, projectID: projectID), !users.contains(where: { $0.id == person.id }) { users.insert(person, at: 0) }
            loading = false
        }
    }
}
