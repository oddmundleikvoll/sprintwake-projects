import AppKit
import SwiftUI
import FjordCore

@main
struct FjordApp: App {
    @NSApplicationDelegateAdaptor(FjordAppDelegate.self) private var delegate
    @ViewState private var model = AppModel()
    @ViewState private var slack = SlackChatModel()
    @ViewState private var slackAuthenticator = SlackWebAuthenticator()
    @ViewState private var updates = AppUpdateController()
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.defaultSelection.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window(AppBrand.name, id: "workspace") {
            Group {
                if model.isRestoring {
                    VStack(spacing: 16) {
                        BrandMark().frame(width: 60, height: 60)
                        ProgressView(L10n.ui("Restoring saved sign-in …"))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.user != nil {
                    WorkspaceView(model: model)
                } else {
                    LoginView(model: model)
                }
            }
            .environment(slack)
            .environment(slackAuthenticator)
            .environment(updates)
            .disabled(updates.isInstalling)
            .environment(\.locale, AppLanguage.storedSelection(language).locale)
            .onChange(of: language) { _, value in LanguageSettings.shared.update(value) }
            .onChange(of: SlackChatContext(accountID: model.user?.nodeID ?? model.user?.login,
                                           projectID: model.selectedProjectID, isDemo: model.isDemo), initial: true) { old, next in
                if old.accountID != next.accountID || old.isDemo != next.isDemo { slackAuthenticator.cancel() }
                slack.updateContext(next)
            }
            .onChange(of: slack.isAuthenticating) { _, active in if !active { slackAuthenticator.closeBrowserIfFinished() } }
            .onChange(of: model.isAuthenticating || model.isMutating || slack.isAuthenticating || slack.isSending, initial: true) { _, busy in
                updates.setOperationsBusy(busy)
            }
            .frame(minWidth: 820, minHeight: 590)
            .tint(WorkspaceStyle.accent)
            .task {
                updates.start()
                if CommandLine.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "FjordDemoMode") as? Bool == true { await model.startDemo() }
                else { await model.start() }
            }
            .task(id: model.user?.login) {
                guard model.user != nil else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    if scenePhase == .active { await model.refresh() }
                }
            }
            .task(id: model.user?.nodeID ?? model.user?.login) {
                guard model.user != nil else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    if scenePhase == .active {
                        await model.refreshSharedProjects()
                        if slack.source == .slack { await slack.refresh() }
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await model.refresh(); await model.refreshSharedProjects() }
                    if slack.source == .slack { Task { await slack.refresh() } }
                }
            }
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.ui("Check for Updates …")) { updates.checkForUpdates() }
                    .disabled(!updates.canCheck || updates.operationsBusy)
            }
            CommandGroup(after: .newItem) {
                Button(L10n.ui("New task")) { NotificationCenter.default.post(name: .fjordNewItem, object: nil) }
                    .keyboardShortcut("n")
                    .disabled(!model.canWrite)
            }
            CommandGroup(after: .toolbar) {
                Button(L10n.ui("Refresh from GitHub")) { Task { await model.refreshWorkspace() } }
                    .keyboardShortcut("r")
                    .disabled(model.user == nil || model.isMutating)
            }
        }
        Settings {
            ScrollView { VStack(alignment: .leading, spacing: 18) {
                Text(L10n.ui("Settings")).font(.title2.weight(.semibold))
                LanguagePicker(disabled: model.isAuthenticating || model.isMutating)
                Divider()
                AppUpdateSettings()
                Divider()
                OAuthConfigurationView()
                Text(L10n.ui("The Client ID is public. Access tokens are stored only in macOS Keychain."))
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                SlackSettingsView()
            }.padding(24) }.frame(width: 550, height: 650)
                .environment(slack)
                .environment(slackAuthenticator)
                .environment(updates)
                .disabled(updates.isInstalling)
                .environment(\.locale, AppLanguage.storedSelection(language).locale)
                .onChange(of: language) { _, value in LanguageSettings.shared.update(value) }
        }
    }
}

final class FjordAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    static let fjordNewItem = Notification.Name("Fjord.NewItem")
}

struct MessageBanner: View {
    @Bindable var model: AppModel
    var body: some View {
        if let error = model.errorMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.ui("Dismiss message"))
            }.font(.callout).padding(12).background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        }
        if let notice = model.notice {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice).textSelection(.enabled)
                    if let url = model.noticeURL { Link(L10n.ui("Open created issue"), destination: url) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.ui("Dismiss message"))
            }.font(.callout).padding(12).background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
    }
}
