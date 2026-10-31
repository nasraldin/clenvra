public import Foundation
import Security
import Synchronization

/// The helper's XPC interface: few methods, typed payloads as JSON, never free-form paths or commands.
@objc public protocol ClenvraHelperProtocol {
    /// `HelperIdentity.protocolVersion` of the installed helper.
    func protocolVersion(reply: @escaping @Sendable (Int) -> Void)
    /// A JSON `HelperRequest` in, a JSON `HelperResponse` out (`nil` if the request could not be read).
    func perform(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
    /// A JSON `ActivityRecord` in; `nil` when it was put back, otherwise a JSON `RestoreError`.
    func restore(_ record: Data, reply: @escaping @Sendable (Data?) -> Void)
    /// A JSON `DeletionItem` for a plist in /Library/LaunchDaemons or /Library/LaunchAgents, an operation ID and an
    /// `AuthorizationExternalForm` in; a JSON `ActivityRecord.Outcome` out.
    func removeOrphanedLaunchItem(
        _ item: Data, operationID: String, authorization: Data, reply: @escaping @Sendable (Data?) -> Void)
    /// A snapshot date in; a `SnapshotDeletion` raw value out.
    func deleteLocalSnapshot(_ date: String, reply: @escaping @Sendable (String?) -> Void)
    /// A JSON `DeletionItem` for a plist in /Library/LaunchDaemons or /Library/LaunchAgents, whether to enable it,
    /// and an `AuthorizationExternalForm` in; a `LaunchItemChange` raw value out.
    func setLaunchItemEnabled(
        _ item: Data, enabled: Bool, authorization: Data, reply: @escaping @Sendable (String?) -> Void)
    /// A TCC service, a bundle ID and an `AuthorizationExternalForm` in; a `PermissionReset` raw value out.
    func resetPermission(
        _ service: String, bundleID: String, authorization: Data, reply: @escaping @Sendable (String?) -> Void)
    /// A package ID and an `AuthorizationExternalForm` in; a `PackageForget` raw value out.
    func forgetPackage(_ id: String, authorization: Data, reply: @escaping @Sendable (String?) -> Void)
}

/// Why a call to the helper did not get an answer.
public enum HelperClientError: Error, Sendable, Equatable {
    /// Not installed, not approved, or the connection was refused (for example a signature mismatch).
    case unavailable
    /// The helper answered with something that could not be read.
    case badReply
}

/// The app's side of the connection. Each call opens a privileged connection, pins the helper's signature, and
/// closes it afterwards, so the helper can exit when idle.
public struct HelperClient: Sendable {
    public init() {}

    @concurrent public func protocolVersion() async throws(HelperClientError) -> Int {
        try await call { proxy, finish in proxy.protocolVersion { finish(.success($0)) } }
    }

    @concurrent public func perform(_ request: HelperRequest) async throws(HelperClientError) -> HelperResponse {
        var request = request
        // Uninstall removes an app's system files for good: the helper asks for the administrator's password.
        var authorization: (form: Data, release: () -> Void)?
        if request.mode == .irreversible, request.items.contains(where: { $0.section == .applications }) {
            guard let made = Self.authorization() else { throw .unavailable }
            authorization = made
            request = HelperRequest(
                operationID: request.operationID, mode: request.mode, items: request.items,
                ownerBundlePaths: request.ownerBundlePaths, authorization: made.form)
        }
        // Kept until the helper has answered: it uses it to show the password dialog.
        defer { authorization?.release() }
        guard let payload = try? request.encoded() else { throw .badReply }
        let data: Data? = try await call { proxy, finish in proxy.perform(payload) { finish(.success($0)) } }
        guard let data, let response = try? HelperResponse.decode(data),
            response.outcomes.count == request.items.count
        else { throw .badReply }
        return response
    }

    /// `nil` when the item was put back.
    @concurrent public func restore(_ record: ActivityRecord) async throws(HelperClientError) -> RestoreError? {
        guard let payload = try? JSONEncoder().encode(record) else { throw .badReply }
        let data: Data? = try await call { proxy, finish in proxy.restore(payload) { finish(.success($0)) } }
        guard let data else { return nil }
        guard let error = try? JSONDecoder().decode(RestoreError.self, from: data) else { throw .badReply }
        return error
    }

    @concurrent public func removeOrphanedLaunchItem(_ item: DeletionItem, operationID: UUID)
        async throws(HelperClientError)
        -> ActivityRecord.Outcome
    {
        guard let payload = try? JSONEncoder().encode(item) else { throw .badReply }
        let id = operationID.uuidString
        guard let authorization = Self.authorization() else { throw .unavailable }
        // Kept until the helper has answered: it uses it to show the password dialog.
        defer { authorization.release() }
        let form = authorization.form
        let data: Data? = try await call { proxy, finish in
            proxy.removeOrphanedLaunchItem(payload, operationID: id, authorization: form) { finish(.success($0)) }
        }
        guard let data, let outcome = try? JSONDecoder().decode(ActivityRecord.Outcome.self, from: data) else {
            throw .badReply
        }
        return outcome
    }

