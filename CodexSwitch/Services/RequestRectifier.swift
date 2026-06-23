import Foundation
import os.log

private let logger = Logger(subsystem: "com.codex.switch", category: "rectifier")

/// Detects specific upstream error patterns and rewrites the request body to
/// fix them, then signals the proxy to retry on the same provider.
///
/// Currently implements:
/// - Media sanitizer: replaces image blocks when upstream rejects image input
struct RequestRectifier {

    // MARK: - Rectification Result

    enum RectificationResult {
        /// No rectification needed — return the error as-is.
        case noRectification
        /// Rectified the request body — retry with the new body.
        case rectified(Data)
    }

    // MARK: - Media Sanitizer

    /// Check if an upstream error indicates the provider does not support
    /// image input. If so, return a sanitized request body with all image
    /// blocks replaced by `[Unsupported Image]` text markers.
    static func rectifyMediaError(requestBody: Data, httpStatus: Int, responseBody: Data) -> RectificationResult {
        // Only rectify on client error statuses that suggest format issues
        guard (400...499).contains(httpStatus) || [501].contains(httpStatus) else {
            return .noRectification
        }

        // Parse error message
        let errorMessage = extractErrorMessage(responseBody)

        // Check for image-related rejection patterns
        guard isImageRejectionError(errorMessage) else {
            return .noRectification
        }

        logger.info("Detected image rejection error from upstream: \(errorMessage)")

        // Parse and sanitize the request body
        guard var json = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] else {
            return .noRectification
        }

        // Sanitize input array (Responses API format)
        if var input = json["input"] as? [[String: Any]] {
            input = sanitizeInputArray(input)
            json["input"] = input
        }

        // Sanitize messages array (Chat Completions format, if somehow present)
        if var messages = json["messages"] as? [[String: Any]] {
            messages = sanitizeMessages(messages)
            json["messages"] = messages
        }

        // Re-serialize
        guard let sanitized = try? JSONSerialization.data(withJSONObject: json) else {
            return .noRectification
        }

        return .rectified(sanitized)
    }

    /// Preventively replace image blocks in a request body when the target
    /// model is known to be text-only.
    static func sanitizeForTextOnlyModel(_ body: Data, modelName: String) -> Data {
        guard isKnownTextOnlyModel(modelName) else { return body }
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return body
        }

        var modified = false

        if var input = json["input"] as? [[String: Any]] {
            let sanitized = sanitizeInputArray(input)
            if !equalJSONArray(input, sanitized) {
                input = sanitized
                json["input"] = input
                modified = true
            }
        }

        if var messages = json["messages"] as? [[String: Any]] {
            let sanitized = sanitizeMessages(messages)
            if !equalJSONArray(messages, sanitized) {
                messages = sanitized
                json["messages"] = messages
                modified = true
            }
        }

        return modified ? (try? JSONSerialization.data(withJSONObject: json)) ?? body : body
    }

    // MARK: - Image Block Replacement

    /// Replace all image blocks in a Responses API input array with text markers.
    private static func sanitizeInputArray(_ input: [[String: Any]]) -> [[String: Any]] {
        input.map { item in
            var sanitized = item

            // Top-level image blocks
            if let type = item["type"] as? String,
               type == "image" || type == "image_url" || type == "input_image" {
                sanitized = ["type": "text", "text": "[Unsupported Image]"]
                return sanitized
            }

            // Nested content array (e.g., tool_result with image content)
            if var content = item["content"] as? [[String: Any]] {
                content = sanitizeContentBlocks(content)
                sanitized["content"] = content
            }

            return sanitized
        }
    }

    /// Replace all image blocks in a Chat Completions messages array.
    private static func sanitizeMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            var sanitized = message
            if var content = message["content"] as? [[String: Any]] {
                content = sanitizeContentBlocks(content)
                sanitized["content"] = content
            }
            return sanitized
        }
    }

    /// Replace image blocks in a content array with text markers.
    private static func sanitizeContentBlocks(_ blocks: [[String: Any]]) -> [[String: Any]] {
        blocks.map { block in
            let type = block["type"] as? String ?? ""
            if type == "image" || type == "image_url" || type == "input_image" {
                return ["type": "text", "text": "[Unsupported Image]"]
            }
            return block
        }
    }

    // MARK: - Error Detection

    /// Extract a human-readable error message from an upstream response body.
    private static func extractErrorMessage(_ body: Data) -> String {
        // Try standard OpenAI error format
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message.lowercased()
            }
            // Try MiniMax base_resp
            if let baseResp = json["base_resp"] as? [String: Any],
               let msg = baseResp["status_msg"] as? String {
                return msg.lowercased()
            }
            // Try plain message
            if let message = json["message"] as? String {
                return message.lowercased()
            }
            // Try detail field
            if let detail = json["detail"] as? String {
                return detail.lowercased()
            }
        }
        // Try plain text
        if let text = String(data: body, encoding: .utf8) {
            return text.lowercased()
        }
        return ""
    }

    /// Check if an error message indicates the provider rejected image input.
    private static func isImageRejectionError(_ message: String) -> Bool {
        let patterns = [
            "does not support image",
            "image input not supported",
            "text only",
            "text-only",
            "unknown variant image_url",
            "cannot process media",
            "attachments not supported",
            "media not supported",
            "image content not allowed",
            "unsupported content type: image",
            "no vision support",
            "image modality not supported",
        ]
        return patterns.contains { message.contains($0) }
    }

    /// Check if a model name is known to be text-only (no vision support).
    private static func isKnownTextOnlyModel(_ modelName: String) -> Bool {
        let lower = modelName.lowercased()
        let textOnlyPatterns = [
            "deepseek-chat",
            "deepseek-reasoner",
            "deepseek-v4",
            "glm-5",
            "qwen3-coder",
            "minimax-m2",
            "mimo-v2",
            "kimi-k2",
            "kimi-for-coding",
            "step-3.5",
        ]
        return textOnlyPatterns.contains { lower.contains($0) }
    }

    // MARK: - Array Comparison Helper

    private static func equalJSONArray(_ a: [[String: Any]], _ b: [[String: Any]]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count {
            if let aData = try? JSONSerialization.data(withJSONObject: a[i], options: [.sortedKeys]),
               let bData = try? JSONSerialization.data(withJSONObject: b[i], options: [.sortedKeys]) {
                if aData != bData { return false }
            } else {
                return false
            }
        }
        return true
    }
}
