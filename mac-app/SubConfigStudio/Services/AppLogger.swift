import Foundation

enum AppLogger {
    static var logFileURL: URL {
        AppPaths.logsDirectory.appendingPathComponent("app.log")
    }

    static func log(_ message: String) {
        do {
            try AppPaths.ensureDirectories()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: logFileURL, options: .atomic)
            }
        } catch {
            // Ignore logging failures in the app flow.
        }
    }
}
