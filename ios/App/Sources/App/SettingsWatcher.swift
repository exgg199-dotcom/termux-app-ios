import Foundation

/// Watches the Termux configuration files (`~/.termux/termux.properties`, `colors.properties`,
/// `font.ttf`) and their directory for changes, so that editing them (e.g. from the built-in shell
/// or the Files app) reloads the settings, like `termux-reload-settings` does on Android.
final class SettingsWatcher {

    private var sources: [DispatchSourceFileSystemObject] = []
    private let onChange: () -> Void
    private var pendingWork: DispatchWorkItem?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// (Re)start watching the given files and directories. Missing paths are skipped.
    func watch(_ urls: [URL]) {
        stop()
        for url in urls {
            let fd = open(url.path, O_EVTONLY)
            if fd < 0 { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
            source.setEventHandler { [weak self] in
                self?.scheduleChange()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        pendingWork?.cancel()
        pendingWork = nil
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
    }

    /// Debounce, editors usually write a file in several steps.
    private func scheduleChange() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
