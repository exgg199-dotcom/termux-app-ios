import Foundation

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

    func watch(_ urls: [URL]) {
        stop()
        for url in urls {
            let fileDescriptor = open(url.path, O_EVTONLY)
            if fileDescriptor < 0 { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
            source.setEventHandler { [weak self] in
                self?.scheduleChange()
            }
            source.setCancelHandler {
                close(fileDescriptor)
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

    private func scheduleChange() {
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
