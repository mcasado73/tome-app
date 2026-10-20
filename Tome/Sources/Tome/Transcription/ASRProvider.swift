import CoreML
import FluidAudio
import Synchronization

/// Owns the session's `AsrManager` and replaces it when inference stops working.
///
/// After a deep-idle wake the Apple Neural Engine can start rejecting the
/// already-loaded Parakeet program (`ANEProgramProcessRequestDirect() Failed`,
/// CoreML `E5RT (11)`), and every `transcribe` call throws from then on. Loading
/// the models onto the ANE again inside the same process keeps failing — on
/// 2026-10-20 a fresh session in the same process stayed broken until Tome was
/// relaunched — so recovery reloads them on CPU+GPU instead, and every later
/// session in this process stays off the ANE.
actor ASRProvider {
    /// Set once the ANE has failed in this process; cleared only by a relaunch.
    private static let aneFailed = Mutex(false)

    private(set) var manager: AsrManager
    /// Bumped on every successful reload, so transcribers that hit the same
    /// broken manager trigger a single reload between them.
    private(set) var generation = 0
    private var reloadTask: Task<Void, Never>?

    private init(manager: AsrManager) {
        self.manager = manager
    }

    static func load() async throws -> ASRProvider {
        let avoidANE = aneFailed.withLock { $0 }
        if avoidANE {
            diagLog("[ASR] loading models on CPU+GPU (ANE failed earlier in this process)")
        }
        return ASRProvider(manager: try await makeManager(avoidANE: avoidANE))
    }

    private static func makeManager(avoidANE: Bool) async throws -> AsrManager {
        var configuration: MLModelConfiguration?
        if avoidANE {
            let config = AsrModels.defaultConfiguration()
            config.computeUnits = .cpuAndGPU
            configuration = config
        }
        let models = try await AsrModels.downloadAndLoad(configuration: configuration, version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        return asr
    }

    func current() -> (manager: AsrManager, generation: Int) {
        (manager, generation)
    }

    /// Replaces the manager that failed at `failedGeneration` with one loaded
    /// off the ANE. Concurrent callers share a single reload; a caller whose
    /// generation is already stale just gets the current manager.
    /// Returns nil if the reload itself failed.
    func recover(after failedGeneration: Int) async -> (manager: AsrManager, generation: Int)? {
        if failedGeneration == generation {
            if reloadTask == nil {
                reloadTask = Task {
                    Self.aneFailed.withLock { $0 = true }
                    diagLog("[ASR] reloading models on CPU+GPU after repeated ASR errors")
                    do {
                        manager = try await Self.makeManager(avoidANE: true)
                        generation += 1
                        diagLog("[ASR] reload OK, generation=\(generation)")
                    } catch {
                        diagLog("[ASR] reload FAILED: \(error)")
                    }
                    reloadTask = nil
                }
            }
            await reloadTask?.value
        }
        return generation > failedGeneration ? (manager, generation) : nil
    }
}
