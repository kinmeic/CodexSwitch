import Foundation
import os.log

private let logger = Logger(subsystem: "com.codex.switch", category: "converter")

final class ProtocolConverter {

    // MARK: - Request Conversion: Responses -> Chat Completions

    func responsesToChatCompletions(
        body: [String: Any],
        reasoningConfig: CodexChatReasoning?,
        toolContext: inout CodexToolContext
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        let model = body["model"] as? String ?? "gpt-4"
        result["model"] = model

        // Map instructions -> system message
        var messages: [[String: Any]] = []
        if let instructions = body["instructions"] as? String, !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }

        // Map input[] -> messages[]
        if let input = body["input"] as? [[String: Any]] {
            let inputMessages = convertInputToMessages(input, toolContext: &toolContext)
            messages.append(contentsOf: inputMessages)
        } else if let input = body["input"] as? String {
            messages.append(["role": "user", "content": input])
        }
        // Strip private (`_`-prefixed) fields from every message so internal
        // metadata the Codex CLI attaches never leaks to the upstream provider.
        messages = messages.compactMap { Self.stripPrivateParams($0) as? [String: Any] }

        // Collapse system messages to head (MiniMax compatibility)
        let systemMessages = messages.filter { ($0["role"] as? String) == "system" }
        let nonSystemMessages = messages.filter { ($0["role"] as? String) != "system" }
        messages = systemMessages + nonSystemMessages

        result["messages"] = messages

        // Map max_output_tokens -> max_tokens
        if let maxOutputTokens = body["max_output_tokens"] as? Int {
            result["max_tokens"] = maxOutputTokens
        }

        // Map temperature
        if let temperature = body["temperature"] as? Double {
            result["temperature"] = temperature
        }

        // Map top_p
        if let topP = body["top_p"] as? Double {
            result["top_p"] = topP
        }

        // Map stream
        if let stream = body["stream"] as? Bool {
            result["stream"] = stream
            if stream {
                result["stream_options"] = ["include_usage": true]
            }
        }

        // Map tools — dispatch on type to handle all four Responses tool kinds
        if let tools = body["tools"] as? [[String: Any]] {
            let chatTools = convertAllTools(tools, toolContext: &toolContext)
            if !chatTools.isEmpty {
                result["tools"] = chatTools
            }
        }

        // Apply reasoning configuration
        if let config = reasoningConfig {
            applyReasoningConfig(config, to: &result, from: body)
        }

