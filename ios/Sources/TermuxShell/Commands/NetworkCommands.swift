import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum NetworkCommands {
    static func register(_ r: CommandRegistry) {
        r.register("curl", "transfer a URL (-o FILE, -O, -s, -I, -L, -X METHOD, -d DATA, -H HEADER)") { curl($0) }
        r.register("wget", "download a URL (-O FILE, -q)") { wget($0) }
    }

    struct Response {
        var data: Data
        var status: Int
        var headers: [String: String]
    }

    enum FetchError: Error { case cancelled, failed(String) }

    static func fetch(_ request: URLRequest, context: CommandContext, followRedirects: Bool = true) -> Result<Response, FetchError> {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        let delegate = RedirectDelegate(follow: followRedirects)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        let result = LockedBox<Result<Response, FetchError>>(.failure(.failed("no response")))
        let task = session.dataTask(with: request) { data, response, error in
            if let e = error {
                result.value = .failure(.failed(e.localizedDescription))
            } else {
                let http = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                for (k, v) in http?.allHeaderFields ?? [:] { headers["\(k)"] = "\(v)" }
                result.value = .success(Response(data: data ?? Data(), status: http?.statusCode ?? 0, headers: headers))
            }
            done.signal()
        }
        task.resume()
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            if context.isCancelled {
                task.cancel()
                _ = done.wait(timeout: .now() + 2)
                return .failure(.cancelled)
            }
        }
        return result.value
    }

    final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        let follow: Bool
        init(follow: Bool) { self.follow = follow }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(follow ? request : nil)
        }
    }

    static func normalizeURL(_ s: String) -> URL? {
        let text = s.contains("://") ? s : "http://" + s
        guard let url = URL(string: text), url.host != nil else { return nil }
        return url
    }

    static func curl(_ context: CommandContext) -> Int32 {
        var arguments = context.arguments
        var output: String? = nil
        var remoteName = false, silent = false, headOnly = false, includeHeaders = false, follow = false, failFlag = false
        var method: String? = nil
        var body: String? = nil
        var headers: [(String, String)] = []
        var urls: [String] = []
        while !arguments.isEmpty {
            let a = arguments.removeFirst()
            func value() -> String? { arguments.isEmpty ? nil : arguments.removeFirst() }
            switch a {
            case "-o", "--output": output = value()
            case "-O", "--remote-name": remoteName = true
            case "-s", "--silent", "-S", "-sS", "-Ss": silent = true
            case "-I", "--head": headOnly = true
            case "-i", "--include": includeHeaders = true
            case "-L", "--location": follow = true
            case "-f", "--fail": failFlag = true
            case "-fsSL", "-sSL", "-sL", "-Ls", "-fsL", "-fSL": silent = true; follow = true; failFlag = a.contains("f")
            case "-X", "--request": method = value()
            case "-d", "--data", "--data-raw", "--data-binary": body = value()
            case "-H", "--header":
                if let h = value(), let colon = h.firstIndex(of: ":") {
                    headers.append((String(h[..<colon]), h[h.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
                }
            case "-A", "--user-agent": if let v = value() { headers.append(("User-Agent", v)) }
            case "-v", "--verbose", "-k", "--insecure", "-#", "--progress-bar", "--compressed": break
            default:
                if a.hasPrefix("-") && a.count > 1 { context.error("option \(a): is unknown"); return 2 }
                urls.append(a)
            }
        }
        guard let urlText = urls.first else { context.error("no URL specified!"); context.stderr.writeLine("curl: try 'curl --help' for more information"); return 2 }
        guard let url = normalizeURL(urlText) else { context.error("(3) URL rejected: Malformed input to a URL function"); return 3 }
        var request = URLRequest(url: url)
        request.httpMethod = method ?? (headOnly ? "HEAD" : (body != nil ? "POST" : "GET"))
        if let b = body {
            request.httpBody = Data(b.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("curl/8.0 (Termux iOS)", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        switch fetch(request, context: context, followRedirects: follow) {
        case .failure(.cancelled):
            return 130
        case .failure(.failed(let message)):
            if !silent || context.arguments.contains("-S") || context.arguments.contains("-sS") { context.error("(6) \(message)") }
            return 6
        case .success(let resp):
            if failFlag && resp.status >= 400 {
                if !silent { context.error("(22) The requested URL returned error: \(resp.status)") }
                return 22
            }
            var out: [UInt8] = []
            if headOnly || includeHeaders {
                var head = "HTTP/1.1 \(resp.status) \(HTTPURLResponse.localizedString(forStatusCode: resp.status).capitalized)\r\n"
                for (k, v) in resp.headers.sorted(by: { $0.key < $1.key }) { head += "\(k.lowercased()): \(v)\r\n" }
                head += "\r\n"
                out += Array(head.utf8)
            }
            if !headOnly { out += [UInt8](resp.data) }
            if remoteName && output == nil {
                let name = url.lastPathComponent
                output = name.isEmpty || name == "/" ? "index.html" : name
            }
            if let o = output, o != "-" {
                do { try Data(out).write(to: URL(fileURLWithPath: context.resolve(o))) }
                catch { context.error("(23) Failure writing output to destination"); return 23 }
                if !silent { context.stderr.writeLine("  % Total: \(out.count) bytes written to \(o)") }
            } else {
                context.stdout.write(out)
            }
            return 0
        }
    }

    static func wget(_ context: CommandContext) -> Int32 {
        var arguments = context.arguments
        var output: String? = nil
        var quiet = false
        var urls: [String] = []
        while !arguments.isEmpty {
            let a = arguments.removeFirst()
            switch a {
            case "-O", "--output-document": output = arguments.isEmpty ? nil : arguments.removeFirst()
            case "-q", "--quiet": quiet = true
            case "-qO", "-qO-": quiet = true; output = a == "-qO-" ? "-" : (arguments.isEmpty ? nil : arguments.removeFirst())
            case "-O-": output = "-"
            case "-c", "--continue", "-nv", "--no-verbose", "--no-check-certificate": break
            default:
                if a.hasPrefix("-") && a.count > 1 { context.error("unrecognized option '\(a)'"); return 2 }
                urls.append(a)
            }
        }
        guard let urlText = urls.first else { context.error("missing URL"); return 1 }
        guard let url = normalizeURL(urlText) else { context.error("\(urlText): Invalid URL"); return 1 }
        if !quiet { context.stderr.writeLine("Connecting to \(url.host ?? urlText)...") }
        switch fetch(URLRequest(url: url), context: context) {
        case .failure(.cancelled): return 130
        case .failure(.failed(let message)): context.error(message); return 4
        case .success(let resp):
            if resp.status >= 400 { context.error("server returned error: HTTP \(resp.status)"); return 8 }
            let name = output ?? { let n = url.lastPathComponent; return n.isEmpty || n == "/" ? "index.html" : n }()
            if name == "-" { context.stdout.write([UInt8](resp.data)); return 0 }
            do { try resp.data.write(to: URL(fileURLWithPath: context.resolve(name))) }
            catch { context.error("\(name): Permission denied"); return 3 }
            if !quiet { context.stderr.writeLine("Saving to: '\(name)'\n'\(name)' saved [\(resp.data.count)]") }
            return 0
        }
    }
}
