import AppKit
import CoreFoundation

enum MonitorRuntime {
    static let helperIdentifier = "com.perpetualradar.macos.monitor"
    static let helperName = "Perpetual Radar Monitor.app"
    static let isHelper = Bundle.main.bundleIdentifier == helperIdentifier || ProcessInfo.processInfo.environment["PERPETUAL_RADAR_ROLE"] == "monitor"
    static let testChannel = ProcessInfo.processInfo.environment["PERPETUAL_RADAR_TEST_CHANNEL"]
    static let portName = "com.perpetualradar.monitor.\(getuid())\(testChannel.map { ".\($0)" } ?? "")"
    static let quitUI = Notification.Name(portName + ".quit-ui")
    static var updateSuppressionURL: URL {
        let directory = storeURL?.deletingLastPathComponent() ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PerpetualRadar")
        return directory.appendingPathComponent("suppress-update-relaunch")
    }
    static var backgroundMonitoringEnabled: Bool { defaults.bool(forKey: "BackgroundMonitoring") }
    static var defaults: UserDefaults {
        let suite = testChannel.map { "RadarServiceTests.\($0)" } ?? "com.perpetualradar.macos"
        // Foundation rejects an explicit suite matching the running app's bundle ID.
        // The interface already uses this domain; the helper opens it as a shared suite.
        if suite == Bundle.main.bundleIdentifier { return .standard }
        return UserDefaults(suiteName: suite)!
    }
    static var appURL: URL {
        if Bundle.main.bundleIdentifier == helperIdentifier {
            return Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        return Bundle.main.bundleURL
    }
    static var helperURL: URL { appURL.appendingPathComponent("Contents/Library/LoginItems/\(helperName)") }
    static var storeURL: URL? {
        guard testChannel != nil, let directory = ProcessInfo.processInfo.environment["PERPETUAL_RADAR_TEST_DIRECTORY"] else { return nil }
        return URL(fileURLWithPath: directory).appendingPathComponent("radar.sqlite3")
    }
    static func markReady() {
        for (key, data) in [("PERPETUAL_RADAR_PID_FILE", Data(String(ProcessInfo.processInfo.processIdentifier).utf8)), ("PERPETUAL_RADAR_READY_FILE", Data())] {
            if let path = ProcessInfo.processInfo.environment[key], !path.isEmpty {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }
}

// A named Mach message port is independent of both app lifetimes. Submit/poll
// messages return immediately: chart/history awaits never block another client
// or the AppKit run loop. Requests and completed replies exist only in memory.
final class MonitorIPCServer: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (Data) async -> Data
    private final class Context {
        weak var server: MonitorIPCServer?
        init(_ server: MonitorIPCServer) { self.server = server }
    }
    private struct Job {
        var task: Task<Void, Never>?
        var reply: Data?
        let expires = Date().addingTimeInterval(120)
    }
    private let handler: Handler
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var port: CFMessagePort?
    private var expiryTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.perpetualradar.monitor.ipc")

    init(name: String = MonitorRuntime.portName, handler: @escaping Handler) throws {
        self.handler = handler
        let info = Unmanaged.passRetained(Context(self))
        defer { info.release() }
        var context = CFMessagePortContext(version: 0, info: info.toOpaque(), retain: {
            guard let pointer = $0 else { return nil }
            _ = Unmanaged<Context>.fromOpaque(pointer).retain(); return UnsafeRawPointer(pointer)
        }, release: { pointer in
            if let pointer { Unmanaged<Context>.fromOpaque(pointer).release() }
        }, copyDescription: nil)
        var unused = DarwinBoolean(false)
        guard let local = CFMessagePortCreateLocal(nil, name as CFString, { _, message, data, info in
            guard let info, let data else { return nil }
            guard let server = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue().server else { return nil }
            return Unmanaged.passRetained(server.receive(message, data: data as Data) as CFData)
        }, &context, &unused), !unused.boolValue else { throw FilterError("Background monitoring is already running.") }
        port = local
        CFMessagePortSetDispatchQueue(local, queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.expireJobs() }
        timer.resume(); expiryTimer = timer
    }

    deinit { invalidate() }
    func invalidate() {
        expiryTimer?.cancel(); expiryTimer = nil
        if let port { CFMessagePortInvalidate(port) }
        port = nil
        lock.lock(); let tasks = jobs.values.compactMap(\.task); jobs.removeAll(); lock.unlock()
        tasks.forEach { $0.cancel() }
    }

    private func expireJobs() {
        lock.lock(); defer { lock.unlock() }
        let expired = jobs.filter { $0.value.expires < Date() }.map(\.key)
        for key in expired { jobs.removeValue(forKey: key)?.task?.cancel() }
    }

    private func receive(_ message: Int32, data: Data) -> Data {
        if message == 1 {
            guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = request["id"] as? String, let body = request["body"],
                  let payload = try? JSONSerialization.data(withJSONObject: body) else { return Data("{}".utf8) }
            lock.lock()
            let expired = jobs.filter { $0.value.expires < Date() }.map(\.key)
            for key in expired { jobs.removeValue(forKey: key)?.task?.cancel() }
            if jobs[id] == nil {
                jobs[id] = Job()
                jobs[id]?.task = Task { @MainActor [weak self, handler] in
                    let reply = await handler(payload)
                    self?.complete(id, reply: reply)
                }
            }
            lock.unlock()
            return Data("{\"accepted\":true}".utf8)
        }
        let id = String(decoding: data, as: UTF8.self)
        lock.lock(); defer { lock.unlock() }
        if message == 3 { jobs.removeValue(forKey: id)?.task?.cancel(); return Data("{}".utf8) }
        guard let job = jobs[id] else { return Data("{\"error\":\"Background request expired.\"}".utf8) }
        if let reply = job.reply { jobs.removeValue(forKey: id); return reply }
        return Data("{\"pending\":true}".utf8)
    }

    private func complete(_ id: String, reply: Data) {
        lock.lock(); defer { lock.unlock() }
        jobs[id]?.reply = reply
        jobs[id]?.task = nil
    }
}

enum MonitorIPC {
    static func send(_ data: Data, message: Int32, name: String = MonitorRuntime.portName) throws -> Data {
        guard let port = CFMessagePortCreateRemote(nil, name as CFString) else { throw FilterError("Background monitoring is not running.") }
        var reply: Unmanaged<CFData>?
        let result = CFMessagePortSendRequest(port, message, data as CFData, 2, 2, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard result == kCFMessagePortSuccess, let reply else { throw FilterError("Cannot reach background monitoring (\(result)).") }
        return reply.takeRetainedValue() as Data
    }

    @MainActor
    static func request(_ body: [String: Any], name: String = MonitorRuntime.portName) async throws -> [String: Any] {
        let id = UUID().uuidString, key = Data(id.utf8)
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "body": body])
        _ = try await Task.detached { try send(data, message: 1, name: name) }.value
        do {
            let deadline = ContinuousClock.now + .seconds(100)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let data = try await Task.detached { try send(key, message: 2, name: name) }.value
                guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FilterError("Invalid background response.") }
                if let error = response["error"] as? String { throw FilterError(error) }
                if let value = response["value"] as? [String: Any] { return value }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw FilterError("Background request timed out.")
        } catch {
            _ = try? await Task.detached { try send(key, message: 3, name: name) }.value
            throw error
        }
    }
}

