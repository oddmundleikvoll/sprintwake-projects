import SwiftUI
import FjordCore

struct ItemEditor: View {
    @Bindable var model: AppModel
    let projectID: String
    let item: ProjectItem
    @Environment(\.dismiss) private var dismiss
    @ViewState private var title: String
    @ViewState private var text: String
    @ViewState private var saving = false

    init(model: AppModel, projectID: String, item: ProjectItem) {
        self.model = model; self.projectID = projectID; self.item = item
        _title = State(initialValue: item.title)
        _text = State(initialValue: item.body)
    }

    private var editable: Bool { model.canWrite && item.canEditContent }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(item.kindLabel).font(.title2.weight(.semibold))
                Spacer()
                if let current = model.snapshot?.items.first(where: { $0.id == item.id }) {
                    AssignmentButton(model: model, item: current)
                    StatusMenu(model: model, item: current).fixedSize()
                }
            }
            MessageBanner(model: model)
            TextField(L10n.ui("Title"), text: $title).textFieldStyle(.roundedBorder).font(.title3).disabled(!editable || saving)
            Text(L10n.ui("Description")).font(.headline)
            TextEditor(text: $text).font(.body).padding(5).frame(minHeight: 200)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5) }
                .disabled(!editable || saving).accessibilityLabel(L10n.ui("Description"))
            if !editable {
                Label(L10n.ui("You do not have write access to the content."), systemImage: "lock").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if let url = item.url { Link(L10n.ui("Open on GitHub"), destination: url) }
                Spacer()
                Button(L10n.ui("Close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button((saving ? L10n.ui("Saving …") : L10n.ui("Save"))) {
                    saving = true
                    Task {
                        let success = await model.saveItem(projectID: projectID, original: item, title: title, body: text)
                        saving = false
                        if success { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!editable || saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 610, height: 540).interactiveDismissDisabled(saving)
            .protectUpdateDraft(isDirty: title != item.title || text != item.body)
    }
}

struct ProjectURLSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var url = ""
    @ViewState private var opening = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.ui("Open a GitHub project")).font(.title2.weight(.semibold))
            Text(L10n.ui("Paste the link to a project you can access. This also works for projects shared by other owners.")).foregroundStyle(.secondary)
            TextField("https://github.com/users/username/projects/1", text: $url).textFieldStyle(.roundedBorder).accessibilityLabel(L10n.ui("Project link"))
            MessageBanner(model: model)
            HStack {
                Spacer()
                Button(L10n.ui("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(opening)
                Button((opening ? L10n.ui("Opening …") : L10n.ui("Open project"))) {
                    opening = true
                    Task { let success = await model.openProject(url: url); opening = false; if success { dismiss() } }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(opening || url.isEmpty)
            }
        }.padding(24).frame(width: 540).interactiveDismissDisabled(opening)
            .protectUpdateDraft(isDirty: !url.isEmpty)
    }
}

struct ParticipantsSheet: View {
    @Bindable var model: AppModel
    let project: ProjectSummary
    @Environment(\.dismiss) private var dismiss
    @ViewState private var username = ""
    @ViewState private var role = CollaboratorRole.reader
    @ViewState private var saving = false
    @ViewState private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.ui("Participants and access")).font(.title2.weight(.semibold))
            Text(project.title).foregroundStyle(.secondary)
            TextField(L10n.ui("GitHub username"), text: $username).textFieldStyle(.roundedBorder)
            Picker(L10n.ui("Access"), selection: $role) { ForEach(CollaboratorRole.allCases) { Text($0.label).tag($0) } }
            Text(L10n.ui("You must be a project administrator. Existing participants receive the selected role. Project access does not automatically grant access to private repositories."))
                .font(.callout).foregroundStyle(.secondary)
            Link(L10n.ui("See all participants and roles on GitHub"), destination: project.url.appendingPathComponent("settings/access"))
            MessageBanner(model: model)
            HStack {
                Spacer()
                Button(L10n.ui("Close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button((saving ? L10n.ui("Updating …") : L10n.ui("Grant project access"))) { confirm = true }
                    .buttonStyle(.borderedProminent).disabled(saving || !model.canWrite || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(saving)
            .protectUpdateDraft(isDirty: !username.isEmpty)
            .confirmationDialog("Gi @\(username) rollen «\(role.label)» i «\(project.title)»?", isPresented: $confirm, titleVisibility: .visible) {
                Button(L10n.ui("Grant access")) {
                    saving = true
                    Task { let success = await model.grantAccess(projectID: project.id, username: username, role: role); saving = false; if success { username = "" } }
                }
                Button(L10n.ui("Cancel"), role: .cancel) {}
            }
    }
}
