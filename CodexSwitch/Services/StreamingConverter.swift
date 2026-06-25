import Foundation
import os.log

private let logger = Logger(subsystem: "com.codex.switch", category: "streaming")

final class StreamingConverter {
    private let provider: CodexProvider
    private let protocolConverter: ProtocolConverter
    private let historyStore: ChatHistoryStore
    private let toolContext: CodexToolContext
    /// The current request's `<cwd>` (usually nil for apply_patch tool-loop
    /// requests). Used as the primary cwd for the apply_patch preflight middle
    /// layer; the candidate history is the fallback.
    private let primaryCwd: String?

    init(provider: CodexProvider, protocolConverter: ProtocolConverter, historyStore: ChatHistoryStore,
         toolContext: CodexToolContext = CodexToolContext(), primaryCwd: String? = nil) {
        self.provider = provider
        self.protocolConverter = protocolConverter
        self.historyStore = historyStore
        self.toolContext = toolContext
        self.primaryCwd = primaryCwd
    }

    /// Convert an upstream Chat Completions SSE stream into Responses-API SSE
    /// events. Returns an AsyncStream so chunks are delivered incrementally
    /// instead of buffered until the entire response completes.
    func convertStream(bytes: URLSession.AsyncBytes) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                defer { continuation.finish() }
                do {
                    try await self._convertStream(bytes: bytes, yield: { continuation.yield($0) })
                } catch {
                    logger.error("Stream conversion error: \(error.localizedDescription)")
                    // Emit an SSE error event so the client knows the stream
                    // was truncated. The HTTP 200 + SSE header has already been
                    // sent by ProxyServer, so we can only signal via the SSE
                    // channel itself.
                    let errorJSON: [String: Any] = [
                        "error": [
                            "message": "Stream conversion failed: \(error.localizedDescription)",
                            "type": "server_error",
                            "code": "stream_error"
                        ] as [String: Any]
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: errorJSON, options: [.sortedKeys]) {
                        var sse = Data("data: ".utf8)
                        sse.append(data)
                        sse.append(Data("\n\n".utf8))
                        continuation.yield(sse)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Internal implementation that yields chunks as they are produced.
    private func _convertStream(bytes: URLSession.AsyncBytes, yield: @escaping (Data) -> Void) async throws {
        let responseId = "resp_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        var outputIndex = 0
        var currentMessageId = ""
        var hasStarted = false

        // Collect full response for history caching
        var fullContent = ""
        var fullReasoning = ""
        var toolCalls: [(id: String, chatName: String, arguments: String, itemId: String)] = []

        // Track reasoning item
        var reasoningItemId = ""
        var reasoningItemStarted = false

        // Split non-standard inline  tags out of content
        // deltas and route them to the reasoning channel. Some Chat
        // Completions upstreams (GLM, Kimi, etc.) emit reasoning inline rather
        // than via `reasoning_content`.
        let thinkSplitter = InlineThinkSplitter()

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Skip SSE comments
            if trimmed.hasPrefix(":") { continue }

            guard trimmed.hasPrefix("data: ") else { continue }

            let eventData = String(trimmed.dropFirst(6))

            if eventData == "[DONE]" {
                // Flush any buffered inline-think content before completing.
                for segment in thinkSplitter.flush() {
                    switch segment {
                    case .text(let text):
                        emitTextDelta(text, responseId: responseId, currentMessageId: &currentMessageId,
                                      outputIndex: &outputIndex, fullContent: &fullContent, yield: yield)
                    case .reasoning(let reasoning):
                        emitReasoningDelta(reasoning, responseId: responseId, reasoningItemId: &reasoningItemId,
                                           reasoningItemStarted: &reasoningItemStarted, outputIndex: &outputIndex,
                                           fullReasoning: &fullReasoning, yield: yield)
                    }
                }
                for event in generateCompletionEvents(
                    responseId: responseId,
                    output: buildOutputForCaching(content: fullContent, reasoning: fullReasoning, toolCalls: toolCalls)
                ) {
                    yield(event)
                }
                break
            }

            guard let data = eventData.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let delta = choice["delta"] as? [String: Any] else {
                continue
            }

            // Send start events on first chunk
            if !hasStarted {
                for event in generateStartEvents(responseId: responseId) {
                    yield(event)
                }
                hasStarted = true
            }

            // Handle reasoning_content
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                emitReasoningDelta(reasoning, responseId: responseId, reasoningItemId: &reasoningItemId,
                                   reasoningItemStarted: &reasoningItemStarted, outputIndex: &outputIndex,
                                   fullReasoning: &fullReasoning, yield: yield)
            }

            // Handle content — route through the inline-think splitter so that
            // non-standard  tags become reasoning events.
            if let content = delta["content"] as? String, !content.isEmpty {
                for segment in thinkSplitter.feed(content) {
                    switch segment {
                    case .text(let text):
                        emitTextDelta(text, responseId: responseId, currentMessageId: &currentMessageId,
                                      outputIndex: &outputIndex, fullContent: &fullContent, yield: yield)
                    case .reasoning(let reasoning):
                        emitReasoningDelta(reasoning, responseId: responseId, reasoningItemId: &reasoningItemId,
                                           reasoningItemStarted: &reasoningItemStarted, outputIndex: &outputIndex,
                                           fullReasoning: &fullReasoning, yield: yield)
                    }
                }
            }

            // Handle tool_calls — dispatch based on tool kind
            if let toolCallsDelta = delta["tool_calls"] as? [[String: Any]] {
                for call in toolCallsDelta {
                    let index = call["index"] as? Int ?? 0

                    if index >= toolCalls.count {
                        let callId = (call["id"] as? String) ?? "call_\(UUID().uuidString)"
                        let rawChatName = (call["function"] as? [String: Any])?["name"] as? String ?? ""

                        // Determine item type and ID prefix based on tool kind
                        let spec = toolContext.spec(forChatName: rawChatName)
                        let itemType: String
                        let itemIdPrefix: String
                        let itemExtra: [String: Any]

                        if spec?.kind == .custom {
                            itemType = "custom_tool_call"
                            itemIdPrefix = "ctc_"
                            itemExtra = ["name": rawChatName]
                        } else if spec?.kind == .toolSearch {
                            itemType = "tool_search_call"
                            itemIdPrefix = "tsc_"
                            itemExtra = ["name": "tool_search", "execution": "client"]
                        } else if let ns = spec?.namespace {
                            itemType = "function_call"
                            itemIdPrefix = "fc_"
                            itemExtra = ["name": spec?.originalName ?? rawChatName, "namespace": ns]
                        } else {
                            itemType = "function_call"
                            itemIdPrefix = "fc_"
                            let originalName = toolContext.restoreOriginalName(rawChatName)
                            itemExtra = ["name": originalName]
                        }

                        // Generate item ID once and reuse it for all delta events
                        let itemId = "\(itemIdPrefix)\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
                        toolCalls.append((id: callId, chatName: rawChatName, arguments: "", itemId: itemId))

                        var item: [String: Any] = [
                            "id": itemId,
                            "type": itemType,
                            "call_id": callId,
                            "status": "in_progress"
                        ]
                        for (k, v) in itemExtra { item[k] = v }

                        yield(formatSSE([
                            "type": "response.output_item.added",
                            "response_id": responseId,
                            "output_index": outputIndex,
                            "item": item
                        ]))
                        outputIndex += 1
                    }

                    if let arguments = (call["function"] as? [String: Any])?["arguments"] as? String {
                        toolCalls[index].arguments += arguments

                        // Emit the appropriate delta event based on tool kind
                        let spec = toolContext.spec(forChatName: toolCalls[index].chatName)

                        // apply_patch: buffer args only, do NOT stream raw
                        // `{"input":"..."}` JSON-fragment deltas. The full
                        // (preflight-repaired) V4A input is emitted once at
                        // completion via custom_tool_call_input.delta + .done.
                        // Streaming JSON fragments as input deltas would feed the
                        // client wrong (JSON, not V4A) bytes; the preflight middle
                        // layer also can't run until the args are fully assembled.
                        if spec?.kind == .custom,
                           ApplyPatchPreflight.isApplyPatchTool(toolCalls[index].chatName) {
                            continue
                        }

                        let deltaEventType: String
                        let deltaField: String
                        let deltaValue: String

                        if spec?.kind == .custom {
                            deltaEventType = "response.custom_tool_call_input.delta"
                            deltaField = "delta"
                            deltaValue = arguments
                        } else if spec?.kind == .toolSearch {
                            deltaEventType = "response.tool_search_call_arguments.delta"
                            deltaField = "delta"
                            deltaValue = arguments
                        } else {
                            deltaEventType = "response.function_call_arguments.delta"
                            deltaField = "delta"
                            deltaValue = arguments
                        }

                        // Reuse the item_id from output_item.added for consistency
                        yield(formatSSE([
                            "type": deltaEventType,
                            "response_id": responseId,
                            "item_id": toolCalls[index].itemId,
                            "output_index": outputIndex - 1,
                            deltaField: deltaValue
                        ]))
                    }
                }
            }
        }

        // Cache response for history
        let responseDict: [String: Any] = [
            "id": responseId,
            "output": buildOutputForCaching(content: fullContent, reasoning: fullReasoning, toolCalls: toolCalls)
        ]
        historyStore.cacheFromResponse(responseDict)
    }

