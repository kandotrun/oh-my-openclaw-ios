import Foundation

public struct ComposerDraft: Codable, Sendable, Equatable {
    public var text = ""
    public var attachments: [ChatAttachment] = []
    public init(text: String = "", attachments: [ChatAttachment] = []) { self.text = text; self.attachments = attachments }
}

public struct PendingSubmission: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var target: ChatSession
    public var params: JSONValue
    public var message: ChatMessage
    public var accepted: Bool
    public init(id: String, target: ChatSession, params: JSONValue, message: ChatMessage, accepted: Bool = false) {
        self.id = id; self.target = target; self.params = params; self.message = message; self.accepted = accepted
    }
}

/// Durable, gateway-local conversation state. Transient activity is rebuilt from history.
public struct ConversationStore: Codable, Sendable {
    public var sessions: [ChatSession] = []
    public var selectedID: String?
    public var drafts: [String: ComposerDraft] = [:]
    public var transcripts: [String: [ChatMessage]] = [:]
    public var pending: [String: PendingSubmission] = [:]
    public var creationRequests: [String: JSONValue] = [:]
    public var creationIssuedAt: [String: Date]?
    public var activeRunIDs: [String: String] = [:]
    public var activities: [String: ActivityState] = [:]
    private var runSequences: [String: Int] = [:]

    public init() {}
    public var selectedSession: ChatSession? { sessions.first { $0.id == selectedID } }
    public var selectedMessages: [ChatMessage] { selectedID.flatMap { transcripts[$0] } ?? [] }
    public var selectedDraft: ComposerDraft { selectedID.flatMap { drafts[$0] } ?? ComposerDraft() }

    public mutating func setDraft(_ draft: ComposerDraft, for id: String) { drafts[id] = draft }

