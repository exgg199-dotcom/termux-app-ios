import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PackageFetchError: Error, Equatable {
    case cancelled
    case failed(String)
    case httpStatus(Int)

    public var message: String {
        switch self {
        case .cancelled: return "Interrupted"
        case .failed(let message): return message
        case .httpStatus(let status): return "\(status)  \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)"
        }
    }
}

public protocol PackageFetcher: AnyObject {
    func fetch(_ url: URL, to destination: String, cancellation: CancellationToken,
               progress: @escaping (Int64, Int64?) -> Void) -> Result<Int64, PackageFetchError>
}

public final class URLSessionPackageFetcher: NSObject, PackageFetcher {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    public func fetch(_ url: URL, to destination: String, cancellation: CancellationToken,
                      progress: @escaping (Int64, Int64?) -> Void) -> Result<Int64, PackageFetchError> {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: destination)
        if url.isFileURL {
            if cancellation.isCancelled { return .failure(.cancelled) }
            guard fileManager.fileExists(atPath: url.path) else { return .failure(.failed("File not found - \(url.path)")) }
            do {
                try fileManager.copyItem(atPath: url.path, toPath: destination)
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
            let size = (try? fileManager.attributesOfItem(atPath: destination)[.size] as? NSNumber)?.int64Value ?? 0
            progress(size, size)
            return .success(size)
        }
        guard fileManager.createFile(atPath: destination, contents: nil), let handle = FileHandle(forWritingAtPath: destination) else {
            return .failure(.failed("Could not create \(destination)"))
        }
        let download = PackageDownload(handle: handle)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("termux-ios-pkg/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        task.resume()
        var cancelled = false
        while download.finished.wait(timeout: .now() + 0.1) == .timedOut {
            let state = download.state
            progress(state.received, state.expected)
            if cancellation.isCancelled && !cancelled {
                cancelled = true
                task.cancel()
            }
        }
        session.finishTasksAndInvalidate()
        handle.closeFile()
        let state = download.state
        if cancelled || cancellation.isCancelled {
            try? fileManager.removeItem(atPath: destination)
            return .failure(.cancelled)
        }
        if let status = state.status, !(200..<300).contains(status) {
            try? fileManager.removeItem(atPath: destination)
            return .failure(.httpStatus(status))
        }
        if let error = state.error {
            try? fileManager.removeItem(atPath: destination)
            return .failure(.failed(error))
        }
        progress(state.received, state.expected ?? state.received)
        return .success(state.received)
    }
}

final class PackageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct State {
        var received: Int64 = 0
        var expected: Int64?
        var status: Int?
        var error: String?
    }

    let finished = DispatchSemaphore(value: 0)
    private let handle: FileHandle
    private let lock = NSLock()
    private var current = State()

    init(handle: FileHandle) {
        self.handle = handle
    }

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode
        lock.lock()
        current.status = status
        current.expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        lock.unlock()
        if let status = status, !(200..<300).contains(status) {
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handle.write(data)
        lock.lock()
        current.received += Int64(data.count)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if current.status == nil, let response = task.response as? HTTPURLResponse {
            current.status = response.statusCode
        }
        if let error = error, current.status.map({ (200..<300).contains($0) }) ?? true {
            current.error = error.localizedDescription
        }
        lock.unlock()
        finished.signal()
    }
}
