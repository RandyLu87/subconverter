import Foundation

enum AppPaths {
    static let appName = "clashconvert"
    private static let legacyAppName = "SubConfigStudio"

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
        try migrateLegacyRootIfNeeded(using: manager)
        for directory in [rootDirectory, importsDirectory, logsDirectory, runtimeDirectory, presetsDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func migrateLegacyRootIfNeeded(using manager: FileManager) throws {
        guard legacyRootDirectory != rootDirectory else {
            return
        }

        guard manager.fileExists(atPath: legacyRootDirectory.path) else {
            return
        }

        guard !manager.fileExists(atPath: rootDirectory.path) else {
            return
        }

        try manager.moveItem(at: legacyRootDirectory, to: rootDirectory)
    }

    private static var legacyRootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(legacyAppName, isDirectory: true)
    }
}
