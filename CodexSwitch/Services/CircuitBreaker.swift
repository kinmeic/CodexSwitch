import Foundation

// MARK: - Circuit Breaker State

/// Three-state circuit breaker: Closed (normal) → Open (reject) → HalfOpen (probe).
enum CircuitBreakerState: String {
    case closed
    case open
    case halfOpen
}

// MARK: - Circuit Breaker

/// Per-provider circuit breaker. Thread-safe via an internal NSLock.
///
/// Configuration:
/// - `failureThreshold`: consecutive failures before opening (default 3)
/// - `recoveryTimeout`: seconds to wait in Open before probing (default 60)
/// - `successThreshold`: consecutive successes in HalfOpen to close (default 1)
final class CircuitBreaker {
    private let lock = NSLock()

    private(set) var state: CircuitBreakerState = .closed
    private(set) var consecutiveFailures: Int = 0
    private(set) var consecutiveSuccesses: Int = 0
    private(set) var lastSuccessAt: Date?
    private(set) var lastFailureAt: Date?
    private(set) var lastError: String?
    private(set) var openedAt: Date?

    /// Guards against multiple concurrent probe requests in the half-open state.
    private var isProbing: Bool = false

    let failureThreshold: Int
    let recoveryTimeout: TimeInterval
    let successThreshold: Int

    init(failureThreshold: Int = 3, recoveryTimeout: TimeInterval = 60, successThreshold: Int = 1) {
        self.failureThreshold = failureThreshold
        self.recoveryTimeout = recoveryTimeout
        self.successThreshold = successThreshold
    }

    /// Whether the provider is available to accept a request right now.
    /// Does NOT consume a HalfOpen permit — call `allowRequest()` for that.
    var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return checkAvailability()
    }

    /// Check and optionally consume a HalfOpen probe permit. Returns true if
    /// the request is allowed to proceed.
    func allowRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .closed:
            return true
        case .open:
            // Check if timeout has elapsed
            if let openedAt = openedAt, Date().timeIntervalSince(openedAt) >= recoveryTimeout {
                state = .halfOpen
                consecutiveSuccesses = 0
                isProbing = true
                return true
            }
            return false
        case .halfOpen:
            // Only allow one probe request at a time
            if isProbing {
                return false
            }
            isProbing = true
            return true
        }
    }

    /// Record a successful request. May transition HalfOpen → Closed.
    func recordSuccess() {
        lock.lock()
        defer { lock.unlock() }

        consecutiveFailures = 0
        consecutiveSuccesses += 1
        lastSuccessAt = Date()
        isProbing = false

        if state == .halfOpen, consecutiveSuccesses >= successThreshold {
            state = .closed
            consecutiveSuccesses = 0
        }
    }

    /// Record a failed request. May transition Closed → Open or HalfOpen → Open.
    func recordFailure(error: String) {
        lock.lock()
        defer { lock.unlock() }

        consecutiveSuccesses = 0
        consecutiveFailures += 1
        lastFailureAt = Date()
        lastError = error
        isProbing = false

        switch state {
        case .closed:
            if consecutiveFailures >= failureThreshold {
                state = .open
                openedAt = Date()
            }
        case .halfOpen:
            state = .open
            openedAt = Date()
        case .open:
            break
        }
    }

    /// Release a consumed HalfOpen probe permit WITHOUT recording a success or
    /// failure. Call this when a request that passed `allowRequest()` bails out
    /// before it can resolve the probe outcome (e.g. malformed request → 400,
    /// invalid upstream URL → 502, client disconnect mid-stream). Without this,
    /// `isProbing` stays true forever and the breaker is jammed in HalfOpen,
    /// rejecting every subsequent request.
    func releaseProbe() {
        lock.lock()
        defer { lock.unlock() }
        isProbing = false
    }

    /// Reset the circuit breaker to its initial Closed state.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        state = .closed
        consecutiveFailures = 0
        consecutiveSuccesses = 0
        lastSuccessAt = nil
        lastFailureAt = nil
        lastError = nil
        openedAt = nil
        isProbing = false
    }

    private func checkAvailability() -> Bool {
        switch state {
        case .closed:
            return true
        case .open:
            if let openedAt = openedAt, Date().timeIntervalSince(openedAt) >= recoveryTimeout {
                return true // Will transition to HalfOpen on next allowRequest
            }
            return false
        case .halfOpen:
            return true
        }
    }
}

// MARK: - Circuit Breaker Registry

/// Manages per-provider circuit breaker instances, keyed by provider ID.
final class CircuitBreakerRegistry {
    private let lock = NSLock()
    private var breakers: [UUID: CircuitBreaker] = [:]

    let failureThreshold: Int
    let recoveryTimeout: TimeInterval
    let successThreshold: Int

    init(failureThreshold: Int = 3, recoveryTimeout: TimeInterval = 60, successThreshold: Int = 1) {
        self.failureThreshold = failureThreshold
        self.recoveryTimeout = recoveryTimeout
        self.successThreshold = successThreshold
    }

    /// Get or create the circuit breaker for a provider.
    func breaker(for providerId: UUID) -> CircuitBreaker {
        lock.lock()
        defer { lock.unlock() }
        if let existing = breakers[providerId] {
            return existing
        }
        let cb = CircuitBreaker(
            failureThreshold: failureThreshold,
            recoveryTimeout: recoveryTimeout,
            successThreshold: successThreshold
        )
        breakers[providerId] = cb
        return cb
    }

    /// Remove the circuit breaker for a provider (e.g., when deleted).
    func remove(providerId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        breakers.removeValue(forKey: providerId)
    }

    /// Record a successful request for a provider.
    func recordSuccess(providerId: UUID) {
        breaker(for: providerId).recordSuccess()
    }

    /// Record a failed request for a provider.
    func recordFailure(providerId: UUID, error: String) {
        breaker(for: providerId).recordFailure(error: error)
    }

    /// Check if a provider's circuit breaker allows requests.
    func isAvailable(providerId: UUID) -> Bool {
        breaker(for: providerId).isAvailable
    }

    /// Allow a request for a provider (consumes HalfOpen permit if applicable).
    func allowRequest(providerId: UUID) -> Bool {
        breaker(for: providerId).allowRequest()
    }

    /// Release a HalfOpen probe permit for a provider without recording an
    /// outcome. Used when a request bails out before reaching the upstream.
    func releaseProbe(providerId: UUID) {
        breaker(for: providerId).releaseProbe()
    }
}
