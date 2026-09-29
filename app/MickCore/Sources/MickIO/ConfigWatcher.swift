import Darwin
import Dispatch
import Foundation

/// Notices hand edits to `config.json` (SPEC §11). Mick's own saves and most editors
/// replace the file (write a temp file, rename it over), which a vnode source on the
/// file itself would lose, so this watches the directory for entry changes and the
/// current file for in-place writes (editors that overwrite), reopening the file
/// source whenever the directory changes. Changes are debounced, then `onChange`
/// runs; the caller compares contents, since the directory also changes for every
/// state save and events rotation.
public final class ConfigWatcher: @unchecked Sendable {
    public let file: URL
    private let debounce: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "mick.config-watcher")

    // Only touched on `queue`.
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var pending: DispatchWorkItem?
    private var stopped = false

    public init(file: URL, debounce: TimeInterval = 0.15, onChange: @escaping @Sendable () -> Void) {
        self.file = file
        self.debounce = debounce
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard !stopped, directorySource == nil else { return }
            let dirFD = open(file.deletingLastPathComponent().path, O_EVTONLY)
            guard dirFD >= 0 else { return }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: [.write, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self] in
                self?.watchFile()
                self?.changed()
            }
            source.setCancelHandler { close(dirFD) }
            source.resume()
            directorySource = source
            watchFile()
        }
    }

    public func stop() {
        queue.sync { [self] in
            stopped = true
            pending?.cancel()
            pending = nil
            directorySource?.cancel()
            directorySource = nil
            fileSource?.cancel()
            fileSource = nil
        }
    }

    /// Blocks until everything queued so far has run (tests).
    public func waitUntilIdle() {
        queue.sync {}
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(file.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) { self.watchFile() }
            self.changed()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func changed() {
        guard !stopped else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.onChange()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
