//
//  AndroidFileSystemProvider.swift
//  Code
//
//  FileSystemProvider backend for a lightweight LAN file server running on
//  an Android device. Local-network only: no cloud relay, no remote code
//  execution, no remote terminal — file browsing/editing only.
//
//  gitServiceProvider is intentionally nil for now: GitServiceProvider's
//  methods return native SwiftGit2 object types (Commit, OID, Branch,
//  TagReference, StatusEntry) backed by libgit2, which LocalGitServiceProvider
//  gets "for free" by opening a real local .git directory. There is no local
//  .git directory here to open, so wiring Git support up properly needs a
//  deliberate design choice (see the accompanying explanation) rather than a
//  provider that builds but silently returns fake objects.
//

import Foundation

enum AndroidFSError: String, LocalizedError {
    case InvalidHostURL = "errors.android.invalid_host_url"
    case ServerUnreachable = "errors.android.server_unreachable"
    case AuthFailure = "errors.android.auth_failure"
    case BadResponse = "errors.android.bad_response"
    case WriteConflict = "errors.android.write_conflict"

    var errorDescription: String? {
        NSLocalizedString(self.rawValue, comment: "")
    }
}

private struct AndroidListEntry: Decodable {
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Double  // unix epoch seconds
}

private struct AndroidStatResponse: Decodable {
    let size: Int64
    let modified: Double
    let isDirectory: Bool
}

private struct AndroidMovePayload: Encodable {
    let from: String
    let to: String
}

class AndroidFileSystemProvider: NSObject, FileSystemProvider {

    static var registeredScheme: String = "android"
    var gitServiceProvider: GitServiceProvider? = nil
    var searchServiceProvider: SearchServiceProvider? = nil
    var terminalServiceProvider: TerminalServiceProvider? = nil
    var portforwardServiceProvider: (any PortForwardServiceProvider)? = nil

    private let host: String
    private let port: Int
    private let token: String
    private let session: URLSession
    private var wsTask: URLSessionWebSocketTask?
    private var wsReconnectAttempt = 0
    private var manuallyDisconnected = false

    private let didDisconnect: (Error) -> Void
    private let onFileChanged: (URL) -> Void

    /// Tracks the last-known modification time per remote path, populated on
    /// read, so `write` can detect a conflicting external edit before
    /// clobbering it (the "prevent overwrite conflicts" requirement).
    private var knownModified: [String: Double] = [:]
    private let stateQueue = DispatchQueue(label: "android.fs.state.queue")

    init?(
        baseURL: URL, token: String, didDisconnect: @escaping (Error) -> Void,
        onFileChanged: @escaping (URL) -> Void
    ) {
        guard baseURL.scheme == "android", let host = baseURL.host, let port = baseURL.port
        else {
            return nil
        }
        self.host = host
        self.port = port
        self.token = token
        self.didDisconnect = didDisconnect
        self.onFileChanged = onFileChanged

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        super.init()
    }

    deinit {
        wsTask?.cancel(with: .goingAway, reason: nil)
    }

