// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
import Darwin
import Synchronization

final class HTTPRequestTests: XCTestCase {
    func testParsesCompletePost() throws {
        let raw = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer abc123\r\nContent-Length: 9\r\n\r\n{\"a\":\"b\"}"
        let request = try XCTUnwrap(HTTPRequest(Data(raw.utf8)))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.bearerToken, "abc123")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "{\"a\":\"b\"}")
    }

    func testHeaderLookupIsCaseInsensitive() throws {
        let raw = "POST / HTTP/1.1\r\nAUTHORIZATION: bearer XYZ\r\nContent-Length: 0\r\n\r\n"
        let request = try XCTUnwrap(HTTPRequest(Data(raw.utf8)))
        XCTAssertEqual(request.bearerToken, "XYZ")
    }

    func testIncompleteBodyReturnsNil() {
        // Declares 20 bytes but only "short" (5) are present — wait for more.
        let raw = "POST / HTTP/1.1\r\nContent-Length: 20\r\n\r\nshort"
        XCTAssertNil(HTTPRequest(Data(raw.utf8)))
    }

    func testIncompleteHeadersReturnNil() {
        XCTAssertNil(HTTPRequest(Data("POST / HTTP/1.1\r\nHost: x".utf8)))
    }

    func testMissingTokenIsNil() throws {
        let raw = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        let request = try XCTUnwrap(HTTPRequest(Data(raw.utf8)))
        XCTAssertNil(request.bearerToken)
        XCTAssertEqual(request.method, "GET")
    }
}

extension HTTPRequestTests {
    func testRejectsNegativeOverflowingAndAmbiguousLengths() {
        for length in ["-1", "+1", "9223372036854775808", "1, 1", "", "one", "1 0"] {
            let raw = "POST /mcp HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n"
            assertInvalid(raw, .malformed)
        }
        assertInvalid("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n", .malformed)
        assertInvalid("POST / HTTP/1.1\r\nContent-Length: 1\r\ncontent-length: 1\r\n\r\nx", .malformed)
    }

    func testRejectsUnsupportedTransferEncodingAndMissingPostLength() {
        assertInvalid("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", .malformed)
        assertInvalid("POST / HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n", .malformed)
        assertInvalid("POST / HTTP/1.1\r\nHost: localhost\r\n\r\n", .lengthRequired)
    }

    func testRejectsOversizeHeadersBeforeTheyComplete() {
        assertInvalid(String(repeating: "a", count: HTTPRequest.maximumHeaderBytes), .headersTooLarge)
        let raw = "GET / HTTP/1.1\r\nLong: " + String(repeating: "a", count: HTTPRequest.maximumHeaderBytes) + "\r\n\r\n"
        assertInvalid(raw, .headersTooLarge)
    }

    func testRejectsOversizeBodyFromDeclaredLengthBeforeReceivingIt() {
        assertInvalid("POST / HTTP/1.1\r\nContent-Length: \(HTTPRequest.maximumBodyBytes + 1)\r\n\r\n", .bodyTooLarge)
    }

    func testAcceptsBodyAtLimitAndRejectsTrailingBytes() throws {
        let header = "POST / HTTP/1.1\r\nContent-Length: \(HTTPRequest.maximumBodyBytes)\r\n\r\n"
        var raw = Data(header.utf8)
        raw.append(Data(repeating: 65, count: HTTPRequest.maximumBodyBytes))
        XCTAssertEqual(try XCTUnwrap(HTTPRequest(raw)).body.count, HTTPRequest.maximumBodyBytes)
        raw.append(65)
        guard case .invalid(.bodyTooLarge) = HTTPRequest.parse(raw) else { return XCTFail("Oversize body accepted") }
        assertInvalid("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\nx", .malformed)
    }

    func testEveryFragmentStaysIncompleteUntilRequestIsComplete() throws {
        let raw = Data("POST /mcp HTTP/1.1\r\nContent-Length: 7\r\n\r\n{\"a\":1}".utf8)
        for end in 0..<raw.count {
            guard case .incomplete = HTTPRequest.parse(Data(raw.prefix(end))) else {
                return XCTFail("Prefix of \(end) bytes was not incomplete")
            }
        }
        XCTAssertEqual(try XCTUnwrap(HTTPRequest(raw)).body, Data("{\"a\":1}".utf8))
    }

    func testRejectsMalformedRequestLinesAndAmbiguousHeaders() {
        for line in ["POST /", "POST / HTTP/2", "POST  / HTTP/1.1", "POST / HTTP/1.1 extra", "P\tOST / HTTP/1.1"] {
            assertInvalid(line + "\r\nContent-Length: 0\r\n\r\n", .malformed)
        }
        for header in [" Content-Length: 0", "Content-Length : 0", "Broken", "X-Test: bad\u{0}value", "Authorization: Bearer a\r\nAuthorization: Bearer b"] {
            assertInvalid("GET / HTTP/1.1\r\n" + header + "\r\n\r\n", .malformed)
        }
    }

    func testRepeatedNonFramingHeadersCanBeCombined() throws {
        let request = try XCTUnwrap(HTTPRequest(Data("GET / HTTP/1.1\r\nAccept: application/json\r\nAccept: text/event-stream\r\n\r\n".utf8)))
        XCTAssertEqual(request.headers["accept"], "application/json, text/event-stream")
    }

