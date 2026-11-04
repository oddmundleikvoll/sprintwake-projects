import AppKit
import Combine
import FjordCore
import Observation
import Sparkle
import SwiftUI

@MainActor @Observable
// Sparkle's UI delegate is invoked on the main thread but its Objective-C
// protocol lacks a Swift actor annotation. Keep runtime actor checks enabled.
final class AppUpdateController: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    let configuration: UpdateConfiguration
    private(set) var availableVersion: String?
    private(set) var canCheck = false
    private(set) var checking = false
    private(set) var automaticChecks = false
    private(set) var lastChecked: Date?
    private(set) var waitingToRestart = false
    private(set) var errorMessage: String?
    private(set) var operationsBusy = false
    private(set) var isInstalling = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: Set<AnyCancellable> = []
    @ObservationIgnored private let relaunchGate = UpdateRelaunchGate()
    @ObservationIgnored private var dirtyDrafts: Set<UUID> = []
    @ObservationIgnored private var discardApproved = false
    private var started = false
    private let demoUpdate: Bool

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let demo = CommandLine.arguments.contains("--demo") || info["FjordDemoMode"] as? Bool == true
        configuration = UpdateConfiguration(info: info, isDemo: demo)
        demoUpdate = configuration.mode == .demo && info["FjordUpdateDemoAvailable"] as? Bool == true
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        if demoUpdate { availableVersion = "0.3.0"; canCheck = true; return }
        guard configuration.mode == .ready else { return }
        let updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller = updaterController
        let updater = updaterController.updater
        do {
            try updater.start()
            updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in self?.canCheck = value }.store(in: &observations)
            updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] value in self?.automaticChecks = value }.store(in: &observations)
            updater.publisher(for: \.lastUpdateCheckDate).sink { [weak self] value in self?.lastChecked = value }.store(in: &observations)
        } catch {
            errorMessage = L10n.ui("Updates could not be started. Please download the latest release from GitHub.")
        }
    }

    func checkForUpdates() {
        guard canCheck, !operationsBusy else { return }
        if demoUpdate {
            let alert = NSAlert()
            alert.messageText = L10n.ui("Update preview")
            alert.informativeText = L10n.ui("This is a local preview. No update will be downloaded or installed.")
            alert.addButton(withTitle: L10n.ui("Close"))
            alert.runModal()
            return
        }
        errorMessage = nil
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ value: Bool) { controller?.updater.automaticallyChecksForUpdates = value }
    func setOperationsBusy(_ value: Bool) {
        operationsBusy = value
        refreshRelaunchGate()
    }

    func setDraftDirty(_ id: UUID, _ dirty: Bool) {
        if dirty { dirtyDrafts.insert(id) } else { dirtyDrafts.remove(id) }
        refreshRelaunchGate()
    }

    func removeDraft(_ id: UUID) {
        dirtyDrafts.remove(id)
        refreshRelaunchGate()
    }

    private func refreshRelaunchGate() {
        let blockedByDraft = !discardApproved && !dirtyDrafts.isEmpty
        relaunchGate.setBusy(operationsBusy || blockedByDraft)
    }

    // Keep the publisher's bundled feed authoritative. Credentials from GitHub
    // and Slack are never attached to update requests.
    func feedURLString(for updater: SPUUpdater) -> String? { configuration.feedURL?.absoluteString }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !operationsBusy else {
            throw NSError(domain: "Sprintwake.Updates", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.ui("Finish the current action before updating.")])
        }
        checking = true
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        checking = false
        let code = (error as NSError).code
        if code != Int(SUError.noUpdateError.rawValue) && code != Int(SUError.installationCanceledError.rawValue) {
            errorMessage = L10n.ui("Could not complete the update check. Try again later.")
        }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) { checking = false }
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        // Sparkle calls its postponement delegate only once per session. A
        // second Install click must still respect drafts/writes and cancel the
        // session instead of bypassing the pending continuation.
        if waitingToRestart && relaunchGate.isBusy {
            Task { @MainActor [weak self] in self?.showEditorWindow() }
            return false
        }
        return true
    }
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { isInstalling = true }
    private func showEditorWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.identifier?.rawValue == "workspace" }?.makeKeyAndOrderFront(nil)
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard operationsBusy || (!discardApproved && !dirtyDrafts.isEmpty) else { return false }
        waitingToRestart = true
        _ = relaunchGate.postpone { [weak self] in
            self?.waitingToRestart = false
            installHandler()
        }
        if !dirtyDrafts.isEmpty && !discardApproved {
            let alert = NSAlert()
            alert.messageText = L10n.ui("Unsent changes")
            alert.informativeText = L10n.ui("Installing the update restarts the app. Save or send your changes first, or discard them and update.")
            alert.addButton(withTitle: L10n.ui("Keep editing"))
            alert.addButton(withTitle: L10n.ui("Discard changes and update"))
            if alert.runModal() == .alertSecondButtonReturn {
                discardApproved = true
                // Sparkle must first receive the deferral result before its
                // installation continuation can be resumed.
                Task { @MainActor [weak self] in self?.refreshRelaunchGate() }
            } else {
                Task { @MainActor [weak self] in self?.showEditorWindow() }
            }
        }
        return true
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Regular scheduled updates use the download badge. Critical updates
        // retain Sparkle's prominent presentation.
        update.isCriticalUpdate
    }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        checking = false; errorMessage = nil
        availableVersion = update.displayVersionString
    }
    func standardUserDriverWillFinishUpdateSession() {
        relaunchGate.cancel()
        availableVersion = nil; checking = false; waitingToRestart = false; isInstalling = false
        discardApproved = false
        refreshRelaunchGate()
    }
    func standardUserDriverShouldShowVersionHistory(for item: SUAppcastItem) -> Bool { false }
}

