// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import Network

/// Loopback-only, bearer-authenticated HTTP transport. Each connection serves
/// one request. Mutable listener/connection state is confined to `queue`;
/// immutable handlers run on `handlerQueue` so a slow tool cannot block reads
/// or their deadlines. That confinement is the basis for Sendable conformance.
final class HTTPServer: @unchecked Sendable {
    struct Limits: Sendable {
        var maximumConnections = 16
        var requestTimeout: TimeInterval = 15
    }

    private struct Connection {
        let transport: NWConnection
        let deadline: DispatchWorkItem
        var processing = false
        var closed = false
    }

    private let port: NWEndpoint.Port
    private let token: String
    private let limits: Limits
    private let handler: @Sendable (Data) -> Data?
    private let queue = DispatchQueue(label: "es.amodrono.findle.mcp.http")
    private let handlerQueue = DispatchQueue(label: "es.amodrono.findle.mcp.http.handlers", attributes: .concurrent)
    private var listener: NWListener?
    private var connections: [UUID: Connection] = [:]

    init(port: UInt16, token: String, limits: Limits = Limits(), handler: @escaping @Sendable (Data) -> Data?) {
        self.port = NWEndpoint.Port(rawValue: port) ?? .any
        self.token = token
        self.limits = limits
        self.handler = handler
    }

