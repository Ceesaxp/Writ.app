import Foundation

/// Watches the user-selected custom CSS file for external edits and
/// triggers a re-read + re-push to the preview JS bridge whenever it
/// changes (issue #6 follow-up).
///
/// Most editors save via atomic replace (write to `.tmp`, rename over
/// the original), which closes the old file's inode. A naive
/// `DispatchSource` watching a single fd never sees a follow-up
/// `.write` because it's watching the doomed inode. We handle both
/// the in-place edit path (`.write` / `.extend`) and the replace path
/// (`.delete` / `.rename`) by re-opening the file on every event and
/// coalescing changes through a small debounce so a flurry of save
/// events triggers one reload.
@MainActor
final class CustomCSSWatcher {
    private var url: URL?
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?
    private var pendingReload: Task<Void, Never>?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }

    /// Start (or restart) watching the given URL. Passing `nil` stops
    /// the watcher. Idempotent — calling twice with the same URL is a
    /// no-op.
    func start(watching newURL: URL?) {
        if url == newURL, source != nil { return }
        stop()
        guard let newURL else { return }
        url = newURL
        openAndAttach()
    }

    func stop() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        url = nil
    }

    private func openAndAttach() {
        guard let url else { return }
        // The custom CSS lives outside the sandbox; use the
        // security-scoped resource (PreviewAppearance persists the
        // bookmark, which is what made `url` resolvable in the first
        // place — start/stopAccess still required around the open).
        var accessed = false
        if url.startAccessingSecurityScopedResource() { accessed = true }
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.main
        )
        src.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        src.setCancelHandler { [fd] in
            close(fd)
        }
        source = src
        src.activate()
    }

    private func handleEvent() {
        // Coalesce a burst of events (atomic replace can fire delete
        // + rename + write in quick succession) into one reload, and
        // re-open against the (possibly new) inode at the same path.
        pendingReload?.cancel()
        pendingReload = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            if Task.isCancelled { return }
            guard let self else { return }
            let savedURL = self.url
            self.stop()
            if let savedURL {
                self.url = savedURL
                self.openAndAttach()
            }
            self.onChange()
        }
    }
}
