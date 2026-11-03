import Foundation
import CoreFoundation
import Darwin

enum WorkerCommand: String, Codable, Sendable {
    case doctor, authenticate, listDevices = "list_devices", poll
}

struct WorkerRequest: Sendable {
    let requestID: String
    let command: WorkerCommand
    let timeoutMS: Int
    let credentialBundle: Data?
    let deviceID: String?
    let browserHelper: Data?

    init(command: WorkerCommand, timeoutMS: Int, credentialBundle: Data? = nil, deviceID: String? = nil, browserHelper: Data? = nil) {
        self.requestID = UUID().uuidString
        self.command = command
        self.timeoutMS = timeoutMS
        self.credentialBundle = credentialBundle
        self.deviceID = deviceID
        self.browserHelper = browserHelper
    }

    func encodedLine() throws -> Data {
        var object: [String: Any] = [
            "protocol_version": 1,
            "request_id": requestID,
            "command": command.rawValue,
            "timeout_ms": timeoutMS
        ]
        if let credentialBundle {
            guard let bundle = try JSONSerialization.jsonObject(with: credentialBundle) as? [String: Any] else {
                throw WorkerTransportError.malformedOutput
            }
            object["credential_bundle"] = bundle
        }
        if let deviceID { object["device_id"] = deviceID }
        if let browserHelper {
            guard let helper = try JSONSerialization.jsonObject(with: browserHelper) as? [String: Any] else {
                throw WorkerTransportError.malformedOutput
            }
            object["browser_helper"] = helper
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}

struct WorkerEvent: Sendable {
    let requestID: String
    let name: String
    let payload: Data
}

enum WorkerTransportError: Error {
    case unavailable
    case launchFailed
    case timeout
    case cancelled
    case outputLimit
    case malformedOutput
    case unexpectedEvent
    case missingTerminal
    case failedExit
}

final class WorkerProcessClient: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = WorkerRequestGate()
    private var activeProcesses: [String: Process] = [:]
    private var cancelledRequests = Set<String>()
    private let maxLineBytes = 1_048_576
    private let maxOutputBytes = 8 * 1_048_576
    private let configuredWorkingDirectory: URL?
    private let configuredExecutable: URL?
    private let configuredArguments: [String]

    init(workingDirectory: URL? = nil, executableURL: URL? = nil, arguments: [String] = []) {
        self.configuredWorkingDirectory = workingDirectory
        self.configuredExecutable = executableURL
        self.configuredArguments = arguments
    }

    func request(
        _ request: WorkerRequest,
        hardTimeout: Duration,
        onCredentialUpdate: @escaping @Sendable (Data) throws -> Void = { _ in }
    ) async throws -> [WorkerEvent] {
        try Task.checkCancellation()
        guard await gate.acquire() else { throw CancellationError() }
        if Task.isCancelled {
            await gate.release()
            throw CancellationError()
        }
        do {
            let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let events = try self.run(request, hardTimeout: hardTimeout, onCredentialUpdate: onCredentialUpdate)
                        continuation.resume(returning: events)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            } onCancel: {
                self.terminate(requestID: request.requestID)
            }
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    private func run(
        _ request: WorkerRequest,
        hardTimeout: Duration,
        onCredentialUpdate: @escaping @Sendable (Data) throws -> Void
    ) throws -> [WorkerEvent] {
        let override = configuredExecutable.map {
            WorkerLaunch(executableURL: $0, arguments: configuredArguments,
                         workingDirectory: configuredWorkingDirectory ?? Self.defaultSupportDirectory())
        }
        guard let launch = override ?? Self.workerLaunch(configuredWorkingDirectory: configuredWorkingDirectory) else {
            throw WorkerTransportError.unavailable
        }
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.workingDirectory
        process.environment = [
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": Locale.current.identifier
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw WorkerTransportError.launchFailed
        }
        lock.lock()
        activeProcesses[request.requestID] = process
        let cancelledBeforeStart = cancelledRequests.remove(request.requestID) != nil
        lock.unlock()
        defer {
            lock.lock()
            activeProcesses.removeValue(forKey: request.requestID)
            cancelledRequests.remove(request.requestID)
            lock.unlock()
        }
        if cancelledBeforeStart { Self.terminateOwned(process) }

        let timedOut = AtomicFlag()
        let exceededLimit = AtomicFlag()
        let stdoutBuffer = LockedData()
        let stdoutFailure = LockedFailure()
        let stderrSize = LockedCounter()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readGroup.leave() }
            Self.consumeStdout(
                output.fileHandleForReading, maxBytes: self.maxOutputBytes, maxLineBytes: self.maxLineBytes,
                output: stdoutBuffer, overflow: exceededLimit, failure: stdoutFailure, process: process,
                requestID: request.requestID, onCredentialUpdate: onCredentialUpdate
            )
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readGroup.leave() }
            Self.consume(errors.fileHandleForReading, maxBytes: self.maxOutputBytes, output: nil, total: stderrSize, overflow: exceededLimit, process: process)
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        let components = hardTimeout.components
        let timeoutMS = max(1, components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
        timer.schedule(deadline: .now() + .milliseconds(Int(timeoutMS)))
        timer.setEventHandler {
            if process.isRunning {
                timedOut.set()
                Self.terminateOwned(process)
            }
        }
        timer.resume()
        defer { timer.cancel() }

        if cancelledBeforeStart {
            Self.terminateOwned(process)
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            guard readGroup.wait(timeout: .now() + 3) == .success else {
                try? output.fileHandleForReading.close()
                try? errors.fileHandleForReading.close()
                throw WorkerTransportError.cancelled
            }
            if let failure = stdoutFailure.value { throw failure }
            throw WorkerTransportError.cancelled
        }

        do {
            let data = try request.encodedLine()
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
        } catch {
            Self.terminateOwned(process)
            try? input.fileHandleForWriting.close()
            if readGroup.wait(timeout: .now() + 3) == .timedOut {
                try? output.fileHandleForReading.close()
                try? errors.fileHandleForReading.close()
            }
            throw WorkerTransportError.launchFailed
        }
        process.waitUntilExit()
        guard readGroup.wait(timeout: .now() + 3) == .success else {
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            throw WorkerTransportError.timeout
        }
        lock.lock()
        let cancelled = cancelledRequests.contains(request.requestID)
        lock.unlock()
        if cancelled { throw WorkerTransportError.cancelled }
        if timedOut.value { throw WorkerTransportError.timeout }
        if exceededLimit.value { throw WorkerTransportError.outputLimit }
        if let failure = stdoutFailure.value { throw failure }
        let events = try Self.parse(stdoutBuffer.data, requestID: request.requestID, maxLineBytes: maxLineBytes)
        guard process.terminationStatus == 0 else { throw WorkerTransportError.failedExit }
        return events
    }

    private func terminate(requestID: String) {
        lock.lock()
        let process = activeProcesses[requestID]
        cancelledRequests.insert(requestID)
        lock.unlock()
        if let process { Self.terminateOwned(process) }
    }

    private static func terminateOwned(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    private static func consume(
        _ handle: FileHandle,
        maxBytes: Int,
        output: LockedData?,
        total: LockedCounter?,
        overflow: AtomicFlag,
        process: Process
    ) {
        while true {
            let chunk = handle.readData(ofLength: 8192)
            if chunk.isEmpty { break }
            if let output {
                if !output.append(chunk, limit: maxBytes) {
                    overflow.set()
                    terminateOwned(process)
                    break
                }
            } else if let total, !total.add(chunk.count, limit: maxBytes) {
                overflow.set()
                terminateOwned(process)
                break
            }
        }
        try? handle.close()
    }

    private static func consumeStdout(
        _ handle: FileHandle,
        maxBytes: Int,
        maxLineBytes: Int,
        output: LockedData,
        overflow: AtomicFlag,
        failure: LockedFailure,
        process: Process,
        requestID: String,
        onCredentialUpdate: @escaping @Sendable (Data) throws -> Void
    ) {
        var remainder = Data()
        var terminalSeen = false
        while true {
            let chunk = handle.readData(ofLength: 8192)
            if chunk.isEmpty { break }
            guard output.append(chunk, limit: maxBytes) else {
                overflow.set()
                terminateOwned(process)
                break
            }
            remainder.append(chunk)
            while let newline = remainder.firstIndex(of: 0x0A) {
                let line = Data(remainder[..<newline])
                remainder.removeSubrange(...newline)
                do {
                    guard line.count <= maxLineBytes else { throw WorkerTransportError.outputLimit }
                    let event = try decodeEvent(line, requestID: requestID)
                    guard !terminalSeen else { throw WorkerTransportError.malformedOutput }
                    if event.name == "result" || event.name == "error" { terminalSeen = true }
                    if event.name == "credential_update" {
                        try onCredentialUpdate(event.payload)
                    }
                } catch {
                    failure.set(error)
                    terminateOwned(process)
                    try? handle.close()
                    return
                }
            }
            if remainder.count > maxLineBytes {
                failure.set(WorkerTransportError.outputLimit)
                terminateOwned(process)
                break
            }
        }
        if !remainder.isEmpty, failure.value == nil {
            failure.set(WorkerTransportError.malformedOutput)
        }
        try? handle.close()
    }

    private static func decodeEvent(_ line: Data, requestID: String) throws -> WorkerEvent {
        let known: Set<String> = ["ready", "progress", "credential_update", "result", "error", "auth_challenge"]
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let version = object["protocol_version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let id = object["request_id"] as? String, id == requestID,
              let name = object["event"] as? String, known.contains(name) else {
            throw WorkerTransportError.malformedOutput
        }
        guard name != "auth_challenge" else { throw WorkerTransportError.unexpectedEvent }
        let payload: Any
        if let embedded = object["payload"] {
            payload = embedded
        } else if name == "credential_update", let bundle = object["credential_bundle"] {
            payload = ["credential_bundle": bundle]
        } else if name == "error", let code = object["code"] as? String {
            var errorPayload: [String: Any] = ["code": code]
            if let retry = object["retry_after_ms"] { errorPayload["retry_after_ms"] = retry }
            payload = errorPayload
        } else {
            throw WorkerTransportError.malformedOutput
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw WorkerTransportError.malformedOutput
        }
        return WorkerEvent(requestID: id, name: name, payload: payloadData)
    }

    static func parse(_ data: Data, requestID: String, maxLineBytes: Int) throws -> [WorkerEvent] {
        guard !data.isEmpty else { throw WorkerTransportError.missingTerminal }
        guard data.last == 0x0A else { throw WorkerTransportError.malformedOutput }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var events: [WorkerEvent] = []
        var terminalCount = 0
        for (index, line) in lines.enumerated() {
            if index == lines.count - 1 && line.isEmpty { continue }
            guard terminalCount == 0 else { throw WorkerTransportError.malformedOutput }
            guard !line.isEmpty else { throw WorkerTransportError.malformedOutput }
            guard line.count <= maxLineBytes else { throw WorkerTransportError.outputLimit }
            let event = try decodeEvent(Data(line), requestID: requestID)
            let name = event.name
            if name == "result" || name == "error" { terminalCount += 1 }
            if name != "credential_update" { events.append(event) }
        }
        guard terminalCount == 1 else {
            throw terminalCount == 0 ? WorkerTransportError.missingTerminal : WorkerTransportError.malformedOutput
        }
        guard let terminal = events.last, terminal.name == "result" || terminal.name == "error" else {
            throw WorkerTransportError.malformedOutput
        }
        if terminal.name == "error" {
            let payload = (try? JSONSerialization.jsonObject(with: terminal.payload)) as? [String: Any]
            let retryAfterMS = (payload?["retry_after_ms"] as? NSNumber)?.int64Value
                ?? (payload?["retry_after_seconds"] as? NSNumber).map { $0.int64Value * 1_000 }
            throw ProviderFailure.fromWorkerCode(payload?["code"] as? String, retryAfterMS: retryAfterMS)
        }
        return events
    }

    private actor WorkerRequestGate {
        private var held = false
        private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

        /// Returns false when the waiting task was cancelled before acquiring the gate.
        func acquire() async -> Bool {
            if Task.isCancelled { return false }
            if !held {
                held = true
                return true
            }
            let id = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    waiters.append((id, continuation))
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }

        private func cancelWaiter(_ id: UUID) {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
            waiters.remove(at: index).continuation.resume(returning: false)
        }

        func release() {
            if waiters.isEmpty {
                held = false
            } else {
                waiters.removeFirst().continuation.resume(returning: true)
            }
        }
    }

    private struct WorkerLaunch {
        let executableURL: URL
        let arguments: [String]
        let workingDirectory: URL
    }

    private static func workerLaunch(configuredWorkingDirectory: URL?) -> WorkerLaunch? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["TAGTRAIL_WORKER_PATH"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return WorkerLaunch(
                    executableURL: url, arguments: [],
                    workingDirectory: configuredWorkingDirectory ?? defaultSupportDirectory()
                )
            }
        }

        if let root = developmentProjectRoot() {
            let pythonCandidates = [
                root.appendingPathComponent(".venv/bin/python"),
                root.appendingPathComponent("worker/.venv/bin/python")
            ]
            if let python = pythonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
                return WorkerLaunch(executableURL: python, arguments: ["-m", "worker"], workingDirectory: root)
            }
        }
        #endif

        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("worker/tagtrail-worker"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/worker/tagtrail-worker"),
            Bundle.main.resourceURL?.appendingPathComponent("worker/TagTrailWorker"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/worker/TagTrailWorker"),
            Bundle.main.resourceURL?.appendingPathComponent("TagTrailWorker")
        ].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return nil
        }
        return WorkerLaunch(
            executableURL: executable, arguments: [],
            workingDirectory: configuredWorkingDirectory ?? defaultSupportDirectory()
        )
    }

