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
        guard var input = request["input"] as? [[String: Any]] else {
            return request
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

        var enriched = request
        enriched["input"] = enrichedInput
        return enriched
    }
}
