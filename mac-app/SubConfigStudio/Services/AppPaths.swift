import Foundation

enum AppPaths {
    static let appName = "SubConfigStudio"

    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    static var stateFile: URL {
        rootDirectory.appendingPathComponent("state.json")
    }

    static var importsDirectory: URL {
        rootDirectory.appendingPathComponent("imports", isDirectory: true)
    }

    static var logsDirectory: URL {
        rootDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    static var runtimeDirectory: URL {
        rootDirectory.appendingPathComponent("runtime", isDirectory: true)
    }

    static var presetsDirectory: URL {
        runtimeDirectory.appendingPathComponent("presets", isDirectory: true)
    }

    static var engineLogFile: URL {
        logsDirectory.appendingPathComponent("engine.log")
    }

    static func ensureDirectories() throws {
        let manager = FileManager.default
        for directory in [rootDirectory, importsDirectory, logsDirectory, runtimeDirectory, presetsDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
