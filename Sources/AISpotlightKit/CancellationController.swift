import Foundation

/// Manages task lifecycle to prevent the crashes and stale-state
/// bugs caused by concurrent search / LLM tasks.
///
/// **Design:**
/// - Every cancellable operation gets a token.
/// - Starting a new operation automatically cancels the previous
///   one in the same scope.
/// - The UI never sees results from stale operations.
///
/// **Usage:**
/// ```swift
/// let controller = CancellationController()
///
/// // The previous search (if any) is cancelled automatically.
/// let token = controller.beginScope("search")
/// do {
///     let results = try await search()
///     guard !token.isCancelled else { return }
///     // update UI with results
/// } catch {
///     guard !token.isCancelled else { return }
///     // show error
/// }
/// ```
public final class CancellationController: @unchecked Sendable {

    private let lock = NSLock()
    private var activeScopes: [String: CancellationToken] = [:]

    public init() {}

    // MARK: - Scope management

    /// Begin a named scope. Any existing scope with the same name
    /// is cancelled. Returns a token that the caller must check.
    public func beginScope(_ name: String) -> CancellationToken {
        lock.lock(); defer { lock.unlock() }
        // Cancel any previous scope with this name
        activeScopes[name]?.cancel()
        let token = CancellationToken(name: name) { [weak self] in
            self?.lock.lock()
            self?.activeScopes.removeValue(forKey: name)
            self?.lock.unlock()
        }
        activeScopes[name] = token
        return token
    }

    /// Cancel all active scopes. Resets the controller to a clean state.
    public func cancelAll() {
        lock.lock()
        let tokens = Array(activeScopes.values)
        activeScopes.removeAll()
        lock.unlock()
        tokens.forEach { $0.cancel() }
    }

    // MARK: - Convenience

    /// Perform an operation with automatic cancellation of previous
    /// work in the same scope. The block receives a `CancellationToken`
    /// and should check `token.isCancelled` at safe points.
    public func perform<T: Sendable>(
        scope: String,
        operation: @escaping @Sendable (CancellationToken) async throws -> T
    ) async throws -> T {
        let token = beginScope(scope)
        defer {
            if !token.isCancelled {
                token.complete()
            }
        }
        return try await operation(token)
    }
}

// MARK: - CancellationToken

/// A lightweight cancellation token. Does NOT use `Task.isCancelled`
/// (which is tied to the current `Task`). Instead, the token holds
/// its own flag so it survives task boundaries (e.g. detached tasks,
/// child tasks, or continuations that may not inherit cancellation).
public final class CancellationToken: @unchecked Sendable {
    public let name: String
    public private(set) var isCancelled: Bool = false
    private let lock = NSLock()
    private let onComplete: (() -> Void)?

    fileprivate init(name: String, onComplete: (() -> Void)?) {
        self.name = name
        self.onComplete = onComplete
    }

    /// Cancel this token. Subsequent calls are no-ops.
    public func cancel() {
        lock.lock()
        if isCancelled { lock.unlock(); return }
        isCancelled = true
        lock.unlock()
    }

    /// Mark this token as completed (not cancelled). Only the owner
    /// should call this when work finishes normally.
    public func complete() {
        onComplete?()
    }
}
