import Foundation
import Testing
@testable import FjordCore

struct UpdateConfigurationTests {
    private var info: [String: Any] {
        ["CFBundleIdentifier": "no.oddmund.Fjord", "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2",
         "SprintwakeUpdatesEnabled": true, "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
         "SUFeedURL": "https://github.com/oddmundleikvoll/sprintwake-projects/releases/latest/download/appcast.xml"]
    }
    @Test func configuredReleaseUsesOnlyBundledPublicMetadata() {
        let config = UpdateConfiguration(info: info, isDemo: false)
        #expect(config.mode == .ready)
        #expect(config.feedURL?.scheme == "https")
        #expect(config.version == "0.2.0")
    }
    @Test func invalidOrUntrustedFeedNeverEnablesUpdater() {
        for url in ["http://github.com/feed.xml", "file:///tmp/feed.xml", "https://user:password@github.com/feed.xml",
                    "https://github.com/feed.xml?token=credential", "https://github.com/feed.xml#fragment", "relative.xml"] {
            var value = info; value["SUFeedURL"] = url
            #expect(UpdateConfiguration(info: value, isDemo: false).mode == .invalid)
        }
        for key in ["", "not-base64", Data(repeating: 1, count: 31).base64EncodedString()] {
            var value = info; value["SUPublicEDKey"] = key
            #expect(UpdateConfiguration(info: value, isDemo: false).mode == .invalid)
        }
    }
    @Test func demoAndLocalBuildDoNotCreateNetworkConfiguration() {
        #expect(UpdateConfiguration(info: info, isDemo: true).mode == .demo)
        var value = info; value["SprintwakeUpdatesEnabled"] = false
        #expect(UpdateConfiguration(info: value, isDemo: false).mode == .localBuild)
    }
    @Test func loopbackExceptionRequiresAnIsolatedTestBundleAndExplicitFlag() {
        var value = info
        value["SUFeedURL"] = "http://127.0.0.1:9183/appcast.xml"
        value["SprintwakeUpdateTesting"] = true
        #expect(UpdateConfiguration(info: value, isDemo: false).mode == .invalid)
        value["CFBundleIdentifier"] = "no.oddmund.Sprintwake.UpdateTest.fixture"
        #expect(UpdateConfiguration(info: value, isDemo: true).mode == .ready)
        value["SUFeedURL"] = "http://example.com/appcast.xml"
        #expect(UpdateConfiguration(info: value, isDemo: true).mode == .invalid)
    }
    @MainActor @Test func authorizedRelaunchWaitsForWritesAndResumesExactlyOnce() {
        let gate = UpdateRelaunchGate()
        var installs = 0
        gate.setBusy(true)
        #expect(gate.postpone { installs += 1 })
        #expect(installs == 0)
        gate.setBusy(true)
        #expect(installs == 0)
        gate.setBusy(false); gate.setBusy(false)
        #expect(installs == 1)
        #expect(!gate.postpone { installs += 1 })
        #expect(installs == 1) // Sparkle proceeds itself when no deferral is needed.
    }
    @MainActor @Test func cancelledUpdateCannotResumeWhenTheEditorLaterCloses() {
        let gate = UpdateRelaunchGate()
        var installs = 0
        gate.setBusy(true)
        #expect(gate.postpone { installs += 1 })
        gate.cancel()
        gate.setBusy(false)
        #expect(installs == 0)
    }
}
