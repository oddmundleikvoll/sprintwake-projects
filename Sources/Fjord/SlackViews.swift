import AppKit
import AuthenticationServices
import Observation
import SwiftUI
import FjordCore

@MainActor @Observable
final class SlackWebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    @ObservationIgnored private var session: ASWebAuthenticationSession?
    @ObservationIgnored private weak var model: SlackChatModel?
    @ObservationIgnored private var authorization: SlackAuthorization?

    func connect(model: SlackChatModel, clientID: String, includePrivateChannels: Bool) {
        guard let request = model.beginAuthorization(clientID: clientID, includePrivateChannels: includePrivateChannels) else { return }
        self.model = model; authorization = request
        let browser = ASWebAuthenticationSession(url: request.url, callbackURLScheme: "sprintwake-slack") { [weak self] url, error in
            Task { @MainActor in
                guard let self, self.authorization == request, let model = self.model else { return }
                self.session = nil; self.authorization = nil
                if let url { model.completeAuthorization(request, callback: url) }
                else {
                    model.cancelAuthorization()
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        model.errorMessage = L10n.ui("Slack sign-in could not be completed. Try again.")
                    }
                }
            }
        }
        browser.presentationContextProvider = self
        // Let the system browser reuse an existing Slack browser session.
        browser.prefersEphemeralWebBrowserSession = false
        session = browser
        if !browser.start() {
            cancel()
            model.errorMessage = L10n.ui("The Slack sign-in window could not be opened. Try again.")
        }
    }

    func cancel() {
        authorization = nil
        session?.cancel(); session = nil
        model?.cancelAuthorization(); model = nil
    }

    func closeBrowserIfFinished() {
        if model?.isAuthenticating != true { authorization = nil; session?.cancel(); session = nil; model = nil }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    }
}

struct ProjectConversationView: View {
    @Bindable var model: AppModel
    @Environment(SlackChatModel.self) private var slack
    let projectID: String
    let onOpen: (ProjectItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // A bound @MainActor method reference crashes Swift 6.3's IRGen.
                Picker(L10n.ui("Conversation source"), selection: Binding(get: { slack.source }, set: { slack.setSource($0) })) {
                    Text(L10n.ui("GitHub drafts")).tag(ConversationSource.github)
                    Text("Slack").tag(ConversationSource.slack)
                }.pickerStyle(.segmented).frame(width: 300)
                Spacer()
                if slack.source == .slack { Text(L10n.ui("Messages stay in Slack.")).font(.caption).foregroundStyle(.secondary) }
            }.padding(16)
            Divider()
            if slack.source == .slack { SlackChatView(compact: false) }
            else { ChatView(model: model, projectID: projectID, onOpen: onOpen) }
        }
    }
}

struct SlackSettingsView: View {
    @Environment(SlackChatModel.self) private var slack
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Slack").font(.headline)
            SlackConnectionControls()
            if slack.isConnected, slack.context.projectID != nil { SlackChannelPicker() }
        }
    }
}

