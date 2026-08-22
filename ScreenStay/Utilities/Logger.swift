import Foundation

/// Serial queue for log writes.
///
/// Appending from a concurrent queue interleaved partial lines, because
/// `seekToEndOfFile` and `write` are not atomic together. A serial queue makes
/// each line arrive whole, and gives rotation somewhere safe to happen.
private let logQueue = DispatchQueue(label: "com.simonetti.ScreenStay.log", qos: .utility)

/// Reused rather than rebuilt per call; `ISO8601DateFormatter` is expensive to
/// create and is thread-safe once configured.
private let logTimestampFormatter = ISO8601DateFormatter()

/// Roll the log over once it passes this size.
private let logMaxBytes: UInt64 = 5 * 1024 * 1024

/// Number of rolled-over files to keep alongside the live one.
private let logBackupCount = 1

/// Running size of the live log, so the common path costs no `stat` call.
/// Only touched on `logQueue`. Nil until the first write measures it.
private var logCurrentSize: UInt64?

/// Simple file-based logger writing to ~/Library/Logs/ScreenStay/
func log(_ message: String) {
    let timestamp = logTimestampFormatter.string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"

    // Also print to console for debugging
    print(logMessage.trimmingCharacters(in: .newlines))

    guard let data = logMessage.data(using: .utf8) else { return }

    logQueue.async {
        guard let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let screenStayLogsDir = logsDir.appendingPathComponent("Logs/ScreenStay")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: screenStayLogsDir, withIntermediateDirectories: true)

        let logFile = screenStayLogsDir.appendingPathComponent("screenstay.log")

        if logCurrentSize == nil {
            let attributes = try? FileManager.default.attributesOfItem(atPath: logFile.path)
            logCurrentSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        }

        if (logCurrentSize ?? 0) + UInt64(data.count) > logMaxBytes {
            rotateLog(at: logFile)
            logCurrentSize = 0
        }

        // Append to log file
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
                logCurrentSize = (logCurrentSize ?? 0) + UInt64(data.count)
            }
        } else if (try? data.write(to: logFile)) != nil {
            logCurrentSize = UInt64(data.count)
        }
    }
}

/// Shift screenstay.log to screenstay.log.1, discarding any older generation.
///
/// Must only be called on `logQueue`.
private func rotateLog(at logFile: URL) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: logFile.path) else { return }

    // Drop the oldest, then shuffle the rest down a slot.
    let oldest = logFile.appendingPathExtension("\(logBackupCount)")
    try? fileManager.removeItem(at: oldest)

    var index = logBackupCount - 1
    while index >= 1 {
        let source = logFile.appendingPathExtension("\(index)")
        let destination = logFile.appendingPathExtension("\(index + 1)")
        if fileManager.fileExists(atPath: source.path) {
            try? fileManager.moveItem(at: source, to: destination)
        }
        index -= 1
    }

    try? fileManager.moveItem(at: logFile, to: logFile.appendingPathExtension("1"))
}
