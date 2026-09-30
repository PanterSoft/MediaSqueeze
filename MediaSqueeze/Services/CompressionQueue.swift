import Observation
import Photos
import SqueezeCore
import UIKit

/// Runs compression jobs one after another and tracks their state for the UI.
@MainActor
@Observable
final class CompressionQueue {
    enum JobState: Equatable {
        case pending
        case downloading(Double)
        case compressing(Double)
        case saving
        case done(savedBytes: Int64)
        case skipped(String)
        case failed(String)
        case cancelled

        var isFinished: Bool {
            switch self {
            case .done, .skipped, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    struct Job: Identifiable {
        let id: String
        let item: VideoItem
        var state: JobState = .pending
        var outputBytes: Int64?
    }

    enum OriginalsOutcome: Equatable {
        case none
        case deleting
        case deleted(Int)
        case kept(String)
    }

    private(set) var jobs: [Job] = []
    private(set) var isRunning = false
    private(set) var originalsOutcome: OriginalsOutcome = .none

    private let compressor = VideoCompressor()
    private var runTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var totalSavedBytes: Int64 {
        jobs.reduce(0) { total, job in
            if case .done(let saved) = job.state { return total + saved }
            return total
        }
    }

    var completedCount: Int { jobs.filter { $0.state.isFinished }.count }

    /// Overall progress across all jobs, 0...1.
    var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        let sum = jobs.reduce(0.0) { total, job in
            switch job.state {
            case .pending: return total
            case .downloading(let p): return total + p * 0.1
            case .compressing(let p): return total + 0.1 + p * 0.85
            case .saving: return total + 0.95
            default: return total + 1
            }
        }
        return sum / Double(jobs.count)
    }

    var currentJob: Job? {
        jobs.first { !$0.state.isFinished && $0.state != .pending }
    }

    func start(items: [VideoItem], settings: CompressionSettings, library: PhotoLibraryService) {
        guard !isRunning, !items.isEmpty else { return }
        jobs = items.map { Job(id: $0.id, item: $0) }
        originalsOutcome = .none
        isRunning = true
        beginBackgroundWork()

        runTask = Task {
            var originalsToDelete: [PHAsset] = []
            for index in jobs.indices {
                if Task.isCancelled {
                    jobs[index].state = .cancelled
                    continue
                }
                if await process(jobIndex: index, settings: settings, library: library) {
                    originalsToDelete.append(jobs[index].item.asset)
                }
            }

            if settings.deleteOriginals, !originalsToDelete.isEmpty {
                // One batch => iOS asks for confirmation only once.
                originalsOutcome = .deleting
                do {
                    try await library.deleteAssets(originalsToDelete)
                    originalsOutcome = .deleted(originalsToDelete.count)
                } catch {
                    originalsOutcome = .kept("Originals were kept. You can delete them later from the Videos tab.")
                }
            }

            isRunning = false
            endBackgroundWork()
            await library.reloadVideos()
        }
    }

    func cancel() {
        runTask?.cancel()
    }

    func reset() {
        guard !isRunning else { return }
        jobs = []
        originalsOutcome = .none
    }

    /// Returns `true` if the job produced a saved, smaller copy (so the original can go).
    private func process(jobIndex index: Int, settings: CompressionSettings, library: PhotoLibraryService) async -> Bool {
        let item = jobs[index].item
        let jobID = item.id
        jobs[index].state = .downloading(0)

        do {
            let avAsset = try await PhotoKitBridge.avAsset(for: item.asset) { [weak self] progress in
                Task { @MainActor in self?.update(jobID, state: .downloading(progress)) }
            }
            update(jobID, state: .compressing(0))

            let output = try await compressor.compress(
                avAsset,
                originalBytes: item.fileSize,
                settings: settings
            ) { [weak self] progress in
                Task { @MainActor in self?.update(jobID, state: .compressing(progress)) }
            }

            update(jobID, state: .saving)
            _ = try await library.saveCompressedVideo(at: output.url, replacing: item.asset)
            try? FileManager.default.removeItem(at: output.url)

            jobs[index].outputBytes = output.outputBytes
            jobs[index].state = .done(savedBytes: max(0, output.originalBytes - output.outputBytes))
            return true
        } catch is CancellationError {
            jobs[index].state = .cancelled
        } catch let error as CompressionError where error.isSkip {
            jobs[index].state = .skipped(error.localizedDescription)
        } catch {
            jobs[index].state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
        }
        return false
    }

    /// Progress callbacks arrive asynchronously and must not overwrite a finished state.
    private func update(_ jobID: String, state: JobState) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), !jobs[index].state.isFinished else { return }
        if case .saving = jobs[index].state, state != .saving { return }
        if case .compressing = jobs[index].state, case .downloading = state { return }
        jobs[index].state = state
    }

    // MARK: - Keep running briefly in the background and keep the screen awake

    private func beginBackgroundWork() {
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Compression") { [weak self] in
            Task { @MainActor in self?.endBackgroundWork() }
        }
    }

    private func endBackgroundWork() {
        UIApplication.shared.isIdleTimerDisabled = false
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