    // MARK: - Segment Emitters

    private func emitTextDelta(
        _ text: String,
        responseId: String,
        currentMessageId: inout String,
        outputIndex: inout Int,
        fullContent: inout String,
        yield: (Data) -> Void
    ) {
        if currentMessageId.isEmpty {
            currentMessageId = "msg_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
            for event in generateMessageStart(
                responseId: responseId,
                messageId: currentMessageId,
                outputIndex: outputIndex
            ) {
                yield(event)
            }
            outputIndex += 1
        }

        fullContent += text
        yield(formatSSE([
            "type": "response.output_text.delta",
            "response_id": responseId,
            "item_id": currentMessageId,
            "output_index": outputIndex - 1,
            "delta": text
        ]))
    }

    private func emitReasoningDelta(
        _ reasoning: String,
        responseId: String,
        reasoningItemId: inout String,
        reasoningItemStarted: inout Bool,
        outputIndex: inout Int,
        fullReasoning: inout String,
        yield: (Data) -> Void
    ) {
        fullReasoning += reasoning

        if !reasoningItemStarted {
            reasoningItemId = "rs_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
            for event in generateReasoningStart(responseId: responseId, itemId: reasoningItemId, outputIndex: outputIndex) {
                yield(event)
            }
            reasoningItemStarted = true
            outputIndex += 1
        }

        yield(formatSSE([
            "type": "response.reasoning_summary_text.delta",
            "response_id": responseId,
            "item_id": reasoningItemId,
            "output_index": outputIndex - 1,
            "delta": reasoning
        ]))
    }

