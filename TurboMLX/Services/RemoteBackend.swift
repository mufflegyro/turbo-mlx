import Foundation
import CryptoKit

/// Runs the models on a TurboRelay server across the network — a more powerful Mac on the
/// LAN — while speaking the engine's own JSON-lines vocabulary on this side and the wire
/// protocol on the other (TurboRelay/docs/remote-protocol.md). The app cannot tell the
/// difference:
///
/// - commands go out translated: model paths stripped (the server resolves them from its own
///   cache, A2), `output` dropped, reference images and LoRAs uploaded as content-addressed
///   handles (A1)
/// - events come back translated into local form: `preview` frames written to temp files,
///   `done` results fetched to the output path the job asked for, engine stderr appended to
///   the log, the server's memory reported as the backend's (A4)
/// - model downloads go to the server (`GET /models`, download endpoints, M3), with their
///   progress surfaced per model for the picker
@Observable
final class RemoteBackend: EngineTransport {
    private(set) var status: BackendController.Status = .stopped
    private(set) var info: BackendInfo?
    private(set) var loadedModelPath: String?
    private(set) var log = LogBuffer()
    /// Set by stopWorker: no automatic reconnection after that.
    private var shuttingDown = false
    private var reconnectAttempt = 0

    var onReady: (() -> Void)?
    var onEvent: ((WorkerEvent) -> Void)?
    var onCrash: ((String) -> Void)?
    /// The connection dropped (Wi-Fi blip, sleep). Jobs keep running server-side; the
    /// transport reconnects on its own and delivers the results by job id. The app must NOT
    /// treat this as a crash: the queue survives.
    var onDisconnected: ((String) -> Void)?
    /// Model-download progress from the server, for the model picker.
    var onModelStatesChange: (() -> Void)?
    /// The families the render Mac runs, from its ready event (A5).
    private(set) var serverFamilies: [String] = []
    /// True when the render Mac's catalog version differs from this app's (pitfall 11).
    private(set) var serverCatalogVersion: String?
    var catalogDrift: Bool {
        guard let serverCatalogVersion, !serverCatalogVersion.isEmpty else { return false }
        return serverCatalogVersion != Self.localCatalogVersion
    }

    struct ModelState {
        var state: String
        var bytes: Int64
        var total: Int64
        var message: String?
    }
    @ObservationIgnored private(set) var modelStates: [String: ModelState] = [:]
    /// The Quality mode's files (LTX-2's dev transformer), tracked beside the model's own
    /// state: `quality_state` in /models, and `model_download` events tagged `quality`.
    @ObservationIgnored private(set) var qualityStates: [String: ModelState] = [:]
    /// Tracked bump: rows read this (through `AppModel.remoteModelState`) so a download's
    /// progress or failure repaints the picker — `modelStates` itself is untracked because
    /// it is mutated on background queues.
    private(set) var statesRevision = 0

    private func bumpStatesRevision() {
        statesRevision &+= 1
    }

    private let serverURL: URL
    private let token: String
    private let session: URLSession
    private var webSocket: URLSessionWebSocketTask?
    /// Where each job's result lands locally: the `output` path of its command.
    @ObservationIgnored private var outputPaths: [String: URL] = [:]
    private let lock = NSLock()

    init(serverURLString: String, token: String) {
        var string = serverURLString.trimmingCharacters(in: .whitespaces)
        if !string.contains("://") { string = "http://" + string }
        serverURL = URL(string: string) ?? URL(string: "http://127.0.0.1:7700")!
        self.token = token
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        session = URLSession(configuration: configuration)
    }

    /// A stable local alias for a model that lives on the server: `installed` entries and
    /// `loadedModelPath` compare these, and commands carrying them are stripped on the wire.
    static func pseudoPath(_ id: String) -> String { "/TurboRelay/models/\(id)" }

    var base: URL { serverURL }

