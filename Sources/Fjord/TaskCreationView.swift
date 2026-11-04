import SwiftUI
import FjordCore

struct NewTaskSheet: View {
    @Bindable var model: AppModel
    let projectID: String
    let initialPlacement: ItemPlacement?
    @Environment(\.dismiss) private var dismiss
    @ViewState private var kind = "issue"
    @ViewState private var title = ""
    @ViewState private var text = ""
    @ViewState private var repositories: [RepositoryChoice] = []
    @ViewState private var repositoryID = ""
    @ViewState private var repositoryName = ""
    @ViewState private var showingRepositoryLookup = false
    @ViewState private var candidates: [AssignableUser] = []
    @ViewState private var assigneeIDs: Set<String> = []
    @ViewState private var optionID: String
    @ViewState private var loadingRepositories = true
    @ViewState private var loadingPeople = false
    @ViewState private var saving = false
    @FocusState private var titleFocused: Bool

    init(model: AppModel, projectID: String, placement: ItemPlacement?) {
        self.model = model; self.projectID = projectID; self.initialPlacement = placement
        _optionID = State(initialValue: placement?.optionID ?? "")
    }
    private var field: SelectField? {
        if let initialPlacement { return model.snapshot?.fields.first { $0.id == initialPlacement.fieldID } }
        return model.selectedField
    }
    private var selectedRepository: RepositoryChoice? { repositories.first { $0.id == repositoryID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.ui("New task")).font(.title2.weight(.semibold))
                Spacer()
                Picker(L10n.ui("Type"), selection: $kind) { Text(L10n.ui("Issue")).tag("issue"); Text(L10n.ui("Draft")).tag("draft") }
                    .pickerStyle(.segmented).frame(width: 180).disabled(saving)
            }
            MessageBanner(model: model)
            if kind == "issue" {
                HStack {
                    Picker(L10n.ui("Repository"), selection: $repositoryID) {
                        Text((loadingRepositories ? L10n.ui("Loading repositories …") : L10n.ui("Choose repository"))).tag("")
                        ForEach(repositories) { Text($0.nameWithOwner).tag($0.id) }
                    }.disabled(saving || loadingRepositories)
                    Button { showingRepositoryLookup.toggle() } label: { Image(systemName: "magnifyingglass") }.help(L10n.ui("Find another repository"))
                }
                if showingRepositoryLookup || (!loadingRepositories && repositories.isEmpty) {
                    HStack {
                        TextField("owner/repository", text: $repositoryName).textFieldStyle(.roundedBorder).accessibilityLabel(L10n.ui("Find repository"))
                        Button(L10n.ui("Find")) {
                            loadingRepositories = true
                            Task {
                                if let repository = await model.findRepository(named: repositoryName, projectID: projectID) {
                                    if !repositories.contains(where: { $0.id == repository.id }) { repositories.append(repository) }
                                    repositoryID = repository.id; showingRepositoryLookup = false
                                }
                                loadingRepositories = false
                            }
                        }.disabled(saving || loadingRepositories || repositoryName.isEmpty)
                    }
                }
            }
            TextField(L10n.ui("What needs to be done?"), text: $title).textFieldStyle(.roundedBorder).font(.title3)
                .focused($titleFocused).disabled(saving).accessibilityLabel(L10n.ui("Task title"))
            Text(L10n.ui("Description")).font(.headline)
            TextEditor(text: $text).font(.body).padding(6).frame(minHeight: 170)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.separator, lineWidth: 0.5) }
                .disabled(saving).accessibilityLabel(L10n.ui("Description of new task"))
            HStack(spacing: 20) {
                if let field {
                    Picker(field.name, selection: $optionID) {
                        Text(L10n.ui("Not selected")).tag("")
                        ForEach(field.options) { Text($0.name).tag($0.id) }
                    }.disabled(saving)
                }
                Menu {
                    Button(L10n.ui("No assignee")) { assigneeIDs.removeAll() }
                    ForEach(candidates) { person in
                        Button {
                            if assigneeIDs.contains(person.id) { assigneeIDs.remove(person.id) } else { assigneeIDs.insert(person.id) }
                        } label: {
                            if assigneeIDs.contains(person.id) { Label(person.login, systemImage: "checkmark") }
                            else { Text(person.login) }
                        }
                    }
                } label: {
                    Label(assigneeIDs.isEmpty ? (loadingPeople ? L10n.ui("Loading people …") : L10n.ui("Assign")) : candidates.filter { assigneeIDs.contains($0.id) }.map(\.login).joined(separator: ", "), systemImage: "person.crop.circle")
                }.disabled(saving || loadingPeople)
            }
            Text((kind == "issue" ? L10n.ui("Created as an issue in the repository and added to this project.") : L10n.ui("A project draft can later be converted to an issue on GitHub.")))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.ui("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                Button((saving ? L10n.ui("Creating …") : (kind == "issue" ? L10n.ui("Create issue") : L10n.ui("Create draft")))) {
                    let fieldID = initialPlacement?.fieldID ?? field?.id
                    let placement = fieldID.flatMap { optionID.isEmpty ? nil : ItemPlacement(fieldID: $0, optionID: optionID) }
                    let input = NewItemRequest(title: title, body: text, repositoryID: kind == "issue" ? repositoryID : nil,
                                               assigneeIDs: Array(assigneeIDs).sorted(), placement: placement)
                    saving = true
                    Task { let success = await model.createItem(projectID: projectID, request: input); saving = false; if success { dismiss() } }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(saving || !model.canWrite || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (kind == "issue" && repositoryID.isEmpty))
            }
        }.padding(24).frame(width: 640, height: 640).interactiveDismissDisabled(saving)
            .onAppear { titleFocused = true }
            .task {
                let result = await model.loadRepositories(projectID: projectID)
                guard !Task.isCancelled else { return }
                repositories = result
                if repositoryID.isEmpty { repositoryID = result.first?.id ?? "" }
                loadingRepositories = false
            }
            .task(id: "\(kind):\(repositoryID)") {
                if kind == "issue", repositoryID.isEmpty { candidates = []; loadingPeople = false; return }
                loadingPeople = true
                let result = await model.assignmentCandidates(projectID: projectID, repository: kind == "issue" ? selectedRepository?.nameWithOwner : nil)
                guard !Task.isCancelled else { return }
                candidates = result; loadingPeople = false
            }
            .onChange(of: repositoryID) { _, _ in assigneeIDs.removeAll() }
            .onChange(of: kind) { _, _ in assigneeIDs.removeAll() }
            .protectUpdateDraft(isDirty: !title.isEmpty || !text.isEmpty)
    }
}
