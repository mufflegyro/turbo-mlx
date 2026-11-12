import Foundation

/// How AppModel talks to whatever runs the models: the local `turbo-engine` process
/// (BackendController) or a TurboRelay server on another Mac (RemoteBackend). Both speak the
/// engine's JSON-lines vocabulary on this side; RemoteBackend translates to the wire protocol
/// on the other (TurboRelay/docs/remote-protocol.md), so the app cannot tell the difference.
nonisolated protocol EngineTransport: AnyObject {
    var status: BackendController.Status { get }
    var info: BackendInfo? { get }
    var loadedModelPath: String? { get }
    var isRunning: Bool { get }
    var log: LogBuffer { get }
    var onReady: (() -> Void)? { get set }
    var onEvent: ((WorkerEvent) -> Void)? { get set }
    var onCrash: ((String) -> Void)? { get set }
    func ensureWorker()
    func stopWorker()
    func restartWorker()
    func unloadModel()
    func send(_ command: WorkerCommand) throws
}

extension BackendController: EngineTransport {}