    private func url(_ path: String) -> URLRequest {
        var request = URLRequest(url: serverURL.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - EngineTransport

    var isRunning: Bool { webSocket != nil }

    func ensureWorker() {
        guard webSocket == nil else { return }
        shuttingDown = false
        status = .starting
        var request = URLRequest(url: serverURL.appending(path: "engine"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        webSocket = task
        task.resume()
        receiveNext(on: task)
        // The keepalive starts once the handshake has settled (spec §Transport): a ping sent
        // into the handshake would hang the upgrade on some stacks.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.webSocket != nil else { return }
            self.ping()
        }
    }

    func stopWorker() {
        shuttingDown = true
        closeSocket()
        loadedModelPath = nil
        if status == .ready || status == .starting || status == .checking { status = .stopped }
    }

    func restartWorker() {
        stopWorker()
        shuttingDown = false
        ensureWorker()
    }

    func unloadModel() {
        try? send(.unload)
    }

    func send(_ command: WorkerCommand) throws {
        guard webSocket != nil else { throw BackendController.BackendError.notRunning }
        switch command {
        case .cancel, .unload:
            sendRaw(command.jsonLine)
        case .shutdown:
            break // reserved to the server (spec §Commands)
        case .load:
            var wire = try Self.wireCommand(from: command)
            Task { [weak self] in
                guard let self, let line = try? await self.translateInputs(of: &wire) else { return }
                self.sendRaw(line)
            }
        case .generate(let jobID, _, _, _, _, let output, _, _):
            var wire = try Self.wireCommand(from: command)
            rememberOutput(jobID.uuidString, output)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let line = try await translateInputs(of: &wire)
                    sendRaw(line)
                } catch {
                    forgetOutput(jobID.uuidString)
                    emitFailure(jobID: jobID.uuidString, message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Model catalog and downloads (M3)

    /// The server's catalog with per-model download state, for the model picker. Also records
    /// the server's catalog version, so the app can warn about drift (pitfall 11).
    func fetchModels() async throws -> [[String: Any]] {
        let (data, response) = try await session.data(for: url("models"))
        try Self.checkHTTP(response)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            throw RelayClientError.badResponse
        }
        if let version = object["catalog_version"] as? String {
            serverCatalogVersion = version == "unavailable" ? nil : version
        }
        seedModelStates(from: models)
        return models
    }

    /// Seed the picker's per-model states (M3): rows need a state to show the Download
    /// button, and no model_download event has arrived yet on a fresh connection.
    private func seedModelStates(from models: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for entry in models {
            guard let id = entry["id"] as? String, let state = entry["state"] as? String else { continue }
            if modelStates[id]?.state == "downloading", state != "downloaded", state != "failed" {
                continue // a live event's byte progress outranks the polled snapshot
            }
            // The polled snapshot must not clear a failure: the readable error would flash
            // for one frame and vanish (the user then cannot act on it). It clears only
            // when the download actually restarts (a "downloading" event) or succeeds.
            if modelStates[id]?.state == "failed", state == "not-downloaded" {
                continue
            }
            modelStates[id] = ModelState(
                state: state,
                bytes: (entry["bytes_done"] as? NSNumber)?.int64Value ?? 0,
                total: (entry["bytes_total"] as? NSNumber)?.int64Value ?? 0,
                message: entry["error"] as? String
            )
            if let quality = entry["quality_state"] as? String {
                let live = qualityStates[id]?.state
                // The same rule as the model's state: a live progress or a readable failure
                // outranks the polled snapshot, which would otherwise flash past.
                let keepLive = live == "downloading" && quality != "downloaded" && quality != "failed"
                let keepFailure = live == "failed" && quality == "not-downloaded"
                if !keepLive && !keepFailure {
                    qualityStates[id] = ModelState(state: quality, bytes: 0, total: 0, message: nil)
                }
            }
            changed = true
        }
        if changed { bumpStatesRevision() }
    }

    /// This app's own catalog version, computed exactly like the server's.
    static var localCatalogVersion: String {
        let joined = ModelCatalog.builtIn
            .map { "\($0.id)|\($0.family.rawValue)|\($0.revision ?? "main")" }
            .sorted()
            .joined(separator: "\n")
        return String(SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    func downloadModel(_ model: ModelDescriptor) throws {
        guard webSocket != nil else { throw BackendController.BackendError.notRunning }
        let encoded = model.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model.id
        Task { [weak self] in
            guard let self else { return }
            do {
                var request = self.url("models/\(encoded)/download")
                request.httpMethod = "POST" // the server routes downloads by verb (GET is its 404)
                // The descriptor travels with the request: a model added by hand (a custom
                // repository) is not in the relay's built-in catalog, and this is how the
                // server learns what to download.
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(model)
                let (data, response) = try await self.session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                        ?? "the server refused the download"
                    self.failDownload(id: model.id, message: message)
                }
            } catch {
                self.failDownload(id: model.id, message: error.localizedDescription)
            }
        }
    }

    func downloadQuality(_ model: ModelDescriptor) throws {
        guard webSocket != nil else { throw BackendController.BackendError.notRunning }
        let encoded = model.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model.id
        Task { [weak self] in
            guard let self else { return }
            do {
                var request = self.url("models/\(encoded)/download/quality")
                request.httpMethod = "POST"
                let (data, response) = try await self.session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                        ?? "the server refused the download"
                    self.failDownload(id: model.id, message: message, quality: true)
                } else {
                    // Accepted: show the download at once, before the listing's first event, but
                    // never undo a state that already arrived (or the files already there). An
                    // `already` answer means there is nothing left to fetch and no event will come.
                    let responseObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    self.noteQualityAccepted(id: model.id,
                                             already: (responseObject?["already"] as? Bool) == true)
                }
            } catch {
                self.failDownload(id: model.id, message: error.localizedDescription, quality: true)
            }
        }
    }

    /// The server accepted a Quality download: reflect it before its first event.
    private func noteQualityAccepted(id: String, already: Bool) {
        lock.lock()
        if already {
            qualityStates[id] = ModelState(state: "downloaded", bytes: 0, total: 0, message: nil)
        } else {
            let current = qualityStates[id]?.state
            if current == nil || current == "not-downloaded" {
                qualityStates[id] = ModelState(state: "downloading", bytes: 0, total: 0, message: nil)
            }
        }
        lock.unlock()
        bumpStatesRevision()
        onModelStatesChange?()
    }

    /// A LoRA the render Mac has kept from a client's job, for another client to import.
    struct RemoteLoRA: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let bytes: Int64
        let family: String?
        let addedAt: Date?
    }

    /// The LoRAs the render Mac has kept from clients' jobs.
    func fetchLoRAs() async throws -> [RemoteLoRA] {
        let (data, response) = try await session.data(for: url("loras"))
        try Self.checkHTTP(response)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["loras"] as? [[String: Any]] else {
            throw RelayClientError.badResponse
        }
        return list.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let name = entry["name"] as? String else { return nil }
            return RemoteLoRA(
                id: id,
                name: name,
                bytes: (entry["bytes"] as? NSNumber)?.int64Value ?? 0,
                family: entry["family"] as? String,
                addedAt: (entry["added_at"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue)
                }
            )
        }
    }

    /// Streams a library LoRA to a temporary file named as it arrived, for `LoRALibrary.add`.
    /// `URLSession.download` writes to disk, so a multi-gigabyte adapter never sits in memory.
    func downloadLoRA(_ lora: RemoteLoRA) async throws -> URL {
        let (temporary, response) = try await session.download(for: url("loras/\(lora.id)"))
        try Self.checkHTTP(response)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurboMLX-LoRA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(Self.safeLoRAFileName(lora.name, fallback: lora.id))
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private static func safeLoRAFileName(_ raw: String, fallback: String) -> String {
        var name = (raw as NSString).lastPathComponent
        name = name.components(separatedBy: CharacterSet.controlCharacters).joined()
        if name.isEmpty || name == "." || name == ".." { name = fallback }
        if name.hasPrefix(".") { name = "LoRA-" + String(name.dropFirst()) }
        let stem = (name as NSString).deletingPathExtension
        return String(stem.prefix(160)) + ".safetensors"
    }

    func cancelModelDownload(id: String) {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        Task { [weak self] in
            guard let self else { return }
            var request = self.url("models/\(encoded)/download/cancel")
            request.httpMethod = "POST"
            _ = try? await self.session.data(for: request)
        }
    }

    // MARK: - Connection

    private func closeSocket() {
        lock.lock()
        let task = webSocket
        webSocket = nil
        lock.unlock()
        task?.cancel(with: .goingAway, reason: nil)
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self, weak task] result in
            guard let self, let current = task, current === self.webSocket else { return }
            switch result {
            case .success(.string(let text)):
                self.handle(line: text)
                self.receiveNext(on: current)
            case .success(.data(let data)):
                self.handle(line: String(decoding: data, as: UTF8.self))
                self.receiveNext(on: current)
            case .failure(let error):
                self.connectionClosed(error.localizedDescription)
            default:
                self.connectionClosed("the server closed the connection")
            }
        }
    }

    private func ping() {
        guard webSocket != nil else { return }
        webSocket?.sendPing { [weak self] error in
            guard let self else { return }
            if error == nil {
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak self] in self?.ping() }
            }
        }
    }