    private static func developmentProjectRoot() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let root = ProcessInfo.processInfo.environment["TAGTRAIL_PROJECT_ROOT"], !root.isEmpty {
            candidates.append(URL(fileURLWithPath: root, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent())
        for candidate in candidates {
            var directory = candidate.standardizedFileURL
            for _ in 0..<8 {
                let workerEntry = directory.appendingPathComponent("worker/__main__.py")
                if fileManager.fileExists(atPath: workerEntry.path) { return directory }
                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path { break }
                directory = parent
            }
        }
        return nil
    }

    private static func defaultSupportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TagTrail", isDirectory: true)
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return storage }
    func set() { lock.lock(); storage = true; lock.unlock() }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: Data, limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard storage.count + value.count <= limit else { return false }
        storage.append(value)
        return true
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func add(_ value: Int, limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        storage += value
        return storage <= limit
    }
}

private final class LockedFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Error?
    var value: Error? { lock.lock(); defer { lock.unlock() }; return storage }
    func set(_ error: Error) { lock.lock(); storage = error; lock.unlock() }
}

private extension ProviderFailure {
    static func fromWorkerCode(_ code: String?, retryAfterMS: Int64? = nil) -> ProviderFailure {
        switch code {
        case "authentication_required", "authentication-required": .authenticationRequired
        case "credentials_locked", "credentials-locked": .credentialsLocked
        case "unsupported_device", "unsupported-device": .unsupportedDevice
        case "rate_limited", "rate-limited":
            .rateLimited(until: retryAfterMS.map { Date().addingTimeInterval(max(0, Double($0) / 1000)) })
        case "network_unavailable", "network-unavailable": .networkUnavailable
        case "timeout": .timeout
        case "decryption_error", "decryption-error": .decryptionError
        case "protocol_error", "protocol-error": .protocolError
        default: .internalError
        }
    }
}
