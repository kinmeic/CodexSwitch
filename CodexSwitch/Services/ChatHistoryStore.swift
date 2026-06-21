import Foundation

final class ChatHistoryStore {
    private let maxEntries = 512
    private var cache: [String: [String: Any]] = [:]
    private var accessOrder: [String] = []
    private let lock = NSLock()

    func cacheFromResponse(_ response: [String: Any]) {
        guard let responseId = response["id"] as? String,
              let output = response["output"] as? [[String: Any]] else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        // Cache function calls by call_id
        for item in output {
            if item["type"] as? String == "function_call",
               let callId = item["call_id"] as? String {
                cache[callId] = item
                accessOrder.append(callId)
            }
        }

        // Cache entire response by response_id
        cache[responseId] = response
        accessOrder.append(responseId)

        // Evict old entries
        while cache.count > maxEntries, !accessOrder.isEmpty {
            let oldest = accessOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    func enrichWithHistory(_ request: [String: Any]) -> [String: Any] {
        // Restore items referenced by previous_response_id first: Chat
        // Completions has no server-side state, so a Responses request that
        // points at a prior turn (whose items aren't in `input`) must have
        // those items reinjected before conversion.
        var enriched = restorePreviousResponseId(request)

        guard var input = enriched["input"] as? [[String: Any]] else {
            return enriched
        }

        lock.lock()
        defer { lock.unlock() }

        var enrichedInput: [[String: Any]] = []

        for item in input {
            let type = item["type"] as? String

            if type == "function_call_output",
               let callId = item["call_id"] as? String,
               let cachedCall = cache[callId] {
                // Insert cached function_call before its output
                enrichedInput.append(cachedCall)
            }

            enrichedInput.append(item)
        }

        enriched["input"] = enrichedInput
        return enriched
    }

    /// Restore the output items of a previous turn referenced by
    /// `previous_response_id`. Codex CLI uses `previous_response_id` to carry
    /// state across turns without resending prior items; when converting to
    /// Chat Completions (which is stateless) those items must be reinjected
    /// into `input` so tool-call chains and conversation history survive.
    private func restorePreviousResponseId(_ request: [String: Any]) -> [String: Any] {
        guard let prevId = request["previous_response_id"] as? String else {
            return request
        }

        lock.lock()
        defer { lock.unlock() }

        guard let cached = cache[prevId],
              let prevOutput = cached["output"] as? [[String: Any]] else {
            return request
        }

        let restorable = prevOutput.filter { item in
            switch item["type"] as? String {
            case "message", "function_call", "function_call_output":
                return true
            default:
                return false
            }
        }

        guard !restorable.isEmpty else { return request }

        var input = request["input"] as? [[String: Any]] ?? []
        input.insert(contentsOf: restorable, at: 0)

        var enriched = request
        enriched["input"] = input
        // Chat Completions has no concept of previous_response_id.
        enriched.removeValue(forKey: "previous_response_id")
        return enriched
    }
}
