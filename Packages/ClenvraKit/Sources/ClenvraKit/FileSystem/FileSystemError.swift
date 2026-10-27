import Darwin

/// A failed filesystem syscall, carrying `errno` so callers can explain the failure (e.g. EACCES → "needs permission").
public struct FileSystemError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: Int32
    public let operation: String
    public let path: String

    public init(code: Int32, operation: String, path: String) {
        self.code = code
        self.operation = operation
        self.path = path
    }

    /// Captures the current `errno` for a failed call.
    static func current(_ operation: String, _ path: String) -> FileSystemError {
        FileSystemError(code: errno, operation: operation, path: path)
    }

    public var description: String {
        "\(operation)(\(path)): \(String(cString: strerror(code)))"
    }
}