@MainActor
final class MonitorClient {
    private var launchTask: Task<Void, Error>?
    private var launchedProcess: Process?
    var workspace = "radar"
    var researchBusy = false
    private var shuttingDown = false
    private var lease: [String: Any] { ["pid": ProcessInfo.processInfo.processIdentifier, "workspace": workspace, "researchBusy": researchBusy] }

    func request(_ body: [String: Any]) async throws -> [String: Any] {
        guard !shuttingDown else { throw CancellationError() }
        try await ensureRunning()
        var request = body; request["foregroundLease"] = lease
        return try await MonitorIPC.request(request)
    }

    func shutdown() async {
        shuttingDown = true; launchTask?.cancel()
        if CFMessagePortCreateRemote(nil, MonitorRuntime.portName as CFString) != nil {
            _ = try? await MonitorIPC.request(["stopForReplacement": true])
            for _ in 0..<60 {
                if CFMessagePortCreateRemote(nil, MonitorRuntime.portName as CFString) == nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        if let process = launchedProcess { if process.isRunning { process.terminate() }; process.waitUntilExit() }
    }

    func ensureRunning() async throws {
        if let launchTask { return try await launchTask.value }
        let task = Task { try await connectOrLaunch() }
        launchTask = task
        defer { launchTask = nil }
        try await task.value
    }

    private func connectOrLaunch() async throws {
        if let info = try? await MonitorIPC.request(["serviceInfo": true]) {
            if info["appPath"] as? String == MonitorRuntime.appURL.path,
               info["revision"] as? String == (Bundle.main.object(forInfoDictionaryKey: "CFBundleSourceRevision") as? String ?? "development") {
                _ = try await MonitorIPC.request(["foregroundLease": lease, "serviceInfo": true]); return
            }
            _ = try await MonitorIPC.request(["stopForReplacement": true])
            for _ in 0..<100 {
                if CFMessagePortCreateRemote(nil, MonitorRuntime.portName as CFString) == nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        if MonitorRuntime.testChannel != nil || MonitorRuntime.appURL.pathExtension != "app" {
            let process = Process()
            process.executableURL = MonitorRuntime.appURL.pathExtension == "app"
                ? MonitorRuntime.helperURL.appendingPathComponent("Contents/MacOS/PerpetualRadar")
                : URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            var environment = ProcessInfo.processInfo.environment
            environment["PERPETUAL_RADAR_ROLE"] = "monitor"
            environment["PERPETUAL_RADAR_OWNER_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            environment.removeValue(forKey: "PERPETUAL_RADAR_PID_FILE")
            environment.removeValue(forKey: "PERPETUAL_RADAR_READY_FILE")
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); launchedProcess = process
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.environment = ["PERPETUAL_RADAR_OWNER_PID": String(ProcessInfo.processInfo.processIdentifier)]
            if let rollback = ProcessInfo.processInfo.environment["PERPETUAL_RADAR_UPDATE_ROLLBACK"] {
                configuration.environment["PERPETUAL_RADAR_UPDATE_ROLLBACK"] = rollback
            }
            _ = try await NSWorkspace.shared.openApplication(at: MonitorRuntime.helperURL, configuration: configuration)
        }
        for _ in 0..<200 {
            if (try? await MonitorIPC.request(["serviceInfo": true, "foregroundLease": lease])) != nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FilterError("Cannot start Perpetual Radar Monitor. Relaunch the app to retry.")
    }
}
