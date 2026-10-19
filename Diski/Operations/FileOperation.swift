import Foundation
import os

/// A long-running file operation (copy, move, trash, ...) and its live progress.
/// Workers update `Progress` under a lock; the UI samples it on a timer.
final class FileOperation: Identifiable {
    enum Kind {
        case copy, move, duplicate, trash, delete, compress, emptyTrash

        var verb: String {
            switch self {
            case .copy: return "Copying"
            case .move: return "Moving"
            case .duplicate: return "Duplicating"
            case .trash: return "Moving to Trash"
            case .delete: return "Deleting"
            case .compress: return "Compressing"
            case .emptyTrash: return "Emptying Trash"
            }
        }

        var pastTense: String {
            switch self {
            case .copy: return "Copied"
            case .move: return "Moved"
            case .duplicate: return "Duplicated"
            case .trash: return "Moved to Trash"
            case .delete: return "Deleted"
            case .compress: return "Compressed"
            case .emptyTrash: return "Emptied Trash"
            }
        }
    }

    enum State: Equatable {
        case preparing, running, paused, finished, failed(String), cancelled

        var isDone: Bool {
            switch self {
            case .finished, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    struct Snapshot {
        var totalBytes: Int64 = 0
        var completedBytes: Int64 = 0
        var totalItems = 0
        var completedItems = 0
        var currentName = ""
        var scanning = true
        /// Every top-level item finished by cloning or renaming (no data copied).
        var instant = true
    }

    let id = UUID()
    let kind: Kind
    let sources: [URL]
    let destination: URL?
    let startedAt = Date()

    /// Main-thread state.
    var state: State = .preparing
    var finishedAt: Date?
    var resultURLs: [URL] = []
    var errors: [String] = []

    private let lock = OSAllocatedUnfairLock(uncheckedState: Snapshot())
    private let control = NSCondition()
    private var _cancelled = false
    private var _paused = false

    // Throughput sampling (main thread).
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0
    private(set) var bytesPerSecond: Double = 0

    init(kind: Kind, sources: [URL], destination: URL?) {
        self.kind = kind
        self.sources = sources
        self.destination = destination
    }

    var title: String {
        let count = sources.count
        let what = count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(count) items"
        switch kind {
        case .copy, .move:
            let target = destination.map { " to “\(FileManager.default.displayName(atPath: $0.path))”" } ?? ""
            return "\(kind.verb) \(what)\(target)"
        case .emptyTrash:
            return kind.verb
        default:
            return "\(kind.verb) \(what)"
        }
    }

    // MARK: Progress (any thread)

    var snapshot: Snapshot { lock.withLockUnchecked { $0 } }

    func update(_ body: (inout Snapshot) -> Void) {
        lock.withLockUnchecked { body(&$0) }
    }

    var fractionCompleted: Double {
        let s = snapshot
        if s.totalBytes > 0 {
            return min(1, Double(s.completedBytes) / Double(s.totalBytes))
        }
        if s.totalItems > 0 { return min(1, Double(s.completedItems) / Double(s.totalItems)) }
        return 0
    }

    /// Samples throughput; call from the main thread a few times per second.
    func sampleThroughput() {
        let now = Date()
        let bytes = snapshot.completedBytes
        let dt = now.timeIntervalSince(lastSampleTime)
        guard dt >= 0.2 else { return }
        let instant = Double(bytes - lastSampleBytes) / dt
        bytesPerSecond = bytesPerSecond == 0 ? instant : bytesPerSecond * 0.7 + instant * 0.3
        lastSampleTime = now
        lastSampleBytes = bytes
    }

    var estimatedSecondsRemaining: Double? {
        let s = snapshot
        guard !s.scanning, bytesPerSecond > 1, s.totalBytes > s.completedBytes else { return nil }
        return Double(s.totalBytes - s.completedBytes) / bytesPerSecond
    }

    // MARK: Control

    var isCancelled: Bool {
        control.lock(); defer { control.unlock() }
        return _cancelled
    }

    var isPaused: Bool {
        control.lock(); defer { control.unlock() }
        return _paused
    }

    func cancel() {
        control.lock()
        _cancelled = true
        _paused = false
        control.broadcast()
        control.unlock()
    }

    func setPaused(_ paused: Bool) {
        control.lock()
        _paused = paused
        control.broadcast()
        control.unlock()
    }

    /// Blocks the calling worker while paused. Returns false when cancelled.
    @discardableResult
    func waitIfPaused() -> Bool {
        control.lock()
        while _paused && !_cancelled { control.wait() }
        let ok = !_cancelled
        control.unlock()
        return ok
    }
}
