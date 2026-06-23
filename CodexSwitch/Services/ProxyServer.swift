import Foundation
import Combine
import Network
import os.log

private let logger = Logger(subsystem: "com.codex.switch", category: "proxy")

// MARK: - HTTP Request

struct HTTPRequest {
    let method: String
    let path: String
    /// Headers with their original casing preserved from the wire format.
    let headers: [(String, String)]
    let body: Data

    func headerValue(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    func bearerToken() -> String? {
        guard let auth = headerValue("authorization") else { return nil }
        let lower = auth.lowercased()
        if lower.hasPrefix("bearer ") {
            return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

struct ProxyRequestLog: Identifiable {
    let id = UUID()
    let timestamp: Date
    let method: String
    let path: String
    let providerName: String?
    let status: Int
    let duration: TimeInterval
    let error: String?
}

// MARK: - ProxyServer

final class ProxyServer: ObservableObject {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.codex.switch.proxy", qos: .userInitiated)
    private var gatewayToken: String = ""
    private var activeProvider: CodexProvider?
    /// Whether to inject a stable `prompt_cache_key` into upstream Responses
    /// requests when the client omits one. Synced from AppState settings.
    var injectPromptCacheKey: Bool = false
    private let maxRequestBodyBytes = 10 * 1024 * 1024

    let protocolConverter = ProtocolConverter()
    let historyStore = ChatHistoryStore()
    let circuitBreakerRegistry = CircuitBreakerRegistry()

    @Published var running = false
    @Published var port: Int = AppEnvironment.defaultPort
    @Published var requestCount: Int = 0
    @Published var lastError: String?
    @Published private(set) var requestLogs: [ProxyRequestLog] = []

    func start(port: Int, provider: CodexProvider, gatewayToken: String) throws {
        guard let rawPort = UInt16(exactly: port),
              let nwPort = NWEndpoint.Port(rawValue: rawPort) else {
            throw NSError(
                domain: "ProxyServer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Port must be between 1 and 65535"]
            )
        }

        stop()

        self.port = port
        self.activeProvider = provider
        self.gatewayToken = gatewayToken
        self.lastError = nil

        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.running = true
                    logger.info("Proxy listening on port \(port)")
                case .failed(let error):
                    self?.running = false
                    self?.lastError = error.localizedDescription
                    logger.error("Listener failed: \(error.localizedDescription)")
                case .cancelled:
                    self?.running = false
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.handleConnection(connection)
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.running = false
        }
    }

    func updateProvider(_ provider: CodexProvider) {
        self.activeProvider = provider
    }

    func updateToken(_ token: String) {
        self.gatewayToken = token
    }

    func clearRequestLogs() {
        DispatchQueue.main.async {
            self.requestLogs.removeAll()
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                logger.error("Connection receive failed: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if nextBuffer.count > self.maxRequestBodyBytes {
                self.recordRequest(method: "?", path: "request", providerName: nil, status: 413, startedAt: Date(), error: "Request body too large")
                self.sendResponse(connection: connection, status: 413, body: self.errorBody("Request body too large"))
                return
            }

            if let request = self.parseHTTPRequest(nextBuffer) {
                self.queue.async {
                    self.processRequest(request: request, connection: connection, startedAt: Date())
                }
            } else if isComplete {
                self.recordRequest(method: "?", path: "request", providerName: nil, status: 400, startedAt: Date(), error: "Bad Request")
                self.sendResponse(connection: connection, status: 400, body: self.errorBody("Bad Request"))
            } else {
                self.receiveRequest(connection, buffer: nextBuffer)
            }
        }
    }

    private func processRequest(request: HTTPRequest, connection: NWConnection, startedAt: Date) {
        DispatchQueue.main.async { self.requestCount += 1 }

        let path = request.path.components(separatedBy: "?").first ?? request.path
        let method = request.method

        logger.info("\(method) \(path)")

        // Health check
        if method == "GET" && path == "/health" {
            recordRequest(method: method, path: path, providerName: nil, status: 200, startedAt: startedAt)
            sendResponse(connection: connection, status: 200, body: Data("{\"status\":\"ok\"}".utf8))
            return
        }

        // Models list (Codex CLI reachability check)
        if method == "GET" && (path == "/models" || path == "/v1/models") {
            handleModels(request: request, connection: connection, startedAt: startedAt)
            return
        }

        // Responses API routes
        if method == "POST" && (
            path == "/v1/responses" ||
            path == "/responses" ||
            path == "/v1/responses/compact" ||
            path == "/responses/compact"
        ) {
            handleResponses(request: request, connection: connection, startedAt: startedAt)
            return
        }

        logger.warning("Unhandled: \(method) \(path)")
        recordRequest(method: method, path: path, providerName: nil, status: 404, startedAt: startedAt, error: "Not Found")
        sendResponse(connection: connection, status: 404, body: errorBody("Not Found"))
    }

    // MARK: - Models Handler

    /// GET /models or GET /v1/models — Codex CLI probes this endpoint at startup
    /// for reachability check. Return the cc-switch-managed model catalog file
    /// so the format always matches what Codex expects.
    private func handleModels(request: HTTPRequest, connection: NWConnection, startedAt: Date) {
        guard validateAuth(request) else {
            recordRequest(method: request.method, path: request.path, providerName: nil, status: 401, startedAt: startedAt, error: "Unauthorized")
            sendResponse(connection: connection, status: 401, body: errorBody("Unauthorized"))
            return
        }

        let catalogPath = AppEnvironment.modelCatalogPath
        let catalog: Data

        if FileManager.default.fileExists(atPath: catalogPath),
           let data = FileManager.default.contents(atPath: catalogPath) {
            catalog = data
        } else {
            // Return empty catalog if file doesn't exist
            catalog = Data("{\"models\":[]}".utf8)
        }

        recordRequest(method: request.method, path: request.path, providerName: activeProvider?.name, status: 200, startedAt: startedAt)
        sendResponse(connection: connection, status: 200, body: catalog, contentType: "application/json")
    }

    // MARK: - Responses Handler

    private func handleResponses(request: HTTPRequest, connection: NWConnection, startedAt: Date) {
        guard validateAuth(request) else {
            recordRequest(method: request.method, path: request.path, providerName: nil, status: 401, startedAt: startedAt, error: "Unauthorized")
            sendResponse(connection: connection, status: 401, body: errorBody("Unauthorized"))
            return
        }

        guard let provider = activeProvider else {
            recordRequest(method: request.method, path: request.path, providerName: nil, status: 503, startedAt: startedAt, error: "No active provider")
            sendResponse(connection: connection, status: 503, body: errorBody("No active provider"))
            return
        }

        // Circuit breaker: check if the provider is available
        if !circuitBreakerRegistry.allowRequest(providerId: provider.id) {
            let cb = circuitBreakerRegistry.breaker(for: provider.id)
            let msg = "Provider circuit is open (\(cb.consecutiveFailures) consecutive failures)"
            recordRequest(method: request.method, path: request.path, providerName: provider.name, status: 503, startedAt: startedAt, error: msg)
            sendResponse(connection: connection, status: 503, body: errorBody(msg))
            return
        }

        let isStreaming = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            .flatMap { $0["stream"] as? Bool } ?? false

        if provider.apiFormat == .chatCompletions {
            // Convert Responses -> Chat Completions
            handleConversion(provider: provider, body: request.body,
                           isStreaming: isStreaming, connection: connection,
                           originalRequest: request, startedAt: startedAt)
        } else {
            // Direct: forward to upstream /v1/responses
            let outboundBody = injectedCacheKeyBody(request.body)
            forwardDirect(provider: provider, body: outboundBody,
                         isStreaming: isStreaming, connection: connection,
                         originalRequest: request, startedAt: startedAt)
        }
    }

    /// Inject a stable `prompt_cache_key` into a Responses-API request body when
    /// the client omitted one, so OpenAI affinity-routes to a consistent
    /// backend and prefix caching hits across turns. Never overrides an existing
    /// key. Only valid for Responses upstreams (the caller guarantees direct mode).
    private func injectedCacheKeyBody(_ body: Data) -> Data {
        guard injectPromptCacheKey,
              var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return body
        }
        if let existing = json["prompt_cache_key"] as? String, !existing.isEmpty {
            return body
        }
        json["prompt_cache_key"] = AppEnvironment.hostKey
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }

    // MARK: - Direct Forward

    private func forwardDirect(
        provider: CodexProvider,
        body: Data,
        isStreaming: Bool,
        connection: NWConnection,
        originalRequest: HTTPRequest,
        startedAt: Date
    ) {
        guard let urlRequest = makeUpstreamRequest(provider: provider, path: "/v1/responses",
                                                   body: body, isStreaming: isStreaming,
                                                   originalHeaders: originalRequest.headers) else {
            recordRequest(method: originalRequest.method, path: originalRequest.path,
                         providerName: provider.name, status: 502, startedAt: startedAt,
                         error: "Invalid upstream URL")
            sendResponse(connection: connection, status: 502, body: errorBody("Invalid upstream URL"))
            return
        }

        if isStreaming {
            streamForwardPassthrough(request: urlRequest, provider: provider,
                                    connection: connection, originalRequest: originalRequest, startedAt: startedAt)
        } else {
            simpleForwardPassthrough(request: urlRequest, provider: provider,
                                    connection: connection, originalRequest: originalRequest, startedAt: startedAt)
        }
    }

    private func makeUpstreamRequest(provider: CodexProvider, path: String, body: Data,
                                     isStreaming: Bool, originalHeaders: [(String, String)]? = nil) -> URLRequest? {
        // Normalize baseURL: strip trailing slashes and any embedded /v1 suffix
        // so that concatenation with a leading-slash path never produces "//".
        var base = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/v1/") {
            base = String(base.dropLast(4))
        } else if base.hasSuffix("/v1") {
            base = String(base.dropLast(3))
        }
        while base.hasSuffix("/") {
            base = String(base.dropLast())
        }
        guard let url = URL(string: base + path) else { return nil }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.timeoutInterval = 300

        // Header Case Preservation: replay original header casing from the
        // Codex CLI request, so proxied requests are wire-identical to direct
        // ones and defeat header-based fingerprinting.
        if let originalHeaders = originalHeaders {
            for (name, value) in originalHeaders {
                let lower = name.lowercased()
                // Skip hop-by-hop and host headers
                if lower == "host" || lower == "connection" || lower == "content-length" || lower == "transfer-encoding" {
                    continue
                }
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
            // Ensure essential headers are set with proper casing
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        }

        if isStreaming {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        return urlRequest
    }

    private func simpleForwardPassthrough(
        request: URLRequest,
        provider: CodexProvider,
        connection: NWConnection,
        originalRequest: HTTPRequest,
        startedAt: Date
    ) {
        let task = NetworkSessionManager.shared.session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                let msg = "Upstream error: \(error.localizedDescription)"
                self.circuitBreakerRegistry.recordFailure(providerId: provider.id, error: msg)
                self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                 providerName: provider.name, status: 502, startedAt: startedAt, error: msg)
                self.sendResponse(connection: connection, status: 502, body: self.errorBody(msg))
                return
            }

            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 502
            let body = data ?? Data()

            if status >= 500 {
                self.circuitBreakerRegistry.recordFailure(providerId: provider.id, error: "HTTP \(status)")
            } else if status >= 200 && status < 400 {
                self.circuitBreakerRegistry.recordSuccess(providerId: provider.id)
            }

            if status >= 400 {
                self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                 providerName: provider.name, status: status, startedAt: startedAt,
                                 error: "Upstream returned HTTP \(status)")
                self.sendResponse(connection: connection, status: status, body: body, contentType: "application/json")
            } else {
                self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                 providerName: provider.name, status: status, startedAt: startedAt)
                self.sendResponse(connection: connection, status: status, body: body, contentType: "application/json")
            }
        }
        task.resume()
    }

    private func streamForwardPassthrough(
        request: URLRequest,
        provider: CodexProvider,
        connection: NWConnection,
        originalRequest: HTTPRequest,
        startedAt: Date
    ) {
        Task { [weak self] in
            guard let self else { return }

            do {
                let (bytes, response) = try await NetworkSessionManager.shared.session.bytes(for: request)
                let httpResponse = response as? HTTPURLResponse
                let status = httpResponse?.statusCode ?? 502

                if status >= 400 {
                    var body = Data()
                    for try await byte in bytes {
                        body.append(byte)
                    }
                    if status >= 500 {
                        self.circuitBreakerRegistry.recordFailure(providerId: provider.id, error: "HTTP \(status)")
                    }
                    self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                     providerName: provider.name, status: status, startedAt: startedAt,
                                     error: "Upstream returned HTTP \(status)")
                    self.sendResponse(connection: connection, status: status, body: body, contentType: "application/json")
                    return
                }

                self.circuitBreakerRegistry.recordSuccess(providerId: provider.id)

                let header = "HTTP/1.1 \(status) \(self.statusText(for: status))\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
                try await self.sendContent(Data(header.utf8), connection: connection)

                var chunk = Data()
                chunk.reserveCapacity(4096)
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 4096 {
                        try await self.sendContent(chunk, connection: connection)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty {
                    try await self.sendContent(chunk, connection: connection)
                }
                self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                 providerName: provider.name, status: status, startedAt: startedAt)
                connection.cancel()
            } catch {
                let msg = "Upstream error: \(error.localizedDescription)"
                self.circuitBreakerRegistry.recordFailure(providerId: provider.id, error: msg)
                self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                 providerName: provider.name, status: 502, startedAt: startedAt, error: msg)
                self.sendResponse(connection: connection, status: 502, body: self.errorBody(msg))
            }
        }
    }

    // MARK: - Conversion Handler (Chat Completions)

    private func handleConversion(
        provider: CodexProvider,
        body: Data,
        isStreaming: Bool,
        connection: NWConnection,
        originalRequest: HTTPRequest,
        startedAt: Date
    ) {
        guard var responsesRequest = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            recordRequest(method: originalRequest.method, path: originalRequest.path,
                         providerName: provider.name, status: 400, startedAt: startedAt,
                         error: "Invalid JSON")
            sendResponse(connection: connection, status: 400, body: errorBody("Invalid JSON"))
            return
        }

        // Enrich with history
        responsesRequest = historyStore.enrichWithHistory(responsesRequest)

        // Build CodexToolContext from the request tools and input
        let tools = responsesRequest["tools"] as? [[String: Any]] ?? []
        let input = responsesRequest["input"] as? [[String: Any]]
        var toolContext = CodexToolContext.buildFromRequest(tools: tools, input: input)

        // Convert Responses -> Chat Completions
        var chatRequest = protocolConverter.responsesToChatCompletions(
            body: responsesRequest,
            reasoningConfig: provider.effectiveReasoning,
            toolContext: &toolContext
        )

        // Map model ID if needed
        if let modelId = chatRequest["model"] as? String,
           let catalogModel = provider.modelCatalog.first(where: { $0.model == modelId || $0.displayName == modelId }) {
            chatRequest["model"] = catalogModel.model
        }

        // Pre-emptive media sanitization for known text-only models
        let modelName = chatRequest["model"] as? String ?? ""
        if let chatBody = try? JSONSerialization.data(withJSONObject: chatRequest) {
            let sanitized = RequestRectifier.sanitizeForTextOnlyModel(chatBody, modelName: modelName)
            if sanitized != chatBody,
               let sanitizedJson = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any] {
                chatRequest = sanitizedJson
            }
        }

        guard let requestBody = try? JSONSerialization.data(withJSONObject: chatRequest) else {
            recordRequest(method: originalRequest.method, path: originalRequest.path,
                         providerName: provider.name, status: 500, startedAt: startedAt,
                         error: "Failed to serialize converted request")
            sendResponse(connection: connection, status: 500,
                        body: errorBody("Failed to serialize converted request"))
            return
        }

        guard let urlRequest = makeUpstreamRequest(provider: provider, path: "/v1/chat/completions",
                                                   body: requestBody, isStreaming: isStreaming,
                                                   originalHeaders: originalRequest.headers) else {
            recordRequest(method: originalRequest.method, path: originalRequest.path,
                         providerName: provider.name, status: 502, startedAt: startedAt,
                         error: "Invalid upstream URL")
            sendResponse(connection: connection, status: 502, body: errorBody("Invalid upstream URL"))
            return
        }

        if isStreaming {
            streamForwardWithConversion(request: urlRequest, provider: provider,
                                       connection: connection, originalRequest: originalRequest,
                                       startedAt: startedAt, toolContext: toolContext)
        } else {
            simpleForwardWithConversion(request: urlRequest, provider: provider,
                                      connection: connection, originalRequest: originalRequest,
                                      startedAt: startedAt, toolContext: toolContext,
                                      originalBody: body)
        }
    }

    private func simpleForwardWithConversion(
        request: URLRequest,
        provider: CodexProvider,
        connection: NWConnection,
        originalRequest: HTTPRequest,
        startedAt: Date,
        toolContext: CodexToolContext,
        originalBody: Data
    ) {
        let task = NetworkSessionManager.shared.session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                let msg = "Upstream error: \(error.localizedDescription)"
                self.circuitBreakerRegistry.recordFailure(providerId: provider.id, error: msg)
                self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                 providerName: provider.name, status: 502, startedAt: startedAt, error: msg)
                self.sendResponse(connection: connection, status: 502, body: self.errorBody(msg))
                return
            }

            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? 502
            let body = data ?? Data()

            // Request Rectifier: check if this is a media rejection error and retry
            let rectification = RequestRectifier.rectifyMediaError(
                requestBody: originalBody,
                httpStatus: status,
                responseBody: body
            )
            if case .rectified(let sanitizedBody) = rectification {
                logger.info("Media rectifier triggered — retrying with sanitized request")
                // Rebuild the converted request with sanitized body
                if let sanitizedJSON = try? JSONSerialization.jsonObject(with: sanitizedBody) as? [String: Any] {
                    var sanitizedRequest = request
                    sanitizedRequest.httpBody = sanitizedBody
                    // Re-convert and retry once
                    self.simpleForwardWithConversion(request: sanitizedRequest, provider: provider,
                                                   connection: connection, originalRequest: originalRequest,
                                                   startedAt: startedAt, toolContext: toolContext,
                                                   originalBody: sanitizedBody)
                    return
                }
            }

            // Circuit breaker: record outcome
            if status >= 500 {
                self.circuitBreakerRegistry.recordFailure(providerId: provider.id, error: "HTTP \(status)")
            } else if status >= 200 && status < 400 {
                self.circuitBreakerRegistry.recordSuccess(providerId: provider.id)
            }
            // 4xx errors don't affect circuit breaker (client fault, not provider fault)

            if status >= 400 {
                // Try to convert Chat Completions error to Responses error
                let errorBody: Data
                if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    let converted = self.protocolConverter.chatErrorToResponseError(json)
                    errorBody = (try? JSONSerialization.data(withJSONObject: converted)) ?? body
                } else {
                    errorBody = body
                }
                self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                 providerName: provider.name, status: status, startedAt: startedAt,
                                 error: "Upstream returned HTTP \(status)")
                self.sendResponse(connection: connection, status: status, body: errorBody, contentType: "application/json")
                return
            }

            // SSE Aggregation Fallback: if upstream returned Content-Type: application/json
            // but the body looks like SSE, aggregate it into a single response
            let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? ""
            if !contentType.contains("text/event-stream") && isSSEBody(body) {
                let aggregatedBody = aggregateSSEResponse(body)
                if let json = try? JSONSerialization.jsonObject(with: aggregatedBody) as? [String: Any] {
                    let responsesResponse = self.protocolConverter.chatCompletionToResponse(
                        body: json,
                        reasoningConfig: provider.effectiveReasoning,
                        toolContext: toolContext
                    )
                    self.historyStore.cacheFromResponse(responsesResponse)
                    if let responseBody = try? JSONSerialization.data(withJSONObject: responsesResponse) {
                        self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                         providerName: provider.name, status: status, startedAt: startedAt)
                        self.sendResponse(connection: connection, status: status, body: responseBody, contentType: "application/json")
                        return
                    }
                }
            }

            guard let chatCompletion = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                 providerName: provider.name, status: 500, startedAt: startedAt,
                                 error: "Invalid Chat Completions response")
                self.sendResponse(connection: connection, status: 500,
                                body: self.errorBody("Invalid Chat Completions response"))
                return
            }

            let responsesResponse = self.protocolConverter.chatCompletionToResponse(
                body: chatCompletion,
                reasoningConfig: provider.effectiveReasoning,
                toolContext: toolContext
            )

            self.historyStore.cacheFromResponse(responsesResponse)

            guard let responseBody = try? JSONSerialization.data(withJSONObject: responsesResponse) else {
                self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                 providerName: provider.name, status: 500, startedAt: startedAt,
                                 error: "Failed to serialize Responses response")
                self.sendResponse(connection: connection, status: 500,
                                body: self.errorBody("Failed to serialize Responses response"))
                return
            }

            self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                             providerName: provider.name, status: status, startedAt: startedAt)
            self.sendResponse(connection: connection, status: status, body: responseBody, contentType: "application/json")
        }
        task.resume()
    }

    private func streamForwardWithConversion(
        request: URLRequest,
        provider: CodexProvider,
        connection: NWConnection,
        originalRequest: HTTPRequest,
        startedAt: Date,
        toolContext: CodexToolContext
    ) {
        let streamingConverter = StreamingConverter(
            provider: provider,
            protocolConverter: protocolConverter,
            historyStore: historyStore,
            toolContext: toolContext
        )

        Task { [weak self] in
            guard let self else { return }

            do {
                let (bytes, response) = try await NetworkSessionManager.shared.session.bytes(for: request)
                let httpResponse = response as? HTTPURLResponse
                let status = httpResponse?.statusCode ?? 502

                if status >= 400 {
                    var body = Data()
                    for try await byte in bytes {
                        body.append(byte)
                    }
                    if status >= 500 {
                        self.circuitBreakerRegistry.recordFailure(providerId: provider.id, error: "HTTP \(status)")
                    }
                    self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                     providerName: provider.name, status: status, startedAt: startedAt,
                                     error: "Upstream returned HTTP \(status)")
                    self.sendResponse(connection: connection, status: status, body: body, contentType: "application/json")
                    return
                }

                self.circuitBreakerRegistry.recordSuccess(providerId: provider.id)

                // Send SSE header
                let header = "HTTP/1.1 \(status) \(self.statusText(for: status))\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
                try await self.sendContent(Data(header.utf8), connection: connection)

                // Convert streaming response — chunks arrive incrementally via AsyncStream
                for await chunk in streamingConverter.convertStream(bytes: bytes) {
                    try await self.sendContent(chunk, connection: connection)
                }

                self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                 providerName: provider.name, status: status, startedAt: startedAt)
                connection.cancel()
            } catch {
                let msg = "Upstream error: \(error.localizedDescription)"
                self.circuitBreakerRegistry.recordFailure(providerId: provider.id, error: msg)
                self.recordRequest(method: originalRequest.method, path: originalRequest.path,
                                 providerName: provider.name, status: 502, startedAt: startedAt, error: msg)
                self.sendResponse(connection: connection, status: 502, body: self.errorBody(msg))
            }
        }
    }

    // MARK: - SSE Aggregation Fallback

    /// Detect if a response body that was labeled as `application/json` actually
    /// contains SSE-formatted data (lines starting with `data: `).
    private func isSSEBody(_ body: Data) -> Bool {
        guard let text = String(data: body, encoding: .utf8) else { return false }
        let lines = text.split(separator: "\n", maxSplits: 10)
        return lines.contains { $0.hasPrefix("data: ") }
    }

    /// Aggregate SSE chunks into a single Chat Completions JSON response.
    /// Merges content deltas, reasoning_content, and tool_calls.
    private func aggregateSSEResponse(_ body: Data) -> Data {
        guard let text = String(data: body, encoding: .utf8) else { return body }

        var fullContent = ""
        var fullReasoning = ""
        var toolCallDeltas: [(index: Int, id: String, name: String, arguments: String)] = []
        var model = ""
        var finishReason = ""
        var usage: [String: Any] = [:]

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data: ") else { continue }
            let eventData = String(trimmed.dropFirst(6))
            if eventData == "[DONE]" { break }

            guard let data = eventData.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let delta = choice["delta"] as? [String: Any] else { continue }

            if let m = json["model"] as? String { model = m }
            if let fr = choice["finish_reason"] as? String { finishReason = fr }
            if let u = json["usage"] as? [String: Any] { usage = u }

            if let content = delta["content"] as? String { fullContent += content }
            if let reasoning = delta["reasoning_content"] as? String { fullReasoning += reasoning }

            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    let idx = call["index"] as? Int ?? 0
                    while toolCallDeltas.count <= idx {
                        toolCallDeltas.append((index: toolCallDeltas.count, id: "", name: "", arguments: ""))
                    }
                    if let id = call["id"] as? String { toolCallDeltas[idx].id = id }
                    if let name = (call["function"] as? [String: Any])?["name"] as? String {
                        toolCallDeltas[idx].name = name
                    }
                    if let args = (call["function"] as? [String: Any])?["arguments"] as? String {
                        toolCallDeltas[idx].arguments += args
                    }
                }
            }
        }

        // Reconstruct as a single Chat Completions response
        var message: [String: Any] = ["role": "assistant", "content": fullContent]
        if !fullReasoning.isEmpty { message["reasoning_content"] = fullReasoning }
        if !toolCallDeltas.isEmpty {
            message["tool_calls"] = toolCallDeltas.map { call -> [String: Any] in
                // If the ID was never populated by any delta chunk, generate a fallback.
                let id = call.id.isEmpty ? "call_\(UUID().uuidString)" : call.id
                return [
                    "id": id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments]
                ]
            }
        }

        var result: [String: Any] = [
            "choices": [["index": 0, "message": message, "finish_reason": finishReason]]
        ]
        if !model.isEmpty { result["model"] = model }
        if !usage.isEmpty { result["usage"] = usage }

        return (try? JSONSerialization.data(withJSONObject: result)) ?? body
    }

    // MARK: - Auth

    private func validateAuth(_ request: HTTPRequest) -> Bool {
        let expected = self.gatewayToken
        guard !expected.isEmpty else { return true }
        let match = request.bearerToken() == expected
        logger.info("Auth result: match=\(match)")
        return match
    }

    // MARK: - HTTP Parsing

    private func parseHTTPRequest(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return nil }
        guard let headerSection = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }

        let lines = headerSection.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }

        let requestLineParts = firstLine.components(separatedBy: " ")
        guard requestLineParts.count >= 2 else { return nil }

        let method = requestLineParts[0]
        let path = requestLineParts[1]

        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            if let colonIdx = line.firstIndex(of: ":") {
                let name = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers.append((name, value))
            }
        }

        let contentLength = headers
            .first { $0.0.lowercased() == "content-length" }
            .flatMap { Int($0.1) } ?? 0
        guard contentLength >= 0 else { return nil }

        let bodyStart = headerEnd.upperBound
        let bodyEnd = bodyStart + contentLength
        guard data.count >= bodyEnd else { return nil }
        let bodyData = Data(data[bodyStart..<bodyEnd])

        return HTTPRequest(method: method, path: path, headers: headers, body: bodyData)
    }

    // MARK: - Response Sending

    private func sendResponse(connection: NWConnection, status: Int, body: Data, contentType: String = "application/json") {
        let statusText = statusText(for: status)
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusText(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Error"
        }
    }

    private func sendContent(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func errorBody(_ message: String) -> Data {
        let json: [String: Any] = [
            "error": [
                "message": message,
                "type": "proxy_error",
                "code": "proxy_error"
            ] as [String: Any]
        ]
        // Always use JSONSerialization to avoid injection when message contains
        // quotes, newlines, or other JSON-special characters. Fall back to a
        // static safe body only if serialization itself fails.
        return (try? JSONSerialization.data(withJSONObject: json))
            ?? Data("{\"error\":{\"message\":\"Internal proxy error\",\"type\":\"proxy_error\",\"code\":\"proxy_error\"}}".utf8)
    }

    private func recordRequest(
        method: String,
        path: String,
        providerName: String?,
        status: Int,
        startedAt: Date,
        error: String? = nil
    ) {
        let log = ProxyRequestLog(
            timestamp: Date(),
            method: method,
            path: path.components(separatedBy: "?").first ?? path,
            providerName: providerName,
            status: status,
            duration: Date().timeIntervalSince(startedAt),
            error: error
        )

        DispatchQueue.main.async {
            self.requestLogs.insert(log, at: 0)
            if self.requestLogs.count > 100 {
                self.requestLogs.removeLast(self.requestLogs.count - 100)
            }
        }
    }
}