    // MARK: - Event Generators

    private func generateStartEvents(responseId: String) -> [Data] {
        var events: [Data] = []

        events.append(formatSSE([
            "type": "response.created",
            "response": ["id": responseId, "object": "response", "status": "in_progress"] as [String: Any]
        ]))

        events.append(formatSSE([
            "type": "response.in_progress",
            "response": ["id": responseId, "object": "response", "status": "in_progress"] as [String: Any]
        ]))

        return events
    }

    private func generateReasoningStart(responseId: String, itemId: String, outputIndex: Int) -> [Data] {
        return [formatSSE([
            "type": "response.output_item.added",
            "response_id": responseId,
            "output_index": outputIndex,
            "item": [
                "id": itemId,
                "type": "reasoning",
                "summary": [] as [Any]
            ] as [String: Any]
        ])]
    }

    private func generateMessageStart(responseId: String, messageId: String, outputIndex: Int) -> [Data] {
        var events: [Data] = []

        events.append(formatSSE([
            "type": "response.output_item.added",
            "response_id": responseId,
            "output_index": outputIndex,
            "item": ["id": messageId, "type": "message", "role": "assistant", "status": "in_progress"] as [String: Any]
        ]))

        events.append(formatSSE([
            "type": "response.content_part.added",
            "response_id": responseId,
            "item_id": messageId,
            "output_index": outputIndex,
            "part": ["type": "output_text", "text": ""] as [String: Any]
        ]))

        return events
    }