private struct SlackConnectionControls: View {
    @Environment(SlackChatModel.self) private var slack
    @Environment(SlackWebAuthenticator.self) private var authenticator
    @AppStorage("slackOAuthClientID") private var clientID = Bundle.main.object(forInfoDictionaryKey: "SlackOAuthClientID") as? String ?? ""
    @AppStorage("slackPrivateChannels") private var privateChannels = false
    @ViewState private var showSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if slack.context.accountID == nil {
                Text(L10n.ui("Sign in to GitHub before connecting a Slack workspace.")).foregroundStyle(.secondary)
            } else if slack.context.isDemo {
                Label(L10n.ui("Local Slack demo · no network or credentials"), systemImage: "sparkles").foregroundStyle(.secondary)
            } else {
                if let identity = slack.identity {
                    Text(L10n.ui("Connected to %@ as %@", identity.teamName, identity.userName)).font(.callout)
                } else {
                    Text(L10n.ui("Connect a Slack workspace, then choose a channel for this project.")).foregroundStyle(.secondary)
                }
                if slack.isRestoring { ProgressView(L10n.ui("Restoring Slack connection …")).controlSize(.small) }
                if slack.isAuthenticating {
                    HStack {
                        ProgressView(L10n.ui("Approve the connection in your browser …")).controlSize(.small)
                        Button(L10n.ui("Cancel")) { authenticator.cancel() }
                    }
                } else {
                    HStack {
                        Button(slack.isConnected ? L10n.ui("Reconnect Slack") : L10n.ui("Connect Slack")) {
                            authenticator.connect(model: slack, clientID: clientID, includePrivateChannels: privateChannels)
                        }.buttonStyle(.borderedProminent)
                            .disabled(slack.isRestoring || slack.context.accountID == nil || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if slack.canRetryRestore {
                            Button(L10n.ui("Retry saved connection")) { Task { await slack.retryRestore() } }.disabled(slack.isRestoring)
                        }
                        if slack.isConnected {
                            Button(L10n.ui("Disconnect Slack")) { Task { await slack.disconnect() } }.disabled(slack.isSending)
                        }
                    }
                }
                Toggle(L10n.ui("Include private Slack channels"), isOn: $privateChannels).disabled(slack.isAuthenticating)
                Text(L10n.ui("Slack asks permission to read channel messages and send messages as you. Workspace administrators may require approval."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !slack.context.isDemo {
                DisclosureGroup(L10n.ui("Slack app setup"), isExpanded: $showSetup) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(L10n.ui("Public Slack Client ID"), text: $clientID).textFieldStyle(.roundedBorder)
                            .disabled(slack.isAuthenticating).accessibilityLabel(L10n.ui("Public Slack Client ID"))
                        Text(L10n.ui("The app developer configures one Slack app with PKCE enabled. Enter only its public Client ID here; never a Client Secret or token."))
                            .font(.caption).foregroundStyle(.secondary)
                        Link(L10n.ui("Open Slack app settings"), destination: URL(string: "https://api.slack.com/apps")!)
                    }.padding(.top, 6)
                }
                if clientID.isEmpty { Text(L10n.ui("Add the public Slack Client ID under Slack app setup to enable Connect Slack.")).font(.caption).foregroundStyle(.secondary) }
            }
            SlackNotices()
        }.onAppear { if clientID.isEmpty { showSetup = true } }
    }
}

