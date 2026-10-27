public import Foundation
import Synchronization

/// The helper's XPC interface: few methods, typed payloads as JSON, never free-form paths or commands.
@objc public protocol ClenvraHelperProtocol {
    /// `HelperIdentity.protocolVersion` of the installed helper.
    func protocolVersion(reply: @escaping @Sendable (Int) -> Void)
    /// A JSON `HelperRequest` in, a JSON `HelperResponse` out (`nil` if the request could not be read).
    func perform(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
    /// A JSON `ActivityRecord` in; `nil` when it was put back, otherwise a JSON `RestoreError`.
    func restore(_ record: Data, reply: @escaping @Sendable (Data?) -> Void)
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

    public func protocolVersion() async throws(HelperClientError) -> Int {
        try await call { proxy, finish in proxy.protocolVersion { finish(.success($0)) } }
    }

    public func perform(_ request: HelperRequest) async throws(HelperClientError) -> HelperResponse {
        guard let payload = try? request.encoded() else { throw .badReply }
        let data: Data? = try await call { proxy, finish in proxy.perform(payload) { finish(.success($0)) } }
        guard let data, let response = try? HelperResponse.decode(data),
            response.outcomes.count == request.items.count
        else { throw .badReply }
        return response
    }

    /// `nil` when the item was put back.
    public func restore(_ record: ActivityRecord) async throws(HelperClientError) -> RestoreError? {
        guard let payload = try? JSONEncoder().encode(record) else { throw .badReply }
        let data: Data? = try await call { proxy, finish in proxy.restore(payload) { finish(.success($0)) } }
        guard let data else { return nil }
        guard let error = try? JSONDecoder().decode(RestoreError.self, from: data) else { throw .badReply }
        return error
    }

    private func call<Value: Sendable>(
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