    private func generateCompletionEvents(responseId: String, output: [[String: Any]]) -> [Data] {
        var events: [Data] = []

        // Finalize output items
        for (index, item) in output.enumerated() {
            // apply_patch: the input was buffered (not streamed as raw JSON
            // fragments) and preflight-repaired. Emit the full repaired input as
            // a single delta + done before the output_item.done, so the client
            // receives the correct V4A bytes via the proper channel.
            if (item["type"] as? String) == "custom_tool_call",
               ApplyPatchPreflight.isApplyPatchTool(item["name"] as? String ?? "") {
                let itemId = item["id"] as? String ?? ""
                let callId = item["call_id"] as? String ?? ""
                let inputVal = item["input"] as? String ?? ""
                events.append(formatSSE([
                    "type": "response.custom_tool_call_input.delta",
                    "response_id": responseId,
                    "item_id": itemId,
                    "output_index": index,
                    "call_id": callId,
                    "delta": inputVal
                ]))
                events.append(formatSSE([
                    "type": "response.custom_tool_call_input.done",
                    "response_id": responseId,
                    "item_id": itemId,
                    "output_index": index,
                    "call_id": callId,
                    "input": inputVal
                ]))
            }
            events.append(formatSSE([
                "type": "response.output_item.done",
                "response_id": responseId,
                "output_index": index,
                "item": item
            ]))
        }

        // response.completed
        events.append(formatSSE([
            "type": "response.completed",
            "response": [
                "id": responseId,
                "object": "response",
                "status": "completed",
                "output": output
            ] as [String: Any]
        ]))

        return events
    }

    private func buildOutputForCaching(
        content: String,
        reasoning: String,
        toolCalls: [(id: String, chatName: String, arguments: String, itemId: String)]
    ) -> [[String: Any]] {
        var output: [[String: Any]] = []

        if !reasoning.isEmpty {
            output.append([
                "type": "reasoning",
                "summary": [["type": "summary_text", "text": reasoning]]
            ])
        }

        if !content.isEmpty {
            output.append([
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [["type": "output_text", "text": content, "annotations": [] as [Any]]]
            ])
        }

        for call in toolCalls {
            let spec = toolContext.spec(forChatName: call.chatName)

            if spec?.kind == .custom {
                // Custom tool: extract input from arguments
                var inputStr = extractCustomToolInput(call.arguments)
                // apply_patch preflight middle layer: recover known V4A format
                // errors before sending to Codex. Gate envelope completion on JSON
                // completeness so a truncated patch is never "completed".
                let isApplyPatch = ApplyPatchPreflight.isApplyPatchTool(call.chatName)
                if isApplyPatch {
                    let jsonComplete = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) != nil
                    inputStr = ApplyPatchPreflight.optimizePatch(inputStr, primaryCwd: primaryCwd, jsonComplete: jsonComplete).0
                }
                var item: [String: Any] = [
                    "type": "custom_tool_call",
                    "call_id": call.id,
                    "name": call.chatName,
                    "input": inputStr,
                    "status": "completed"
                ]
                // apply_patch needs the item id for the completion-time
                // custom_tool_call_input.delta + .done events.
                if isApplyPatch { item["id"] = call.itemId }
                output.append(item)
            } else if spec?.kind == .toolSearch {
                // Tool search: parse arguments as JSON object
                let argsObj = parseToolArguments(call.arguments)
                output.append([
                    "type": "tool_search_call",
                    "call_id": call.id,
                    "name": "tool_search",
                    "arguments": argsObj,
                    "execution": "client",
                    "status": "completed"
                ])
            } else if let ns = spec?.namespace {
                // Namespace tool
                output.append([
                    "type": "function_call",
                    "call_id": call.id,
                    "name": spec?.originalName ?? call.chatName,
                    "namespace": ns,
                    "arguments": call.arguments,
                    "status": "completed"
                ])
            } else {
                // Plain function
                let originalName = toolContext.restoreOriginalName(call.chatName)
                output.append([
                    "type": "function_call",
                    "call_id": call.id,
                    "name": originalName,
                    "arguments": call.arguments,
                    "status": "completed"
                ])
            }
        }

        return output
    }

    // MARK: - Tool Kind Helpers

    private func extractCustomToolInput(_ arguments: String) -> String {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = json["input"] as? String else {
            return arguments
        }
        return input
    }

    private func parseToolArguments(_ arguments: String) -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func itemIdPrefix(for chatName: String) -> String {
        let spec = toolContext.spec(forChatName: chatName)
        switch spec?.kind {
        case .custom: return "ctc_"
        case .toolSearch: return "tsc_"
        default: return "fc_"
        }
    }

    private func formatSSE(_ event: [String: Any]) -> Data {
        guard let json = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else {
            return Data()
        }
        var data = Data("data: ".utf8)
        data.append(json)
        data.append(Data("\n\n".utf8))
        return data
    }
}
