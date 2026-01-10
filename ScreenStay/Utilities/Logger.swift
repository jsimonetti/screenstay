import Foundation

/// Simple file-based logger writing to ~/Library/Logs/ScreenStay/
func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"
    
    // Also print to console for debugging
    print(logMessage.trimmingCharacters(in: .newlines))
    
    // Write to log file
    DispatchQueue.global(qos: .utility).async {
        guard let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let screenStayLogsDir = logsDir.appendingPathComponent("Logs/ScreenStay")
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: screenStayLogsDir, withIntermediateDirectories: true)
        
        let logFile = screenStayLogsDir.appendingPathComponent("screenstay.log")
        
        // Append to log file
        if let data = logMessage.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }
}