    /// Binding can fail asynchronously; callers can surface that failure rather
    /// than announcing readiness before Network.framework has opened the port.
    func start(
        onReady: (@Sendable (UInt16) -> Void)? = nil,
        onFailure: (@Sendable (NWError) -> Void)? = nil
    ) throws {
        try queue.sync {
            guard listener == nil else { throw POSIXError(.EALREADY) }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                self.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    if let boundPort = listener.port { onReady?(boundPort.rawValue) }
                case .failed(let error), .waiting(let error):
                    self.closeAll()
                    onFailure?(error)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { self.closeAll() }
    }

    private func closeAll() {
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        for id in Array(connections.keys) { close(id) }
    }

    private func accept(_ transport: NWConnection) {
        guard listener != nil, connections.count < max(1, limits.maximumConnections) else {
            transport.cancel()
            return
        }
        let id = UUID()
        // Absolute read deadline: receiving another byte never extends it.
        let deadline = DispatchWorkItem { [weak self] in self?.close(id) }
        connections[id] = Connection(transport: transport, deadline: deadline)
        transport.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close(id)
            default:
                break
            }
        }
        transport.start(queue: queue)
        queue.asyncAfter(deadline: .now() + max(0.01, limits.requestTimeout), execute: deadline)
        receive(id, buffer: Data())
    }

    private func close(_ id: UUID) {
        guard var connection = connections[id] else { return }
        connection.closed = true
        connection.deadline.cancel()
        connection.transport.stateUpdateHandler = nil
        connection.transport.cancel()
        // An abandoned client cannot free a slot while its tool still runs;
        // otherwise repeatedly disconnecting could spawn unlimited handlers.
        if connection.processing {
            connections[id] = connection
        } else {
            connections.removeValue(forKey: id)
        }
    }

    private func receive(_ id: UUID, buffer: Data) {
        guard let connection = connections[id], !connection.closed else { return }
        let remaining = HTTPRequest.maximumHeaderBytes + HTTPRequest.maximumBodyBytes - buffer.count
        connection.transport.receive(minimumIncompleteLength: 1, maximumLength: min(64 * 1024, max(1, remaining + 1))) { [weak self] data, _, isComplete, error in
            guard let self, let connection = self.connections[id], !connection.closed else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                self.respond(to: request, id: id)
            case .invalid(let error):
                self.send(error.status, body: Self.errorBody(error.message), id: id)
            case .incomplete:
                if error != nil || isComplete {
                    self.close(id)
                } else {
                    self.receive(id, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: HTTPRequest, id: UUID) {
        guard request.bearerToken == token, !token.isEmpty else {
            send("401 Unauthorized", body: Self.errorBody("Unauthorized"), id: id)
            return
        }
        switch request.method {
        case "POST":
            connections[id]?.deadline.cancel()
            connections[id]?.processing = true
            handlerQueue.async {
                let response = self.handler(request.body)
                self.queue.async {
                    guard let connection = self.connections[id] else { return }
                    self.connections[id]?.processing = false
                    guard !connection.closed else { self.close(id); return }
                    self.send(response == nil ? "202 Accepted" : "200 OK", body: response ?? Data(), id: id)
                }
            }
        case "GET":
            send("405 Method Not Allowed", body: Self.errorBody("Method Not Allowed"), id: id)
        case "DELETE":
            send("200 OK", body: Data(), id: id)
        default:
            send("404 Not Found", body: Self.errorBody("Not Found"), id: id)
        }
    }

    private func send(_ status: String, body: Data, id: UUID) {
        guard let connection = connections[id], !connection.closed else { return }
        // A client that stops reading the response must eventually release its slot.
        connection.deadline.cancel()
        let writeDeadline = DispatchWorkItem { [weak self] in self?.close(id) }
        connections[id] = Connection(transport: connection.transport, deadline: writeDeadline)
        queue.asyncAfter(deadline: .now() + max(0.01, limits.requestTimeout), execute: writeDeadline)
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.transport.send(content: data, completion: .contentProcessed { [weak self] _ in self?.close(id) })
    }

    private static func errorBody(_ message: String) -> Data {
        Data(#"{"error":"\#(message)"}"#.utf8)
    }
}

/// Strict framing for the single-request HTTP transport. Invalid requests are
/// distinct from incomplete ones so an attacker cannot keep malformed input
/// buffered until a timeout or trigger a negative-size collection operation.
struct HTTPRequest {
    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 1024 * 1024

    enum ParseResult {
        case incomplete
        case complete(HTTPRequest)
        case invalid(ParseError)
    }

    enum ParseError: Equatable {
        case malformed, headersTooLarge, bodyTooLarge, lengthRequired

        var status: String {
            switch self {
            case .malformed: "400 Bad Request"
            case .headersTooLarge: "431 Request Header Fields Too Large"
            case .bodyTooLarge: "413 Content Too Large"
            case .lengthRequired: "411 Length Required"
            }
        }

        var message: String {
            switch self {
            case .malformed: "Invalid request framing"
            case .headersTooLarge: "Request headers too large"
            case .bodyTooLarge: "Request body too large"
            case .lengthRequired: "Content-Length required"
            }
        }
    }

    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var bearerToken: String? {
        guard let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") else { return nil }
        return String(auth.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }

    init?(_ buffer: Data) {
        guard case .complete(let request) = Self.parse(buffer) else { return nil }
        self = request
    }

    private init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    static func parse(_ buffer: Data) -> ParseResult {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count >= maximumHeaderBytes ? .invalid(.headersTooLarge) : .incomplete
        }
        guard buffer.distance(from: buffer.startIndex, to: separator.upperBound) <= maximumHeaderBytes else {
            return .invalid(.headersTooLarge)
        }
        guard let headerString = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else { return .invalid(.malformed) }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid(.malformed) }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, isToken(parts[0]), parts[1].hasPrefix("/"),
              parts[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .invalid(.malformed) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), isToken(line[..<colon]) else { return .invalid(.malformed) }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else { return .invalid(.malformed) }
            // Duplicate framing/auth fields are ambiguous, even when a proxy
            // might choose to coalesce them. This transport never needs them.
            if let existing = headers[key] {
                guard !["content-length", "transfer-encoding", "authorization", "host"].contains(key) else {
                    return .invalid(.malformed)
                }
                headers[key] = existing + ", " + value
            } else {
                headers[key] = value
            }
        }
        // Chunked and other transfer encodings are deliberately unsupported.
        guard headers["transfer-encoding"] == nil else { return .invalid(.malformed) }
        let contentLength: Int
        if let rawLength = headers["content-length"] {
            guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let length = Int(rawLength) else { return .invalid(.malformed) }
            guard length <= maximumBodyBytes else { return .invalid(.bodyTooLarge) }
            contentLength = length
        } else {
            guard parts[0] != "POST" else { return .invalid(.lengthRequired) }
            contentLength = 0
        }
        let available = buffer[separator.upperBound...]
        guard available.count <= maximumBodyBytes else { return .invalid(.bodyTooLarge) }
        guard available.count <= contentLength else { return .invalid(.malformed) }
        guard available.count == contentLength else { return .incomplete }
        return .complete(HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: Data(available)))
    }

    private static func isToken(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || "!#$%&'*+-.^_`|~".utf8.contains(byte)
        }
    }
}
