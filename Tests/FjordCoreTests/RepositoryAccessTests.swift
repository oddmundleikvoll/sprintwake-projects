import Foundation
import Testing
@testable import FjordCore

@MainActor
struct RepositoryAccessTests {
    private func model(api: WorkspaceAPI, storage: MemoryStorage, poll: @escaping @Sendable (DeviceChallenge) async throws -> Credential) -> AppModel {
        let oauth = MockOAuth(beginHandler: { clientID, includePrivate in
            #expect(includePrivate)
            return DeviceChallenge(deviceCode: "fixture-device", userCode: "TEST-CODE", expiresAt: .distantFuture, interval: 1, clientID: clientID)
        }, pollHandler: poll)
        return AppModel(storage: storage, oauth: oauth,
                        preferences: UserDefaults(suiteName: "Fjord.tests.\(UUID())")!, makeAPI: { _ in api })
    }

    @Test(.timeLimit(.minutes(1))) func reauthorizationRefreshesTheCurrentSharedProject() async throws {
        let gate = Gate(), storage = MemoryStorage(), api = WorkspaceAPI(data: [fixtureSnapshot(id: "first"), fixtureSnapshot(id: "shared")])
        let subject = model(api: api, storage: storage) { _ in
            await gate.wait()
            return Credential(accessToken: "fixture-expanded")
        }
        await subject.signIn(token: "fixture-original")
        await subject.selectProject(fixtureSnapshot(id: "shared").project)
        subject.beginOAuth(clientID: "public", includePrivateRepositories: true)
        await gate.waitUntilRequested()
        #expect(subject.user?.login == "tester")
        #expect(subject.snapshot?.project.id == "shared")
        #expect(!subject.canWrite)
        #expect(try storage.load()?.accessToken == "fixture-original")
        await gate.open()
        while subject.isAuthenticating || subject.isLoadingProject { await Task.yield() }
        #expect(subject.snapshot?.project.id == "shared")
        #expect(try storage.load()?.accessToken == "fixture-expanded")
        #expect(subject.canWrite)
        #expect(subject.errorMessage == nil)
    }

    @Test(.timeLimit(.minutes(1))) func failedReauthorizationKeepsTheWorkingSession() async throws {
        let gate = Gate(), storage = MemoryStorage(), api = WorkspaceAPI()
        let subject = model(api: api, storage: storage) { _ in
            await gate.wait()
            throw FjordError.message("Authorization declined")
        }
        await subject.signIn(token: "fixture-original")
        subject.beginOAuth(clientID: "public", includePrivateRepositories: true)
        await gate.waitUntilRequested(); await gate.open()
        while subject.isAuthenticating { await Task.yield() }
        #expect(subject.user?.login == "tester")
        #expect(subject.snapshot != nil)
        #expect(try storage.load()?.accessToken == "fixture-original")
        #expect(subject.errorMessage == "Authorization declined")
        #expect(subject.canWrite)
    }

    @Test(.timeLimit(.minutes(1))) func anotherAccountCannotReplaceTheWorkingSession() async throws {
        let gate = Gate(), storage = MemoryStorage(), api = WorkspaceAPI()
        let subject = model(api: api, storage: storage) { _ in
            await gate.wait()
            return Credential(accessToken: "fixture-other-account")
        }
        await subject.signIn(token: "fixture-original")
        subject.beginOAuth(clientID: "public", includePrivateRepositories: true)
        await gate.waitUntilRequested()
        await api.changeProfileLogin("another-user")
        await gate.open()
        while subject.isAuthenticating { await Task.yield() }
        #expect(subject.user?.login == "tester")
        #expect(try storage.load()?.accessToken == "fixture-original")
        #expect(storage.saveCount() == 1)
        #expect(subject.errorMessage == L10n.core("Authorize access with the same GitHub account you are signed in with. Your existing sign-in was kept."))
        #expect(subject.snapshot != nil)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledReauthorizationCannotReplaceTheSession() async throws {
        let gate = Gate(), storage = MemoryStorage(), api = WorkspaceAPI()
        let subject = model(api: api, storage: storage) { _ in
            await gate.wait()
            return Credential(accessToken: "fixture-late")
        }
        await subject.signIn(token: "fixture-original")
        subject.beginOAuth(clientID: "public", includePrivateRepositories: true)
        await gate.waitUntilRequested()
        subject.cancelOAuth()
        await gate.open()
        // A second attempt must remain independent of the cancelled result.
        subject.beginOAuth(clientID: "public", includePrivateRepositories: true)
        while subject.isAuthenticating { await Task.yield() }
        #expect(subject.user?.login == "tester")
        #expect(storage.saveCount() == 2)
        #expect(subject.snapshot != nil)
    }

    @Test(.timeLimit(.minutes(1))) func logoutDuringReauthorizationDiscardsTheNewCredential() async throws {
        let gate = Gate(), storage = MemoryStorage(), api = WorkspaceAPI()
        let subject = model(api: api, storage: storage) { _ in
            await gate.wait()
            return Credential(accessToken: "fixture-late")
        }
        await subject.signIn(token: "fixture-original")
        subject.beginOAuth(clientID: "public", includePrivateRepositories: true)
        await gate.waitUntilRequested()
        await subject.logout(); await gate.open()
        // A sign-in failure gives the cancelled task an opportunity to resume.
        await api.configure(profileError: .unauthenticated)
        await subject.signIn(token: "fixture-invalid")
        #expect(subject.user == nil)
        #expect(subject.snapshot == nil)
        #expect(try storage.load() == nil)
        #expect(storage.saveCount() == 1)
    }
}
