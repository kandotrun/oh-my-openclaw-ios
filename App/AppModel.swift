import CryptoKit
import Foundation
import Observation
import OhMyOpenClawCore

@Observable @MainActor
final class AppModel {
    var connectionState: ConnectionState = .disconnected
    var isDemo = false
    var agentName = "Claw"
    var models: [ModelOption] = []
    var errorMessage: String?
    var notice: String?
    var hasMoreHistory = false
    private var store = ConversationStore()
    private var promptRecords: [ApprovalPrompt] = []
    private var promptTargets: [String: String] = [:]
    private var sendingTargets = Set<String>()

    @ObservationIgnored private var service: (any GatewayServing)?
    @ObservationIgnored private var hello: GatewayHello?
    @ObservationIgnored private var endpoint: URL?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var selectionGeneration = UUID()
    @ObservationIgnored private var streamRevisions: [String: Int] = [:]
    @ObservationIgnored private var sessionRevisions: [String: Int] = [:]
    @ObservationIgnored private var pendingHistoryRefresh = Set<String>()
    @ObservationIgnored private var nextHistoryOffset = 0
    @ObservationIgnored private var persistence: ConversationPersistence?
    @ObservationIgnored private var persistenceRevision = 0
    @ObservationIgnored private var autoConnect = true
    @ObservationIgnored private var questionRecords: [String: JSONValue] = [:]
    @ObservationIgnored private var questionAnswers: [String: [String: JSONValue]] = [:]
    @ObservationIgnored private var currentSubscription: ChatSession?
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var attemptedAutomaticRecovery = false

    var sessions: [ChatSession] { store.sessions }
    var selectedSession: ChatSession? { store.selectedSession }
    var selectedSessionKey: String? { selectedSession?.key }
    var composerContextID: String {
        [isDemo ? "local-demo" : endpoint?.absoluteString ?? "unconfigured", selectedSession?.agentID ?? "", selectedSession?.key ?? "", selectedSession?.sessionID ?? "", connectionGeneration.uuidString, selectionGeneration.uuidString].joined(separator: "|")
    }
    var messages: [ChatMessage] { store.selectedMessages }
    var draftText: String {
        get { store.selectedDraft.text }
        set {
            guard let id = store.selectedID else { return }
            var draft = store.selectedDraft; draft.text = newValue
            store.setDraft(draft, for: id); scheduleSave()
        }
    }
    var attachments: [ChatAttachment] { store.selectedDraft.attachments }
    var activity: ActivityState { store.selectedID.flatMap { store.activities[$0] } ?? .idle }
    var selectedModelID: String? { selectedSession?.modelID }
    var selectedThinkingLevel: String? { selectedSession?.thinkingLevel }
    var thinkingLevels: [ThinkingLevel] { models.first(where: { $0.id == selectedModelID })?.thinkingLevels ?? [] }
    var prompts: [ApprovalPrompt] { promptRecords.filter { promptTargets[$0.id] == store.selectedID } }
    var canSend: Bool {
        guard connectionState == .connected, let selectedSession, activity == .idle,
              !sendingTargets.contains(selectedSession.id), !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        if selectedSession.sessionID == nil, store.pending.values.contains(where: { $0.target.id == selectedSession.id }),
           store.unresolvedSubmission(matching: store.selectedDraft, for: selectedSession) == nil { return false }
        return true
    }

    init(service: (any GatewayServing)? = nil, initialStore: ConversationStore = ConversationStore(), policy: JSONValue = .null) {
        self.service = service; self.store = initialStore
        if service != nil { connectionState = .connected; hello = GatewayHello(payload: .object(["policy": policy])) }
    }

    func restore() async {
        guard service == nil, !restoring else { return }
        restoring = true
        defer { restoring = false }
        if UserDefaults.standard.bool(forKey: "useDemo") { await startDemo(); return }
        guard let text = UserDefaults.standard.string(forKey: "lastGateway"), let url = try? GatewayEndpoint.parse(text) else { return }
        endpoint = url
        do {
            try await loadStore(namespace: url.absoluteString)
            await retryConnection()
        } catch { errorMessage = error.localizedDescription }
    }

    func startDemo() async {
        reconnectTask?.cancel(); attemptedAutomaticRecovery = false
        await retireConnection()
        isDemo = true; endpoint = nil; autoConnect = true
        UserDefaults.standard.set(true, forKey: "useDemo")
        do {
            try await loadStore(namespace: "local-demo")
            // A fresh deterministic service owns its own history; cached drafts remain useful.
            store.pending = [:]
            service = DemoGateway()
            await establishConnection()
        } catch { fail(error) }
    }

