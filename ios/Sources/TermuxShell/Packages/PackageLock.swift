import Foundation

final class PackageLock {
    private let fileDescriptor: Int32

    init?(path: String) {
        try? FileManager.default.createDirectory(atPath: ShellPath.dirname(path), withIntermediateDirectories: true)
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        fileDescriptor = descriptor
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }
}
