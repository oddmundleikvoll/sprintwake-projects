import AppKit
import SwiftUI
import FjordCore

struct LoginView: View {
    @Bindable var model: AppModel
    @AppStorage("oauthClientID") private var clientID = Bundle.main.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String ?? ""
    @AppStorage("includePrivateRepositories") private var privateRepositories = false
    @ViewState private var token = ""
    @ViewState private var showConfiguration = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    BrandMark().frame(width: 64, height: 64).shadow(color: WorkspaceStyle.accent.opacity(0.2), radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppBrand.name).font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(L10n.ui("Your projects. A little closer.")).foregroundStyle(.secondary)
                    }
                }
                UpdateAvailableButton()
                Text(L10n.ui("Connect to GitHub to choose a project, move tasks, and keep your board and list up to date."))
                    .font(.title3).fixedSize(horizontal: false, vertical: true)
                MessageBanner(model: model)

                if model.hasSavedSession && !model.isAuthenticating {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.ui("A sign-in is saved. It is kept when the network is unavailable.")).foregroundStyle(.secondary)
                        HStack {
                            Button(L10n.ui("Try saved sign-in again")) { Task { await model.restoreSession() } }
                            Button(L10n.ui("Forget saved sign-in")) { Task { await model.logout() } }
                        }
                    }
                }

                if let challenge = model.challenge {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.ui("Authorize %@ on GitHub", AppBrand.name)).font(.headline)
                        Text(L10n.ui("GitHub shows the existing app registration “Fjord Projects”.")).font(.caption).foregroundStyle(.secondary)
                        Text(L10n.ui("Open github.com/login/device and enter this code:"))
                        HStack(spacing: 16) {
                            Text(challenge.userCode).font(.system(.title, design: .monospaced)).textSelection(.enabled)
                            Button(L10n.ui("Copy code"), systemImage: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(challenge.userCode, forType: .string)
                            }
                        }
                        Button(L10n.ui("Open GitHub"), systemImage: "arrow.up.right") { NSWorkspace.shared.open(challenge.verificationURL) }
                            .buttonStyle(.borderedProminent)
                        HStack { ProgressView().controlSize(.small); Text(L10n.ui("Waiting for approval …")).foregroundStyle(.secondary) }
                        Text(L10n.ui("The code is valid until %@.", challenge.expiresAt.formatted(.dateTime.hour().minute().locale(AppLanguage.current.locale)))).font(.caption).foregroundStyle(.secondary)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                } else if model.isAuthenticating {
                    ProgressView(L10n.ui("Connecting to GitHub …"))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(L10n.ui("Language")).font(.callout.weight(.medium))
                            Spacer()
                            LanguagePicker(disabled: model.isAuthenticating).labelsHidden()
                        }
                        if clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(L10n.ui("Enter the app’s public Client ID under Settings to enable browser sign-in."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Toggle(L10n.ui("Include private issues and pull requests"), isOn: $privateRepositories)
                        Text(privateRepositories
                             ? L10n.ui("Also requests repo access, which grants the OAuth app access to private source code on GitHub.")
                             : L10n.ui("Private tasks are hidden without this option. Requests project, profile, organization and public issue access."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(L10n.ui("Sign in with GitHub"), systemImage: "person.crop.circle.badge.checkmark") {
                            model.beginOAuth(clientID: clientID, includePrivateRepositories: privateRepositories)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if model.isAuthenticating {
                    Button(L10n.ui("Cancel sign-in")) { model.cancelOAuth() }
                } else {
                    Divider()
                    DisclosureGroup(L10n.ui("GitHub settings"), isExpanded: $showConfiguration) { OAuthConfigurationView().padding(.top, 10) }
                    DisclosureGroup(L10n.ui("Alternative: personal access token")) {
                        VStack(alignment: .leading, spacing: 10) {
                            SecureField(L10n.ui("GitHub token"), text: $token)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { signInWithToken() }
                            Text(L10n.ui("For a classic token: project for project editing, and repo for private issues. The token is stored in the Keychain."))
                                .font(.caption).foregroundStyle(.secondary)
                            Button(L10n.ui("Connect with token")) { signInWithToken() }
                                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(.top, 10)
                    }
                    Button(L10n.ui("Explore a local demo"), systemImage: "sparkles") { Task { await model.startDemo() } }
                        .buttonStyle(.plain).foregroundStyle(.indigo)
                    Label(L10n.ui("Sign-in is stored securely in the macOS Keychain."), systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(32).frame(maxWidth: 580, alignment: .leading)
            .workspaceSurface(radius: 24)
            .padding(40).frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(colors: [WorkspaceStyle.sidebar, WorkspaceStyle.canvas, WorkspaceStyle.canvas],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .onAppear { showConfiguration = clientID.isEmpty }
        .onDisappear { token = "" }
        .protectUpdateDraft(isDirty: !token.isEmpty)
    }

    private func signInWithToken() {
        let suppliedToken = token
        token = ""
        Task { await model.signIn(token: suppliedToken) }
    }
}

struct OAuthConfigurationView: View {
    @AppStorage("oauthClientID") private var clientID = Bundle.main.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String ?? ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L10n.ui("Public OAuth Client ID"), text: $clientID).textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.ui("OAuth Client ID"))
            Text(L10n.ui("The developer registers one OAuth app with “Enable Device Flow” enabled. The Client ID can be shared with users. Do not enter a Client Secret here."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link(L10n.ui("Open OAuth apps on GitHub"), destination: URL(string: "https://github.com/settings/developers")!)
        }
    }
}
