import Foundation

/// Port of `com.termux.terminal.Logger`. Logs go to the `TerminalSessionClient` if set,
/// otherwise to standard error (in place of Android's `android.util.Log`).
public enum Logger {

    /// If logs without a client should be printed to standard error.
    public static var printLogsWithoutClient = true

    public static func log(_ client: TerminalSessionClient?, _ level: LogLevel, _ tag: String, _ message: String) {
        if let client = client {
            client.log(level, tag: tag, message)
        } else if printLogsWithoutClient {
            let levelChar: String
            switch level {
            case .error: levelChar = "E"
            case .warn: levelChar = "W"
            case .info: levelChar = "I"
            case .debug: levelChar = "D"
            case .verbose: levelChar = "V"
            }
            FileHandle.standardError.write(Data("\(levelChar)/\(tag): \(message)\n".utf8))
        }
    }

    public static func logError(_ client: TerminalSessionClient?, _ tag: String, _ message: String) {
        log(client, .error, tag, message)
    }

    public static func logWarn(_ client: TerminalSessionClient?, _ tag: String, _ message: String) {
        log(client, .warn, tag, message)
    }

    public static func logInfo(_ client: TerminalSessionClient?, _ tag: String, _ message: String) {
        log(client, .info, tag, message)
    }

    public static func logDebug(_ client: TerminalSessionClient?, _ tag: String, _ message: String) {
        log(client, .debug, tag, message)
    }

    public static func logVerbose(_ client: TerminalSessionClient?, _ tag: String, _ message: String) {
        log(client, .verbose, tag, message)
    }

    public static func logStackTraceWithMessage(_ client: TerminalSessionClient?, _ tag: String, _ message: String?, _ error: Error?) {
        if let text = getMessageAndStackTraceString(message, error) {
            logError(client, tag, text)
        }
    }

    public static func getMessageAndStackTraceString(_ message: String?, _ error: Error?) -> String? {
        if message == nil && error == nil {
            return nil
        } else if let message = message, let error = error {
            return message + ":\n" + String(describing: error)
        } else if let error = error {
            return String(describing: error)
        } else {
            return message
        }
    }
}
