import Foundation
import os.log

private let logger = Logger(subsystem: "com.codex.switch", category: "streaming")

final class StreamingConverter {
    private let provider: CodexProvider
    private let protocolConverter: ProtocolConverter
    private let historyStore: ChatHistoryStore
    private let toolContext: ToolNameContext

    init(provider: CodexProvider, protocolConverter: ProtocolConverter, historyStore: ChatHistoryStore,
         toolContext: ToolNameContext = ToolNameContext()) {
        self.provider = provider
        self.protocolConverter = protocolConverter
        self.historyStore = historyStore
        self.toolContext = toolContext
    }

    func convertStream(bytes: URLSession.AsyncBytes) async throws -> [Data] {
        var chunks: [Data] = []
        let responseId = "resp_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        var outputIndex = 0
        var currentMessageId = ""
        var hasStarted = false

        // Collect full response for history caching
        var fullContent = ""
        var fullReasoning = ""
        var toolCalls: [(id: String, name: String, arguments: String)] = []

        // Track reasoning item
        var reasoningItemId = ""
        var reasoningItemStarted = false

        // Split non-standard inline `<think>...</think>` tags out of content
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
                                      outputIndex: &outputIndex, fullContent: &fullContent, chunks: &chunks)
                    case .reasoning(let reasoning):
                        emitReasoningDelta(reasoning, responseId: responseId, reasoningItemId: &reasoningItemId,
                                           reasoningItemStarted: &reasoningItemStarted, outputIndex: &outputIndex,
                                           fullReasoning: &fullReasoning, chunks: &chunks)
                    }
                }
                chunks.append(contentsOf: generateCompletionEvents(
                    responseId: responseId,
                    output: buildOutputForCaching(content: fullContent, reasoning: fullReasoning, toolCalls: toolCalls)
                ))
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
                chunks.append(contentsOf: generateStartEvents(responseId: responseId))
                hasStarted = true
            }

            // Handle reasoning_content
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
                emitReasoningDelta(reasoning, responseId: responseId, reasoningItemId: &reasoningItemId,
                                   reasoningItemStarted: &reasoningItemStarted, outputIndex: &outputIndex,
                                   fullReasoning: &fullReasoning, chunks: &chunks)
            }

            // Handle content — route through the inline-think splitter so that
            // non-standard ` Reid... Reeves` tags become reasoning events.
            if let content = delta["content"] as? String, !content.isEmpty {
                for segment in thinkSplitter.feed(content) {
                    switch segment {
                    case .text(let text):
                        emitTextDelta(text, responseId: responseId, currentMessageId: &currentMessageId,
                                      outputIndex: &outputIndex, fullContent: &fullContent, chunks: &chunks)
                    case .reasoning(let reasoning):
                        emitReasoningDelta(reasoning, responseId: responseId, reasoningItemId: &reasoningItemId,
                                           reasoningItemStarted: &reasoningItemStarted, outputIndex: &outputIndex,
                                           fullReasoning: &fullReasoning, chunks: &chunks)
                    }
                }
            }

            // Handle tool_calls
            if let toolCallsDelta = delta["tool_calls"] as? [[String: Any]] {
                for call in toolCallsDelta {
                    let index = call["index"] as? Int ?? 0

                    if index >= toolCalls.count {
                        let callId = (call["id"] as? String) ?? "call_\(UUID().uuidString)"
                        let rawName = (call["function"] as? [String: Any])?["name"] as? String ?? ""
                        let restoredName = toolContext.restore(rawName)
                        toolCalls.append((id: callId, name: restoredName, arguments: ""))

                        let fcId = "fc_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
                        chunks.append(formatSSE([
                            "type": "response.output_item.added",
                            "response_id": responseId,
                            "output_index": outputIndex,
                            "item": [
                                "id": fcId,
                                "type": "function_call",
                                "call_id": callId,
                                "name": restoredName,
                                "arguments": "",
                                "status": "in_progress"
                            ] as [String: Any]
                        ]))
                        outputIndex += 1
                    }

                    if let arguments = (call["function"] as? [String: Any])?["arguments"] as? String {
                        toolCalls[index].arguments += arguments
                        chunks.append(formatSSE([
                            "type": "response.function_call_arguments.delta",
                            "response_id": responseId,
                            "item_id": toolCalls[index].id,
                            "output_index": outputIndex - 1,
                            "delta": arguments
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

        return chunks
    }

    // MARK: - Segment Emitters

    private func emitTextDelta(
        _ text: String,
        responseId: String,
        currentMessageId: inout String,
        outputIndex: inout Int,
        fullContent: inout String,
        chunks: inout [Data]
    ) {
        if currentMessageId.isEmpty {
            currentMessageId = "msg_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
            chunks.append(contentsOf: generateMessageStart(
                responseId: responseId,
                messageId: currentMessageId,
                outputIndex: outputIndex
            ))
            outputIndex += 1
        }

        fullContent += text
        chunks.append(formatSSE([
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
        chunks: inout [Data]
    ) {
        fullReasoning += reasoning

        if !reasoningItemStarted {
            reasoningItemId = "rs_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
            chunks.append(contentsOf: generateReasoningStart(responseId: responseId, itemId: reasoningItemId, outputIndex: outputIndex))
            reasoningItemStarted = true
            outputIndex += 1
        }

        chunks.append(formatSSE([
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
        toolCalls: [(id: String, name: String, arguments: String)]
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
            output.append([
                "type": "function_call",
                "call_id": call.id,
                "name": call.name,
                "arguments": call.arguments,
                "status": "completed"
            ])
        }

        return output
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
