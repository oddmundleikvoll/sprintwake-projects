import SwiftUI
import FjordCore

private struct TaskCreationTarget: Identifiable {
    let id = UUID()
    let projectID: String
    let placement: ItemPlacement?
}

struct WorkspaceView: View {
    @Bindable var model: AppModel
    @Environment(SlackChatModel.self) private var slack
    @AppStorage("workspaceLayout") private var layout = "board"
    @ViewState private var search = ""
    @ViewState private var showProjectURL = false
    @ViewState private var showNewProject = false
    @ViewState private var showColumns = false
    @ViewState private var showParticipants = false
    @ViewState private var showRepositoryAccess = false
    @ViewState private var taskTarget: TaskCreationTarget?
    @ViewState private var editingItem: ProjectItem?
    @ViewState private var deletingProject: ProjectSummary?
    @ViewState private var deletingColumn: SelectOption?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if model.isDemo {
                    HStack {
                        Label(L10n.ui("Local demo · sample data"), systemImage: "sparkles")
                        Spacer()
                        Button(L10n.ui("Connect to GitHub")) { Task { await model.logout() } }
                    }.font(.callout).padding(.horizontal, 18).padding(.vertical, 10).background(.indigo.opacity(0.08))
                }
                if model.errorMessage != nil || model.notice != nil {
                    VStack(spacing: 8) { MessageBanner(model: model) }.padding(16)
                }
                if model.inaccessibleItemCount > 0 {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.ui("GitHub hides %lld tasks for this sign-in.", model.inaccessibleItemCount)).fontWeight(.medium)
                            Text(L10n.ui("Private issues and PRs require repository access in addition to project access. Organizations may also require approval or SSO."))
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button(L10n.ui("Grant access …")) { showRepositoryAccess = true }.disabled(model.isMutating)
                    }.font(.callout).padding(16).background(.orange.opacity(0.07))
                }
                if let snapshot = model.snapshot { projectContent(snapshot) }
                else if model.isLoadingProject || model.isLoadingProjects {
                    ProgressView(L10n.ui("Loading project …")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(L10n.ui("A place for your project"), systemImage: "rectangle.stack")
                    } description: {
                        Text(L10n.ui("Choose a project in the sidebar, create one, or open a project link."))
                    } actions: {
                        Button(L10n.ui("New project"), systemImage: "plus") { showNewProject = true }.buttonStyle(.borderedProminent)
                        Button(L10n.ui("Open project link")) { showProjectURL = true }.disabled(model.isDemo)
                    }
                }
            }
            .background(WorkspaceStyle.canvas)
            .navigationTitle(model.snapshot?.project.title ?? AppBrand.name)
            .toolbar {
                ToolbarItemGroup {
                    Picker(L10n.ui("View"), selection: $layout) {
                        Text(L10n.ui("Board")).tag("board")
                        Text(L10n.ui("List")).tag("list")
                        Text(L10n.ui("Conversation")).tag("chat")
                    }.pickerStyle(.segmented).frame(width: 245)
                    Button { Task { await model.refreshWorkspace() } } label: { Image(systemName: "arrow.clockwise") }
                        .help(L10n.ui("Refresh from GitHub (⌘R)")).disabled(model.isMutating || model.isLoadingProject)
                    Menu {
                        Button(L10n.ui("Slack channel …"), systemImage: "number") { slack.setSource(.slack); layout = "chat" }
                        Divider()
                        Button(L10n.ui("Columns …"), systemImage: "rectangle.split.3x1") { showColumns = true }
                            .disabled(model.selectedField == nil)
                        Button(L10n.ui("Participants and access …"), systemImage: "person.2") { showParticipants = true }
                            .disabled(model.snapshot == nil || model.isDemo)
                        if let project = model.snapshot?.project {
                            if !model.isDemo { Link(L10n.ui("Open on GitHub"), destination: project.url) }
                            Divider()
                            Button(L10n.ui("Delete project …"), systemImage: "trash", role: .destructive) { deletingProject = project }
                                .disabled(!model.canWrite)
                        }
                    } label: { Label(L10n.ui("Project"), systemImage: "slider.horizontal.3").labelStyle(.titleAndIcon) }
                        .disabled(model.isMutating || model.snapshot == nil)
                }
            }
        }
        .sheet(isPresented: $showRepositoryAccess) { RepositoryAccessSheet(model: model) }
        .sheet(isPresented: $showProjectURL) { ProjectURLSheet(model: model) }
        .sheet(isPresented: $showNewProject) { NewProjectSheet(model: model) }
        .sheet(item: $taskTarget) { target in NewTaskSheet(model: model, projectID: target.projectID, placement: target.placement) }
        .sheet(item: $editingItem) { item in
            if let snapshot = model.snapshot { ItemEditor(model: model, projectID: snapshot.project.id, item: item) }
        }
        .sheet(isPresented: $showColumns) {
            if let snapshot = model.snapshot { ColumnsSheet(model: model, projectID: snapshot.project.id) }
        }
        .sheet(isPresented: $showParticipants) {
            if let snapshot = model.snapshot { ParticipantsSheet(model: model, project: snapshot.project) }
        }
        .sheet(item: $deletingProject) { DeleteProjectSheet(model: model, project: $0) }
        .sheet(item: $deletingColumn) { option in
            if let projectID = model.selectedProjectID { DeleteColumnSheet(model: model, projectID: projectID, option: option) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .fjordNewItem)) { _ in
            if taskTarget == nil, editingItem == nil, !showNewProject, !showColumns, !showParticipants, !showProjectURL { openTask(placement: nil) }
        }
        .onChange(of: model.selectedProjectID) { _, _ in search = ""; editingItem = nil; taskTarget = nil; deletingColumn = nil }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 11) {
                    BrandMark().frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppBrand.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(L10n.ui("Your projects. A little closer.")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker(L10n.ui("Owner"), selection: Binding(get: { model.selectedOwner?.id ?? "" }, set: { id in
                    if let owner = model.owners.first(where: { $0.id == id }) { Task { await model.selectOwner(owner) } }
                })) { ForEach(model.owners) { Text($0.login).tag($0.id) } }.labelsHidden().controlSize(.large).disabled(model.isMutating)
                HStack {
                    Text(L10n.ui("PROJECTS")).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button(L10n.ui("New project"), systemImage: "folder.badge.plus") { showNewProject = true }
                        Button(L10n.ui("Open project link"), systemImage: "link") { showProjectURL = true }.disabled(model.isDemo)
                    } label: { Image(systemName: "plus.circle.fill") }.menuStyle(.borderlessButton).fixedSize()
                        .help(L10n.ui("Add project")).accessibilityLabel(L10n.ui("Add project")).disabled(model.isMutating)
                }
            }.padding(20).padding(.bottom, -6)
            List(selection: Binding(get: { model.selectedProjectID }, set: { id in
                if let project = model.sharedProjects.first(where: { $0.id == id }) {
                    Task { _ = await model.openProject(url: project.url.absoluteString) }
                } else if let project = model.projects.first(where: { $0.id == id }) {
                    Task { await model.selectProject(project) }
                }
            })) {
                ForEach(model.projects.filter { project in !model.sharedProjects.contains(where: { $0.id == project.id }) }) { project in
                    Label {
                        Text(project.title).fontWeight(model.selectedProjectID == project.id ? .semibold : .regular).lineLimit(3).padding(.vertical, 8)
                    } icon: { Image(systemName: project.closed ? "archivebox" : "folder") }
                    .tag(project.id)
                    .contextMenu {
                        Button(L10n.ui("Open project")) { Task { await model.selectProject(project) } }
                        if !model.isDemo { Link(L10n.ui("Open on GitHub"), destination: project.url) }
                        Divider()
                        Button(L10n.ui("Delete project …"), role: .destructive) {
                            Task {
                                if model.selectedProjectID != project.id { await model.selectProject(project) }
                                if model.snapshot?.project.id == project.id { deletingProject = project }
                            }
                        }
                    }
                }
                if model.isLoadingProjects { ProgressView(L10n.ui("Loading projects …")).controlSize(.small) }
                Section {
                    ForEach(model.sharedProjects) { project in sharedProjectRow(project) }
                    if model.isLoadingSharedProjects {
                        ProgressView(L10n.ui("Checking shared projects …")).controlSize(.small)
                    } else if model.isCheckingMoreSharedProjects {
                        Text(L10n.ui("More shared projects are checked automatically over the next few minutes."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.sharedProjects.isEmpty {
                        Text(L10n.ui("No shared projects found through your GitHub connections."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.sharedProjectsError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    Button(L10n.ui("Open shared project link …"), systemImage: "link") { showProjectURL = true }
                        .disabled(model.isDemo)
                        .help(L10n.ui("If a shared project is missing, open its link once. The app remembers and checks that owner automatically."))
                } header: {
                    HStack {
                        Label(L10n.ui("Shared projects"), systemImage: "person.2")
                        Spacer()
                        if !model.unseenSharedProjectIDs.isEmpty {
                            Text(L10n.ui("New: %lld", model.unseenSharedProjectIDs.count)).foregroundStyle(.indigo)
                        }
                    }
                    .help(L10n.ui("Checks shared projects every minute while active. Refresh also checks for new repository connections."))
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden).disabled(model.isMutating)
            Divider().padding(.horizontal, 16)
            VStack(spacing: 12) {
                UpdateAvailableButton()
                Button { showNewProject = true } label: {
                    Label(L10n.ui("New project"), systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 4)
                }.buttonStyle(.bordered).controlSize(.large).disabled(model.isMutating)
                HStack {
                    Button { Task { await model.reloadProjects() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help(L10n.ui("Refresh project list")).disabled(model.isMutating || model.isLoadingProjects)
                    Spacer()
                    Label(model.user?.login ?? "", systemImage: "person.crop.circle").font(.callout).lineLimit(1)
                    Menu {
                        SettingsLink { Text(L10n.ui("Settings …")) }
                        if !model.isDemo { Button(L10n.ui("Access private tasks …")) { showRepositoryAccess = true } }
                        Button(model.isDemo ? L10n.ui("Exit demo") : L10n.ui("Sign out")) { Task { await model.logout() } }
                    } label: { Image(systemName: "gearshape") }.menuStyle(.borderlessButton).fixedSize().help(L10n.ui("Account and settings"))
                }
            }.padding(16)
        }.background(WorkspaceStyle.sidebar)
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
    }

    private func sharedProjectRow(_ project: ProjectSummary) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title).lineLimit(3)
                HStack {
                    Text(project.owner?.login ?? "").lineLimit(1)
                    if project.isPublic == true { Text(L10n.ui("Public project")) }
                    if model.unseenSharedProjectIDs.contains(project.id) {
                        Text(L10n.ui("New")).fontWeight(.semibold).foregroundStyle(.indigo)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 6)
        } icon: { Image(systemName: project.closed ? "archivebox" : "person.2") }
        .tag(project.id)
        .contextMenu {
            Button(L10n.ui("Open project")) { Task { _ = await model.openProject(url: project.url.absoluteString) } }
            if !model.isDemo { Link(L10n.ui("Open on GitHub"), destination: project.url) }
        }
    }

    private func openTask(placement: ItemPlacement?) {
        guard model.canWrite, let projectID = model.selectedProjectID else { return }
        model.errorMessage = nil; model.notice = nil; model.noticeURL = nil
        taskTarget = TaskCreationTarget(projectID: projectID, placement: placement)
    }

    @ViewBuilder private func projectContent(_ snapshot: ProjectSnapshot) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(snapshot.project.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 12) {
                        Label(L10n.ui("%lld tasks", snapshot.items.count), systemImage: "square.stack.3d.up")
                        if !snapshot.canUpdate { Label(L10n.ui("Read only"), systemImage: "lock") }
                    }.font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if !snapshot.fields.isEmpty {
                        Picker(L10n.ui("Group by"), selection: Binding(get: { model.selectedFieldID ?? "" }, set: model.setGrouping)) {
                            ForEach(snapshot.fields) { Text($0.name).tag($0.id) }
                        }.frame(maxWidth: 260).disabled(model.isMutating)
                    }
                    Spacer(minLength: 8)
                    if model.isMutating { ProgressView((model.isDemo ? L10n.ui("Saving …") : L10n.ui("Saving to GitHub …"))).controlSize(.small) }
                    else if model.isLoadingProject { ProgressView().controlSize(.small) }
                    if layout != "chat" {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                            TextField(L10n.ui("Search tasks"), text: $search)
                                .textFieldStyle(.plain).accessibilityLabel(L10n.ui("Search tasks"))
                        }.padding(.horizontal, 12).padding(.vertical, 9)
                            .frame(minWidth: 120, idealWidth: 220, maxWidth: 260)
                            .workspaceSurface(radius: 10)
                    }
                }.controlSize(.regular)
            }.padding(.horizontal, 24).padding(.vertical, 20)
            Divider()
            let items = snapshot.items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.repository?.localizedCaseInsensitiveContains(search) ?? false) || $0.assigneeLogins.contains(where: { $0.localizedCaseInsensitiveContains(search) }) }
            if layout == "chat" {
                ProjectConversationView(model: model, projectID: snapshot.project.id, onOpen: { editingItem = $0 }).id(snapshot.project.id)
            } else if layout == "list" {
                ItemListView(model: model, items: items, onOpen: { editingItem = $0 })
            } else {
                BoardView(model: model, items: items, onOpen: { editingItem = $0 }, onCreate: openTask,
                          onColumns: { showColumns = true }, onDeleteColumn: { deletingColumn = $0 }).id(snapshot.project.id)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: model.isDemo ? "sparkles" : "checkmark.circle")
                if model.isDemo { Text(L10n.ui("Local demo · changes are saved only in this session")) }
                else if let date = model.lastSync { Text(L10n.ui("Synced %@", date.formatted(.dateTime.hour().minute().second().locale(AppLanguage.current.locale)))) }
                Spacer()
                Text(model.selectedOwner?.login ?? "")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10)
                .help(L10n.ui("Refreshes from GitHub when the app activates and every 30 seconds while active."))
        }
    }
}