        logger.debug("Converted Responses→ChatCompletions model=\(model) tools=\(result["tools"] is [[String: Any]] ? "\((result["tools"] as? [[String: Any]] ?? []).count)" : "0")")
        return result
    }

    // MARK: - Tool Conversion (all four kinds)

    private func convertAllTools(_ tools: [[String: Any]], toolContext: inout CodexToolContext) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for tool in tools {
            let type = tool["type"] as? String ?? ""
            switch type {
            case "function":
                if let converted = toolContext.addFunctionTool(tool) {
                    result.append(converted)
                }
            case "namespace":
                let children = toolContext.addNamespaceTool(tool)
                result.append(contentsOf: children)
            case "custom":
                if let wrapped = toolContext.addCustomTool(tool) {
                    result.append(wrapped)
                }
            case "tool_search":
                let synthetic = toolContext.addToolSearchTool()
                result.append(synthetic)
            default:
                // Bare string tool or unknown type — treat as custom
                if tool.count == 1, let name = tool["name"] as? String {
                    let wrapped = toolContext.addCustomTool(["type": "custom", "name": name])
                    if let w = wrapped { result.append(w) }
                }
            }
        }
        return result
    }

    // MARK: - Input Conversion

    private func convertInputToMessages(_ input: [[String: Any]], toolContext: inout CodexToolContext) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        var pendingToolCalls: [[String: Any]] = []

        for item in input {
            guard let type = item["type"] as? String else { continue }

            switch type {
            case "message":
                // Flush pending tool calls first
                if !pendingToolCalls.isEmpty {
                    var assistantMsg: [String: Any] = ["role": "assistant"]
                    assistantMsg["tool_calls"] = pendingToolCalls
                    assistantMsg["content"] = ""
                    messages.append(assistantMsg)
                    pendingToolCalls = []
                }

                if let role = item["role"] as? String {
                    var message: [String: Any] = ["role": role]

                    // Handle content as string or array
                    if let contentStr = item["content"] as? String {
                        message["content"] = contentStr
                    } else if let contentArray = item["content"] as? [[String: Any]] {
                        let textParts = contentArray.compactMap { block -> String? in
                            let blockType = block["type"] as? String
                            if blockType == "text" || blockType == "output_text" || blockType == "input_text" {
                                return block["text"] as? String
                            }
                            return nil
                        }
                        message["content"] = textParts.joined(separator: "\n")
                    }

                    // Map developer role to system
                    if role == "developer" {
                        message["role"] = "system"
                    }

                    messages.append(message)
                }

            case "function_call":
                if let callId = item["call_id"] as? String,
                   let name = item["name"] as? String,
                   let arguments = item["arguments"] as? String {
                    // For namespace tools, use the flattened chat name
                    let chatName: String
                    if let ns = item["namespace"] as? String {
                        chatName = "\(ns)__\(name)"
                    } else {
                        chatName = name
                    }
                    pendingToolCalls.append([
                        "id": callId,
                        "type": "function",
                        "function": [
                            "name": chatName,
                            "arguments": arguments
                        ]
                    ])
                }

            case "custom_tool_call":
                // Custom tool calls: extract raw input and send as JSON arguments
                if let callId = item["call_id"] as? String,
                   let name = item["name"] as? String {
                    let inputStr = item["input"] as? String ?? ""
                    let arguments: String
                    if let data = try? JSONSerialization.data(withJSONObject: ["input": inputStr]),
                       let json = String(data: data, encoding: .utf8) {
                        arguments = json
                    } else {
                        arguments = "{\"input\":\"\(inputStr.replacingOccurrences(of: "\"", with: "\\\""))\"}"
                    }
                    pendingToolCalls.append([
                        "id": callId,
                        "type": "function",
                        "function": [
                            "name": name,
                            "arguments": arguments
                        ]
                    ])
                }

            case "tool_search_call":
                // Tool search calls: forward as function call with JSON arguments
                if let callId = item["call_id"] as? String {
                    let args = item["arguments"] as? [String: Any] ?? [:]
                    let arguments: String
                    if let data = try? JSONSerialization.data(withJSONObject: args),
                       let json = String(data: data, encoding: .utf8) {
                        arguments = json
                    } else {
                        arguments = "{}"
                    }
                    pendingToolCalls.append([
                        "id": callId,
                        "type": "function",
                        "function": [
                            "name": "tool_search",
                            "arguments": arguments
                        ]
                    ])
                }

            case "function_call_output":
                // Flush pending tool calls
                if !pendingToolCalls.isEmpty {
                    var assistantMsg: [String: Any] = ["role": "assistant"]
                    assistantMsg["tool_calls"] = pendingToolCalls
                    assistantMsg["content"] = ""
                    messages.append(assistantMsg)
                    pendingToolCalls = []
                }

                if let callId = item["call_id"] as? String,
                   let output = item["output"] as? String {
                    messages.append([
                        "role": "tool",
                        "tool_call_id": callId,
                        "content": output
                    ])
                }

            case "tool_search_output":
                // Flush pending tool calls
                if !pendingToolCalls.isEmpty {
                    var assistantMsg: [String: Any] = ["role": "assistant"]
                    assistantMsg["tool_calls"] = pendingToolCalls
                    assistantMsg["content"] = ""
                    messages.append(assistantMsg)
                    pendingToolCalls = []
                }

                // tool_search_output is consumed by CodexToolContext.buildFromRequest
                // to register dynamically loaded tools. We don't forward it as a message.

            case "reasoning":
                // Attach reasoning to preceding assistant message
                if let lastMessage = messages.last,
                   lastMessage["role"] as? String == "assistant",
                   let summary = item["summary"] as? [[String: Any]],
                   let text = summary.first?["text"] as? String {
                    var updated = lastMessage
                    updated["reasoning_content"] = text
                    messages[messages.count - 1] = updated
                }

            default:
                break
            }
        }

        // Flush remaining tool calls
        if !pendingToolCalls.isEmpty {
            var assistantMsg: [String: Any] = ["role": "assistant"]
            assistantMsg["tool_calls"] = pendingToolCalls
            assistantMsg["content"] = ""
            messages.append(assistantMsg)
        }

        return messages
    }

    private func applyReasoningConfig(_ config: CodexChatReasoning, to result: inout [String: Any], from body: [String: Any]) {
        // Detect whether the request asks for reasoning. Codex's
        // `reasoning.effort` controls this; absence means reasoning off.
        let requestedEffort = (body["reasoning"] as? [String: Any])?["effort"] as? String
        let reasoningEnabled = requestedEffort != nil

        // Apply thinking parameter
        if config.supportsThinking, reasoningEnabled {
            switch config.thinkingParam {
            case "thinking":
                result["thinking"] = ["type": "enabled"]
            case "enable_thinking":
                result["enable_thinking"] = true
            case "reasoning_split":
                result["reasoning_split"] = true
            default:
                break
            }
        }

        // Apply effort parameter
        if config.supportsEffort, let effortValue = requestedEffort {
            let mappedEffort = mapEffortValue(effortValue, mode: config.effortValueMode)

            switch config.effortParam {
            case "reasoning_effort":
                result["reasoning_effort"] = mappedEffort
            case "reasoning.effort":
                var reasoningObj = result["reasoning"] as? [String: Any] ?? [:]
                reasoningObj["effort"] = mappedEffort
                result["reasoning"] = reasoningObj
            default:
                break
            }
        } else if config.effortParam == "reasoning.effort" {
            // OpenRouter "explicit off": some OpenRouter models default to
            // thinking-on and cannot be turned off by merely omitting the
            // field. Forward `{reasoning:{effort:"none"}}` so the model
            // actually disables reasoning.
            result["reasoning"] = ["effort": "none"]
        }
    }

    private func mapEffortValue(_ effort: String, mode: CodexEffortValueMode?) -> String {
        guard let mode = mode else { return effort }

        switch mode {
        case .deepseek:
            switch effort.lowercased() {
            case "minimal", "low": return "low"
            case "medium", "high": return "high"
            case "max", "xhigh": return "max"
            default: return effort
            }

        case .lowHigh:
            switch effort.lowercased() {
            case "minimal", "low", "medium": return "low"
            case "high", "max", "xhigh": return "high"
            default: return effort
            }

        case .openrouter:
            switch effort.lowercased() {
            case "minimal": return "minimal"
            case "low": return "low"
            case "medium": return "medium"
            case "high": return "high"
            case "max", "xhigh": return "xhigh"
            default: return effort
            }
        }
    }

    // MARK: - Response Conversion: Chat Completions -> Responses

    func chatCompletionToResponse(
        body: [String: Any],
        reasoningConfig: CodexChatReasoning?,
        toolContext: CodexToolContext = CodexToolContext()
    ) -> [String: Any] {
        var result: [String: Any] = [:]

        let responseId = "resp_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        result["id"] = responseId
        result["object"] = "response"
        result["created_at"] = Int(Date().timeIntervalSince1970)
        result["model"] = body["model"] ?? "gpt-4"
        result["status"] = "completed"

        guard let choices = body["choices"] as? [[String: Any]],
              let firstChoice = choices.first else {
            logger.warning("chatCompletionToResponse: no choices in response")
            result["status"] = "failed"
            result["error"] = ["message": "No choices in response", "type": "server_error"]
            return result
        }

        let message = firstChoice["message"] as? [String: Any] ?? [:]
        let finishReason = firstChoice["finish_reason"] as? String

        var output: [[String: Any]] = []

        // Extract reasoning
        let reasoningContent = extractReasoning(from: message, config: reasoningConfig)

        // Handle inline <think>...</think> tags
        var textContent = message["content"] as? String ?? ""
        let (cleanedText, inlineThinking) = extractInlineThinking(textContent)
        textContent = cleanedText

        let finalReasoning = reasoningContent.isEmpty ? inlineThinking : reasoningContent
        if !finalReasoning.isEmpty {
            output.append([
                "type": "reasoning",
                "id": "rs_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))",
                "summary": [
                    ["type": "summary_text", "text": finalReasoning]
                ]
            ])
        }

        // Add text message
        if !textContent.isEmpty {
            let msgId = "msg_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
            output.append([
                "type": "message",
                "id": msgId,
                "role": "assistant",
                "status": "completed",
                "content": [
                    [
                        "type": "output_text",
                        "text": textContent,
                        "annotations": [] as [Any]
                    ]
                ]
            ])
        }

        // Extract tool calls — restore original Responses tool format based on kind
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                if let id = call["id"] as? String,
                   let function = call["function"] as? [String: Any],
                   let chatName = function["name"] as? String,
                   let arguments = function["arguments"] as? String {

                    let spec = toolContext.spec(forChatName: chatName)

                    if spec?.kind == .custom {
                        // Custom tool: extract "input" from JSON arguments, emit custom_tool_call
                        let inputStr = extractCustomToolInput(arguments)
                        output.append([
                            "type": "custom_tool_call",
                            "id": "ctc_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))",
                            "call_id": id,
                            "name": chatName,
                            "input": inputStr,
                            "status": "completed"
                        ])
                    } else if spec?.kind == .toolSearch {
                        // Tool search: parse arguments as JSON object, emit tool_search_call
                        let argsObj = parseToolArguments(arguments)
                        output.append([
                            "type": "tool_search_call",
                            "id": "tsc_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))",
                            "call_id": id,
                            "name": "tool_search",
                            "arguments": argsObj,
                            "execution": "client",
                            "status": "completed"
                        ])
                    } else if let ns = spec?.namespace {
                        // Namespace tool: restore original name + namespace
                        output.append([
                            "type": "function_call",
                            "id": "fc_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))",
                            "call_id": id,
                            "name": spec?.originalName ?? chatName,
                            "namespace": ns,
                            "arguments": arguments,
                            "status": "completed"
                        ])
                    } else {
                        // Plain function: restore original name
                        let originalName = toolContext.restoreOriginalName(chatName)
                        output.append([
                            "type": "function_call",
                            "id": "fc_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))",
                            "call_id": id,
                            "name": originalName,
                            "arguments": arguments,
                            "status": "completed"
                        ])
                    }
                }
            }
        }

        result["output"] = output

        // Map usage
        if let usage = body["usage"] as? [String: Any] {
            result["usage"] = [
                "input_tokens": usage["prompt_tokens"] ?? 0,
                "output_tokens": usage["completion_tokens"] ?? 0,
                "total_tokens": usage["total_tokens"] ?? 0
            ]
        }

        // Map finish reason
        if finishReason == "length" {
            result["status"] = "incomplete"
            result["incomplete_details"] = ["reason": "max_output_tokens"]
        }

        return result
    }

    // MARK: - Custom Tool Helpers

    /// Extract the "input" field from a JSON-encoded arguments string.
    private func extractCustomToolInput(_ arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = json["input"] as? String else {
            return arguments
        }
        return input
    }

    /// Parse a JSON arguments string into a dictionary.
    private func parseToolArguments(_ arguments: String) -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func extractReasoning(from message: [String: Any], config: CodexChatReasoning?) -> String {
        let format = config?.outputFormat ?? "auto"

        switch format {
        case "reasoning_content":
            return message["reasoning_content"] as? String ?? ""
        case "reasoning_details":
            if let details = message["reasoning_details"] as? [[String: Any]] {
                return details.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            return ""
        case "reasoning":
            if let reasoning = message["reasoning"] as? [String: Any] {
                return reasoning["content"] as? String ?? ""
            }
            return ""
        default:
            // Try all formats
            if let content = message["reasoning_content"] as? String, !content.isEmpty {
                return content
            }
            if let reasoning = message["reasoning"] as? [String: Any],
               let content = reasoning["content"] as? String, !content.isEmpty {
                return content
            }
            if let details = message["reasoning_details"] as? [[String: Any]] {
                let text = details.compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !text.isEmpty { return text }
            }
            return ""
        }
    }

    private func extractInlineThinking(_ text: String) -> (cleaned: String, thinking: String) {
        var thinking = ""
        var cleaned = text

        guard let regex = try? NSRegularExpression(pattern: "<think>(.*?)</think>", options: [.dotMatchesLineSeparators]) else {
            return (text, "")
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)

        for match in matches.reversed() {
            if let thinkingRange = Range(match.range(at: 1), in: text),
               let fullRange = Range(match.range, in: text) {
                thinking += text[thinkingRange] + "\n"
                cleaned.removeSubrange(fullRange)
            }
        }

        return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), thinking.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Private Parameter Filtering

    /// Recursively strip keys beginning with `_` from a JSON object, so
    /// internal metadata the Codex CLI attaches (e.g. `_meta`, `_debug`) is not
    /// forwarded to upstream providers that may reject unknown fields.
    /// JSON Schema property names are preserved so user tool schemas remain intact.
    static func stripPrivateParams(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var filtered: [String: Any] = [:]
            for (key, val) in dict {
                if key.hasPrefix("_") { continue }
                filtered[key] = stripPrivateParams(val)
            }
            return filtered
        }
        if let array = value as? [Any] {
            return array.map { stripPrivateParams($0) }
        }
        return value
    }

    // MARK: - Error Conversion

    func chatErrorToResponseError(_ body: [String: Any]) -> [String: Any] {
        // Try standard OpenAI error format
        if let error = body["error"] as? [String: Any] {
            return [
                "type": "error",
                "error": [
                    "message": error["message"] ?? "Unknown error",
                    "type": error["type"] ?? "upstream_error",
                    "code": error["code"] ?? "upstream_error"
                ] as [String: Any]
            ]
        }

        // Try MiniMax base_resp format
        if let baseResp = body["base_resp"] as? [String: Any] {
            let statusCode = baseResp["status_code"] as? Int ?? 0
            let statusMsg = baseResp["status_msg"] as? String ?? "Unknown error"
            return [
                "type": "error",
                "error": [
                    "message": statusMsg,
                    "type": "upstream_error",
                    "code": String(statusCode)
                ] as [String: Any]
            ]
        }

        // Plain message
        if let message = body["message"] as? String {
            return [
                "type": "error",
                "error": [
                    "message": message,
                    "type": "upstream_error",
                    "code": "upstream_error"
                ] as [String: Any]
            ]
        }

        return [
            "type": "error",
            "error": [
                "message": "Unknown upstream error",
                "type": "upstream_error",
                "code": "upstream_error"
            ] as [String: Any]
        ]
    }
}