private struct SlackNotices: View {
    @Environment(SlackChatModel.self) private var slack
    var body: some View {
        if let error = slack.errorMessage {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button { slack.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.ui("Dismiss message"))
            }.font(.callout)
        }
        if let notice = slack.notice {
            VStack(alignment: .leading, spacing: 8) {
                Text(notice).font(.callout).textSelection(.enabled)
                if slack.deliveryNeedsReview {
                    HStack {
                        if let url = slack.channelURL { Link(L10n.ui("Check in Slack"), destination: url) }
                        Button(L10n.ui("I checked the channel")) { slack.acknowledgeUnconfirmedDelivery() }
                    }
                }
            }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct SlackChannelPicker: View {
    @Environment(SlackChatModel.self) private var slack
    var body: some View {
        HStack(spacing: 10) {
            Picker(L10n.ui("Slack channel"), selection: Binding(get: { slack.channel?.id ?? "" }, set: { slack.chooseChannel($0.isEmpty ? nil : $0) })) {
                Text(L10n.ui("Choose channel")).tag("")
                ForEach(slack.channels) { channel in
                    Text((channel.isPrivate ? "🔒 " : "#") + channel.name).tag(channel.id)
                }
            }.disabled(slack.isLoadingChannels || slack.isAuthenticating || slack.isSending)
            Button { Task { await slack.loadChannels() } } label: { Image(systemName: "arrow.clockwise") }
                .help(L10n.ui("Refresh Slack channels")).disabled(slack.isLoadingChannels || slack.isAuthenticating)
        }
    }
}

struct SlackChatView: View {
    @Environment(SlackChatModel.self) private var slack
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !slack.isConnected {
                ScrollView { SlackConnectionControls().padding(20) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if compact { Label("Slack", systemImage: "number").font(.headline) }
                    SlackChannelPicker()
                    if let identity = slack.identity {
                        HStack {
                            Text(identity.teamName).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let url = slack.channelURL { Link(L10n.ui("Open in Slack"), destination: url).font(.caption) }
                            Button { Task { await slack.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                                .help(L10n.ui("Refresh Slack messages")).disabled(slack.channel == nil || slack.isLoadingMessages || slack.isAuthenticating)
                        }
                    }
                    SlackNotices()
                }.padding(compact ? 12 : 16)
                Divider()
                if slack.channel == nil {
                    ContentUnavailableView(L10n.ui("Choose a Slack channel"), systemImage: "number", description: Text(L10n.ui("The channel is remembered for this project on this Mac.")))
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                if slack.nextCursor != nil {
                                    Button(L10n.ui("Load older messages")) { Task { await slack.loadOlder() } }.disabled(slack.isLoadingMessages)
                                }
                                if slack.messages.isEmpty && !slack.isLoadingMessages {
                                    Text(L10n.ui("No messages in this channel yet.")).foregroundStyle(.secondary).font(.callout)
                                }
                                ForEach(slack.messages) { message in SlackMessageBubble(message: message).id(message.id) }
                                if slack.isLoadingMessages { ProgressView().controlSize(.small) }
                            }.padding(compact ? 12 : 20).frame(maxWidth: .infinity, alignment: .leading)
                        }.defaultScrollAnchor(.bottom)
                            .onChange(of: slack.messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                    Divider()
                    SlackComposer().id("\(slack.context.projectID ?? "").\(slack.channel?.id ?? "")").padding(compact ? 12 : 16)
                }
            }
        }
    }
}

private struct SlackMessageBubble: View {
    @Environment(SlackChatModel.self) private var slack
    let message: SlackMessage
    private var author: String { message.userID.flatMap { slack.userNames[$0] } ?? message.displayName ?? message.userID ?? L10n.ui("Slack app") }
    private var formattedText: AttributedString {
        let plain = SlackMessageText.plainText(message.text, userNames: slack.userNames,
                                              channelNames: Dictionary(slack.channels.map { ($0.id, $0.name) }, uniquingKeysWith: { _, value in value }))
        var result = AttributedString(plain)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      let range = Range(match.range, in: plain), let attributedRange = Range(range, in: result) else { continue }
                result[attributedRange].link = url
            }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(author).font(.caption.weight(.semibold))
                Spacer()
                if let date = message.createdAt { Text(date, format: .dateTime.day().month().hour().minute()).font(.caption2).foregroundStyle(.secondary) }
                if message.isEdited { Text(L10n.ui("Edited")).font(.caption2).foregroundStyle(.secondary) }
                if let url = slack.messageURL(message) {
                    Link(destination: url) { Image(systemName: "arrow.up.right") }.help(L10n.ui("Open in Slack"))
                }
            }
            if message.text.isEmpty { Text(L10n.ui("Open this message in Slack to view its content.")).font(.callout).foregroundStyle(.secondary) }
            else { Text(formattedText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if message.replyCount > 0, let url = slack.messageURL(message) {
                Link(L10n.ui("%lld replies · open thread in Slack", message.replyCount), destination: url).font(.caption)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .workspaceSurface()
    }
}

private struct SlackComposer: View {
    @Environment(SlackChatModel.self) private var slack
    @ViewState private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if slack.channel?.isMember == false { Text(L10n.ui("Join this channel in Slack before sending messages.")).font(.caption).foregroundStyle(.secondary) }
            TextEditor(text: $message).font(.body).scrollContentBackground(.hidden).frame(height: 70).padding(7)
                .workspaceSurface(radius: 12)
                .accessibilityLabel(L10n.ui("Slack message")).disabled(slack.isSending)
            HStack {
                Text(L10n.ui("Sent as your Slack user")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(slack.isSending ? L10n.ui("Sending …") : L10n.ui("Send to Slack")) {
                    let text = message
                    Task { if case .sent = await slack.send(text), message == text { message = "" } }
                }.buttonStyle(.borderedProminent)
                    .disabled(!slack.canSend || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.count > 4_000)
            }
            if message.count > 4_000 { Text(L10n.ui("Slack messages are limited to 4,000 characters here.")).font(.caption).foregroundStyle(.orange) }
        }
        .protectUpdateDraft(isDirty: !message.isEmpty)
    }
}
