import Foundation
import os.log

private let logger = Logger(subsystem: "com.codex.switch", category: "toolcontext")

// MARK: - Tool Kind

/// The four tool kinds the Codex Responses API supports. Chat Completions only
/// knows flat `type: "function"` tools; the proxy flattens namespace children,
/// wraps custom tools, and injects a synthetic tool_search function so upstream
/// providers see standard function tools, then restores the original form when
/// responses come back.
enum CodexToolKind: String {
    case function
    case namespace
    case custom
    case toolSearch
}

// MARK: - Tool Spec

/// Metadata for one registered tool, used to reverse the Chat Completions
/// flattening back to the original Responses API format.
struct CodexToolSpec {
    let kind: CodexToolKind
    /// The original tool name as declared in the Responses API request.
    let originalName: String
    /// The flattened name sent to the Chat Completions upstream.
    let chatName: String
    /// For namespace tools, the parent namespace name.
    let namespace: String?
    /// For custom tools, whether the tool had no parameters schema.
    let isCustom: Bool
}

// MARK: - Tool Context

/// Tracks the mapping between Codex Responses-API tool definitions and the
/// flattened Chat Completions function tools sent upstream. Supports all four
/// Responses tool kinds: function, namespace, custom, and tool_search.
struct CodexToolContext {
    private var specs: [String: CodexToolSpec] = [:]

    /// Maximum length for a flattened Chat tool name. Some upstreams reject
    /// names longer than this.
    private static let maxNameLength = 64

    // MARK: - Registration

    /// Register a plain `type: "function"` tool.
    mutating func addFunctionTool(_ tool: [String: Any]) -> [String: Any]? {
        guard let function = tool["function"] as? [String: Any] ?? nil,
              let name = function["name"] as? String else {
            // Responses-style: top-level name + parameters
            guard let name = tool["name"] as? String else { return nil }
            let chatName = register(kind: .function, originalName: name, chatName: name, namespace: nil)
            var fn: [String: Any] = ["name": chatName]
            if let params = tool["parameters"] { fn["parameters"] = params }
            if let desc = tool["description"] as? String { fn["description"] = desc }
            return ["type": "function", "function": fn]
        }
        let chatName = register(kind: .function, originalName: name, chatName: name, namespace: nil)
        var fn = function
        fn["name"] = chatName
        return ["type": "function", "function": fn]
    }

    /// Register a `type: "namespace"` tool. Each child function is flattened
    /// into a separate Chat Completions function with a combined name.
    mutating func addNamespaceTool(_ tool: [String: Any]) -> [[String: Any]] {
        guard let nsName = tool["name"] as? String,
              let children = tool["tools"] as? [[String: Any]] else {
            return []
        }
        var result: [[String: Any]] = []
        for child in children {
            guard let fn = child["function"] as? [String: Any] ?? nil,
                  let childName = fn["name"] as? String else {
                // Bare child with top-level name
                if let childName = child["name"] as? String {
                    let flatName = flattenNamespaceToolName(nsName, childName)
                    let chatName = register(kind: .namespace, originalName: childName, chatName: flatName, namespace: nsName)
                    var fn: [String: Any] = ["name": chatName]
                    if let params = child["parameters"] { fn["parameters"] = params }
                    if let desc = child["description"] as? String { fn["description"] = desc }
                    result.append(["type": "function", "function": fn])
                }
                continue
            }
            let flatName = flattenNamespaceToolName(nsName, childName)
            let chatName = register(kind: .namespace, originalName: childName, chatName: flatName, namespace: nsName)
            var fnCopy = fn
            fnCopy["name"] = chatName
            result.append(["type": "function", "function": fnCopy])
        }
        return result
    }

