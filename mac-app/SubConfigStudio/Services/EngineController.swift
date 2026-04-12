import Foundation

final class EngineController {
    private var process: Process?
    private var stderrPipe: Pipe?
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        self.session = URLSession(configuration: configuration)
    }

    func start(using runtime: RuntimeContext) async throws {
        if process != nil, await healthCheck() {
            AppLogger.log("Engine already running and healthy.")
            return
        }

        stop()
        AppLogger.log("Starting engine at \(runtime.binaryURL.path).")

        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = runtime.binaryURL
        process.arguments = ["-f", runtime.prefURL.path, "-l", AppPaths.engineLogFile.path]
        process.currentDirectoryURL = runtime.rootDirectory
        process.standardOutput = Pipe()
        process.standardError = stderrPipe
        try process.run()
        self.process = process
        self.stderrPipe = stderrPipe
        AppLogger.log("Engine process started with pid \(process.processIdentifier).")

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if await healthCheck() {
                AppLogger.log("Engine became healthy.")
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        AppLogger.log("Engine failed to become healthy before timeout.")
        throw EngineError.failedToStart(startupDiagnostic())
    }

    func stop() {
        if let process {
            AppLogger.log("Stopping engine pid \(process.processIdentifier).")
        }
        process?.terminate()
        process = nil
        stderrPipe = nil
    }

    func healthCheck() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:25500/version") else {
            return false
        }

        do {
            let (_, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return false
            }

            return http.statusCode == 200
        } catch {
            return false
        }
    }

    func fetchProxyList(for rawSources: [String], configPath: String) async throws -> String {
        guard !rawSources.isEmpty else {
            throw EngineError.noSources
        }
        AppLogger.log("Requesting proxy list for \(rawSources.count) source(s) using config \(configPath).")

        var components = URLComponents(string: "http://127.0.0.1:25500/sub")
        components?.queryItems = [
            URLQueryItem(name: "target", value: "clash"),
            URLQueryItem(name: "list", value: "true"),
            URLQueryItem(name: "insert", value: "false"),
            URLQueryItem(name: "add_emoji", value: "false"),
            URLQueryItem(name: "remove_emoji", value: "false"),
            URLQueryItem(name: "config", value: configPath),
            URLQueryItem(name: "url", value: rawSources.joined(separator: "|"))
        ]

        guard let url = components?.url else {
            throw EngineError.invalidRequest
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.invalidResponse
        }

        let body = String(decoding: data, as: UTF8.self)
        guard http.statusCode == 200 else {
            AppLogger.log("Proxy list request failed with status \(http.statusCode).")
            throw EngineError.requestFailed(body.isEmpty ? "HTTP \(http.statusCode)" : body)
        }

        AppLogger.log("Proxy list request succeeded with \(data.count) bytes.")
        return body
    }
}

enum EngineError: LocalizedError {
    case failedToStart(String)
    case noSources
    case invalidRequest
    case invalidResponse
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .failedToStart(let details):
            return details
        case .noSources:
            return "No enabled sources were provided."
        case .invalidRequest:
            return "Failed to build the local engine request."
        case .invalidResponse:
            return "The local engine returned an invalid response."
        case .requestFailed(let message):
            return message
        }
    }
}

private extension EngineController {
    func startupDiagnostic() -> String {
        var parts: [String] = ["Local subconverter engine did not become ready in time."]

        if let process, !process.isRunning {
            parts.append("Process exited with code \(process.terminationStatus).")
        }

        if let stderrPipe {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderr.isEmpty {
                parts.append(stderr)
            }
        }

        if let logTail = try? String(contentsOf: AppPaths.engineLogFile, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .suffix(10)
            .joined(separator: "\n"),
           !logTail.isEmpty {
            parts.append(logTail)
        }

        return parts.joined(separator: "\n\n")
    }
}
