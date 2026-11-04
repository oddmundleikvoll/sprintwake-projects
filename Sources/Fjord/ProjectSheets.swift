import SwiftUI
import FjordCore

struct NewProjectSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var title = ""
    @ViewState private var ownerID = ""
    @ViewState private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.ui("New project"), systemImage: "folder.badge.plus").font(.title2.weight(.semibold))
            TextField(L10n.ui("Project name"), text: $title).textFieldStyle(.roundedBorder).accessibilityLabel(L10n.ui("Project name"))
            Picker(L10n.ui("Owner"), selection: $ownerID) { ForEach(model.owners) { Text($0.login).tag($0.id) } }.disabled(saving)
            Text(model.isDemo ? L10n.ui("The project is created only in the local demo.") : L10n.ui("The project is created in the GitHub account or organization you choose.")).font(.callout).foregroundStyle(.secondary)
            MessageBanner(model: model)
            HStack {
                Button(L10n.ui("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button(saving ? L10n.ui("Creating …") : L10n.ui("Create project")) {
                    guard let owner = model.owners.first(where: { $0.id == ownerID }) else { return }
                    saving = true
                    Task { let success = await model.createProject(owner: owner, title: title); saving = false; if success { dismiss() } }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || model.isMutating || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownerID.isEmpty)
            }
        }.padding(24).frame(width: 500).interactiveDismissDisabled(saving)
            .onAppear { ownerID = model.selectedOwner?.id ?? model.owners.first?.id ?? "" }
            .protectUpdateDraft(isDirty: !title.isEmpty)
    }
}

struct DeleteProjectSheet: View {
    @Bindable var model: AppModel
    let project: ProjectSummary
    @Environment(\.dismiss) private var dismiss
    @ViewState private var confirmation = ""
    @ViewState private var deleting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.ui("Delete project"), systemImage: "trash").font(.title2.weight(.semibold))
            Text(project.title).font(.headline).textSelection(.enabled)
            Text(model.isDemo ? L10n.ui("This removes the project and drafts from the local demo.") : L10n.ui("The project and project drafts are permanently deleted on GitHub. Issues and pull requests in repositories are kept.")).foregroundStyle(.secondary)
            Text(L10n.ui("Type the project name to confirm:")).font(.callout)
            TextField(L10n.ui("Project name"), text: $confirmation).textFieldStyle(.roundedBorder).accessibilityLabel(L10n.ui("Confirm project name"))
            MessageBanner(model: model)
            HStack {
                Button(L10n.ui("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(deleting)
                Spacer()
                Button(deleting ? L10n.ui("Deleting …") : (model.isDemo ? L10n.ui("Delete demo project") : L10n.ui("Delete project permanently")), role: .destructive) {
                    deleting = true
                    Task { let success = await model.deleteProject(projectID: project.id, confirmationTitle: confirmation); deleting = false; if success { dismiss() } }
                }.disabled(deleting || !model.canWrite || confirmation != project.title)
            }
        }.padding(24).frame(width: 520).interactiveDismissDisabled(deleting)
    }
}

struct ColumnsSheet: View {
    @Bindable var model: AppModel
    let projectID: String
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var saving = false
    @ViewState private var deleting: SelectOption?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(L10n.ui("Columns"), systemImage: "rectangle.split.3x1").font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.ui("Done")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
            }
            if let field = model.selectedField {
                Text(L10n.ui("Grouped by «%@»", field.name)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(field.options) { option in
                            HStack {
                                Circle().fill(option.swiftUIColor).frame(width: 8, height: 8)
                                Text(option.name)
                                Spacer()
                                Text("\(model.snapshot?.items.filter { $0.selections[field.id] == option.id }.count ?? 0)").foregroundStyle(.secondary)
                                Button { deleting = option } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                                    .help(L10n.ui("Delete column %@", option.name)).disabled(saving || !model.canWrite)
                            }.padding(.vertical, 10)
                            Divider()
                        }
                    }
                }.frame(maxHeight: 270)
                if model.isDemo {
                    HStack {
                        TextField(L10n.ui("New column"), text: $name).textFieldStyle(.roundedBorder).accessibilityLabel(L10n.ui("New column name"))
                        Button(L10n.ui("Add"), systemImage: "plus") {
                            saving = true
                            Task { if await model.addColumn(projectID: projectID, name: name) { name = "" }; saving = false }
                        }.disabled(saving || !model.canWrite || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else if let project = model.snapshot?.project {
                    Text(L10n.ui("Add and remove status options in GitHub's column settings. Refresh here after saving the change.")).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Link(L10n.ui("Add column on GitHub"), destination: project.url)
                        Spacer()
                        Button(L10n.ui("Refresh")) { Task { await model.refresh() } }.disabled(model.isLoadingProject)
                    }
                }
            }
            MessageBanner(model: model)
        }.padding(24).frame(width: 520)
            .sheet(item: $deleting) { option in DeleteColumnSheet(model: model, projectID: projectID, option: option) }
            .protectUpdateDraft(isDirty: !name.isEmpty)
    }
}

struct DeleteColumnSheet: View {
    @Bindable var model: AppModel
    let projectID: String
    let option: SelectOption
    @Environment(\.dismiss) private var dismiss
    @ViewState private var deleting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.ui("Delete «%@»", option.name)).font(.title2.weight(.semibold))
            let count = model.snapshot?.items.filter { $0.selections[model.selectedFieldID ?? ""] == option.id }.count ?? 0
            Text(L10n.ui("%lld tasks use this column. When the status option is deleted, these tasks will have no value in the field. The tasks remain in the project.", count)).foregroundStyle(.secondary)
            if model.isDemo {
                MessageBanner(model: model)
                HStack {
                    Button(L10n.ui("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(deleting)
                    Spacer()
                    Button(L10n.ui("Delete column"), role: .destructive) {
                        deleting = true
                        Task { let success = await model.deleteColumn(projectID: projectID, optionID: option.id); deleting = false; if success { dismiss() } }
                    }.disabled(deleting || !model.canWrite)
                }
            } else if let project = model.snapshot?.project {
                Text(L10n.ui("Open the column menu on GitHub to delete the status option. Refresh the app afterwards.")).font(.callout)
                HStack {
                    Button(L10n.ui("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Link(L10n.ui("Open project on GitHub"), destination: project.url)
                }
            }
        }.padding(24).frame(width: 500).interactiveDismissDisabled(deleting)
    }
}
