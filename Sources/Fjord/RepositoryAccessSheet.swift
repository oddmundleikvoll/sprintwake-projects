import AppKit
import SwiftUI
import FjordCore

struct RepositoryAccessSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("oauthClientID") private var clientID = Bundle.main.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String ?? ""
    @AppStorage("includePrivateRepositories") private var privateRepositories = false
    @ViewState private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.ui("Access to private tasks"), systemImage: "lock.open").font(.title2.weight(.semibold))
            Text(L10n.ui("GitHub has separate permissions for the project board and repository content. Drafts may be visible even when private issues and PRs are hidden."))
            Text(L10n.ui("To load private items, %@ requests repository access. GitHub’s OAuth permission also grants read and write access to private source code. You approve this on GitHub with the account %@.", AppBrand.name, model.user?.login ?? ""))
                .foregroundStyle(.secondary)
            Text(L10n.ui("GitHub shows the existing app registration “Fjord Projects”. Organizations may require separate approval or SSO. A personal token must have access to the repository itself."))
                .font(.caption).foregroundStyle(.secondary)
            if clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { OAuthConfigurationView() }
            MessageBanner(model: model)
            if let challenge = model.challenge {
                Text(L10n.ui("Open github.com/login/device and enter this code:"))
                HStack(spacing: 14) {
                    Text(challenge.userCode).font(.system(.title, design: .monospaced)).textSelection(.enabled)
                    Button(L10n.ui("Copy code"), systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(challenge.userCode, forType: .string)
                    }
                    Button(L10n.ui("Open GitHub")) { NSWorkspace.shared.open(challenge.verificationURL) }.buttonStyle(.borderedProminent)
                }
                HStack { ProgressView().controlSize(.small); Text(L10n.ui("Waiting for approval …")) }
            } else if model.isAuthenticating {
                ProgressView(L10n.ui("Preparing GitHub authorization …"))
            }
            Text(L10n.ui("The saved sign-in is kept if you cancel or authorization fails."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button((model.isAuthenticating ? L10n.ui("Cancel") : L10n.ui("Close"))) {
                    if model.isAuthenticating { model.cancelOAuth() }
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                if !model.isAuthenticating {
                    Button(L10n.ui("Continue to GitHub")) {
                        started = true
                        privateRepositories = true
                        model.beginOAuth(clientID: clientID, includePrivateRepositories: true)
                    }.buttonStyle(.borderedProminent)
                        .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isMutating)
                }
            }
        }.padding(26).frame(width: 570)
            .interactiveDismissDisabled(model.isAuthenticating)
            .onChange(of: model.isAuthenticating) { wasAuthenticating, authenticating in
                if started, wasAuthenticating, !authenticating, model.errorMessage == nil { dismiss() }
            }
            .onDisappear { if started, model.isAuthenticating { model.cancelOAuth() } }
    }
}
