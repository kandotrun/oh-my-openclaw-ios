import Foundation
import Testing
import OhMyOpenClawCore
@testable import OhMyOpenClawState

private actor HistoryBeforeSend: GatewayServing {
    private let started = AsyncStream<Void>.makeStream()
    private var held: CheckedContinuation<Void, Never>?
    private var reads = 0
    private(set) var sends: [JSONValue] = []
    private(set) var aborts: [JSONValue] = []
    func connect() async throws -> GatewayHello { GatewayHello(payload: .null) }
    func events() async -> AsyncStream<GatewayEvent> { AsyncStream { $0.finish() } }
    func disconnect() async {}
    func waitForRead() async { for await _ in started.stream { return } }
    func releaseRead() { held?.resume(); held = nil }
    func request(method: String, params: JSONValue) async throws -> JSONValue {
        if method == "chat.history" {
            reads += 1
            if reads == 1 { await withCheckedContinuation { held = $0; started.continuation.yield(()) } }
            return .object(["sessionId": .string("physical"), "messages": .array([])])
        }
        if method == "chat.send" { sends.append(params); return .object(["status": .string("started"), "runId": params["idempotencyKey"]]) }
        if method == "chat.abort" { aborts.append(params) }
        return .object([:])
    }
}

@Test @MainActor func historyReadStartedBeforeLocalSendCannotRetireTheNewRun() async throws {
    let main = ChatSession(key: "agent:a:main", agentID: "a", sessionID: "physical", title: "Main", isMain: true)
    var store = ConversationStore(); store.upsertSession(main); store.selectedID = main.id
    store.setDraft(ComposerDraft(text: "send after history starts"), for: main.id)
    let service = HistoryBeforeSend()
    let app = AppModel(service: service, initialStore: store)
    let history = Task { try await app.refreshHistory(for: main) }
    await service.waitForRead()
    await app.send()
    let expectedRun = try #require(await service.sends.first?["idempotencyKey"].stringValue)
    await service.releaseRead()
    try await history.value
    #expect(app.activity == .working)
    await app.stop()
    #expect(await service.aborts.first?["runId"].stringValue == expectedRun)
}
