import Foundation

struct AppStateStore {
    func load() -> PersistedAppState {
        do {
            try AppPaths.ensureDirectories()
            guard FileManager.default.fileExists(atPath: AppPaths.stateFile.path) else {
                return .empty
            }

            let data = try Data(contentsOf: AppPaths.stateFile)
            return try JSONDecoder().decode(PersistedAppState.self, from: data)
        } catch {
            return .empty
        }
    }

    func save(_ state: PersistedAppState) {
        do {
            try AppPaths.ensureDirectories()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: AppPaths.stateFile, options: .atomic)
        } catch {
            // Keep the app responsive even when persistence fails.
        }
    }
}
