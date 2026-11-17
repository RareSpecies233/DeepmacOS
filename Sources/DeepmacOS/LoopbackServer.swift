import Foundation
import Network

/// 只监听 127.0.0.1 的只读静态服务：让前端跑在真实 http origin 上（localStorage / IndexedDB 才可靠）。
final class LoopbackServer {
    private let listener: NWListener
    private let root: URL
    private let queue = DispatchQueue(label: "com.deepmacos.loopback")
    private let onReady: (UInt16) -> Void
    private let onFailure: () -> Void

    private(set) var port: UInt16 = 0
    private let requestedPort: UInt16

    init?(root: URL, port: UInt16, onReady: @escaping (UInt16) -> Void,
          onFailure: @escaping () -> Void) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // 端口必须固定：origin 变了，localStorage / IndexedDB 就换一套，历史会"消失"
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        guard let listener = try? NWListener(using: params) else { return nil }
        self.listener = listener
        self.root = root.standardizedFileURL
        self.onReady = onReady
        self.onFailure = onFailure
        self.requestedPort = port
        self.port = port
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port else { return }
                self.port = port.rawValue
                DispatchQueue.main.async { self.onReady(port.rawValue) }
            case let .failed(error):
                NSLog("DeepmacOS loopback listener failed on port \(port): \(error)")
                self.listener.cancel()
                DispatchQueue.main.async { self.onFailure() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - 请求处理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var data = buffer
            if let chunk { data.append(chunk) }
            if let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: data.subdata(in: data.startIndex ..< headerEnd.lowerBound))
                return
            }
            if error != nil || isComplete || data.count > 64 * 1024 {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: data)
        }
    }

    private func respond(_ connection: NWConnection, head: Data) {
        guard let text = String(data: head, encoding: .utf8),
              let requestLine = text.split(separator: "\r\n").first else {
            return send(connection, status: 400, type: "text/plain; charset=utf-8", body: Data("bad request".utf8))
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return send(connection, status: 400, type: "text/plain; charset=utf-8", body: Data("bad request".utf8))
        }
        let method = String(parts[0])
        var rawPath = String(parts[1])
        if let queryIndex = rawPath.firstIndex(of: "?") {
            rawPath = String(rawPath[..<queryIndex])
        }
        guard method == "GET" || method == "HEAD" else {
            return send(connection, status: 405, type: "text/plain; charset=utf-8", body: Data("method not allowed".utf8))
        }
        guard let decoded = rawPath.removingPercentEncoding, let fileURL = resolve(decoded) else {
            return send(connection, status: 404, type: "text/plain; charset=utf-8", body: Data("not found".utf8))
        }
        guard let body = try? Data(contentsOf: fileURL) else {
            return send(connection, status: 500, type: "text/plain; charset=utf-8", body: Data("read failed".utf8))
        }
        let cache = (decoded.contains("/static/"))
            ? "public, max-age=31536000, immutable"
            : "no-cache"
        send(connection, status: 200, type: mimeType(for: fileURL.pathExtension),
             body: body, cache: cache, headOnly: method == "HEAD")
    }

    /// 路径越界防护 + 目录补 index.html + 无扩展名走 SPA fallback
    private func resolve(_ path: String) -> URL? {
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !relative.contains(".."), !relative.contains("\\") else { return nil }
        var candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path.hasPrefix(root.path) else { return nil }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                candidate.appendPathComponent("index.html")
            }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        if URL(fileURLWithPath: relative).pathExtension.isEmpty {
            let index = root.appendingPathComponent("index.html")
            if FileManager.default.fileExists(atPath: index.path) { return index }
        }
        return nil
    }

    private func send(_ connection: NWConnection, status: Int, type: String, body: Data,
                      cache: String = "no-cache", headOnly: Bool = false) {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: \(cache)\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        if !headOnly { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        case "txt", "md": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