    private var httpBaseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }

    private var wsBaseURL: URL {
        URL(string: "ws://\(host):\(port)/ws/watch")!
    }

    // MARK: - Connectivity

    /// Verifies the server is reachable and the token is accepted, then
    /// starts the live-sync WebSocket. Called once by WorkSpaceStorage right
    /// after construction, mirroring how FTPFileSystemProvider probes with
    /// `contentsOfDirectory` before being registered.
    func ping() async throws {
        let request = authorizedRequest(path: "api/ping")
        _ = try await perform(request, body: nil)
        startWatching()
    }

    func disconnect() {
        manuallyDisconnected = true
        wsTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Networking core

    private func authorizedRequest(path: String, query: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(
            url: httpBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform(_ request: URLRequest, body: Data?) async throws -> Data {
        var request = request
        if let body {
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AndroidFSError.ServerUnreachable
        }
        guard let http = response as? HTTPURLResponse else {
            throw AndroidFSError.BadResponse
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw AndroidFSError.AuthFailure
        case 409:
            throw AndroidFSError.WriteConflict
        default:
            throw AndroidFSError.BadResponse
        }
    }

    private func remotePath(for url: URL) -> String {
        // `android://host:port/some/project/path` -> "/some/project/path"
        url.path.isEmpty ? "/" : url.path
    }

    // MARK: - FileSystemProvider

    func contentsOfDirectory(at url: URL, completionHandler: @escaping ([URL]?, Error?) -> Void) {
        Task {
            do {
                let req = authorizedRequest(
                    path: "api/list", query: ["path": remotePath(for: url)])
                let data = try await perform(req, body: nil)
                let entries = try JSONDecoder().decode([AndroidListEntry].self, from: data)
                let urls = entries.map { entry -> URL in
                    url.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
                }
                completionHandler(urls, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }

    func fileExists(at url: URL, completionHandler: @escaping (Bool) -> Void) {
        Task {
            let req = authorizedRequest(
                path: "api/exists", query: ["path": remotePath(for: url)])
            guard let data = try? await perform(req, body: nil),
                let result = try? JSONDecoder().decode([String: Bool].self, from: data)
            else {
                completionHandler(false)
                return
            }
            completionHandler(result["exists"] ?? false)
        }
    }

    func createDirectory(
        at: URL, withIntermediateDirectories: Bool, completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                var req = authorizedRequest(
                    path: "api/mkdir", query: ["path": remotePath(for: at)])
                req.httpMethod = "POST"
                _ = try await perform(req, body: nil)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func removeItem(at: URL, completionHandler: @escaping (Error?) -> Void) {
        Task {
            do {
                var req = authorizedRequest(
                    path: "api/delete", query: ["path": remotePath(for: at)])
                req.httpMethod = "POST"
                _ = try await perform(req, body: nil)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func moveItem(at: URL, to: URL, completionHandler: @escaping (Error?) -> Void) {
        transfer(operation: "move", at: at, to: to, completionHandler: completionHandler)
    }

    func copyItem(at: URL, to: URL, completionHandler: @escaping (Error?) -> Void) {
        transfer(operation: "copy", at: at, to: to, completionHandler: completionHandler)
    }

    /// Handles move/copy, including the cross-transport case where one side
    /// is a local `file://` URL (dragging a file between the local Explorer
    /// node and the Android node) — mirrors SFTPFileSystemProvider's
    /// copyItemFromRemoteToLocal handling.
    private func transfer(
        operation: String, at: URL, to: URL, completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                if at.isFileURL && !to.isFileURL {
                    // Local -> Android: upload
                    let localData = try Data(contentsOf: at)
                    try await self.writeRemote(at: to, content: localData, overwrite: true)
                    if operation == "move" {
                        try? FileManager.default.removeItem(at: at)
                    }
                } else if !at.isFileURL && to.isFileURL {
                    // Android -> Local: download
                    let remoteData = try await self.readData(at: at)
                    try remoteData.write(to: to)
                    if operation == "move" {
                        try await self.deleteRemote(at: at)
                    }
                } else {
                    // Android -> Android
                    var req = authorizedRequest(path: "api/\(operation)")
                    req.httpMethod = "POST"
                    let payload = AndroidMovePayload(
                        from: remotePath(for: at), to: remotePath(for: to))
                    _ = try await perform(req, body: try JSONEncoder().encode(payload))
                }
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    private func writeRemote(at: URL, content: Data, overwrite: Bool) async throws {
        var req = authorizedRequest(
            path: "api/write",
            query: ["path": remotePath(for: at), "overwrite": overwrite ? "true" : "false"])
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try await perform(req, body: content)
    }

    private func readData(at url: URL) async throws -> Data {
        let req = authorizedRequest(path: "api/read", query: ["path": remotePath(for: url)])
        return try await perform(req, body: nil)
    }

    private func deleteRemote(at url: URL) async throws {
        var req = authorizedRequest(path: "api/delete", query: ["path": remotePath(for: url)])
        req.httpMethod = "POST"
        _ = try await perform(req, body: nil)
    }

    func contents(at: URL, completionHandler: @escaping (Data?, Error?) -> Void) {
        Task {
            do {
                let data = try await readData(at: at)
                // Record modification time at read so `write` can detect a
                // conflicting change made on the Android device meanwhile.
                if let attrs = try? await fetchStat(at: at) {
                    stateQueue.sync { knownModified[remotePath(for: at)] = attrs.modified }
                }
                completionHandler(data, nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }

    func write(
        at: URL, content: Data, atomically: Bool, overwrite: Bool,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                // Overwrite-conflict guard: if we have a last-known mtime for
                // this path and the server's current mtime has moved past
                // it, the file changed on the Android device since we last
                // loaded it into Monaco — refuse instead of silently
                // clobbering it.
                let path = remotePath(for: at)
                if let known = stateQueue.sync(execute: { knownModified[path] }),
                    let current = try? await fetchStat(at: at), current.modified > known
                {
                    completionHandler(AndroidFSError.WriteConflict)
                    return
                }

                try await writeRemote(at: at, content: content, overwrite: overwrite)
                if let attrs = try? await fetchStat(at: at) {
                    stateQueue.sync { knownModified[path] = attrs.modified }
                }
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    private func fetchStat(at url: URL) async throws -> AndroidStatResponse {
        let req = authorizedRequest(path: "api/stat", query: ["path": remotePath(for: url)])
        let data = try await perform(req, body: nil)
        return try JSONDecoder().decode(AndroidStatResponse.self, from: data)
    }

    func attributesOfItem(
        at: URL, completionHandler: @escaping ([FileAttributeKey: Any?]?, Error?) -> Void
    ) {
        Task {
            do {
                let attrs = try await fetchStat(at: at)
                completionHandler(
                    [
                        .size: attrs.size,
                        .modificationDate: Date(timeIntervalSince1970: attrs.modified),
                    ], nil)
            } catch {
                completionHandler(nil, error)
            }
        }
    }

    // MARK: - Live synchronization (WebSocket)

    private struct ChangeEvent: Decodable {
        let event: String
        let path: String
    }

    private func startWatching() {
        manuallyDisconnected = false
        wsReconnectAttempt = 0
        connectWebSocket()
    }

    private func connectWebSocket() {
        var request = URLRequest(url: wsBaseURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        self.wsTask = task
        task.resume()
        listen()
    }

    private func listen() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.wsReconnectAttempt = 0
                if case .string(let text) = message,
                    let data = text.data(using: .utf8),
                    let event = try? JSONDecoder().decode(ChangeEvent.self, from: data)
                {
                    var components = URLComponents()
                    components.scheme = "android"
                    components.host = self.host
                    components.port = self.port
                    components.path = event.path
                    if let url = components.url {
                        DispatchQueue.main.async {
                            self.onFileChanged(url)
                        }
                    }
                }
                self.listen()
            case .failure:
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard !manuallyDisconnected else { return }
        wsReconnectAttempt += 1
        let delay = min(30.0, pow(2.0, Double(wsReconnectAttempt)))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.manuallyDisconnected else { return }
            self.connectWebSocket()
        }
    }
}
