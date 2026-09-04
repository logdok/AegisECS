import Foundation

/// Receives a diagnostic message. Called on the thread that hit the problem.
public typealias ErrorHandler = (String) -> Void

/// Diagnostic sink for library misuse. This is the port of the original's
/// `push_error()`: the library never throws and never traps, it reports and
/// then returns a failure value, because an ECS embedded in an app that
/// terminates the process on a bad argument is worse than one that logs and
/// carries on.
public enum AegisDiagnostics {
    nonisolated(unsafe) private static var handler: ErrorHandler = { message in
        FileHandle.standardError.write(Data("[AegisECS] \(message)\n".utf8))
    }

    /// Installs a diagnostic sink. `nil` restores the default (stderr). Set it
    /// once during start-up; it is not synchronised.
    public static func setErrorHandler(_ handler: ErrorHandler?) {
        self.handler = handler ?? { message in
            FileHandle.standardError.write(Data("[AegisECS] \(message)\n".utf8))
        }
    }

    @inline(__always)
    static func report(_ message: @autoclosure () -> String) {
        handler(message())
    }
}
