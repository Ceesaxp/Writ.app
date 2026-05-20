import Foundation
import CoreServices

/// FSEvents-backed recursive folder watcher.
///
/// `FolderWindowController` enumerates its directory recursively for the
/// file list, so this watcher uses the FSEventStream API to observe the
/// whole tree under the chosen folder. `onChange` fires on the watcher's
/// own dispatch queue whenever the kernel reports activity — additions,
/// deletions, renames, attribute changes. The owner is responsible for
/// debouncing + main-thread hopping.
final class FolderWatcher {
    private let folder: URL
    private let onChange: () -> Void
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?

    init(folder: URL, onChange: @escaping () -> Void) {
        self.folder = folder
        self.onChange = onChange
        self.queue = DispatchQueue(label: "org.ceesaxp.Writ.FolderWatcher", qos: .utility)
        start()
    }

    deinit {
        stop()
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func start() {
        let pathsToWatch = [folder.path] as CFArray
        // sinceWhen = kFSEventStreamEventIdSinceNow → we only care
        // about activity from this point onward, not historical replay.
        let sinceWhen = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        // 0.25 s latency: the kernel batches events for us before
        // delivery, complementing the controller's own debounce.
        let latency: CFTimeInterval = 0.25
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, _, _, _ in
                guard let info, count > 0 else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.onChange()
            },
            &context,
            pathsToWatch,
            sinceWhen,
            latency,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }
}