    @concurrent public func deleteLocalSnapshot(date: String) async throws(HelperClientError) -> SnapshotDeletion {
        let raw: String? = try await call { proxy, finish in proxy.deleteLocalSnapshot(date) { finish(.success($0)) } }
        guard let raw, let result = SnapshotDeletion(rawValue: raw) else { throw .badReply }
        return result
    }

    /// The helper asks for an administrator's password in this login session before acting.
    @concurrent public func setLaunchItemEnabled(_ item: DeletionItem, enabled: Bool) async throws(HelperClientError)
        -> LaunchItemChange
    {
        guard let payload = try? JSONEncoder().encode(item) else { throw .badReply }
        guard let authorization = Self.authorization() else { throw .unavailable }
        // Kept until the helper has answered: it uses it to show the password dialog.
        defer { authorization.release() }
        let form = authorization.form
        let raw: String? = try await call { proxy, finish in
            proxy.setLaunchItemEnabled(payload, enabled: enabled, authorization: form) { finish(.success($0)) }
        }
        guard let raw, let result = LaunchItemChange(rawValue: raw) else { throw .badReply }
        return result
    }

    /// The helper asks for an administrator's password in this login session before acting.
    @concurrent public func resetPermission(service: String, bundleID: String) async throws(HelperClientError)
        -> PermissionReset
    {
        guard let authorization = Self.authorization() else { throw .unavailable }
        // Kept until the helper has answered: it uses it to show the password dialog.
        defer { authorization.release() }
        let form = authorization.form
        let raw: String? = try await call { proxy, finish in
            proxy.resetPermission(service, bundleID: bundleID, authorization: form) { finish(.success($0)) }
        }
        guard let raw, let result = PermissionReset(rawValue: raw) else { throw .badReply }
        return result
    }

    /// The helper asks for an administrator's password in this login session before acting.
    @concurrent public func forgetPackage(id: String) async throws(HelperClientError) -> PackageForget {
        guard let authorization = Self.authorization() else { throw .unavailable }
        // Kept until the helper has answered: it uses it to show the password dialog.
        defer { authorization.release() }
        let form = authorization.form
        let raw: String? = try await call { proxy, finish in
            proxy.forgetPackage(id, authorization: form) { finish(.success($0)) }
        }
        guard let raw, let result = PackageForget(rawValue: raw) else { throw .badReply }
        return result
    }

    /// The authorization of the user action in progress (`withOneAuthorization`), if any.
    @TaskLocal static var actionAuthorization: Data?

    /// The action's authorization, or a new one for this call alone (released, and its approval destroyed, after).
    private static func authorization() -> (form: Data, release: () -> Void)? {
        if let shared = actionAuthorization { return (shared, {}) }
        guard let made = HelperRight.makeClientAuthorization() else { return nil }
        return (made.externalForm, { AuthorizationFree(made.reference, [.destroyRights]) })
    }

    /// One authorization for every helper call of one action; destroyed afterwards, so the next action asks again.
    public func withOneAuthorization<T>(
        isolation: isolated (any Actor)? = #isolation, _ body: () async -> T
    ) async -> T {
        guard let made = HelperRight.makeClientAuthorization() else { return await body() }
        defer { AuthorizationFree(made.reference, [.destroyRights]) }
        return await Self.$actionAuthorization.withValue(made.externalForm, operation: body)
    }

    @concurrent private func call<Value: Sendable>(
        _ body: (any ClenvraHelperProtocol, @escaping @Sendable (Result<Value, HelperClientError>) -> Void) -> Void
    ) async throws(HelperClientError) -> Value {
        let connection = NSXPCConnection(machServiceName: HelperIdentity.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: (any ClenvraHelperProtocol).self)
        connection.setCodeSigningRequirement(HelperIdentity.helperRequirement)
        connection.resume()
        defer { connection.invalidate() }

        let result: Result<Value, HelperClientError> = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(.failure(.unavailable)) }
            guard let helper = proxy as? any ClenvraHelperProtocol else {
                once.resume(.failure(.unavailable))
                return
            }
            body(helper) { once.resume($0) }
        }
        return try result.get()
    }
}

/// Resumes a continuation exactly once: XPC may call both the reply and the error handler.
private final class Once<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Result<Value, HelperClientError>, Never>?>

    init(_ continuation: CheckedContinuation<Result<Value, HelperClientError>, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ result: Result<Value, HelperClientError>) {
        continuation.withLock { pending in
            pending?.resume(returning: result)
            pending = nil
        }
    }
}
