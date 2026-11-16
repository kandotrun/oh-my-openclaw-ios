import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private actor StoredConversations: ConversationPersisting {
    let seed: ConversationStore
    private var holdLoad: Bool
    private var holdSave: Bool
    private let loadStarted = AsyncStream<Void>.makeStream()
    private let saveStarted = AsyncStream<Void>.makeStream()
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var loadCount = 0
    private(set) var writes: [ConversationStore] = []
    init(_ seed: ConversationStore, holdLoad: Bool = false, holdSave: Bool = false) { self.seed = seed; self.holdLoad = holdLoad; self.holdSave = holdSave }
    func load() async throws -> ConversationStore {
        loadCount += 1
        if holdLoad { await withCheckedContinuation { loadWaiters.append($0); loadStarted.continuation.yield(()) } }
        return seed
    }
    func save(_ state: ConversationStore, revision: Int) async throws {
        if holdSave { await withCheckedContinuation { saveWaiters.append($0); saveStarted.continuation.yield(()) } }
        writes.append(state)
    }
    func waitForLoad() async { for await _ in loadStarted.stream { return } }
    func waitForSave() async { for await _ in saveStarted.stream { return } }
    func releaseLoads() { holdLoad = false; let waiters = loadWaiters; loadWaiters = []; for waiter in waiters { waiter.resume() } }
    func releaseSaves() { holdSave = false; let waiters = saveWaiters; saveWaiters = []; for waiter in waiters { waiter.resume() } }
    func pauseSaves() { holdSave = true }
}

private actor LifecycleGateway: GatewayServing {
    private(set) var disconnectCount = 0
    func connect() async throws -> GatewayHello { GatewayHello(payload: .null) }
    func request(method: String, params: JSONValue) async throws -> JSONValue { .object([:]) }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func disconnect() async { disconnectCount += 1 }
}

private func savedDraft(_ text: String) -> ConversationStore {
    var store = ConversationStore()
    let main = ChatSession(key: "agent:demo:main", agentID: "demo", sessionID: "demo-main", title: "Main", isMain: true)
    store.upsertSession(main); store.selectedID = main.id
    store.setDraft(ComposerDraft(text: text), for: main.id)
    return store
}

@Suite(.serialized)
@MainActor struct LifecycleIsolationTests {
    @Test func staleBackgroundSaveCannotDisconnectAfterForegroundReturns() async {
        let state = savedDraft("foreground draft")
        let disk = StoredConversations(state, holdSave: true)
        let gateway = LifecycleGateway()
        let app = AppModel(service: gateway, initialStore: state, initialPersistence: disk, initialNamespace: "A")
        let leaving = Task { await app.background() }
        await disk.waitForSave()
        await app.foreground()
        await disk.releaseSaves()
        await leaving.value
        #expect(app.connectionState == .connected)
        #expect(await gateway.disconnectCount == 0)
    }

    @Test func overlappingSwitchDoesNotPublishAnIncomingStoreBeforeItsLoadCompletes() async {
        let previous = UserDefaults.standard.object(forKey: "useDemo")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "useDemo") } else { UserDefaults.standard.removeObject(forKey: "useDemo") } }
        let diskA = StoredConversations(savedDraft("A private draft"))
        let diskB = StoredConversations(savedDraft("B saved draft"), holdLoad: true)
        let app = AppModel(service: LifecycleGateway(), initialStore: savedDraft("A private draft"), initialPersistence: diskA, initialNamespace: "A", persistenceFactory: { _ in diskB })
        let first = Task { await app.startDemo() }
        await diskB.waitForLoad()
        #expect(app.connectionState == .connecting)
        app.draftText = "A edited during load"
        let second = Task { await app.startDemo() }
        let ignoredDuplicate = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await second.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(1)); return false }
            let finished = await group.next() ?? false
            await diskB.releaseLoads()
            group.cancelAll()
            return finished
        }
        await first.value
        #expect(ignoredDuplicate)
        #expect(await diskB.loadCount == 1)
        #expect(app.draftText == "B saved draft")
        #expect(await diskA.writes.last?.selectedDraft.text == "A edited during load")
        #expect(await diskB.writes.allSatisfy { !$0.selectedDraft.text.hasPrefix("A ") })
    }

    @Test func backgroundInvalidatesAStillLoadingDestinationWithoutOverwritingIt() async {
        let previous = UserDefaults.standard.object(forKey: "useDemo")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "useDemo") } else { UserDefaults.standard.removeObject(forKey: "useDemo") } }
        let diskA = StoredConversations(savedDraft("A private draft"))
        let diskB = StoredConversations(savedDraft("B saved draft"), holdLoad: true)
        let app = AppModel(service: LifecycleGateway(), initialStore: savedDraft("A private draft"), initialPersistence: diskA, initialNamespace: "A", persistenceFactory: { _ in diskB })
        let switching = Task { await app.startDemo() }
        await diskB.waitForLoad()
        await app.background()
        await diskB.releaseLoads()
        await switching.value
        #expect(app.connectionState == .disconnected)
        #expect(app.draftText == "A private draft")
        #expect(await diskB.writes.isEmpty)
    }

    @Test func foregroundRestartsSavedDemoRestoreInterruptedDuringItsInitialLoad() async {
        let previous = UserDefaults.standard.object(forKey: "useDemo")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "useDemo") } else { UserDefaults.standard.removeObject(forKey: "useDemo") } }
        UserDefaults.standard.set(true, forKey: "useDemo")
        let disk = StoredConversations(savedDraft("restored draft"), holdLoad: true)
        let app = AppModel(persistenceFactory: { _ in disk })
        let restoring = Task { await app.restore() }
        await disk.waitForLoad()
        await app.background()
        await disk.releaseLoads()
        await restoring.value
        await app.foreground()
        #expect(app.connectionState == .connected)
        #expect(app.draftText == "restored draft")
        await app.disconnect()
    }

    @Test func editsDuringTheFinalOutgoingSaveStayWithTheirOriginalOwner() async {
        let previous = UserDefaults.standard.object(forKey: "useDemo")
        defer { if let previous { UserDefaults.standard.set(previous, forKey: "useDemo") } else { UserDefaults.standard.removeObject(forKey: "useDemo") } }
        let diskA = StoredConversations(savedDraft("A initial"))
        let diskB = StoredConversations(savedDraft("B saved"), holdLoad: true)
        let app = AppModel(service: LifecycleGateway(), initialStore: savedDraft("A initial"), initialPersistence: diskA, initialNamespace: "A", persistenceFactory: { _ in diskB })
        let switching = Task { await app.startDemo() }
        await diskB.waitForLoad()
        app.draftText = "A first edit"
        await diskA.pauseSaves()
        await diskB.releaseLoads()
        await diskA.waitForSave()
        app.draftText = "A final edit"
        await diskA.releaseSaves()
        await switching.value
        #expect(await diskA.writes.last?.selectedDraft.text == "A final edit")
        #expect(app.draftText == "B saved")
        #expect(await diskB.writes.allSatisfy { !$0.selectedDraft.text.hasPrefix("A ") })
        await app.disconnect()
    }
}
