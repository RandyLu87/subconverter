import Darwin
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
        // 必须确认存活的是「自己拉起来的那个」。健康检查只是打 25500,任何别的引擎进程
        // 都会回 200 —— 光看端口通不通,会把别人的进程当成自己的直接复用。
        if let process, process.isRunning, await healthCheck() {
            AppLogger.log("Engine already running and healthy.")
            return
        }

        stop()
        await reapStrayEngines(named: runtime.binaryURL.lastPathComponent)
        AppLogger.log("Starting engine at \(runtime.binaryURL.path).")

        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = runtime.binaryURL
        // 显式把自己的 pid 交给引擎:app 被强制退出 / 崩溃时 stop() 没机会执行,
        // 引擎靠这个自行退出,不会变成占着 25500 的孤儿进程
        process.arguments = ["-f", runtime.prefURL.path,
                             "-l", AppPaths.engineLogFile.path,
                             "--exit-with-parent", String(getpid())]
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

    /// 停引擎。必须是同步阻塞的:调用点之一是 `applicationWillTerminate`,
    /// 那之后 app 立刻就没了,任何异步的 SIGKILL 兜底都不会有机会执行。
    func stop() {
        defer {
            process = nil
            stderrPipe = nil
        }
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        AppLogger.log("Stopping engine pid \(pid).")
        process.terminate()

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            usleep(100_000)
        }
        if process.isRunning {
            AppLogger.log("Engine pid \(pid) ignored SIGTERM, sending SIGKILL.")
            kill(pid, SIGKILL)
            process.waitUntilExit()
        }
    }

    /// 收掉上一轮遗留的引擎进程。app 被强制退出 / 崩溃 / 被 Xcode 停止时,
    /// `applicationWillTerminate` 不会走,子进程被 launchd 收养后继续活着;
    /// 而 httplib 开着 SO_REUSEPORT,新旧进程能同时监听 25500,请求落到谁身上是随机的
    /// —— 落到旧进程就会拿到旧引擎的结果(表现为「改了代码却毫无变化」)。
    /// 按可执行文件名匹配,连手动从终端跑起来的那份也一并收掉,确保端口上只剩一个。
    private func reapStrayEngines(named executableName: String) async {
        var strays = runningProcessIDs().filter { pid in
            pid != getpid() && executablePath(of: pid).map {
                ($0 as NSString).lastPathComponent == executableName
            } == true
        }
        guard !strays.isEmpty else { return }
        AppLogger.log("Reaping \(strays.count) stray engine process(es): \(strays).")
        strays.forEach { kill($0, SIGTERM) }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            strays = strays.filter { kill($0, 0) == 0 }
            if strays.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        // 端口不能留给赖着不走的旧进程,超时直接 SIGKILL
        AppLogger.log("Stray engine(s) \(strays) ignored SIGTERM, sending SIGKILL.")
        strays.forEach { kill($0, SIGKILL) }
    }

    private func runningProcessIDs() -> [pid_t] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let written = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard written > 0 else { return [] }
        return pids.prefix(Int(written)).filter { $0 > 0 }
    }

    private func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE(= 4 * MAXPATHLEN)在 sys/proc_info.h 里被标为
        // "structure not supported",Swift 拿不到,只能把值写死
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
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

    /// 让引擎把一份 Clash 配置文件解析为 sing-box 节点列表(`{"outbounds":[...]}`)。
    func fetchSingBoxNodes(fromConfigPath path: String) async throws -> String {
        AppLogger.log("Requesting sing-box node list from \(path).")

        var components = URLComponents(string: "http://127.0.0.1:25500/sub")
        components?.queryItems = [
            URLQueryItem(name: "target", value: "singbox"),
            URLQueryItem(name: "list", value: "true"),
            URLQueryItem(name: "url", value: path)
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
            AppLogger.log("sing-box node request failed with status \(http.statusCode).")
            throw EngineError.requestFailed(body.isEmpty ? "HTTP \(http.statusCode)" : body)
        }
        AppLogger.log("sing-box node request succeeded with \(data.count) bytes.")
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