    /// Register a `type: "custom"` tool. Wrapped into a single-string-argument
    /// function so Chat Completions upstreams accept it.
    ///
    /// **apply_patch special-case**: Codex CLI registers apply_patch as a freeform
    /// custom tool whose upstream description says "do not wrap the patch in JSON".
    /// On the chat path the model MUST wrap the patch in a JSON `input` string, so
    /// that instruction would mislead it. Replace the description with the
    /// chat-path-accurate V4A guidance (single-sided `@@`, Add File `+`-prefix,
    /// byte-exact context, etc.) so non-OpenAI chat providers emit a usable patch.
    /// The response side (`ProtocolConverter` / `StreamingConverter`) detects the
    /// same tool name and runs the preflight middle layer on the returned input.
    mutating func addCustomTool(_ tool: [String: Any]) -> [String: Any]? {
        guard let name = tool["name"] as? String else { return nil }
        let chatName = register(kind: .custom, originalName: name, chatName: name, namespace: nil)

        let toolDescription: String
        let inputDescription: String
        if ApplyPatchPreflight.isApplyPatchTool(name) {
            // Chat-path-accurate V4A guidance replaces the freeform "do not wrap in JSON" description.
            toolDescription = ApplyPatchGuidance.toolDescription
            inputDescription = ApplyPatchGuidance.inputDescription
        } else {
            // Other custom tools: serialize the original definition into the
            // description so the LLM knows what the tool does.
            if let data = try? JSONSerialization.data(withJSONObject: tool, options: []),
               let str = String(data: data, encoding: .utf8) {
                toolDescription = "Original tool definition:\n```json\n\(str)\n```"
            } else {
                toolDescription = "Original tool definition: \(name)"
            }
            inputDescription = "Raw string input for the original custom tool. Provide the input as a plain string."
        }

        return [
            "type": "function",
            "function": [
                "name": chatName,
                "description": toolDescription,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "input": [
                            "type": "string",
                            "description": inputDescription
                        ]
                    ],
                    "required": ["input"]
                ]
            ]
        ]
    }

    /// Register a `type: "tool_search"` tool. A synthetic function is injected
    /// so the LLM can trigger dynamic tool discovery.
    mutating func addToolSearchTool() -> [String: Any] {
        let chatName = register(kind: .toolSearch, originalName: "tool_search", chatName: "tool_search", namespace: nil)
        return [
            "type": "function",
            "function": [
                "name": chatName,
                "description": "Search and load Codex tools, plugins, connectors, and MCP namespaces for the current task.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Search query for tools or connectors to load."],
                        "limit": ["type": "integer", "description": "Maximum number of tool groups to return."]
                    ],
                    "required": ["query"]
                ]
            ]
        ]
    }

    // MARK: - Lookup

    /// Look up the spec for a flattened chat name.
    func spec(forChatName chatName: String) -> CodexToolSpec? {
        specs[chatName]
    }

    /// Restore a flattened chat name back to its original Responses form.
    /// Returns the original name for plain functions, or the child name for
    /// namespace tools.
    func restoreOriginalName(_ chatName: String) -> String {
        specs[chatName]?.originalName ?? chatName
    }

    /// Whether a chat name corresponds to a custom tool.
    func isCustomTool(_ chatName: String) -> Bool {
        specs[chatName]?.kind == .custom
    }

    /// Whether a chat name corresponds to a tool_search tool.
    func isToolSearch(_ chatName: String) -> Bool {
        specs[chatName]?.kind == .toolSearch
    }

    /// For namespace tools, returns the namespace name.
    func namespaceForTool(_ chatName: String) -> String? {
        specs[chatName]?.namespace
    }

    // MARK: - Batch Registration

    /// Build a context from a full `tools` array in a Responses API request.
    /// Dispatches on each tool's `type` field. Also recursively picks up
    /// tools from `tool_search_output` items in the `input` history.
    static func buildFromRequest(tools: [[String: Any]], input: [[String: Any]]?) -> CodexToolContext {
        var ctx = CodexToolContext()

        for tool in tools {
            let type = tool["type"] as? String ?? ""
            switch type {
            case "function":
                _ = ctx.addFunctionTool(tool)
            case "namespace":
                _ = ctx.addNamespaceTool(tool)
            case "custom":
                _ = ctx.addCustomTool(tool)
            case "tool_search":
                _ = ctx.addToolSearchTool()
            default:
                // Bare string tool (treated as custom) or unknown
                if tool.keys.count == 1, let name = tool["name"] as? String {
                    _ = ctx.addCustomTool(["type": "custom", "name": name])
                }
            }
        }

        // Recursively register tools from tool_search_output items in history
        if let input = input {
            collectToolSearchOutputTools(input, ctx: &ctx)
        }

        logger.debug("Built tool context with \(ctx.specs.count) registered tools")
        return ctx
    }

    /// Walk the `input` array and register any tools found inside
    /// `tool_search_output` items. These are tools dynamically loaded by a
    /// previous tool_search round-trip.
    private static func collectToolSearchOutputTools(_ input: [[String: Any]], ctx: inout CodexToolContext) {
        for item in input {
            let type = item["type"] as? String ?? ""
            if type == "tool_search_output",
               let embeddedTools = item["tools"] as? [[String: Any]] {
                for tool in embeddedTools {
                    let toolType = tool["type"] as? String ?? ""
                    switch toolType {
                    case "function":
                        _ = ctx.addFunctionTool(tool)
                    case "namespace":
                        _ = ctx.addNamespaceTool(tool)
                    case "custom":
                        _ = ctx.addCustomTool(tool)
                    default:
                        break
                    }
                }
            }
            // Recurse into nested input (function_call_output may contain nested items)
            if let nested = item["input"] as? [[String: Any]] {
                collectToolSearchOutputTools(nested, ctx: &ctx)
            }
        }
    }

    // MARK: - Name Flattening

    /// Combine namespace + child name into a single flat identifier.
    /// If the result exceeds maxNameLength, truncate and append a hash suffix.
    private func flattenNamespaceToolName(_ namespace: String, _ childName: String) -> String {
        let combined = "\(namespace)__\(childName)"
        if combined.count <= Self.maxNameLength {
            return combined
        }
        // Truncate + hash to stay within limit
        let hash = shortHash(combined)
        let maxPrefix = Self.maxNameLength - hash.count - 1
        let prefix = String(combined.prefix(maxPrefix))
        return "\(prefix)_\(hash)"
    }

    /// Register a tool and return the chat name to use upstream.
    private mutating func register(kind: CodexToolKind, originalName: String, chatName: String, namespace: String?) -> String {
        let spec = CodexToolSpec(kind: kind, originalName: originalName, chatName: chatName, namespace: namespace, isCustom: kind == .custom)
        specs[chatName] = spec
        return chatName
    }

    private func shortHash(_ input: String) -> String {
        var hash: UInt32 = 5381
        for byte in input.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt32(byte)
        }
        return String(hash, radix: 16)
    }
}