    public mutating func upsertSession(_ session: ChatSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            let previous = sessions[index]
            sessions[index] = session
            if let old = previous.sessionID, let new = session.sessionID, old != new {
                transcripts[session.id] = []
                activeRunIDs[session.id] = nil
                activities[session.id] = .idle
                // Drafts and uncertain submissions belong to their original author/target.
                for key in pending.keys where pending[key]?.target.id == session.id {
                    pending[key]?.message.delivery = .uncertain
                }
            }
        } else { sessions.append(session) }
    }

    public mutating func replaceLocalSession(_ old: ChatSession, with new: ChatSession) {
        let draft = drafts.removeValue(forKey: old.id)
        let transcript = transcripts.removeValue(forKey: old.id)
        sessions.removeAll { $0.id == old.id }
        creationRequests[old.id] = nil
        creationIssuedAt?[old.id] = nil
        upsertSession(new)
        if let draft { drafts[new.id] = draft }
        if let transcript { transcripts[new.id] = transcript }
        if selectedID == old.id { selectedID = new.id }
    }

    public mutating func prepareSubmission(for session: ChatSession, policy: JSONValue) throws -> PendingSubmission {
        let draft = drafts[session.id] ?? ComposerDraft()
        guard unresolvedSubmission(matching: draft, for: session) == nil else {
            throw GatewayFailure(code: "UNRESOLVED_SEND", message: "このメッセージの送信結果を確認してから再試行してください。")
        }
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty else {
            throw GatewayFailure(code: "EMPTY_MESSAGE", message: "メッセージを入力してください。")
        }
        let runID = UUID().uuidString
        var params: [String: JSONValue] = ["sessionKey": .string(session.key), "agentId": .string(session.agentID), "message": .string(draft.text), "idempotencyKey": .string(runID)]
        if let physicalID = session.sessionID { params["sessionId"] = .string(physicalID) }
        if !draft.attachments.isEmpty { params["attachments"] = .array(draft.attachments.map(\.wireValue)) }
        for attachment in draft.attachments {
            let limit = attachment.mimeType.hasPrefix("image/") ? policy["attachments"]["maxImageBytes"].intValue : policy["attachments"]["maxBytes"].intValue
            if let limit, attachment.data.count > limit {
                throw GatewayFailure(code: "ATTACHMENT_TOO_LARGE", message: "「\(attachment.fileName)」は接続先のサイズ上限を超えています。")
            }
        }
        let body = JSONValue.object(params)
        let frame = JSONValue.object(["type": .string("req"), "id": .string(UUID().uuidString), "method": .string("chat.send"), "params": body])
        let frameSize = try JSONEncoder().encode(frame).count
        if frameSize > (policy["maxPayload"].intValue ?? 25 * 1024 * 1024) {
            throw GatewayFailure(code: "PAYLOAD_TOO_LARGE", message: "添付ファイルの合計サイズが大きすぎます。ファイルを減らして送信してください。")
        }
        let message = ChatMessage(id: runID + ":user", role: .user, text: draft.text, attachments: draft.attachments, delivery: .pending, runID: runID)
        let submission = PendingSubmission(id: runID, target: session, params: body, message: message)
        pending[runID] = submission
        transcripts[session.id, default: []].append(message)
        activeRunIDs[session.id] = runID
        activities[session.id] = .working
        return submission
    }

    public func unresolvedSubmission(matching draft: ComposerDraft, for session: ChatSession) -> PendingSubmission? {
        pending.values.first {
            $0.target.id == session.id && $0.target.sessionID == session.sessionID && !$0.accepted &&
            ComposerDraft(text: $0.message.text, attachments: $0.message.attachments) == draft
        }
    }

    /// A prepared input has not crossed the send boundary until its target is materialized.
    public mutating func materializeSubmission(_ id: String, as session: ChatSession) throws -> PendingSubmission {
        guard var submission = pending[id], submission.target.sessionID == nil,
              session.sessionID != nil, submission.target.agentID == session.agentID else {
            throw GatewayFailure(code: "SESSION_CHANGED", message: "送信先の会話を確認できませんでした。")
        }
        let old = submission.target
        if old.id != session.id { replaceLocalSession(old, with: session) }
        else { upsertSession(session) }
        var body = submission.params.objectValue ?? [:]
        body["sessionKey"] = .string(session.key)
        body["sessionId"] = session.sessionID.map(JSONValue.string)
        submission.target = session; submission.params = .object(body)
        pending[id] = submission
        if !(transcripts[session.id] ?? []).contains(where: { $0.id == submission.message.id }) {
            transcripts[session.id, default: []].append(submission.message)
        }
        activeRunIDs[old.id] = nil; activities[old.id] = nil
        activeRunIDs[session.id] = id; activities[session.id] = .working
        return submission
    }

    public mutating func acknowledge(_ runID: String) {
        guard var submission = pending[runID] else { return }
        submission.accepted = true
        submission.message.delivery = .accepted
        pending[runID] = submission
        guard let current = sessions.first(where: { $0.id == submission.target.id }), current.sessionID == submission.target.sessionID else { return }
        if let index = transcripts[submission.target.id]?.firstIndex(where: { $0.id == runID + ":user" }) {
            transcripts[submission.target.id]?[index].delivery = .accepted
        }
        // Clear only the exact submitted draft. A user may have typed a new draft while awaiting ACK.
        let original = ComposerDraft(text: submission.message.text, attachments: submission.message.attachments)
        if drafts[submission.target.id] == original { drafts[submission.target.id] = ComposerDraft() }
    }

    public mutating func markUncertain(_ runID: String) {
        guard let submission = pending[runID] else { return }
        pending[runID]?.message.delivery = .uncertain
        if let index = transcripts[submission.target.id]?.firstIndex(where: { $0.runID == runID && $0.role == .user }) {
            transcripts[submission.target.id]?[index].delivery = .uncertain
        }
        if activeRunIDs[submission.target.id] == runID {
            activities[submission.target.id] = .idle
            activeRunIDs[submission.target.id] = nil
        }
    }

    public mutating func reject(_ runID: String) {
        guard let submission = pending.removeValue(forKey: runID) else { return }
        transcripts[submission.target.id]?.removeAll { $0.id == runID + ":user" }
        if activeRunIDs[submission.target.id] == runID {
            activities[submission.target.id] = .idle
            activeRunIDs[submission.target.id] = nil
        }
    }

    public func retrySubmission(_ id: String) throws -> PendingSubmission {
        let runID = id.hasSuffix(":user") ? String(id.dropLast(5)) : id
        guard let submission = pending[runID], let current = sessions.first(where: { $0.id == submission.target.id }),
              submission.target.sessionID == nil || current.sessionID == submission.target.sessionID else {
            throw GatewayFailure(code: "SESSION_CHANGED", message: "会話の保存先が変わったため再送できません。元のメッセージを確認してください。")
        }
        return submission
    }

    /// Applies authoritative chat events once; agent text events must never enter this reducer.
    @discardableResult public mutating func applyChatEvent(_ payload: JSONValue) -> Bool {
        guard let key = payload["sessionKey"].stringValue, let runID = payload["runId"].stringValue,
              let session = matchingSession(key: key, agentID: payload["agentId"].stringValue) else { return false }
        let state = payload["state"].stringValue ?? ""
        let terminal = ["final", "aborted", "error"].contains(state)
        if let target = pending[runID]?.target, target.id != session.id || target.sessionID != session.sessionID {
            // The old receipt may settle, but its stream cannot mutate the replacement conversation.
            if terminal { acknowledge(runID) }
            return false
        }
        if let seq = payload["seq"].intValue {
            let sequenceKey = session.id + "|" + runID
            if let prior = runSequences[sequenceKey], seq <= prior { return false }
            runSequences[sequenceKey] = seq
        }
        if state == "status" {
            activeRunIDs[session.id] = runID; activities[session.id] = .working; return true
        }
        guard state == "delta" || terminal else { return false }
        let messageID = runID + ":assistant"
        var rows = transcripts[session.id] ?? []
        let index = rows.firstIndex { $0.id == messageID }
        var row = index.map { rows[$0] } ?? ChatMessage(id: messageID, role: .assistant, text: "", delivery: .pending, runID: runID)
        if payload.objectValue?["message"] != nil, payload["message"] != .null {
            let snapshot = Self.parseMessage(payload["message"], fallbackID: messageID)
            row.text = snapshot.text
            row.attachments = snapshot.attachments
            row.sourceID = snapshot.sourceID
        } else if state == "delta" {
            let delta = payload["deltaText"].stringValue ?? ""
            if payload["replace"].boolValue == true { row.text = delta } else { row.text += delta }
        }
        if terminal {
            row.delivery = state == "error" ? .failed : .complete
            if row.text.isEmpty, state == "error" { row.text = payload["errorMessage"].stringValue ?? "応答を完了できませんでした。" }
            if activeRunIDs[session.id] == runID { activeRunIDs[session.id] = nil; activities[session.id] = .idle }
            if pending[runID] != nil { acknowledge(runID) }
            if let userIndex = rows.firstIndex(where: { $0.id == runID + ":user" }) { rows[userIndex].delivery = .accepted }
        } else {
            activeRunIDs[session.id] = runID; activities[session.id] = .responding
        }
        if index != nil { rows[index!] = row }
        else if !row.text.isEmpty || !row.attachments.isEmpty { rows.append(row) }
        transcripts[session.id] = rows
        return true
    }

    @discardableResult public mutating func applyHistory(_ payload: JSONValue, for target: ChatSession, preservingOlderHistory: Bool = false) -> Int {
        guard let current = sessions.first(where: { $0.id == target.id }), current.sessionID == target.sessionID else { return 0 }
        if let serverID = payload["sessionId"].stringValue, let physical = target.sessionID, serverID != physical { return 0 }
        let previous = transcripts[target.id] ?? []
        var rows = Self.parseMessages(payload["messages"].arrayValue ?? [], fallbackPrefix: "history")
        var olderRows: [ChatMessage] = []
        if preservingOlderHistory, payload["hasMore"].boolValue == true, let firstID = rows.first?.id,
           let boundary = previous.firstIndex(where: { $0.id == firstID }) {
            olderRows = previous[..<boundary].filter { $0.sourceID != nil }
        }
        for item in payload["pendingInputs"]["items"].arrayValue ?? [] where item["message"] != .null {
            var row = Self.parseMessage(item["message"], fallbackID: item["id"].stringValue ?? UUID().uuidString)
            row.runID = item["runId"].stringValue
            row.delivery = item["state"].stringValue == "cancelled" ? .failed : .accepted
            if !rows.contains(where: { $0.id == row.id }) { rows.append(row) }
        }
        let receipts = payload["inputReceipts"].arrayValue ?? []
        for submission in Array(pending.values) where submission.target.id == target.id && submission.target.sessionID == target.sessionID {
            let receipt = receipts.first { $0["runId"].stringValue == submission.id }
            let stored = rows.contains { $0.sourceID == submission.id + ":user" || ($0.runID == submission.id && $0.role == .user) || $0.sourceID == receipt?["consumedByEventId"].stringValue }
            if stored || ["pending", "consumed"].contains(receipt?["state"].stringValue ?? "") {
                acknowledge(submission.id)
                if stored { pending[submission.id] = nil }
            }
            if !stored { rows.append(pending[submission.id]?.message ?? submission.message) }
        }
        let inflight = payload["inFlightRun"]
        if let runID = inflight["runId"].stringValue {
            activeRunIDs[target.id] = runID
            let text = inflight["text"].stringValue ?? ""
            activities[target.id] = text.isEmpty ? .working : .responding
            if !text.isEmpty { rows.append(ChatMessage(id: runID + ":assistant", role: .assistant, text: text, delivery: .pending, runID: runID)) }
        } else {
            activeRunIDs[target.id] = nil; activities[target.id] = .idle
        }
        transcripts[target.id] = olderRows + rows
        return olderRows.count
    }

    public func matchingSession(key: String, agentID: String?) -> ChatSession? {
        let matches = sessions.filter { $0.key == key && (agentID == nil || $0.agentID == agentID) }
        return matches.count == 1 ? matches.first : nil
    }

    public static func parseMessage(_ value: JSONValue, fallbackID: String) -> ChatMessage {
        let role = ChatMessage.Role(rawValue: value["role"].stringValue ?? "assistant") ?? .system
        var text = value["text"].stringValue ?? value["content"].stringValue ?? ""
        var attachments: [ChatAttachment] = []
        for block in value["content"].arrayValue ?? [] {
            if block["type"].stringValue == "text", let part = block["text"].stringValue { text += part }
            else if let attachment = ChatAttachment.parse(block: block, fallbackID: fallbackID + ":attachment:\(attachments.count)") { attachments.append(attachment) }
        }
        let metadata = value["__openclaw"]
        let id = metadata["id"].stringValue ?? value["id"].stringValue ?? fallbackID
        let runID = metadata["runId"].stringValue ?? value["runId"].stringValue
        return ChatMessage(id: id, role: role, text: text, attachments: attachments, runID: runID, sourceID: id)
    }

    /// A durable record may project to several rows. Keep record identity apart from display identity.
    public static func parseMessages(_ values: [JSONValue], fallbackPrefix: String) -> [ChatMessage] {
        var siblings: [String: Int] = [:]
        return values.enumerated().map { index, value in
            var row = parseMessage(value, fallbackID: "\(fallbackPrefix):\(index)")
            let group = (row.sourceID ?? row.id) + "|" + row.role.rawValue
            let sibling = siblings[group, default: 0]
            siblings[group] = sibling + 1
            row.id = group + "|" + String(sibling)
            return row
        }
    }

    public mutating func retireTransientState() {
        activeRunIDs = [:]; activities = [:]; runSequences = [:]
        for runID in Array(pending.keys) { markUncertain(runID) }
    }
}