    func connect(urlText: String, secret: String, password: Bool, setupCode: String) async {
        reconnectTask?.cancel(); attemptedAutomaticRecovery = false
        do {
            let url: URL
            let credentials: GatewayCredentials
            if !setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let setup = try GatewayEndpoint.decodeSetupCode(setupCode)
                url = setup.url; credentials = GatewayCredentials(bootstrapToken: setup.bootstrapToken)
            } else {
                url = try GatewayEndpoint.parse(urlText)
                let value = secret.isEmpty ? nil : secret
                if value == nil { credentials = try CredentialStore.read(GatewayCredentials.self, key: credentialKey(url)) ?? GatewayCredentials() }
                else { credentials = password ? GatewayCredentials(password: value) : GatewayCredentials(token: value) }
            }
            await retireConnection()
            try CredentialStore.write(credentials, key: credentialKey(url))
            endpoint = url; isDemo = false; autoConnect = true
            UserDefaults.standard.set(false, forKey: "useDemo")
            UserDefaults.standard.set(url.absoluteString, forKey: "lastGateway")
            try await loadStore(namespace: url.absoluteString)
            service = GatewayClient(endpoint: url, credentials: credentials, identity: try identity())
            await establishConnection()
        } catch { fail(error) }
    }

    func retryConnection() async {
        reconnectTask?.cancel(); attemptedAutomaticRecovery = false
        await reconnect()
    }

    private func reconnect() async {
        guard connectionState != .connecting else { return }
        if isDemo { await startDemo(); return }
        guard let endpoint else { return }
        await retireConnection()
        do {
            let credentials = try CredentialStore.read(GatewayCredentials.self, key: credentialKey(endpoint)) ?? GatewayCredentials()
            service = GatewayClient(endpoint: endpoint, credentials: credentials, identity: try identity())
            await establishConnection()
        } catch { fail(error) }
    }

    func foreground() async { if !restoring, autoConnect, connectionState != .connected, connectionState != .connecting { await retryConnection() } }
    func background() async {
        reconnectTask?.cancel()
        do { try await persistNow() } catch { errorMessage = error.localizedDescription }
        await retireConnection()
        connectionState = .disconnected
    }
    func disconnect() async {
        reconnectTask?.cancel()
        autoConnect = false
        do { try await persistNow() } catch { errorMessage = error.localizedDescription }
        await retireConnection(); connectionState = .disconnected
    }

    private func establishConnection() async {
        guard let service else { return }
        let generation = connectionGeneration
        connectionState = .connecting; errorMessage = nil; notice = nil
        let stream = await service.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self, self.connectionGeneration == generation else { break }
                await self.handle(event)
            }
        }
        do {
            let received = try await service.connect()
            guard connectionGeneration == generation else { return }
            hello = received
            if let endpoint, let token = received.payload["auth"]["deviceToken"].stringValue {
                let old = try CredentialStore.read(GatewayCredentials.self, key: credentialKey(endpoint))
                let scopes = received.payload["auth"]["scopes"].arrayValue?.compactMap(\.stringValue)
                let storedScopes = old?.deviceToken == token ? (old?.scopes ?? scopes) : scopes
                try CredentialStore.write(GatewayCredentials(deviceToken: token, scopes: storedScopes), key: credentialKey(endpoint))
            }
            let defaults = received.snapshot["sessionDefaults"]
            guard let agentID = defaults["defaultAgentId"].stringValue, let mainKey = defaults["mainSessionKey"].stringValue else {
                throw GatewayFailure(code: "UNSUPPORTED_GATEWAY", message: "接続先がメインチャットの情報を返しませんでした。Gateway の対応バージョンを確認してください。")
            }
            let existingMain = store.sessions.first { $0.agentID == agentID && $0.key == mainKey }
            store.upsertSession(ChatSession(key: mainKey, agentID: agentID, sessionID: existingMain?.sessionID, title: "メインチャット", isMain: true, modelID: existingMain?.modelID, thinkingLevel: existingMain?.thinkingLevel))
            if store.selectedSession == nil { store.selectedID = agentID + "|" + mainKey }
            connectionState = .connected
            do { try await refreshRoster() } catch { notice = "会話一覧を更新できませんでした。再接続でやり直せます。" }
            guard connectionGeneration == generation else { return }
            if let selected = store.selectedSession { await selectSession(selected) }
            if let result = try? await service.request(method: "agents.identity.get", params: .object(["agentId": .string(agentID)])), connectionGeneration == generation {
                agentName = result["name"].stringValue ?? result["identity"]["name"].stringValue ?? "Claw"
            }
            try await persistNow()
        } catch {
            guard connectionGeneration == generation else { return }
            if let failure = error as? GatewayFailure, failure.code == "NOT_PAIRED" || failure.details["code"].stringValue == "PAIRING_REQUIRED" {
                connectionState = .pairing(requestID: failure.details["requestId"].stringValue ?? "", message: "Gateway 側でこの端末を承認してから、再接続してください。")
            } else { fail(error) }
        }
    }

    private func retireConnection() async {
        connectionGeneration = UUID(); selectionGeneration = UUID()
        eventTask?.cancel(); eventTask = nil; refreshTask?.cancel(); refreshTask = nil
        let previous = service; service = nil; hello = nil; currentSubscription = nil
        promptRecords = []; promptTargets = [:]; questionRecords = [:]; questionAnswers = [:]
        store.retireTransientState()
        await previous?.disconnect()
    }

    func newSideChat() async {
        guard let current = selectedSession ?? sessions.first(where: \.isMain) else { return }
        let session = ChatSession(key: "local:" + UUID().uuidString, agentID: current.agentID, title: "新しいサイドチャット")
        store.upsertSession(session); store.selectedID = session.id; selectionGeneration = UUID()
        models = []; hasMoreHistory = false; scheduleSave()
        await refreshModels(for: session)
    }

    func selectSession(_ session: ChatSession) async {
        store.selectedID = session.id; selectionGeneration = UUID()
        errorMessage = nil; hasMoreHistory = false; nextHistoryOffset = 0; models = []
        scheduleSave()
        guard connectionState == .connected, let service else { return }
        let selection = selectionGeneration; let generation = connectionGeneration
        if let previous = currentSubscription, previous.id != session.id {
            _ = try? await service.request(method: "sessions.messages.unsubscribe", params: targetParams(previous, keyName: "key", extra: ["subscriptionId": .string("foreground")], includeSessionID: false))
        }
        guard selectionGeneration == selection, connectionGeneration == generation else { return }
        if !session.key.hasPrefix("local:") {
            do {
                _ = try await service.request(method: "sessions.messages.subscribe", params: targetParams(session, keyName: "key", extra: ["subscriptionId": .string("foreground"), "includeApprovals": .bool(true)], includeSessionID: false))
                guard selectionGeneration == selection, connectionGeneration == generation else { return }
                currentSubscription = session
                try await refreshHistory(for: session)
            } catch { if selectionGeneration == selection { errorMessage = error.localizedDescription } }
        }
        guard selectionGeneration == selection, connectionGeneration == generation else { return }
        await refreshModels(for: store.selectedSession ?? session)
        await refreshPrompts()
    }

    func send() async {
        guard canSend, let target = selectedSession else { return }
        if let existing = store.unresolvedSubmission(matching: store.selectedDraft, for: target) {
            await retryPending(existing.id)
            return
        }
        errorMessage = nil
        do {
            // Reserve immutable input before creation, disk IO, or subscription can suspend.
            let submission = try store.prepareSubmission(for: target, policy: hello?.policy ?? .null)
            await sendPrepared(submission)
        } catch { errorMessage = error.localizedDescription }
    }

    private func sendPrepared(_ original: PendingSubmission) async {
        guard let service, !sendingTargets.contains(original.target.id) else { return }
        let originalID = original.target.id
        sendingTargets.insert(originalID)
        var workingTargetID = originalID
        defer { sendingTargets.remove(originalID); sendingTargets.remove(workingTargetID) }
        let generation = connectionGeneration
        var submission = original
        var target = submission.target
        do {
            // No network mutation precedes durable custody of the submitted bytes.
            try await persistNow()
            guard connectionGeneration == generation else { return }
            if target.sessionID == nil {
                var creation = store.creationRequests[target.id]
                if creation != nil {
                    guard let issuedAt = store.creationIssuedAt?[target.id], Date().timeIntervalSince(issuedAt) < 240 else {
                        throw GatewayFailure(code: "CREATION_OUTCOME_UNKNOWN", message: "前回の会話作成を確認できません。重複を防ぐため、会話一覧に作成済みの会話がないか確認してください。入力はこの端末に残っています。")
                    }
                }
                if creation == nil {
                    var body: [String: JSONValue] = ["agentId": .string(target.agentID), "idempotencyKey": .string(UUID().uuidString), "titleSource": .string(String(submission.message.text.prefix(1_000)))]
                    if !target.key.hasPrefix("local:") { body["key"] = .string(target.key) }
                    if let model = target.modelID { body["model"] = .string(model) }
                    if let thinking = target.thinkingLevel { body["thinkingLevel"] = .string(thinking) }
                    creation = .object(body); store.creationRequests[target.id] = creation
                    if store.creationIssuedAt == nil { store.creationIssuedAt = [:] }
                    store.creationIssuedAt?[target.id] = Date()
                    try await persistNow()
                }
                let result = try await service.request(method: "sessions.create", params: creation!)
                guard connectionGeneration == generation else { return }
                guard let key = result["key"].stringValue else { throw GatewayFailure(code: "INVALID_RESPONSE", message: "新しい会話の保存先を確認できませんでした。") }
                guard target.key.hasPrefix("local:") || key == target.key else { throw GatewayFailure(code: "SESSION_CHANGED", message: "メインチャットの保存先を確認できませんでした。") }
                let created = parseSession(result["entry"], fallback: ChatSession(key: key, agentID: target.agentID, sessionID: result["sessionId"].stringValue, title: target.title, isMain: target.isMain))
                submission = try store.materializeSubmission(submission.id, as: created)
                store.creationRequests[originalID] = nil; store.creationIssuedAt?[originalID] = nil
                target = submission.target
                workingTargetID = target.id; sendingTargets.insert(workingTargetID)
                try await persistNow()
                // Subscribe before sending so the first delta cannot be missed.
                if store.selectedID == target.id {
                    _ = try await service.request(method: "sessions.messages.subscribe", params: targetParams(target, keyName: "key", extra: ["subscriptionId": .string("foreground"), "includeApprovals": .bool(true)], includeSessionID: false))
                    guard connectionGeneration == generation else { return }
                    if store.selectedID == target.id { currentSubscription = target }
                }
            }
            guard target.sessionID != nil else { throw GatewayFailure(code: "SESSION_UNKNOWN", message: "会話の保存先を確認中です。会話を開き直してから送信してください。") }
            guard connectionGeneration == generation else { return }
            await dispatch(submission, through: service, generation: generation)
        } catch {
            if connectionGeneration == generation {
                store.markUncertain(submission.id)
                errorMessage = error.localizedDescription
                scheduleSave()
            }
        }
    }

    func retryPending(_ messageID: String) async {
        guard service != nil, connectionState == .connected else { return }
        do {
            let submission = try store.retrySubmission(messageID)
            guard !sendingTargets.contains(submission.target.id) else { return }
            store.activeRunIDs[submission.target.id] = submission.id; store.activities[submission.target.id] = .working
            await sendPrepared(submission)
        } catch { errorMessage = error.localizedDescription }
    }

    private func dispatch(_ submission: PendingSubmission, through service: any GatewayServing, generation: UUID) async {
        do {
            let acknowledgment = try await service.request(method: "chat.send", params: submission.params)
            guard connectionGeneration == generation else { return }
            store.acknowledge(submission.id)
            try await persistNow()
            if acknowledgment["status"].stringValue == "ok" {
                try await refreshHistory(for: submission.target)
            }
        } catch {
            guard connectionGeneration == generation else { return }
            if let failure = error as? GatewayFailure, ["INVALID_REQUEST", "FORBIDDEN", "NOT_FOUND", "PAYLOAD_TOO_LARGE"].contains(failure.code) || failure.details["mutationAccepted"].boolValue == false {
                store.reject(submission.id)
                errorMessage = failure.message
            } else {
                store.markUncertain(submission.id)
                errorMessage = "送信結果を確認できませんでした。メッセージは端末に保存されています。再接続後、同じメッセージを確認できます。"
            }
            scheduleSave()
        }
    }

    func stop() async {
        guard let target = selectedSession, let runID = store.activeRunIDs[target.id], let service else { return }
        do {
            _ = try await service.request(method: "chat.abort", params: targetParams(target, extra: ["runId": .string(runID), "userInitiated": .bool(true)]))
            // Acknowledgment is not a terminal stream event. Refresh to settle authoritative state.
            try await refreshHistory(for: target)
        } catch { errorMessage = "停止を確認できませんでした。接続を確認して、もう一度停止してください。" }
    }

    func addAttachment(data: Data, fileName: String, mimeType: String) {
        guard let id = store.selectedID else { return }
        let maxBytes = mimeType.hasPrefix("image/") ? hello?.policy["attachments"]["maxImageBytes"].intValue : hello?.policy["attachments"]["maxBytes"].intValue
        if let maxBytes, data.count > maxBytes { errorMessage = "「\(fileName)」は接続先のサイズ上限を超えています。"; return }
        var draft = store.selectedDraft; draft.attachments.append(ChatAttachment(fileName: fileName, mimeType: mimeType, data: data))
        store.setDraft(draft, for: id); scheduleSave()
    }

    func loadAttachment(_ attachment: ChatAttachment, session: ChatSession) async throws -> Data {
        let context = composerContextID
        guard selectedSession?.id == session.id, selectedSession?.sessionID == session.sessionID else {
            throw GatewayFailure(code: "SESSION_CHANGED", message: "会話を開き直して添付ファイルを読み込んでください。")
        }
        if !attachment.data.isEmpty { return attachment.data }
        guard connectionState == .connected, let service, let endpoint else {
            throw GatewayFailure(code: "NOT_CONNECTED", message: "Gateway に接続してから添付ファイルを読み込んでください。")
        }
        let data = try await GatewayArtifactLoader.load(attachment, session: session, service: service, endpoint: endpoint)
        guard composerContextID == context, selectedSession?.sessionID == session.sessionID else {
            throw GatewayFailure(code: "SESSION_CHANGED", message: "接続または会話が変わったため読み込みを中断しました。")
        }
        return data
    }
    func removeAttachment(_ id: String) {
        guard let target = store.selectedID else { return }
        var draft = store.selectedDraft; draft.attachments.removeAll { $0.id == id }
        store.setDraft(draft, for: target); scheduleSave()
    }

    func setModel(_ id: String?) async { await patchSelection(model: id, thinking: nil, changeModel: true) }
    func setThinking(_ id: String?) async { await patchSelection(model: nil, thinking: id, changeModel: false) }
    private func patchSelection(model: String?, thinking: String?, changeModel: Bool) async {
        guard var target = selectedSession else { return }
        let old = target
        if changeModel { target.modelID = model; target.thinkingLevel = nil } else { target.thinkingLevel = thinking }
        if target.key.hasPrefix("local:") { store.upsertSession(target); scheduleSave(); return }
        guard let service else { return }
        var extra: [String: JSONValue] = changeModel ? ["model": model.map(JSONValue.string) ?? .null, "thinkingLevel": .null] : ["thinkingLevel": thinking.map(JSONValue.string) ?? .null]
        if let id = old.sessionID { extra["expectedSessionId"] = .string(id) }
        let generation = connectionGeneration
        do {
            let result = try await service.request(method: "sessions.patch", params: targetParams(old, keyName: "key", extra: extra, includeSessionID: false))
            guard connectionGeneration == generation, store.sessions.first(where: { $0.id == old.id })?.sessionID == old.sessionID else { return }
            store.upsertSession(parseSession(result["entry"], fallback: target)); scheduleSave()
            await refreshModels(for: target)
        } catch { if connectionGeneration == generation { errorMessage = error.localizedDescription } }
    }

    func renameSession(_ session: ChatSession, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return }
        if session.key.hasPrefix("local:") { var changed = session; changed.title = trimmed; store.upsertSession(changed); scheduleSave(); return }
        guard let service else { return }
        let generation = connectionGeneration
        do {
            let result = try await service.request(method: "sessions.patch", params: targetParams(session, keyName: "key", extra: ["label": .string(trimmed)], includeSessionID: false))
            guard connectionGeneration == generation, store.sessions.first(where: { $0.id == session.id })?.sessionID == session.sessionID else { return }
            var changed = session; changed.title = trimmed
            store.upsertSession(parseSession(result["entry"], fallback: changed)); scheduleSave()
        } catch { if connectionGeneration == generation { errorMessage = error.localizedDescription } }
    }

    func loadOlderHistory() async {
        guard hasMoreHistory, let target = selectedSession, let service else { return }
        let generation = connectionGeneration; let selection = selectionGeneration
        do {
            let result = try await service.request(method: "chat.history", params: targetParams(target, extra: ["limit": .number(100), "offset": .number(Double(nextHistoryOffset))]))
            guard connectionGeneration == generation, selectionGeneration == selection else { return }
            let older = ConversationStore.parseMessages(result["messages"].arrayValue ?? [], fallbackPrefix: "older:\(nextHistoryOffset)")
            var current = store.transcripts[target.id] ?? []
            let known = Set(current.map(\.id))
            current.insert(contentsOf: older.filter { !known.contains($0.id) }, at: 0)
            store.transcripts[target.id] = current
            hasMoreHistory = result["hasMore"].boolValue ?? false
            nextHistoryOffset = result["nextOffset"].intValue ?? nextHistoryOffset + older.count
            scheduleSave()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refreshRoster() async throws {
        guard let service else { return }
        let generation = connectionGeneration
        let revisions = sessionRevisions
        let result = try await service.request(method: "sessions.subscribe", params: .object(["limit": .number(100)]))
        guard generation == connectionGeneration else { return }
        for row in result["list"]["sessions"].arrayValue ?? result["sessions"].arrayValue ?? [] {
            if let parsed = sessionFromRow(row), sessionRevisions[parsed.id, default: 0] == revisions[parsed.id, default: 0] { store.upsertSession(parsed) }
        }
        scheduleSave()
    }

    private func refreshHistory(for target: ChatSession) async throws {
        guard !target.key.hasPrefix("local:"), let service else { return }
        let generation = connectionGeneration
        let revision = streamRevisions[target.id, default: 0]
        let runIDs = store.pending.values.filter { $0.target.id == target.id }.map { JSONValue.string($0.id) }
        var extra: [String: JSONValue] = ["limit": .number(100)]
        if !runIDs.isEmpty { extra["inputRunIds"] = .array(Array(runIDs.prefix(50))) }
        let result = try await service.request(method: "chat.history", params: targetParams(target, extra: extra))
        guard generation == connectionGeneration, let current = store.sessions.first(where: { $0.id == target.id }), current.sessionID == target.sessionID else { return }
        guard streamRevisions[target.id, default: 0] == revision else {
            pendingHistoryRefresh.insert(target.id)
            scheduleQuietRefresh(); return
        }
        var resolved = current
        if let physicalID = result["sessionId"].stringValue { resolved.sessionID = physicalID }
        if let model = result["sessionInfo"]["model"].stringValue { resolved.modelID = qualifiedModel(id: model, provider: result["sessionInfo"]["modelProvider"].stringValue) }
        if let thinking = result["sessionInfo"]["thinkingLevel"].stringValue { resolved.thinkingLevel = thinking }
        store.upsertSession(resolved)
        store.applyHistory(result, for: resolved)
        pendingHistoryRefresh.remove(target.id)
        if store.selectedID == target.id {
            hasMoreHistory = result["hasMore"].boolValue ?? false
            nextHistoryOffset = result["nextOffset"].intValue ?? result["messages"].arrayValue?.count ?? 0
        }
        scheduleSave()
    }

    private func refreshModels(for target: ChatSession) async {
        guard let service else { return }
        let generation = connectionGeneration
        do {
            let params: JSONValue = target.key.hasPrefix("local:") ? .object(["agentId": .string(target.agentID), "includeDetails": .bool(true)]) : .object(["agentId": .string(target.agentID), "sessionKey": .string(target.key), "includeDetails": .bool(true)])
            let result = try await service.request(method: "models.list", params: params)
            guard generation == connectionGeneration, store.selectedID == target.id else { return }
            models = (result["models"].arrayValue ?? []).compactMap { row in
                guard let id = row["id"].stringValue, row["manualSelectionAllowed"].boolValue != false, row["available"].boolValue != false else { return nil }
                let levels = (row["thinkingLevels"].arrayValue ?? []).compactMap { level -> ThinkingLevel? in
                    guard let id = level["id"].stringValue ?? level.stringValue else { return nil }
                    return ThinkingLevel(id: id, label: level["label"].stringValue ?? id)
                }
                return ModelOption(id: qualifiedModel(id: id, provider: row["provider"].stringValue), name: row["name"].stringValue ?? id, thinkingLevels: levels)
            }
        } catch { if generation == connectionGeneration, store.selectedID == target.id { notice = "モデル一覧を取得できませんでした。現在の設定で会話は続けられます。" } }
    }

    private func handle(_ event: GatewayEvent) async {
        if event.name == "client.disconnected" {
            store.retireTransientState(); connectionState = .disconnected; scheduleSave()
            if autoConnect, !attemptedAutomaticRecovery {
                attemptedAutomaticRecovery = true
                reconnectTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
                    guard !Task.isCancelled, let self, self.autoConnect else { return }
                    await self.reconnect()
                }
            }
            return
        }
        if event.name == "client.eventGap" {
            notice = "接続の続きを確認しています。"
            return
        }
        let payload = event.payload
        if event.name == "chat", let session = store.matchingSession(key: payload["sessionKey"].stringValue ?? "", agentID: payload["agentId"].stringValue) {
            streamRevisions[session.id, default: 0] += 1
            store.applyChatEvent(payload)
            if ["final", "aborted", "error"].contains(payload["state"].stringValue ?? "") {
                pendingHistoryRefresh.insert(session.id); scheduleQuietRefresh()
            }
            scheduleSave(); return
        }
        if event.name == "agent", let session = store.matchingSession(key: payload["sessionKey"].stringValue ?? "", agentID: payload["agentId"].stringValue),
           let runID = payload["runId"].stringValue, store.activeRunIDs[session.id] == runID {
            let data = payload["data"]
            if payload["stream"].stringValue == "tool" {
                let name = data["name"].stringValue ?? ""
                let ending = ["end", "result", "error"].contains(data["phase"].stringValue ?? "")
                store.activities[session.id] = ending ? .working : (["web_search", "web_fetch", "browser"].contains(name) ? .searching : .working)
            }
            return
        }
        if event.name == "sessions.changed" || event.name == "chat.title" {
            let row = payload["session"] != .null ? payload["session"] : payload
            if let session = sessionFromRow(row) {
                sessionRevisions[session.id, default: 0] += 1
                store.upsertSession(session); scheduleSave()
            }
            else if event.name == "sessions.changed" { try? await refreshRoster() }
            return
        }
        if event.name == "session.message", let target = selectedSession, payload["sessionKey"].stringValue == target.key {
            pendingHistoryRefresh.insert(target.id); scheduleQuietRefresh(); return
        }
        if ["exec.approval.requested", "plugin.approval.requested", "question.requested"].contains(event.name) { addPrompt(event.name, payload: payload); return }
        if ["exec.approval.resolved", "plugin.approval.resolved", "question.resolved"].contains(event.name), let id = payload["id"].stringValue {
            promptRecords.removeAll { $0.id == id || $0.id.hasPrefix(id + "|") }; questionRecords[id] = nil; questionAnswers[id] = nil
        }
    }

    private func scheduleQuietRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !Task.isCancelled, let target = self.selectedSession, self.pendingHistoryRefresh.contains(target.id) else { return }
            try? await self.refreshHistory(for: target)
        }
    }

    private func refreshPrompts() async {
        guard let service else { return }
        let generation = connectionGeneration
        for (method, event) in [("question.list", "question.requested"), ("exec.approval.list", "exec.approval.requested"), ("plugin.approval.list", "plugin.approval.requested")] {
            if let result = try? await service.request(method: method, params: .object([:])), generation == connectionGeneration {
                for record in result["questions"].arrayValue ?? result["approvals"].arrayValue ?? [] { addPrompt(event, payload: record) }
            }
        }
    }

    private func addPrompt(_ name: String, payload: JSONValue) {
        let request = payload["request"] != .null ? payload["request"] : payload
        guard let requestID = payload["id"].stringValue, let session = store.matchingSession(key: request["sessionKey"].stringValue ?? payload["sessionKey"].stringValue ?? "", agentID: request["agentId"].stringValue ?? payload["agentId"].stringValue), payload["status"].stringValue == nil || payload["status"].stringValue == "pending" else { return }
        if name == "question.requested" {
            questionRecords[requestID] = payload
            for question in payload["questions"].arrayValue ?? [] {
                guard let questionID = question["questionId"].stringValue else { continue }
                let id = requestID + "|" + questionID
                let choices = question["options"].arrayValue?.compactMap { $0["label"].stringValue } ?? []
                let kind = question["isSecret"].boolValue == true ? "secret" : "question"
                let prompt = ApprovalPrompt(id: id, kind: kind, title: question["header"].stringValue ?? "質問", detail: question["question"].stringValue ?? "回答してください。", choices: choices)
                if !promptRecords.contains(where: { $0.id == id }) { promptRecords.append(prompt) }
                promptTargets[id] = session.id
            }
        } else {
            let plugin = name.hasPrefix("plugin")
            let choices = request["allowedDecisions"].arrayValue?.compactMap(\.stringValue) ?? ["allow-once", "deny"]
            let prompt = ApprovalPrompt(id: requestID, kind: plugin ? "plugin" : "exec", title: request["title"].stringValue ?? "実行の承認", detail: request["detail"].stringValue ?? request["description"].stringValue ?? request["command"].stringValue ?? "この操作を許可しますか？", choices: choices)
            if !promptRecords.contains(where: { $0.id == requestID }) { promptRecords.append(prompt) }
            promptTargets[requestID] = session.id
        }
        store.activities[session.id] = .waitingForApproval
    }

    func resolvePrompt(_ prompt: ApprovalPrompt, answer: String) async {
        guard let service else { return }
        let generation = connectionGeneration
        do {
            if prompt.kind == "question" || prompt.kind == "secret" {
                let parts = prompt.id.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let record = questionRecords[parts[0]] else { return }
                let question = record["questions"].arrayValue?.first { $0["questionId"].stringValue == parts[1] }
                let option = question?["options"].arrayValue?.first { $0["label"].stringValue == answer }
                let value = option?["value"].stringValue ?? answer
                questionAnswers[parts[0], default: [:]][parts[1]] = .array([.string(value)])
                let answers = questionAnswers[parts[0]] ?? [:]
                if answers.count == record["questions"].arrayValue?.count {
                    _ = try await service.request(method: "question.resolve", params: .object(["id": .string(parts[0]), "answers": .object(["answers": .object(answers)])]))
                    questionAnswers[parts[0]] = nil; questionRecords[parts[0]] = nil
                }
            } else {
                guard prompt.choices.contains(answer) else { return }
                _ = try await service.request(method: prompt.kind == "plugin" ? "plugin.approval.resolve" : "exec.approval.resolve", params: .object(["id": .string(prompt.id), "decision": .string(answer)]))
            }
            guard generation == connectionGeneration else { return }
            promptRecords.removeAll { $0.id == prompt.id }
            if let target = promptTargets[prompt.id], store.activities[target] == .waitingForApproval { store.activities[target] = .working }
        } catch { if generation == connectionGeneration { errorMessage = error.localizedDescription } }
    }

    private func sessionFromRow(_ row: JSONValue) -> ChatSession? {
        guard let key = row["key"].stringValue ?? row["sessionKey"].stringValue else { return nil }
        let agentID = row["agentId"].stringValue ?? agentFromKey(key)
        guard let agentID else { return nil }
        let previous = store.sessions.first { $0.key == key && $0.agentID == agentID }
        let fallback = previous ?? ChatSession(key: key, agentID: agentID, title: "サイドチャット")
        return parseSession(row, fallback: fallback)
    }
    private func parseSession(_ row: JSONValue, fallback: ChatSession) -> ChatSession {
        var session = fallback
        session.key = row["key"].stringValue ?? row["sessionKey"].stringValue ?? session.key
        session.agentID = row["agentId"].stringValue ?? session.agentID
        session.sessionID = row["sessionId"].stringValue ?? session.sessionID
        if !session.isMain { session.title = row["label"].stringValue ?? row["displayName"].stringValue ?? row["title"].stringValue ?? session.title }
        if let model = row["model"].stringValue { session.modelID = qualifiedModel(id: model, provider: row["modelProvider"].stringValue) }
        if row.objectValue?["thinkingLevel"] != nil { session.thinkingLevel = row["thinkingLevel"].stringValue }
        return session
    }
    private func agentFromKey(_ key: String) -> String? {
        let parts = key.split(separator: ":", maxSplits: 2)
        return parts.count == 3 && parts[0] == "agent" ? String(parts[1]) : nil
    }
    private func qualifiedModel(id: String, provider: String?) -> String {
        guard let provider, !id.hasPrefix(provider + "/") else { return id }
        return provider + "/" + id
    }
    private func targetParams(_ target: ChatSession, keyName: String = "sessionKey", extra: [String: JSONValue] = [:], includeSessionID: Bool = true) -> JSONValue {
        var body = extra
        body[keyName] = .string(target.key); body["agentId"] = .string(target.agentID)
        if includeSessionID, let id = target.sessionID { body["sessionId"] = .string(id) }
        return .object(body)
    }

    private func identity() throws -> DeviceIdentity {
        if let data = try CredentialStore.read(Data.self, key: "device-identity") { return try DeviceIdentity(privateKeyData: data) }
        let identity = DeviceIdentity(); try CredentialStore.write(identity.privateKeyData, key: "device-identity"); return identity
    }
    private func credentialKey(_ url: URL) -> String { "gateway:" + digest(url.absoluteString) }
    private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func loadStore(namespace: String) async throws {
        saveTask?.cancel()
        if let persistence { try await persistence.save(store, revision: persistenceRevision + 1) }
        let persistence = try ConversationPersistence(namespace: digest(namespace))
        self.persistence = persistence; persistenceRevision = 0
        store = try await persistence.load()
        store.retireTransientState()
        promptRecords = []; promptTargets = [:]; models = []; streamRevisions = [:]; sessionRevisions = [:]; pendingHistoryRefresh = []
    }
    private func scheduleSave() {
        persistenceRevision += 1
        saveTask?.cancel()
        let revision = persistenceRevision; let snapshot = store; let persistence = persistence
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                try await persistence?.save(snapshot, revision: revision)
            } catch is CancellationError { }
            catch { self?.errorMessage = "入力を端末に保存できませんでした。空き容量を確認してください。" }
        }
    }
    private func persistNow() async throws {
        saveTask?.cancel(); persistenceRevision += 1
        try await persistence?.save(store, revision: persistenceRevision)
    }
    private func fail(_ error: any Error) { connectionState = .failed(error.localizedDescription); errorMessage = error.localizedDescription }
}

private actor ConversationPersistence {
    private let url: URL
    private var newestRevision = -1
    init(namespace: String) throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        url = base.appendingPathComponent(namespace + ".json")
    }
    func load() throws -> ConversationStore {
        guard FileManager.default.fileExists(atPath: url.path) else { return ConversationStore() }
        return try JSONDecoder().decode(ConversationStore.self, from: Data(contentsOf: url))
    }
    func save(_ state: ConversationStore, revision: Int) throws {
        guard revision > newestRevision else { return }
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        newestRevision = revision
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var resourceURL = url; try resourceURL.setResourceValues(values)
    }
}