    private func assertInvalid(_ raw: String, _ expected: HTTPRequest.ParseError, file: StaticString = #filePath, line: UInt = #line) {
        guard case .invalid(let error) = HTTPRequest.parse(Data(raw.utf8)) else {
            return XCTFail("Invalid request was accepted or treated as incomplete", file: file, line: line)
        }
        XCTAssertEqual(error, expected, file: file, line: line)
    }
}

final class HTTPServerTests: XCTestCase {
    func testLoopbackAuthenticationAndMalformedFraming() throws {
        let (server, port) = try startServer { body in body }
        defer { server.stop() }
        let unauthorized = try SocketClient(port: port)
        try unauthorized.send(request(body: "{}", token: "wrong"))
        XCTAssertTrue(try unauthorized.readAll().contains("401 Unauthorized"))

        let malformed = try SocketClient(port: port)
        try malformed.send("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n")
        XCTAssertTrue(try malformed.readAll().contains("400 Bad Request"))

        let valid = try SocketClient(port: port)
        try valid.send("POST /mcp HTTP/1.1\r\nAuthorization: Bearer test-token\r\nContent-Length: 2\r\n\r\n{")
        try valid.send("}")
        let response = try valid.readAll()
        XCTAssertTrue(response.contains("200 OK"))
        XCTAssertTrue(response.hasSuffix("{}"))
    }

    func testReadDeadlineClosesStalledRequestAndReleasesSlot() throws {
        let (server, port) = try startServer(limits: .init(maximumConnections: 1, requestTimeout: 0.1)) { $0 }
        defer { server.stop() }
        let stalled = try SocketClient(port: port)
        try stalled.send("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\nx")
        // Wait for the server's real timeout/EOF, not a timing sleep. The socket
        // itself has a larger deadline, so a server that never expires fails.
        XCTAssertEqual(try stalled.readAll(), "")
        let valid = try SocketClient(port: port)
        try valid.send(request(body: "{}"))
        XCTAssertTrue(try valid.readAll().contains("200 OK"))
    }

    func testConnectionLimitIncludesActiveHandlers() throws {
        let entered = expectation(description: "First tool entered")
        let release = DispatchSemaphore(value: 0)
        let (server, port) = try startServer(limits: .init(maximumConnections: 1, requestTimeout: 2)) { body in
            if body == Data("block".utf8) {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
            }
            return body
        }
        defer { release.signal(); server.stop() }
        let first = try SocketClient(port: port)
        try first.send(request(body: "block"))
        wait(for: [entered], timeout: 3)

        let excess = try SocketClient(port: port)
        // No request is needed: admission must reject this connection even
        // while the first handler is running on a different queue.
        XCTAssertEqual(try excess.readAll(), "")
        release.signal()
        XCTAssertTrue(try first.readAll().contains("200 OK"))

        let next = try SocketClient(port: port)
        try next.send(request(body: "{}"))
        XCTAssertTrue(try next.readAll().contains("200 OK"))
    }

    func testDisconnectReleasesReadSlot() throws {
        let (server, port) = try startServer(limits: .init(maximumConnections: 1, requestTimeout: 2)) { $0 }
        defer { server.stop() }
        let incomplete = try SocketClient(port: port)
        try incomplete.send("POST /mcp HTTP/1.1\r\n")
        incomplete.finishSending()
        XCTAssertEqual(try incomplete.readAll(), "")
        let next = try SocketClient(port: port)
        try next.send(request(body: "{}"))
        XCTAssertTrue(try next.readAll().contains("200 OK"))
    }

    func testOccupiedPortReportsStartupFailure() throws {
        let (server, port) = try startServer { $0 }
        defer { server.stop() }
        let failure = expectation(description: "Occupied port reported")
        let second = HTTPServer(port: port, token: "test-token") { $0 }
        defer { second.stop() }
        do {
            try second.start(onReady: { _ in XCTFail("Bound an occupied exclusive port") }, onFailure: { _ in failure.fulfill() })
        } catch {
            failure.fulfill()
        }
        wait(for: [failure], timeout: 3)
    }

    private func startServer(limits: HTTPServer.Limits = .init(), handler: @escaping @Sendable (Data) -> Data?) throws -> (HTTPServer, UInt16) {
        let ready = expectation(description: "Listener ready")
        let port = Mutex<UInt16?>(nil)
        let server = HTTPServer(port: 0, token: "test-token", limits: limits, handler: handler)
        try server.start(onReady: { bound in port.withLock { $0 = bound }; ready.fulfill() }, onFailure: { error in
            XCTFail("Listener failed: \(error)")
            ready.fulfill()
        })
        wait(for: [ready], timeout: 3)
        return (server, try XCTUnwrap(port.withLock { $0 }))
    }

    private func request(body: String, token: String = "test-token") -> String {
        "POST /mcp HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }
}

/// A bounded, blocking test peer. Server callbacks run on their own queue.
private final class SocketClient {
    private let descriptor: Int32

    init(port: UInt16) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    deinit { Darwin.close(descriptor) }

    func send(_ text: String) throws {
        let data = Data(text.utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }

    func finishSending() { shutdown(descriptor, SHUT_WR) }

    func readAll() throws -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 || (count < 0 && errno == ECONNRESET) { return String(decoding: data, as: UTF8.self) }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw POSIXError(.EMSGSIZE)
    }
}
