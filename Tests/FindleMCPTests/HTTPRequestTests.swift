// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest

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