private struct ProtectUpdateDraftModifier: ViewModifier {
    @Environment(AppUpdateController.self) private var updates
    let isDirty: Bool
    @ViewState private var registryID = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: isDirty, initial: true) { _, dirty in
                updates.setDraftDirty(registryID, dirty)
            }
            .onDisappear { updates.removeDraft(registryID) }
    }
}

extension View {
    func protectUpdateDraft(isDirty: Bool) -> some View {
        modifier(ProtectUpdateDraftModifier(isDirty: isDirty))
    }
}

struct UpdateAvailableButton: View {
    @Environment(AppUpdateController.self) private var updates
    var body: some View {
        if let version = updates.availableVersion {
            Button { updates.checkForUpdates() } label: {
                Label(L10n.ui("Update %@ available", version), systemImage: "arrow.down.circle.fill")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
                .disabled(!updates.canCheck || updates.operationsBusy)
                .help(L10n.ui("Download and install update …"))
                .accessibilityLabel(L10n.ui("Download and install update %@", version))
        }
    }
}

struct AppUpdateSettings: View {
    @Environment(AppUpdateController.self) private var updates
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.ui("Updates")).font(.headline)
            Text(L10n.ui("Version %@ (%@)", updates.configuration.version, updates.configuration.build)).foregroundStyle(.secondary)
            switch updates.configuration.mode {
            case .localBuild:
                Text(L10n.ui("Automatic updates are available in official release builds.")).font(.callout).foregroundStyle(.secondary)
            case .demo:
                Text(L10n.ui("Updates are disabled in the local demo.")).font(.callout).foregroundStyle(.secondary)
            case .invalid:
                Text(L10n.ui("Update settings are incomplete. Download the latest release from GitHub.")).font(.callout).foregroundStyle(.secondary)
            case .ready:
                Toggle(L10n.ui("Automatically check for updates"), isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) }))
                Text(L10n.ui("You choose when to download and install. Updates are verified before installation.")).font(.caption).foregroundStyle(.secondary)
            }
            UpdateAvailableButton()
            if updates.configuration.mode == .ready {
                Button(updates.checking ? L10n.ui("Checking for updates …") : L10n.ui("Check for Updates …")) { updates.checkForUpdates() }
                    .disabled(!updates.canCheck || updates.operationsBusy)
                if let date = updates.lastChecked {
                    HStack { Text(L10n.ui("Last checked:")); Text(date, format: .dateTime.day().month().hour().minute()) }.font(.caption).foregroundStyle(.secondary)
                }
            }
            if updates.waitingToRestart {
                Text(L10n.ui("The update will restart the app after the current action finishes.")).font(.callout)
            }
            if let message = updates.errorMessage { Text(message).font(.callout).foregroundStyle(.orange) }
        }
    }
}
