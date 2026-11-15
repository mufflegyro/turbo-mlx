import AppKit
import Foundation
import Observation

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var offersLog = false
}

/// App-wide state: model catalog, generation settings, the job queue and the history.
@Observable
final class AppModel {
    /// What the image viewer shows: the job in progress / latest result, a picked history item, a
    /// picked job (running or queued), or the frame of the next generation (the "+" after the history).
    enum ViewerSelection: Hashable {
        case live
        case item(HistoryItem.ID)
        case job(GenerationJob.ID)
        case draft
    }

    /// Why "Generate" is not available right now.
    enum Blocker: Equatable {
        case noModel
        case modelNotDownloaded
        case modelDownloading
        case missingReference
        case emptyPrompt
        case emptyLyrics
        case upscaleTooLarge
        /// LTX's Quality mode needs its dev transformer, downloaded apart (`ModelFamily.qualityFiles`).
        case qualityNotDownloaded
        case qualityDownloading
        /// The LoRA chosen for the model is not in the library any more, or not for this model.
        case loraMissing(String)
        case loraMismatch(String, base: String)
        /// The generation should need more memory than the render Mac can give (`MemoryEstimate`):
        /// about `needed` GB, and what would bring it within reach.
        case notEnoughMemory(needed: Int, machine: String, remedy: String)

        var hint: String {
            switch self {
            case .noModel: "Choose a model."
            case .modelNotDownloaded: "Download the model to get started."
            case .modelDownloading: "Waiting for the download to finish."
            case .missingReference: "Add the picture to edit."
            case .emptyPrompt: "Write a prompt."
            case .emptyLyrics: "Write the lyrics, or turn on Instrumental."
            case .upscaleTooLarge: "Choose a smaller scale: at most 4096 × 4096 pixels."
            case .qualityNotDownloaded: "Quality runs the full model: download its files once."
            case .qualityDownloading: "Waiting for the Quality files to download."
            case .loraMissing(let name): "The LoRA \(name) is no longer among your LoRAs: add it again, or choose None."
            case .loraMismatch(let name, let base): "The LoRA \(name) is for \(base), not this model: choose another one, or None."
            case .notEnoughMemory(let needed, let machine, let remedy):
                "Needs about \(needed) GB of memory, more than \(machine) can give: \(remedy)."
            }
        }
    }

    private(set) var backend: any EngineTransport = AppModel.makeTransport()
    let downloads = DownloadCenter()
    let history = HistoryStore()
    let promptLibrary = PromptLibrary()

    /// Whether the models run here or on the render Mac (TurboRelay), from the settings.
    var isRemote: Bool { backend is RemoteBackend }

