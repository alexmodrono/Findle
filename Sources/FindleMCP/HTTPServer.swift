// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import Network

/// A minimal Streamable-HTTP transport for the MCP server, for tunnelling to
/// remote clients (e.g. ChatGPT via ngrok). JSON-RPC over HTTP POST, gated by a
/// bearer token. No SSE — tools don't need server push, so GET returns 405.
///
/// Built on Network.framework to avoid pulling in a web-server dependency. Binds
/// to 127.0.0.1 only; exposure is the user's tunnel's job, and the token is the
/// security boundary.
final class HTTPServer: @unchecked Sendable {
    private let port: NWEndpoint.Port
    private let token: String
    private let handler: @Sendable (Data) -> Data?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "es.amodrono.foodle.mcp.http", attributes: .concurrent)

    init(port: UInt16, token: String, handler: @escaping @Sendable (Data) -> Data?) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 8080
        self.token = token
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest(buffer) {
                self.respond(to: request, on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        guard request.bearerToken == token else {
            send("401 Unauthorized", body: Self.errorBody("Unauthorized"), on: connection)
            return
        }
        switch request.method {
        case "POST":
            if let response = handler(request.body) {
                send("200 OK", body: response, on: connection)
            } else {
                send("202 Accepted", body: Data(), on: connection)
            }
        case "GET":
            // No server-initiated SSE stream is offered.
            send("405 Method Not Allowed", body: Self.errorBody("Method Not Allowed"), on: connection)
        case "DELETE":
            // Session termination — this server is stateless, nothing to clean up.
            send("200 OK", body: Data(), on: connection)
        default:
            send("404 Not Found", body: Self.errorBody("Not Found"), on: connection)
        }
    }

    private func send(_ status: String, body: Data, on connection: NWConnection) {
        var header = "HTTP/1.1 \(status)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"

        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func errorBody(_ message: String) -> Data {
        Data(#"{"error":"\#(message)"}"#.utf8)
    }
}

/// A parsed HTTP/1.1 request, or `nil` if the buffer doesn't yet hold a complete
/// one (headers up to `\r\n\r\n` plus `Content-Length` body bytes).
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var bearerToken: String? {
        guard let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") else { return nil }
        return String(auth.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
    }

    init?(_ buffer: Data) {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerString = String(data: buffer[..<separator.lowerBound], encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        self.headers = headers

        let available = buffer[separator.upperBound...]
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        guard available.count >= contentLength else { return nil }
        body = Data(available.prefix(contentLength))
    }
}