    private func rememberOutput(_ id: String, _ url: URL) {
        lock.lock()
        outputPaths[id] = url
        lock.unlock()
    }

    private func forgetOutput(_ id: String) {
        lock.lock()
        outputPaths[id] = nil
        lock.unlock()
    }

    private func outputPath(_ id: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return outputPaths[id]
    }

    private func connectionClosed(_ reason: String) {
        lock.lock()
        let wasOpen = webSocket != nil
        webSocket = nil
        lock.unlock()
        guard wasOpen else { return }
        // A lost connection is NOT an engine crash: jobs keep running on the server and the
        // registry delivers their results on reconnect (spec §Job registry). The queue and
        // the loaded-model state survive; a backoff loop brings the transport back.
        status = .starting // reconnecting
        log.append("[relay] connection lost: \(reason)")
        onDisconnected?(reason)
        let delay = min(10.0, 1.0 * pow(2.0, Double(reconnectAttempt)))
        reconnectAttempt += 1
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.ensureWorker()
        }
    }

    // MARK: - Lines in (wire → engine vocabulary)

    private func handle(line: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let event = object["event"] as? String else {
            log.append(line)
            return
        }
        switch event {
        case "ready":
            info = BackendInfo(
                engine: object["engine"] as? String ?? "turbo-relay",
                mlx: object["mlx"] as? String ?? "?",
                device: object["device"] as? String ?? "Apple Silicon",
                memory: object["memory"] as? Int64 ?? 0
            )
            serverFamilies = object["families"] as? [String] ?? []
            reconnectAttempt = 0 // connected: the backoff starts over
            status = .ready
            reconcileJobs()
            onReady?()
        case "log":
            log.append(object["message"] as? String ?? "")
        case "model_download":
            handleModelDownload(object)
        case "model_loaded":
            // The wire names the model; the app tracks a stable local alias (A2).
            let name = object["name"] as? String ?? object["path"] as? String ?? ""
            var wire = object
            wire["path"] = Self.pseudoPath(name)
            reemit(wire)
            loadedModelPath = Self.pseudoPath(name)
        case "preview":
            translatePreview(object)
        case "done":
            translateDone(object)
        default:
            reemit(object)
        }
    }

    private func handleModelDownload(_ object: [String: Any]) {
        guard let id = object["model_id"] as? String else { return }
        let isQuality = object["quality"] as? Bool == true
        let state = ModelState(
            state: object["status"] as? String ?? "",
            bytes: (object["bytes"] as? NSNumber)?.int64Value ?? 0,
            total: (object["total"] as? NSNumber)?.int64Value ?? 0,
            message: object["message"] as? String
        )
        if state.state == "failed", let message = state.message {
            // Durable: the picker row can be refreshed away, the log keeps the reason.
            log.append("[relay] \(isQuality ? "Quality " : "")download of \(id) failed: \(message)")
        }
        lock.lock()
        if isQuality {
            qualityStates[id] = state
        } else {
            modelStates[id] = state
        }
        lock.unlock()
        bumpStatesRevision()
        onModelStatesChange?()
    }

    /// `preview` travels as base64 bytes (A3): write them where the app's image loader reads.
    private func translatePreview(_ object: [String: Any]) {
        let id = object["id"] as? String ?? "preview"
        let step = object["step"] as? Int ?? 0
        var wire = object
        var path: URL?
        if let data = object["data"] as? String, let bytes = Data(base64Encoded: data) {
            path = Self.previewURL(id: id, step: step)
            try? bytes.write(to: path!, options: .atomic)
        } else if let fileID = object["file_id"] as? String {
            path = Self.previewURL(id: id, step: step)
            Task { [weak self] in
                guard let self, let data = try? await self.fetchFile(fileID) else { return }
                try? data.write(to: path!, options: .atomic)
                self.reemitPreview(object, path: path!)
            }
            return
        }
        wire["path"] = path?.path
        wire.removeValue(forKey: "data")
        wire.removeValue(forKey: "file_id")
        reemit(wire)
    }

    private func reemitPreview(_ object: [String: Any], path: URL) {
        var wire = object
        wire["path"] = path.path
        wire.removeValue(forKey: "data")
        wire.removeValue(forKey: "file_id")
        reemit(wire)
    }

    /// `done` carries a `file_id` (A2): fetch the result and write it to the output path the
    /// job asked for, then hand the app a local `done` — history and metadata as usual.
    private func translateDone(_ object: [String: Any]) {
        let jobID = object["id"] as? String ?? ""
        guard let fileID = object["file_id"] as? String, let output = outputPath(jobID) else {
            reemit(object)
            return
        }
        deliverResult(Self.jsonLine(object), jobID: jobID, fileID: fileID, output: output, attempt: 1)
    }

    /// Fetches a finished result and hands the app a local `done`. A transient fetch failure
    /// retries with backoff and only fails the job after several tries — the result stays in
    /// the server's registry, so a later reconnect's reconcile can still deliver it (spec
    /// §Job registry).
    private func deliverResult(_ wireLine: String, jobID: String, fileID: String, output: URL, attempt: Int) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.fetchFile(fileID)
                try data.write(to: output, options: .atomic)
                guard let object = (try? JSONSerialization.jsonObject(with: Data(wireLine.utf8))) as? [String: Any] else { return }
                var wire = object
                wire["path"] = output.path
                wire.removeValue(forKey: "file_id")
                if let posterID = wire["poster_file_id"] as? String {
                    wire.removeValue(forKey: "poster_file_id")
                    if let poster = await self.writePoster(from: posterID, for: output) {
                        wire["poster"] = poster
                    }
                }
                self.forgetOutput(jobID)
                self.reemit(wire)
            } catch {
                if attempt < 3 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + Double(1 << attempt)) { [weak self] in
                        self?.deliverResult(wireLine, jobID: jobID, fileID: fileID, output: output, attempt: attempt + 1)
                    }
                } else {
                    self.emitFailure(jobID: jobID, message: "Couldn't fetch the result after several tries: \(error.localizedDescription). It stays on the render Mac until the next reconnect.")
                }
            }
        }
    }

    /// Fetches a staged poster and writes it beside the result as `<name>-poster.png`; returns
    /// its path for the `done` event. Nil when the poster was evicted or could not be written.
    private func writePoster(from posterID: String, for output: URL) async -> String? {
        guard let data = try? await fetchFile(posterID) else { return nil }
        let url = output.deletingLastPathComponent()
            .appendingPathComponent(output.deletingPathExtension().lastPathComponent + "-poster.png")
        do {
            try data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    /// A job may have finished while the connection was down: ask the registry (spec §Job
    /// registry and resume) and deliver what is waiting.
    private func reconcileJobs() {
        Task { [weak self] in
            guard let self else { return }
            guard let result = try? await self.session.data(for: self.url("jobs")) else { return }
            let (data, response) = result
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let jobs = object["jobs"] as? [[String: Any]] else { return }
            for job in jobs {
                guard job["status"] as? String == "done", let id = job["id"] as? String,
                      outputPaths[id] != nil else { continue }
                guard let fileID = job["file_id"] as? String else {
                    // The result was staged once but evicted before this client fetched it:
                    // say so instead of leaving the job hanging (spec §Files and staging).
                    emitFailure(jobID: id, message: "The result was evicted on the render Mac before it was fetched; run the job again.")
                    continue
                }
                if let data = try? await fetchFile(fileID) {
                    try? data.write(to: outputPaths[id]!, options: .atomic)
                    var wire: [String: Any] = ["event": "done", "id": id, "path": outputPaths[id]!.path]
                    for key in ["seed", "width", "height", "seconds", "peak_memory", "timings"] {
                        if let value = job[key] { wire[key] = value }
                    }
                    if let posterID = job["poster_file_id"] as? String,
                       let poster = await writePoster(from: posterID, for: outputPaths[id]!) {
                        wire["poster"] = poster
                    }
                    reemit(wire)
                    log.append("[relay] delivered the result of a job that finished while the connection was down.")
                }
            }
        }
    }

    // MARK: - Lines out (engine vocabulary → wire)

    /// Strips what the wire must not carry (A2) and turns local file paths into upload
    /// handles (A1). Runs off the main thread; uploads happen before the command is sent.
    private func translateInputs(of wire: inout [String: Any]) async throws -> String {
        if var model = wire["model"] as? [String: Any] {
            model.removeValue(forKey: "path")
            model.removeValue(forKey: "text_encoder_path")
            wire["model"] = model
        }
        guard var params = wire["params"] as? [String: Any] else {
            return Self.jsonLine(wire)
        }
        params.removeValue(forKey: "output")
        for key in ["image", "last_image"] {
            if let path = params[key] as? String {
                params[key] = ["upload": try await upload(path)]
            }
        }
        if let images = params["images"] as? [String] {
            var handles: [[String: String]] = []
            for image in images { handles.append(["upload": try await upload(image)]) }
            params["images"] = handles
        }
        if let loras = params["loras"] as? [[String: Any]] {
            var translated: [[String: Any]] = []
            for lora in loras {
                guard let path = lora["path"] as? String else { continue }
                // The engine's LoRA loader keys off the file extension (only .safetensors is
                // accepted), and the upload is content-addressed by a bare hex name. Carry the
                // original filename so the server can stage the LoRA under a real extension.
                let name = URL(fileURLWithPath: path).lastPathComponent
                translated.append(["upload": try await upload(path), "scale": lora["scale"] ?? 1, "name": name])
            }
            params["loras"] = translated
        }
        wire["params"] = params
        return Self.jsonLine(wire)
    }

    /// Uploads one local file, content-addressed: probe first, then the bytes (spec §Uploads).
    private func upload(_ path: String) async throws -> String {
        let file = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // Streamed hash and streamed upload: LoRAs can be hundreds of MB and must never sit
        // in memory whole.
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        var probe = url("upload/probe")
        probe.httpMethod = "POST"
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.httpBody = try JSONSerialization.data(withJSONObject: ["sha256": hex, "size": handle.seekToEnd()])
        guard let (probeData, probeResponse) = try? await session.data(for: probe),
              let http = probeResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = (try? JSONSerialization.jsonObject(with: probeData)) as? [String: Any],
              object["exists"] as? Bool == true else {
            var put = url("upload/\(hex)")
            put.httpMethod = "PUT"
            let (_, response) = try await session.upload(for: put, fromFile: file)
            try Self.checkHTTP(response)
            return hex
        }
        return hex // the server has these bytes already
    }

    private func fetchFile(_ fileID: String) async throws -> Data {
        let (data, response) = try await session.data(for: url("files/\(fileID)"))
        try Self.checkHTTP(response)
        return data
    }

    private func sendRaw(_ line: String) {
        webSocket?.send(.string(line)) { [weak self] error in
            if let error { self?.log.append("[relay] send failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Helpers

    private func emitFailure(jobID: String, message: String) {
        log.append("[relay] \(message)")
        reemit(["event": "failed", "id": jobID, "message": message])
    }

    private func failDownload(id: String, message: String, quality: Bool = false) {
        log.append("[relay] \(quality ? "Quality " : "")download of \(id) failed: \(message)")
        lock.lock()
        let state = ModelState(state: "failed", bytes: 0, total: 0, message: message)
        if quality {
            qualityStates[id] = state
        } else {
            modelStates[id] = state
        }
        lock.unlock()
        bumpStatesRevision()
        onModelStatesChange?()
    }

    private func reemit(_ object: [String: Any]) {
        if let event = WorkerEvent.parse(Self.jsonLine(object)) {
            onEvent?(event)
        }
    }

    private static func jsonLine(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The engine-vocabulary command as the app composed it, as a mutable dictionary.
    static func wireCommand(from command: WorkerCommand) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(command.jsonLine.utf8))) as? [String: Any] else {
            throw BackendController.BackendError.notRunning
        }
        return object
    }

    static func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw RelayClientError.http(http.statusCode)
        }
    }

    static func previewURL(id: String, step: Int) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TurboMLX-Previews", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(id)-\(step).png")
    }
}

enum RelayClientError: LocalizedError {
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(let status): "The render Mac answered \(status)."
        case .badResponse: "The render Mac sent an unexpected answer."
        }
    }
}