    static func makeTransport() -> any EngineTransport {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Keys.remoteEnabled),
           let address = defaults.string(forKey: Keys.remoteAddress), !address.isEmpty {
            return RemoteBackend(serverURLString: address, token: defaults.string(forKey: Keys.remoteToken) ?? "")
        }
        return BackendController()
    }

    /// Sets the render Mac and switches the transport live: jobs on the queue do not survive
    /// the switch, since the other side knows nothing of them.
    func applyTransport(enabled: Bool, address: String, token: String) {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Keys.remoteEnabled)
        defaults.set(address, forKey: Keys.remoteAddress)
        defaults.set(token, forKey: Keys.remoteToken)
        downloads.cancelAll()
        removeServerModels()
        backend.stopWorker()
        backend = Self.makeTransport()
        activeJob = nil
        queue.removeAll()
        preloadRequested = nil
        installed = [:]
        bytesOnDisk = [:]
        // The mflux families run only on the render Mac: switching back to this Mac's engine
        // must not leave one selected, out of the picker and impossible to run.
        if !isRemote, let selected = selectedModel, selected.family.engine == .mflux {
            selectedModelID = ModelCatalog.defaultModelID
        }
        connectTransport()
        refreshInstalled()
        queueChanged()
        backend.ensureWorker()
    }

    var remoteAddress: String { UserDefaults.standard.string(forKey: Keys.remoteAddress) ?? "" }
    var remoteToken: String { UserDefaults.standard.string(forKey: Keys.remoteToken) ?? "" }
    var remoteEnabled: Bool { UserDefaults.standard.bool(forKey: Keys.remoteEnabled) }

    /// The memory the render Mac reports (A4): in remote mode the gate judges the M4 Max's
    /// RAM, not this Mac's — the server still re-checks authoritatively.
    var renderMemoryGB: Double {
        if isRemote, let bytes = backend.info?.memory, bytes > 0 {
            return Double(bytes) / Double(1 << 30)
        }
        return MemoryEstimate.installedGigabytes
    }

    /// Per-backend history (A7): a faster render Mac's times must not skew the promises this
    /// Mac makes on its Generate button, and the other way round.
    var estimateHistory: [HistoryItem] {
        let remote = isRemote
        return history.items.filter { ($0.backend == "relay") == remote }
    }

    private func connectTransport() {
        // The transports deliver their callbacks on their own queues (URLSession's, for the
        // relay; a process pipe's, for the local engine). Everything here lives on the main
        // actor, so each callback hops there first — reading `pendingJobs` off the main queue
        // trips Swift's main-actor assertion (SIGTRAP) when a download event arrives.
        backend.onReady = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                preloadRequested = nil
                refreshInstalled() // the render Mac's downloaded models become available (M3)
                pump()
                preloadIfUseful()
            }
        }
        backend.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        backend.onCrash = { [weak self] reason in
            Task { @MainActor [weak self] in self?.backendCrashed(reason) }
        }
        if let remote = backend as? RemoteBackend {
            remote.onModelStatesChange = { [weak self] in
                Task { @MainActor [weak self] in self?.transportStatesChanged() }
            }
            remote.onDisconnected = { [weak self] reason in
                Task { @MainActor [weak self] in self?.backendDisconnected(reason) }
            }
        }
    }

    /// Download progress from the server changed: refresh availability, and generate when the
    /// user asked to download-and-generate and the model just arrived.
    private func transportStatesChanged() {
        guard let remote = backend as? RemoteBackend else { return }
        refreshInstalled()
        var changed = false
        for (id, state) in remote.modelStates where state.state == "downloaded" && generateAfterDownload == id {
            generateAfterDownload = nil
            changed = true
        }
        // The Quality mode's files have their own state on the render Mac; the same finish and
        // failure paths as a local Quality download apply.
        var qualityReady: String?
        for (id, state) in remote.qualityStates {
            switch state.state {
            case "downloaded" where generateAfterQuality == id:
                generateAfterQuality = nil
                qualityReady = id
            case "failed":
                if reportedQualityFailures.insert(id).inserted, let message = state.message {
                    alert = AppAlert(title: "Couldn’t download the Quality files",
                                     message: message, offersLog: true)
                }
            case "downloading":
                reportedQualityFailures.remove(id)
            default:
                break
            }
        }
        queueChanged()
        if let id = qualityReady, selectedModelID == id,
           let model = selectedModel, !settings.trimmedPrompt.isEmpty || !model.family.takesPrompt {
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            generate()
        } else if changed, let model = selectedModel, !settings.trimmedPrompt.isEmpty || !model.family.takesPrompt {
            generate()
        }
    }
    let loraLibrary = LoRALibrary()
    #if !SEALED
    let updater = AppUpdater()
    #endif

    private(set) var models: [ModelDescriptor]
    private(set) var installed: [String: URL] = [:]
    /// Models listed by the relay that this app's own catalog does not have (added by hand on
    /// the server): shown in remote mode, dropped when this Mac runs its own engine.
    @ObservationIgnored private var serverModelIDs: Set<String> = []
    /// Bytes each Hugging Face repository of the list (companions too) takes in the cache, partial
    /// downloads included: what moving a model to the Trash frees. Measured with `installed`.
    private(set) var bytesOnDisk: [String: Int64] = [:]
    /// Installed models that also have the Quality mode's files (`ModelFamily.qualityFiles`).
    private(set) var qualityInstalled: Set<String> = []
    /// Model to generate with once its Quality files are downloaded.
    @ObservationIgnored private var generateAfterQuality: String?
    /// Remote Quality downloads already reported, so one failure does not alert on every
    /// state refresh (cleared when a download starts again).
    @ObservationIgnored private var reportedQualityFailures: Set<String> = []
    let locator = ModelLocator()
    /// The hub cache the models are kept in (Settings → Models), as `ModelFolder` has it.
    private(set) var modelsFolder = ModelFolder.hubCache

    var selectedModelID: String {
        didSet {
            UserDefaults.standard.set(selectedModelID, forKey: Keys.selectedModel)
            if controlsSource == .draft { storeDraft() }
            if selectedModelID != oldValue {
                preloadDeclined = false
                preloadIfUseful()
            }
            guard selectedModelID != oldValue, let model = selectedModel else { return }
            let previous = models.first(where: { $0.id == oldValue })
            // Only the draft edits a model's settings; a history item shows a snapshot and must
            // not overwrite what the model was last run with.
            if controlsSource == .draft {
                if let previous {
                    modelTunings[previous.id] = ModelTuning(steps: settings.steps,
                                                            guidance: settings.guidance,
                                                            negativePrompt: settings.negativePrompt)
                    storeModelTunings()
                }
                if let saved = modelTunings[model.id] {
                    var restored = settings
                    restored.steps = saved.steps
                    restored.guidance = saved.guidance
                    restored.negativePrompt = saved.negativePrompt
                    settings = restored
                    return
                }
            }
            let needsDefaults = previous.map { prior in
                prior.family != model.family
                    || prior.defaultSteps(quality: settings.fullPipeline(for: prior))
                        != model.defaultSteps(quality: settings.fullPipeline(for: model))
            } ?? true
            guard needsDefaults else { return }
            // A model without a remembered tuning starts from the family's defaults: steps and
            // guidance mean different things across families.
            let quality = settings.fullPipeline(for: model)
            settings.steps = model.defaultSteps(quality: quality)
            settings.guidance = model.defaultGuidance(quality: quality)
        }
    }

    var settings: GenerationSettings {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) {
                UserDefaults.standard.set(data, forKey: Keys.settings)
            }
            if controlsSource == .draft { storeDraft() }
            preloadIfUseful()
        }
    }

    /// Where the controls' settings come from: the draft behind the "+", which keeps every change
    /// made to it, or a history item being looked at, whose settings are only shown.
    enum ControlsSource: Equatable {
        case draft
        case item
    }

    private(set) var controlsSource = ControlsSource.draft

    /// The settings and model the "+" brings back, as last changed there (saved across launches).
    @ObservationIgnored private var draft: (settings: GenerationSettings, modelID: String)?

    /// The few settings that belong to a model rather than to the draft: steps, guidance and the
    /// negative prompt. The defaults are not always what a model wants (MOSS-Image at guidance 3,
    /// then a LoRA, is the example), so picking a model brings back what it was last run with.
    /// LoRAs already stick per family in the settings themselves.
    private struct ModelTuning: Codable, Equatable {
        var steps: Int
        var guidance: Double
        var negativePrompt: String
    }

    @ObservationIgnored private var modelTunings: [String: ModelTuning] = [:]

    private func storeDraft() {
        draft = (settings, selectedModelID)
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Keys.draftSettings) }
        defaults.set(selectedModelID, forKey: Keys.draftModel)
    }

    private func storeModelTunings() {
        if let data = try? JSONEncoder().encode(modelTunings) {
            UserDefaults.standard.set(data, forKey: Keys.modelTunings)
        }
    }

    /// Model path the worker was asked to load ahead of time, so the request is not repeated.
    private var preloadRequested: String?
    /// Set when the user frees the memory: no preloading until the model changes or an image runs.
    @ObservationIgnored private var preloadDeclined = false
    @ObservationIgnored private var preloadScheduled = false

    private(set) var queue: [GenerationJob] = []
    private(set) var activeJob: GenerationJob?
    var viewer = ViewerSelection.live
    var alert: AppAlert?
    /// Model to generate with as soon as its download completes ("Download and Generate").
    private(set) var generateAfterDownload: String?
    @ObservationIgnored private var started = false
    /// A queue left running when the user walks away finishes instead of waiting for the Mac to wake.
    @ObservationIgnored private let awake = KeepAwake(reason: "Generating images and videos")

    private enum Keys {
        static let settings = "generationSettings"
        static let selectedModel = "selectedModelID"
        static let customModels = "customModels"
        static let draftSettings = "draftSettings"
        static let draftModel = "draftModelID"
        static let modelTunings = "modelTunings"
        static let historyOrder = "historyOrder"
        static let remoteEnabled = "remoteEnabled"
        static let remoteAddress = "remoteAddress"
        static let remoteToken = "remoteToken"
    }

    /// How the strip arranges the history: by date, or as the user dragged it.
    var historyOrder: HistoryOrder = HistoryOrder(rawValue: UserDefaults.standard.string(forKey: Keys.historyOrder) ?? "") ?? .date {
        didSet { UserDefaults.standard.set(historyOrder.rawValue, forKey: Keys.historyOrder) }
    }

    /// The history item under the pointer in the strip, which a drag there moves.
    @ObservationIgnored var pointedHistoryItem: HistoryItem.ID?

    /// The strip's padlock: private history shown, and new generations kept there.
    var showsPrivateHistory = false

    /// The items the strip shows: the normal history, or the private one while the padlock is on.
    var visibleHistory: [HistoryItem] {
        history.items.filter { $0.inPrivateHistory == showsPrivateHistory }
    }

    /// The history left to right, as the strip shows it and ⌘[ ⌘] walk it.
    var arrangedHistory: [HistoryItem] {
        history.arranged(historyOrder).filter { $0.inPrivateHistory == showsPrivateHistory }
    }

    /// The padlock: switches which history the strip shows, and where the next generations go.
    func setPrivateHistory(_ on: Bool) {
        guard showsPrivateHistory != on else { return }
        showsPrivateHistory = on
        // The item being shown has left this list: follow the list now shown.
        if case .item = viewer { viewer = .live }
    }

    /// Moves an item between the normal and the private history.
    func setPrivate(_ item: HistoryItem, _ isPrivate: Bool) {
        history.setPrivate(item.id, isPrivate)
        guard isPrivate != showsPrivateHistory, case .item(let shown) = viewer, shown == item.id else { return }
        viewer = .live
    }

    /// A drag in the strip: `id` goes where `target` is, and the strip keeps the custom order from
    /// then on (a first drag starts it from the order by date).
    func moveHistoryItem(_ id: HistoryItem.ID, to target: HistoryItem.ID) {
        history.move(id, to: target, in: arrangedHistory)
        historyOrder = .custom
    }

    init() {
        let defaults = UserDefaults.standard
        let custom = defaults.data(forKey: Keys.customModels)
            .flatMap { try? JSONDecoder().decode([ModelDescriptor].self, from: $0) } ?? []
        let catalog = ModelCatalog.builtIn + custom
        let selectedID = defaults.string(forKey: Keys.selectedModel) ?? ModelCatalog.defaultModelID
        models = catalog
        selectedModelID = selectedID

        if let data = defaults.data(forKey: Keys.settings),
           let saved = try? JSONDecoder().decode(GenerationSettings.self, from: data) {
            settings = saved
        } else {
            settings = Self.initialSettings(for: catalog.first { $0.id == selectedID })
        }
        // The controls open on the draft, as the "+" left it.
        if let data = defaults.data(forKey: Keys.draftSettings),
           let saved = try? JSONDecoder().decode(GenerationSettings.self, from: data),
           let modelID = defaults.string(forKey: Keys.draftModel), catalog.contains(where: { $0.id == modelID }) {
            settings = saved
            selectedModelID = modelID
        }
        if let data = defaults.data(forKey: Keys.modelTunings),
           let saved = try? JSONDecoder().decode([String: ModelTuning].self, from: data) {
            modelTunings = saved
        }
        draft = (settings, selectedModelID)

        connectTransport()
        downloads.onFinish = { [weak self] in self?.downloadFinished($0) }
        downloads.onQualityFinish = { [weak self] in self?.qualityDownloadFinished($0) }
        refreshInstalled()
    }

    func start() async {
        guard !started else { return }
        started = true
        // A model remembered from another transport may not exist here: a relay's own model
        // in local mode, or a custom model that was removed. In remote mode the /models fetch
        // adds or resolves it.
        if !isRemote, !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = ModelCatalog.defaultModelID
        }
        history.load()
        promptLibrary.load()
        history.pruneReferences(keeping: [settings.referenceImage, settings.lastFrameImage].compactMap { $0 })
        loraLibrary.refresh()
        // The models folder and local model folders before the engine, which inherits the access
        // they open.
        ModelFolder.restore()
        modelsFolder = locator.hubCache
        FolderAccess.restore()
        refreshInstalled()
        backend.ensureWorker()
    }

    func shutdown() {
        downloads.cancelAll()
        backend.stopWorker()
    }

    // MARK: Models

    var selectedModel: ModelDescriptor? {
        models.first { $0.id == selectedModelID } ?? models.first
    }

    func isInstalled(_ model: ModelDescriptor) -> Bool { installed[model.id] != nil }

    /// The model the engine holds in memory, if it is one of the catalog's.
    var loadedModel: ModelDescriptor? {
        guard let path = backend.loadedModelPath else { return nil }
        return models.first { installed[$0.id]?.path == path }
    }

    /// The model being loaded ahead of time, until it is in memory (or the load fails).
    var loadingModel: ModelDescriptor? {
        guard let path = preloadRequested, path != backend.loadedModelPath else { return nil }
        return models.first { installed[$0.id]?.path == path }
    }

    func isLoaded(_ model: ModelDescriptor) -> Bool {
        guard let path = backend.loadedModelPath else { return false }
        return installed[model.id]?.path == path
    }

    /// Keeps the models in `folder` from now on (nil: the default one). The models are looked for
    /// there, and the engine starts again so that it inherits the access to the folder.
    func useModelsFolder(_ folder: URL?) throws {
        if let folder { try ModelFolder.choose(folder) } else { ModelFolder.useDefault() }
        modelsFolder = locator.hubCache
        refreshInstalled()
        if backend.isRunning { backend.restartWorker() }
    }

    func refreshInstalled() {
        if isRemote {
            refreshInstalledFromServer()
            return
        }
        var found: [String: URL] = [:]
        var bytes: [String: Int64] = [:]
        for model in models {
            if let url = locator.installedLocation(of: model) { found[model.id] = url }
            for repo in [model.repo, model.family.companion?.repo].compactMap(\.self) where bytes[repo] == nil {
                bytes[repo] = locator.bytesOnDisk(of: repo)
            }
        }
        installed = found
        bytesOnDisk = bytes
        qualityInstalled = Set(found.compactMap { id, url in
            guard let model = models.first(where: { $0.id == id }), !model.family.qualityFiles.isEmpty else { return nil }
            return model.family.qualityFiles.allSatisfy { FileManager.default.fileExists(atPath: url.appending(path: $0).path) } ? id : nil
        })
    }

    func hasQualityFiles(_ model: ModelDescriptor) -> Bool {
        if let remote = backend as? RemoteBackend {
            _ = remote.statesRevision // tracked: the Quality row repaints when the state lands
            return remote.qualityStates[model.id]?.state == "downloaded"
        }
        return qualityInstalled.contains(model.id)
    }

    /// The Quality files' download, locally or on the render Mac; nil when none is running.
    func qualityProgress(_ model: ModelDescriptor) -> DownloadCenter.Progress? {
        if let remote = backend as? RemoteBackend {
            _ = remote.statesRevision
            guard let state = remote.qualityStates[model.id], state.state == "downloading" else { return nil }
            return DownloadCenter.Progress(bytes: state.bytes, total: state.total)
        }
        return downloads.qualityProgress(model)
    }

    /// Remote mode: the server's catalog decides what is installed (M3). Each downloaded
    /// model gets a stable alias path (`RemoteBackend.pseudoPath`) that commands carry and
    /// the transport strips on the wire (A2/A6).
    private func refreshInstalledFromServer() {
        guard let remote = backend as? RemoteBackend else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await remote.fetchModels()
                mergeServerModels(entries)
                var found: [String: URL] = [:]
                for entry in entries {
                    guard let id = entry["id"] as? String, entry["state"] as? String == "downloaded" else { continue }
                    found[id] = URL(fileURLWithPath: RemoteBackend.pseudoPath(id))
                }
                installed = found
                qualityInstalled = []
                queueChanged()
            } catch {
                // Keep the previous availability; the connection may come back (spec §Job registry).
            }
        }
    }

    /// Adds the relay's own models (those this app's catalog does not ship) to the picker, and
    /// drops ones that are gone from the relay. A descriptor travels with each /models entry
    /// (A10), so a model added by hand on the render Mac is usable here without being added
    /// again. They exist only while the app is in remote mode.
    private func mergeServerModels(_ entries: [[String: Any]]) {
        guard isRemote else { return }
        var listed: [String: ModelDescriptor] = [:]
        for entry in entries {
            guard let object = entry["descriptor"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let descriptor = try? JSONDecoder().decode(ModelDescriptor.self, from: data),
                  !descriptor.isBuiltIn,
                  !ModelCatalog.builtIn.contains(where: { $0.id == descriptor.id })
            else { continue }
            listed[descriptor.id] = descriptor
        }
        // A model removed on the relay goes away here too.
        models.removeAll { serverModelIDs.contains($0.id) && listed[$0.id] == nil }
        serverModelIDs.formIntersection(listed.keys)
        for (id, var descriptor) in listed {
            // A model this app added itself keeps its own descriptor.
            if let index = models.firstIndex(where: { $0.id == id }) {
                guard serverModelIDs.contains(id) else { continue }
                descriptor.isBuiltIn = true
                models[index] = descriptor
            } else {
                descriptor.isBuiltIn = true
                models.append(descriptor)
                serverModelIDs.insert(id)
            }
        }
        if !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = ModelCatalog.defaultModelID
        }
    }

    /// Back on this Mac's engine: the relay's own models are not local models.
    private func removeServerModels() {
        guard !serverModelIDs.isEmpty else { return }
        let selectedWasServer = serverModelIDs.contains(selectedModelID)
        models.removeAll { serverModelIDs.contains($0.id) }
        serverModelIDs.removeAll()
        if selectedWasServer || !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = ModelCatalog.defaultModelID
        }
    }

    /// Download progress for the picker: the server's states in remote mode, DownloadCenter's
    /// locally.
    func isDownloading(_ model: ModelDescriptor) -> Bool {
        if let remote = backend as? RemoteBackend {
            _ = remote.statesRevision // tracked: callers repaint when states change
            return remote.modelStates[model.id]?.state == "downloading"
        }
        return downloads.isDownloading(model)
    }

    /// The server-reported download state for one model (from GET /models), for rows that
    /// have no `model_download` event yet. Reads the tracked revision first: download
    /// progress and failures land in the (untracked) states dictionary, and without this
    /// read the picker rows would never repaint.
    func remoteModelState(_ model: ModelDescriptor) -> RemoteBackend.ModelState? {
        guard let remote = backend as? RemoteBackend else { return nil }
        _ = remote.statesRevision
        return remote.modelStates[model.id]
    }

    /// The render Mac's model list differs from this app's: one of the two needs updating.
    var catalogDrift: Bool { (backend as? RemoteBackend)?.catalogDrift ?? false }

    /// The connection dropped. NOT a crash: jobs keep rendering on the render Mac, the queue
    /// stays, and the transport reconnects on its own — reconcileJobs then delivers whatever
    /// finished while the connection was down (spec §Job registry).
    func backendDisconnected(_ reason: String) {
        backend.log.append("[relay] \(reason)")
    }

    /// Downloads the Quality mode's files of the selected model, then generates with the current
    /// prompt unless it is empty.
    func downloadQuality(generating: Bool = true) {
        guard let model = selectedModel else { return }
        generateAfterQuality = generating && !settings.trimmedPrompt.isEmpty ? model.id : nil
        if let remote = backend as? RemoteBackend {
            // The render Mac downloads the Quality mode's files on top of the model it already
            // has (`POST /models/{id}/download/quality`), and its progress arrives as
            // `quality`-tagged model_download events.
            do {
                try remote.downloadQuality(model)
            } catch {
                generateAfterQuality = nil
                alert = AppAlert(title: "Couldn't reach the render Mac", message: error.localizedDescription, offersLog: true)
            }
            return
        }
        downloads.startQuality(model, locator: locator)
    }

    func cancelQualityDownload(_ model: ModelDescriptor) {
        if generateAfterQuality == model.id { generateAfterQuality = nil }
        if let remote = backend as? RemoteBackend {
            // One download runs at a time on the render Mac; its cancel route applies.
            remote.cancelModelDownload(id: model.id)
            return
        }
        downloads.cancelQuality(model)
        refreshInstalled()
    }

    /// Downloads the model (checking the disk has room for what is still missing first).
    func download(_ model: ModelDescriptor) {
        if let remote = backend as? RemoteBackend {
            do {
                try remote.downloadModel(model)
            } catch {
                alert = AppAlert(title: "Couldn't reach the render Mac", message: error.localizedDescription, offersLog: true)
            }
            return
        }
        downloads.start(model, locator: locator)
    }

    /// Downloads the selected model, then generates with the current prompt.
    func downloadAndGenerate() {
        guard let model = selectedModel else { return }
        let isEmpty = model.family.takesPrompt ? settings.trimmedPrompt.isEmpty : !hasReferenceImage
        generateAfterDownload = isEmpty ? nil : model.id
        download(model)
        if !isDownloading(model) { generateAfterDownload = nil }
    }

    func cancelDownload(_ model: ModelDescriptor) {
        if generateAfterDownload == model.id { generateAfterDownload = nil }
        if let remote = backend as? RemoteBackend {
            remote.cancelModelDownload(id: model.id)
            return
        }
        downloads.cancel(model)
        // What arrived stays, to resume from or to move to the Trash.
        refreshInstalled()
    }

    private func qualityDownloadFinished(_ model: ModelDescriptor) {
        refreshInstalled()
        let generateNow = generateAfterQuality == model.id && hasQualityFiles(model)
        generateAfterQuality = nil
        if let failure = downloads.qualityFailure(model) {
            alert = AppAlert(title: "Couldn’t download the Quality files of \(model.name)", message: failure, offersLog: true)
        } else if generateNow, selectedModelID == model.id {
            generate()
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    private func downloadFinished(_ model: ModelDescriptor) {
        refreshInstalled()
        let generateNow = generateAfterDownload == model.id
        if generateNow { generateAfterDownload = nil }
        if let failure = downloads.failures[model.id] {
            alert = AppAlert(title: "Couldn’t download \(model.name)", message: failure, offersLog: true)
        } else if generateNow, selectedModelID == model.id {
            generate()
        } else {
            preloadIfUseful()
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Frees the loaded model and stops loading it ahead of time until the model changes or an
    /// image is generated.
    func freeMemory() {
        preloadDeclined = true
        preloadRequested = nil
        backend.unloadModel()
    }

    /// Loads the selected model as soon as a prompt is being written, so that the first image
    /// starts at the prompt instead of at a 5–40 s load. Nothing happens while the worker is
    /// busy, when the model is already in memory, or after "Free Memory". An engine that is not
    /// running (stopped, or crashed) is brought up first.
    ///
    /// At most once every 1.5 s, for the model selected by then: clicking through the history
    /// switches models, and each switch would otherwise start loading one.
    private func preloadIfUseful() {
        guard !preloadScheduled else { return }
        preloadScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.preloadScheduled = false
            self?.preloadNow()
        }
    }

    private func preloadNow() {
        guard !preloadDeclined, activeJob == nil, queue.isEmpty, !settings.trimmedPrompt.isEmpty,
              let model = selectedModel, let location = installed[model.id]
        else { return }
        if !backend.isRunning {
            switch backend.status {
            case .stopped, .failed: backend.ensureWorker() // onReady comes back here
            default: break
            }
            return
        }
        guard backend.status == .ready, backend.loadedModelPath != location.path, preloadRequested != location.path
        else { return }
        preloadRequested = location.path
        try? backend.send(.load(model: model, modelPath: location.path, textEncoderPath: locator.companionLocation(of: model)?.path,
                                lowMemory: settings.lowMemory))
    }

    /// What moving a model to the Trash takes away: its repository in the Hugging Face cache and,
    /// when no other downloaded model needs it, its companion. Nil for a local folder, or when
    /// nothing of the model is on disk (a download stopped halfway counts).
    func downloadFiles(of model: ModelDescriptor) -> (repos: [String], bytes: Int64)? {
        guard let repo = model.repo, bytesOnDisk[repo, default: 0] > 0 else { return nil }
        var repos = [repo]
        if let companion = model.family.companion,
           !models.contains(where: { $0.id != model.id && $0.family.companion?.repo == companion.repo && isInstalled($0) }) {
            repos.append(companion.repo)
        }
        return (repos, repos.reduce(0) { $0 + bytesOnDisk[$1, default: 0] })
    }

    /// Not while the model is downloading or has images waiting to be generated.
    func canTrash(_ model: ModelDescriptor) -> Bool {
        !downloads.isDownloading(model) && !pendingJobs.contains { $0.model.id == model.id } && downloadFiles(of: model) != nil
    }

    /// Moves the model's files to the Trash, where they can still be put back until it is
    /// emptied; the model stays in the list, to be downloaded again.
    func trashDownload(of model: ModelDescriptor) {
        guard canTrash(model), let files = downloadFiles(of: model) else { return }
        if isLoaded(model) || loadingModel?.id == model.id {
            preloadRequested = nil
            backend.unloadModel()
        }
        var failure: String?
        for repo in files.repos {
            do {
                try FileManager.default.trashItem(at: locator.repoFolder(repo), resultingItemURL: nil)
            } catch {
                failure = failure ?? error.localizedDescription
            }
        }
        downloads.clearFailure(model)
        refreshInstalled()
        if let failure {
            alert = AppAlert(title: "Couldn’t move \(model.name) to the Trash", message: failure)
        }
    }

    func addCustomModel(_ model: ModelDescriptor) {
        models.removeAll { $0.id == model.id && !$0.isBuiltIn }
        guard !models.contains(where: { $0.id == model.id }) else {
            selectedModelID = model.id
            return
        }
        models.append(model)
        saveCustomModels()
        refreshInstalled()
        // A folder picked just now: the running engine started before its access was opened.
        // Restarted first, so the model is preloaded once, when the new engine is ready.
        if case .local = model.source, backend.isRunning, !isBusy { backend.restartWorker() }
        selectedModelID = model.id
    }

    func removeCustomModel(_ model: ModelDescriptor) {
        guard !model.isBuiltIn else { return }
        cancelDownload(model)
        if case .local(let path) = model.source { FolderAccess.forget(path) }
        modelTunings[model.id] = nil
        storeModelTunings()
        models.removeAll { $0.id == model.id }
        saveCustomModels()
        if selectedModelID == model.id { selectedModelID = ModelCatalog.defaultModelID }
    }

    private func saveCustomModels() {
        let custom = models.filter { !$0.isBuiltIn }
        UserDefaults.standard.set(try? JSONEncoder().encode(custom), forKey: Keys.customModels)
    }

    // MARK: Generation

    var blocker: Blocker? {
        guard let model = selectedModel else { return .noModel }
        if downloads.isDownloading(model) { return .modelDownloading }
        if !isInstalled(model) { return .modelNotDownloaded }
        if settings.fullPipeline(for: model), !hasQualityFiles(model) {
            return qualityProgress(model) != nil ? .qualityDownloading : .qualityNotDownloaded
        }
        if model.family.requiresReferenceImage, !hasReferenceImage { return .missingReference }
        if model.family.takesPrompt, settings.trimmedPrompt.isEmpty { return .emptyPrompt }
        if model.family.isSong, settings.songLyrics.isEmpty { return .emptyLyrics }
        if model.family.isUpscaler, let size = settings.upscaledSize, size.megapixels > Upscale.maxMegapixels { return .upscaleTooLarge }
        switch loraState(for: model) {
        case .missing(let choice): return .loraMissing(choice.name)
        case .mismatch(let choice, let base): return .loraMismatch(choice.name, base: base.displayName)
        case .none, .ready: break
        }
        return memoryBlocker(for: model)
    }

    /// Puts a word (a LoRA's trigger word) at the start of the prompt's first block.
    func addToPrompt(_ word: String) {
        guard !settings.trimmedPrompt.localizedCaseInsensitiveContains(word) else { return }
        if settings.blocks.isEmpty { settings.blocks = PromptBlock.defaults() }
        let text = settings.blocks[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.blocks[0].text = text.isEmpty ? word : "\(word), \(text)"
    }

    /// The LoRA chosen for a model, as the library has it.
    enum LoRAState: Equatable {
        case none
        case ready(LoRAChoice, LoRALibrary.Entry)
        case missing(LoRAChoice)
        case mismatch(LoRAChoice, LoRABase)
    }

    private func loraGigabytes(for model: ModelDescriptor) -> Double {
        guard case .ready(_, let entry) = loraState(for: model) else { return 0 }
        return Double(entry.bytes) / Double(1 << 30)
    }

    func loraState(for model: ModelDescriptor) -> LoRAState {
        guard let choice = settings.lora(for: model.family) else { return .none }
        guard let entry = loraLibrary.entry(choice.file) else { return .missing(choice) }
        if let base = entry.info?.base, base.fits(model) == false { return .mismatch(choice, base) }
        return .ready(choice, entry)
    }

    /// A generation this Mac cannot hold: the engine would run out of memory and die with it, so
    /// it is refused, with the change that would make it fit.
    private func memoryBlocker(for model: ModelDescriptor) -> Blocker? {
        let size = settings.size(for: model.family)
        let frames = model.family.media == .video ? settings.videoFrames
            : model.family.isSong ? Int(settings.songSeconds * 25)
            : model.family.media == .audio ? Int(settings.soundSeconds * 50) : nil
        let memoryGB = renderMemoryGB
        guard let peak = MemoryEstimate.peak(model: model, size: size, frames: frames, lowMemory: settings.lowMemory, memory: memoryGB)
        else { return nil }
        // A LoRA's matrices stay in memory beside the model's, as large as its file.
        let needed = peak + loraGigabytes(for: model)
        guard needed > MemoryEstimate.available(memory: memoryGB) else { return nil }
        let fitsAtAll = { (candidate: ModelDescriptor) in
            MemoryEstimate.smallestPeak(model: candidate).map { $0 <= MemoryEstimate.available(memory: memoryGB) } ?? false
        }
        let remedy = if MemoryEstimate.smallestPeak(model: model) != nil, !fitsAtAll(model) {
            models.contains(where: fitsAtAll) ? "choose another model" : "the models need a Mac with more memory"
        } else if !settings.lowMemory,
                  let saving = MemoryEstimate.peak(model: model, size: size, frames: frames, lowMemory: true, memory: memoryGB),
                  saving <= MemoryEstimate.available(memory: memoryGB) {
            "turn on Save memory"
        } else if model.family.isUpscaler {
            "choose a smaller scale"
        } else if model.family.media == .video {
            "choose a smaller size or a shorter clip"
        } else {
            "choose a smaller size"
        }
        let machine = isRemote ? "the render Mac" : "this Mac"
        return .notEnoughMemory(needed: Int(needed.rounded(.up)), machine: machine, remedy: remedy)
    }

    /// The settings name a reference image whose file is still there.
    var hasReferenceImage: Bool {
        settings.referenceImage.map { FileManager.default.fileExists(atPath: HistoryStore.referenceURL($0).path) } ?? false
    }

    /// The running job first, then the queue.
    var pendingJobs: [GenerationJob] {
        (activeJob.map { [$0] } ?? []) + queue
    }

    var isBusy: Bool { activeJob != nil || !queue.isEmpty }

    func generate() {
        guard blocker == nil, let model = selectedModel else { return }
        preloadDeclined = false
        let isVideo = model.family.media == .video
        let isObject = model.family.media == .model3D
        let isSound = model.family.media == .audio
        let upscales = model.family.isUpscaler
        let quality = settings.fullPipeline(for: model)
        // A reference image whose file is gone (a history folder emptied by hand) is dropped.
        let reference = settings.referenceImage.flatMap { name in
            FileManager.default.fileExists(atPath: HistoryStore.referenceURL(name).path) ? name : nil
        }
        let lastFrame = settings.lastFrameImage.flatMap { name in
            FileManager.default.fileExists(atPath: HistoryStore.referenceURL(name).path) ? name : nil
        }
        for seed in settings.nextSeeds() {
            // An upscale and a 3D object have no prompt: the picture (and the factor, the detail) say it all.
            let takesPrompt = model.family.takesPrompt
            var request = GenerationRequest(
                prompt: takesPrompt ? settings.trimmedPrompt : "",
                blocks: takesPrompt ? settings.blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } : nil,
                negativePrompt: settings.negativePrompt(for: model),
                seed: seed,
                size: settings.size(for: model.family),
                steps: min(max(settings.steps, model.stepRange(quality: quality).lowerBound), model.stepRange(quality: quality).upperBound),
                guidance: upscales ? 1 : settings.guidance,
                transparentBackground: settings.transparentBackground && model.family.producesAlpha,
                lowMemory: settings.lowMemory,
                frames: isVideo ? settings.videoFrames : nil,
                fps: isVideo ? settings.videoFrameRate : nil,
                autoDuration: isVideo && settings.autoDuration(for: model.family) ? true : nil,
                referenceImage: model.family.takesReferenceImage ? reference : nil,
                lastFrameImage: model.family.takesLastFrame ? lastFrame : nil,
                upscale: upscales ? settings.upscale : nil,
                softness: upscales ? settings.softness : nil,
                halfPrecision: model.family.supportsHalfPrecision && settings.halfPrecision ? true : nil,
                loras: settings.lora(for: model.family).map { [$0] },
                quality: quality ? true : nil
            )
            if isObject {
                request.numGaussians = settings.gaussians
                request.objectMode = settings.objectMode.rawValue
            }
            if model.family.isSong {
                request.lyrics = settings.songLyrics
                request.duration = min(max(settings.songSeconds, GenerationSettings.songDurations.lowerBound),
                                       GenerationSettings.songDurations.upperBound)
            } else if isSound {
                // A sound effect's length, in the tenths the model reads.
                request.duration = (min(max(settings.soundSeconds, GenerationSettings.soundDurations.lowerBound),
                                        GenerationSettings.soundDurations.upperBound) * 10).rounded() / 10
            }
            let output = isVideo ? history.newVideoURL(seed: seed) : isObject ? history.newObjectURL(seed: seed)
                : isSound ? history.newSongURL(seed: seed) : history.newImageURL(seed: seed)
            let job = GenerationJob(model: model, request: request, outputURL: output,
                                    isPrivate: showsPrivateHistory)
            job.plan = TimeEstimate.plan(model: model, request: request, history: estimateHistory, models: models)
            queue.append(job)
        }
        viewer = .live
        pump()
    }

    /// What the "+" after the history starts from: the last generation queued, running or finished.
    var lastGeneration: (model: ModelDescriptor, request: GenerationRequest)? {
        if let job = queue.last ?? activeJob { return (job.model, job.request) }
        guard let item = history.items.first, let model = models.first(where: { $0.id == item.modelID }) else { return nil }
        return (model, item.request)
    }

    /// The "+": the draft on the left, as last changed there, and the frame of the next generation
    /// on the right, for Generate to start. Without a draft yet, the last generation's settings.
    func startDraft(undoManager: UndoManager? = nil) {
        var target = draft ?? (settings, selectedModelID)
        if draft == nil, let (model, request) = lastGeneration {
            target = controls(from: request, modelID: model.id, media: model.family.media)
        }
        replaceControls(with: target.settings, modelID: target.modelID, viewer: .draft, source: .draft, actionName: "New",
                        undoManager: undoManager)
    }

    var showsDraft: Bool { viewer == .draft }

    /// The Styles & Prompts browser: a sheet on the main window, so it stays in front until closed.
    var showsPromptLibrary = false

    /// Appends a style prompt to the Style block (creating the block when the prompt has none).
    /// The prompt alone changes: the model, size, steps, seed, transparency and LoRAs stay.
    func appendStyle(_ text: String) {
        let style = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isEmpty else { return }
        if controlsSource != .draft { startDraft() }
        if settings.blocks.isEmpty { settings.blocks = PromptBlock.defaults() }
        let index = settings.blocks.firstIndex { $0.name == PromptBlock.styleName }
            ?? settings.blocks.firstIndex { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let index else {
            settings.blocks.append(PromptBlock(name: PromptBlock.styleName, text: style))
            return
        }
        let current = settings.blocks[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.localizedCaseInsensitiveContains(style) else { return }
        settings.blocks[index].text = current.isEmpty ? style : current + "\n\n" + style
    }

    /// Puts a style prompt in the Style block in place of what it holds.
    func replaceStyle(_ text: String) {
        let style = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !style.isEmpty else { return }
        if controlsSource != .draft { startDraft() }
        if settings.blocks.isEmpty { settings.blocks = PromptBlock.defaults() }
        if let index = settings.blocks.firstIndex(where: { $0.name == PromptBlock.styleName }) {
            settings.blocks[index].text = style
        } else {
            settings.blocks.append(PromptBlock(name: PromptBlock.styleName, text: style))
        }
    }

    /// Puts a library prompt in the controls: its blocks and negative prompt, and nothing else —
    /// the model, size, steps, seed, transparency and LoRAs stay as they are. When a history
    /// item's settings are being shown, this returns to the draft first (that is the prompt the
    /// next image is written with).
    func use(_ saved: SavedPrompt, undoManager: UndoManager? = nil) {
        if controlsSource != .draft { startDraft(undoManager: undoManager) }
        // Fresh ids: a saved block's id must not collide with a block a field still holds.
        settings.blocks = saved.blocks.map { block in
            var copy = block
            copy.id = UUID()
            return copy
        }
        settings.negativePrompt = saved.negativePrompt
    }

    func cancel(_ job: GenerationJob) {
        if let index = queue.firstIndex(where: { $0 === job }) {
            queue.remove(at: index)
            queueChanged()
            return
        }
        guard job === activeJob else { return }
        if job.isCancelling {
            // Asked twice: the worker is inside a step that cannot be interrupted (loading,
            // prompt encoding, decoding). Restart it; the model will be reloaded next time.
            activeJob = nil
            backend.restartWorker()
            queueChanged()
        } else {
            job.isCancelling = true
            try? backend.send(.cancel(jobID: job.id))
        }
    }

    func cancelAll() {
        queue.removeAll()
        if let activeJob { cancel(activeJob) }
        queueChanged()
    }

    private func pump() {
        defer { queueChanged() }
        guard activeJob == nil, let job = queue.first else { return }
        switch backend.status {
        case .ready:
            break
        case .starting, .checking:
            return // onReady pumps again
        case .stopped, .failed:
            // Not running, or crashed: bring it up; onReady pumps.
            backend.ensureWorker()
            return
        }
        queue.removeFirst()
        guard let location = installed[job.model.id] else {
            alert = AppAlert(title: "Model not found", message: "\(job.model.name) is no longer on disk.")
            pump()
            return
        }
        activeJob = job
        job.phase = .starting
        job.startedAt = Date()
        // Prompts and negative prompts of the images queued behind this one, for the same model
        // and memory mode, so the worker can encode them while the text encoder is in memory.
        var upcoming: [String] = []
        let current = [job.request.prompt, job.request.negativePrompt].compactMap(\.self)
        for queued in queue where queued.model.id == job.model.id && queued.request.lowMemory == job.request.lowMemory {
            for prompt in [queued.request.prompt, queued.request.negativePrompt].compactMap(\.self)
            where !current.contains(prompt) && !upcoming.contains(prompt) {
                upcoming.append(prompt)
            }
        }
        do {
            try backend.send(.generate(
                jobID: job.id,
                model: job.model,
                modelPath: location.path,
                textEncoderPath: locator.companionLocation(of: job.model)?.path,
                request: job.request,
                output: job.outputURL,
                upcomingPrompts: Array(upcoming.prefix(8)),
                preview: settings.livePreview && job.model.family.showsPreview
            ))
        } catch {
            activeJob = nil
            alert = AppAlert(title: "Couldn’t start generating", message: error.localizedDescription, offersLog: true)
        }
    }

    private func handle(_ event: WorkerEvent) {
        if event.event == "load_failed" {
            preloadRequested = nil
            return
        }
        guard let job = activeJob, event.id == nil || event.id == job.id.uuidString else { return }
        if let total = event.total, (event.event == "progress" && job.phase != .composing) || event.phase == "denoising" {
            job.reportedTotal = Int(total)
        }
        switch event.event {
        case "phase":
            switch event.phase {
            case "loading": job.phase = .loadingModel
            // A 3D object's picture is cut out, then read: both "Reading the picture…".
            case "encoding", "segmenting": job.phase = .encodingPrompt
            // A song's frames, up to `total`.
            case "composing": job.beginComposing(frames: Int(event.total ?? 0))
            case "denoising":
                // A length the model picked: the clip it will make, planned again.
                if job.request.autoDuration == true, let frames = event.frames {
                    job.settleFrames(frames)
                    job.plan = TimeEstimate.plan(model: job.model, request: job.request, history: estimateHistory, models: models)
                }
                job.beginDenoising()
            case "decoding": job.phase = .decoding
            case "encoding_video": job.phase = .encodingVideo
            case "saving": job.phase = .saving
            default: break
            }
        case "progress":
            if job.phase == .composing {
                job.advanceComposing(to: event.step ?? job.step)
            } else {
                job.advance(to: event.step ?? job.step)
            }
        case "preview":
            if let path = event.path { job.showPreview(at: URL(fileURLWithPath: path), step: event.step ?? job.step) }
        case "done":
            complete(job, with: event)
        case "cancelled":
            activeJob = nil
            pump()
        case "failed":
            activeJob = nil
            let dropped = queue.count
            queue.removeAll()
            alert = AppAlert(
                title: "Generation failed",
                message: (event.message ?? "Unknown error")
                    + (dropped > 0 ? "\n\nThe \(dropped) queued images were cancelled." : ""),
                offersLog: true
            )
            queueChanged()
        default:
            break
        }
    }

    private func complete(_ job: GenerationJob, with event: WorkerEvent) {
        var request = job.request
        if let width = event.width, let height = event.height {
            request.size = PixelSize(width: width, height: height)
        }
        if job.model.family.media == .video, let frames = event.frames {
            request.frames = frames
        }
        // A 3D object comes without a still: the app draws one of it, next to it.
        var poster = event.poster.map { URL(fileURLWithPath: $0).lastPathComponent }
        if job.model.family.media == .model3D {
            let still = job.outputURL.deletingPathExtension().appendingPathExtension("png")
            if (try? ObjectStill.write(of: job.outputURL, to: still)) != nil { poster = still.lastPathComponent }
        }
        // A song: the frames it came out at, 25 a second (the model may end it before `duration`, the longest asked);
        // a sound effect lasts its `duration`. Either way its waveform drawn.
        if job.model.family.media == .audio {
            if job.model.family.isSong, let frames = event.frames { request.frames = frames }
            let still = job.outputURL.deletingPathExtension().appendingPathExtension("png")
            if (try? SongWaveform.write(of: job.outputURL, to: still)) != nil { poster = still.lastPathComponent }
        }
        // The job's ID, so that a job being looked at stays in view as its image or clip.
        history.add(HistoryItem(
            id: job.id,
            createdAt: Date(),
            fileName: job.outputURL.lastPathComponent,
            media: job.model.family.media,
            posterFileName: poster,
            modelID: job.model.id,
            modelName: job.model.name,
            request: request,
            seconds: event.seconds ?? job.startedAt.map { Date().timeIntervalSince($0) } ?? 0,
            peakMemory: event.peakMemory,
            timings: event.timings,
            backend: isRemote ? "relay" : nil,
            engine: isRemote ? event.engine : nil,
            isPrivate: job.isPrivate ? true : nil
        ))
        if viewer == .job(job.id) { viewer = .item(job.id) }
        activeJob = nil
        if queue.isEmpty, !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
        pump()
    }

    private func backendCrashed(_ message: String) {
        guard isBusy else { return }
        activeJob = nil
        queue.removeAll()
        queueChanged()
        alert = AppAlert(title: "The engine stopped", message: message, offersLog: true)
    }

    /// The Dock badge counts what is left, and the Mac stays awake until it is done. A job being
    /// looked at that was stopped, removed or dropped gives way to the live view.
    private func queueChanged() {
        let count = pendingJobs.count
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        awake.isOn = count > 0
        if case .job(let id) = viewer, job(withID: id) == nil { viewer = .live }
    }

    private func job(withID id: GenerationJob.ID) -> GenerationJob? {
        pendingJobs.first { $0.id == id }
    }

    // MARK: History

    /// The history item the viewer shows, if it shows one.
    var displayedItem: HistoryItem? {
        switch viewer {
        case .item(let id):
            // An item moved to the other history is no longer in the strip: show this one's first.
            guard let item = history.item(withID: id), item.inPrivateHistory == showsPrivateHistory else {
                return visibleHistory.first
            }
            return item
        case .live:
            return activeJob == nil ? visibleHistory.first : nil
        case .job, .draft:
            return nil
        }
    }

    /// The job the viewer shows instead: one picked in the strip, or the running one live.
    var displayedJob: GenerationJob? {
        switch viewer {
        case .job(let id): job(withID: id)
        case .live: activeJob
        case .item, .draft: nil
        }
    }

    /// Shows a history item and puts its prompt, model and settings in the controls on the left.
    /// `undoManager` is the window's, where ⌘Z finds what they replaced.
    func select(_ item: HistoryItem, undoManager: UndoManager? = nil) {
        let controls = controls(from: item.request, modelID: item.modelID, media: item.kind)
        replaceControls(with: controls.settings, modelID: controls.modelID,
                        viewer: item.id == history.items.first?.id && activeJob == nil ? .live : .item(item.id),
                        source: .item, actionName: "Load Settings", undoManager: undoManager)
    }

    /// The same for a job running or waiting in the queue: once done, its image or clip stays in view.
    func select(_ job: GenerationJob, undoManager: UndoManager? = nil) {
        let controls = controls(from: job.request, modelID: job.model.id, media: job.model.family.media)
        replaceControls(with: controls.settings, modelID: controls.modelID, viewer: .job(job.id),
                        source: .item, actionName: "Load Settings", undoManager: undoManager)
    }

    func isSelected(_ item: HistoryItem) -> Bool {
        displayedItem?.id == item.id
    }

    func isSelected(_ job: GenerationJob) -> Bool {
        displayedJob === job
    }

    /// Moves through the strip, loading each item's or job's settings as a click would; `offset` -1
    /// is to the right (newer, by date), +1 to the left.
    func moveSelection(by offset: Int, undoManager: UndoManager? = nil) {
        // Left to right, as in the strip: the history as arranged, then the running and queued jobs.
        let entries: [ViewerSelection] = arrangedHistory.map { .item($0.id) } + pendingJobs.map { .job($0.id) }
        guard !entries.isEmpty else { return }
        // The draft sits after them all: left of it is the last one, right of it nothing.
        if viewer == .draft, offset < 0 { return }
        let shown = displayedJob.map { ViewerSelection.job($0.id) } ?? displayedItem.map { .item($0.id) }
        let current = viewer == .draft ? entries.count : shown.flatMap { entries.firstIndex(of: $0) } ?? entries.count
        switch entries[min(max(current - offset, 0), entries.count - 1)] {
        case .item(let id):
            if let item = history.item(withID: id) { select(item, undoManager: undoManager) }
        case .job(let id):
            if let job = job(withID: id) { select(job, undoManager: undoManager) }
        case .live, .draft:
            break
        }
    }

    /// Moves items to the Trash. The one on show gives way to its neighbor in the strip: the one on
    /// its right, which slides into its place, or else the one on its left. The controls on the left
    /// stay as they are.
    func delete(_ items: [HistoryItem]) {
        let ids = Set(items.map(\.id))
        let arranged = arrangedHistory
        if let shown = displayedItem, ids.contains(shown.id),
           let index = arranged.firstIndex(where: { $0.id == shown.id }) {
            let right = arranged[(index + 1)...].first { !ids.contains($0.id) }
            let left = arranged[..<index].last { !ids.contains($0.id) }
            viewer = (right ?? left).map { .item($0.id) } ?? .live
        }
        history.remove(ids)
    }

    /// Clears the history the strip shows: the private one while the padlock is on, the normal
    /// one otherwise. The other list is left alone.
    func clearHistory() {
        viewer = .live
        history.remove(Set(visibleHistory.map(\.id)))
    }

    /// A generation's prompt blocks, model and settings, as the controls should show them. Its seed
    /// goes in the seed field with Random on, as always by default: Generate makes a variation, and
    /// turning Random off makes the same one again.
    private func controls(from request: GenerationRequest, modelID: String, media: MediaKind)
        -> (settings: GenerationSettings, modelID: String) {
        let model = models.first { $0.id == modelID }
        var updated = settings
        let isVideo = media == .video
        if model?.family.isUpscaler == true {
            // An upscale has neither prompt nor format: those stay as they are for the next image.
            updated.upscale = request.upscale ?? updated.upscale
            updated.softness = request.softness ?? updated.softness
        } else if media == .model3D {
            // A 3D object: its detail and its picture's kind; the prompt and the format stay as they are.
            updated.gaussians = request.numGaussians ?? updated.gaussians
            updated.objectMode = request.objectMode.flatMap(ObjectMode.init(rawValue:)) ?? updated.objectMode
        } else if media == .audio, model?.family.isSong == false {
            // A sound effect: its description, what guidance kept out of it, its length; the format stays as it is.
            updated.blocks = request.blocks.flatMap { $0.isEmpty ? nil : $0 } ?? PromptBlock.defaults(subject: request.prompt)
            if request.guidance > 1 { updated.negativePrompt = request.negativePrompt ?? "" }
            updated.soundSeconds = request.duration ?? updated.soundSeconds
        } else if media == .audio {
            // A song: its description, its lyrics (none for an instrumental) and the longest it was asked to last;
            // the format stays as it is.
            updated.blocks = request.blocks.flatMap { $0.isEmpty ? nil : $0 } ?? PromptBlock.defaults(subject: request.prompt)
            if let lyrics = request.lyrics {
                updated.instrumental = lyrics.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == GenerationSettings.instrumentalTag
                updated.lyrics = updated.instrumental ? "" : lyrics
            }
            updated.songSeconds = request.duration ?? updated.songSeconds
        } else {
            if let blocks = request.blocks, !blocks.isEmpty {
                updated.blocks = blocks
            } else {
                updated.blocks = PromptBlock.defaults(subject: request.prompt)
            }
            // Only a generation that ran guidance on a model that takes a negative prompt says
            // which it had, none included; the others leave the field as it is.
            if model?.supportsNegativePrompt(quality: request.quality == true) == true, request.guidance > 1 || request.quality == true {
                updated.negativePrompt = request.negativePrompt ?? ""
            }
            // LTX: the mode the clip was made in.
            if model?.family.isLTX == true {
                updated.videoQuality = request.quality ?? false
            }
            // Sides in the family's multiple: SenseNova's 16:9 at 2048 is 2720 wide (32), not 2736
            // (16), and must not turn Custom size on, which locks the resolution.
            updated.apply(size: request.size, video: isVideo, multiple: model?.family.sizeMultiple ?? 16)
        }
        if isVideo, let frames = request.frames, let fps = request.fps, fps > 0 {
            updated.videoFrameRate = fps
            updated.videoAutoDuration = request.autoDuration ?? false
            let durations = GenerationSettings.videoDurations(family: model?.family, frameRate: fps)
            updated.videoSeconds = min(max((Double(frames - 1) / Double(fps)).rounded(), durations.lowerBound),
                                       durations.upperBound)
        }
        // A model that takes a reference image gets the generation's, or none; the others leave it.
        if model?.family.takesReferenceImage == true {
            updated.referenceImage = request.referenceImage.flatMap { name in
                FileManager.default.fileExists(atPath: HistoryStore.referenceURL(name).path) ? name : nil
            }
        }
        if model?.family.takesLastFrame == true {
            updated.lastFrameImage = request.lastFrameImage.flatMap { name in
                FileManager.default.fileExists(atPath: HistoryStore.referenceURL(name).path) ? name : nil
            }
        }
        updated.steps = request.steps
        updated.guidance = request.guidance
        updated.seed = request.seed
        updated.randomSeed = true
        // Only a model that makes transparent images says which background was chosen: the
        // others always save false, which would turn the choice off for the next Ming image.
        if model?.family.producesAlpha == true {
            updated.transparentBackground = request.transparentBackground
        }
        // Likewise the precision: only the families with the option say which was chosen.
        if model?.family.supportsHalfPrecision == true {
            updated.halfPrecision = request.halfPrecision ?? false
        }
        // And the LoRA: the generation's, or none, for a family that takes them.
        if let family = model?.family, family.takesLoRAs {
            updated.setLoRA(request.loras?.first, for: family)
        }
        return (updated, model?.id ?? selectedModelID)
    }

    /// Reset: the model and settings of a first launch, as a new draft, with the prompt down to one
    /// empty block without a name instead of the subject and the style.
    func resetControls(undoManager: UndoManager? = nil) {
        let model = models.first { $0.id == ModelCatalog.defaultModelID } ?? models.first
        // Reset means the model's defaults stick, not a tuning from before it.
        if let model {
            modelTunings[model.id] = nil
            storeModelTunings()
        }
        var initial = Self.initialSettings(for: model)
        initial.blocks = [PromptBlock(name: "")]
        replaceControls(with: initial, modelID: model?.id ?? selectedModelID, viewer: .draft,
                        source: .draft, actionName: "Reset", undoManager: undoManager)
    }

    /// Settings for a first launch: the model's steps and guidance, Save memory below 64 GB.
    private static func initialSettings(for model: ModelDescriptor?) -> GenerationSettings {
        var initial = GenerationSettings()
        // At 1024 px with everything resident Ming-Image peaks at ~35 GB and Qwen-Image at
        // ~43 GB (~15 and ~21 GB with Save memory): below 64 GB the full-speed mode would swap.
        initial.lowMemory = ProcessInfo.processInfo.physicalMemory < 64 << 30
        if let model {
            initial.steps = model.defaultSteps
            initial.guidance = model.defaultGuidance
        }
        return initial
    }

    /// Puts other settings and another model in the controls, and shows `newViewer`, so that ⌘Z
    /// brings back what they replaced and what was shown: a click in the history, the "+" or Reset
    /// does not lose a prompt being written. Without the view's undo manager (a menu command), the
    /// main window's, which exists while the app is active.
    private func replaceControls(
        with new: GenerationSettings, modelID: String, viewer newViewer: ViewerSelection? = nil,
        source newSource: ControlsSource? = nil, actionName: String, undoManager: UndoManager?
    ) {
        let previous = (settings: settings, modelID: selectedModelID, viewer: viewer, source: controlsSource)
        var shown = newViewer ?? viewer
        // A job brought back by ⌘Z may have finished since (its image has its ID) or been stopped.
        if case .job(let id) = shown, job(withID: id) == nil {
            shown = history.item(withID: id) == nil ? .live : .item(id)
        }
        let source = newSource ?? controlsSource
        guard new != previous.settings || modelID != previous.modelID || shown != previous.viewer || source != previous.source
        else { return }
        if let undoManager = undoManager ?? NSApp.mainWindow?.undoManager {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated {
                    model.replaceControls(with: previous.settings, modelID: previous.modelID, viewer: previous.viewer,
                                          source: previous.source, actionName: actionName, undoManager: undoManager)
                }
            }
            undoManager.setActionName(actionName)
        }
        // The source first, so that a history item's settings do not land in the draft; then the
        // model: switching family resets steps and guidance, which `new` then sets.
        controlsSource = source
        selectedModelID = modelID
        settings = new
        viewer = shown
    }

    /// The upscaler, when the list has one.
    var upscaler: ModelDescriptor? { models.first { $0.family.isUpscaler } }

    /// Sets up an upscale of a generated image (a clip's first frame): the upscaler, the image as
    /// its picture, in the draft for Generate to start; ⌘Z brings back the controls.
    func upscale(_ item: HistoryItem, undoManager: UndoManager? = nil) {
        guard let model = upscaler else { return }
        let url = url(for: item)
        Task {
            do {
                var new = settings
                new.referenceImage = try await HistoryStore.importReference(from: url)
                replaceControls(with: new, modelID: model.id, viewer: .draft, source: .draft, actionName: "Upscale",
                                undoManager: undoManager)
            } catch {
                alert = AppAlert(title: "Couldn’t use the image", message: error.localizedDescription)
            }
        }
    }

    /// Makes a generated image (a clip's first frame) the reference image of the next clip, or
    /// with `lastFrame` the image it ends on.
    func useAsReference(_ item: HistoryItem, lastFrame: Bool = false) {
        let url = url(for: item)
        Task {
            do {
                let name = try await HistoryStore.importReference(from: url)
                if lastFrame { settings.lastFrameImage = name } else { settings.referenceImage = name }
            } catch {
                alert = AppAlert(title: "Couldn’t use the image", message: error.localizedDescription)
            }
        }
    }

    func url(for item: HistoryItem) -> URL { history.url(for: item) }
    func posterURL(for item: HistoryItem) -> URL { history.posterURL(for: item) }
}
