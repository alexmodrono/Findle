// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import MCP
import FindlePersistence

/// Findle's MCP server: a local, stdio, read-only bridge that lets an agent
/// query the user's synced Moodle coursework without manual uploads.
///
/// It opens the same database the app and File Provider extension use, but
/// read-only — the app remains the single writer. The Moodle token never enters
/// this process.
@main
struct FindleMCP {
    static func main() async {
        guard let dbPath = resolveDatabasePath() else {
            failStartup("no complete database found. Open Findle and sign in first.")
        }

        let database: Database
        do {
            database = try Database(path: dbPath, readOnly: true)
        } catch {
            failStartup("could not open database: \(error.localizedDescription)")
        }

        // The full-text index and embedder are best-effort; the catalog tools
        // work without them (only text/semantic search need them).
        let indexStore = try? IndexStore()
        let catalog = Catalog(database: database, indexStore: indexStore, embedder: Embedder())

        let server = Server(
            name: "findle",
            version: "0.1.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            let args = params.arguments
            let reader = ArgReader(string: { stringArg(args, $0) }, int: { intArg(args, $0) })
            let result = catalog.callTool(named: params.name, args: reader)
            return .init(content: [.text(text: result.text, annotations: nil, _meta: nil)], isError: result.isError)
        }

        // HTTP (Streamable HTTP + bearer token) when requested, otherwise stdio.
        if let http = HTTPOptions.fromArguments() {
            runHTTP(http, catalog: catalog)
        } else {
            do {
                try await server.start(transport: StdioTransport())
                await server.waitUntilCompleted()
            } catch {
                failStartup("server error: \(error.localizedDescription)")
            }
        }
    }

    /// Serve the tools over HTTP (for tunnelling to remote clients like ChatGPT)
    /// and block forever. Bearer-token gated; `trigger_sync` is intentionally not
    /// exposed remotely (it's a local side effect).
    static func runHTTP(_ options: HTTPOptions, catalog: Catalog) -> Never {
        let httpTools = tools.filter { !httpExcludedTools.contains($0.name) }
        let server = HTTPServer(port: options.port, token: options.token) { body in
            processHTTPBody(body, catalog: catalog, tools: httpTools)
        }
        do {
            try server.start()
            FileHandle.standardError.write(Data("findle-mcp: HTTP server listening on 127.0.0.1:\(options.port)\n".utf8))
        } catch {
            failStartup("could not start HTTP server: \(error.localizedDescription)")
        }
        // Park forever; the listener serves requests on its own queue. `server`
        // stays retained by this frame.
        while true { Thread.sleep(forTimeInterval: 3600) }
    }

    // MARK: - Tool definitions

    static let tools: [Tool] = [
        Tool(
            name: "list_courses",
            description: "List the user's Moodle courses with sync state, tags, file count, and last-synced time.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
        ),
        Tool(
            name: "get_course_brief",
            description: "Get a compact, bounded course overview in one call: summary, sync status, section outline, representative files, and upcoming deadlines. Prefer this over browsing the full tree.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "course": .object([
                        "type": .string("integer"),
                        "description": .string("The course id from list_courses.")
                    ]),
                    "max_sections": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum sections to return (default 12).")
                    ]),
                    "max_files_per_section": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum representative files per section (default 8).")
                    ]),
                    "max_chars": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum characters for the course summary (default 2000).")
                    ])
                ]),
                "required": .array([.string("course")])
            ])
        ),
        Tool(
            name: "search_items",
            description: "Find synced files by name across courses. Catalog/keyword match over file names (full-text search arrives in a later milestone).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive text to match in file names.")
                    ]),
                    "course": .object([
                        "type": .string("integer"),
                        "description": .string("Optional course id to restrict the search.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of results (default 20).")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        ),
        Tool(
            name: "get_course_contents",
            description: "Browse a course's full folder/file tree (sections, sub-folders, and files with sizes and download state). Use the `course` id from list_courses.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "course": .object([
                        "type": .string("integer"),
                        "description": .string("The course id (from list_courses).")
                    ])
                ]),
                "required": .array([.string("course")])
            ])
        ),
        Tool(
            name: "read_item",
            description: "Read the extracted text of one synced file by id. Downloads the file on demand via the File Provider if it isn't local yet. Supports PDF, plain-text/markdown/code, and HTML.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("The item id (from search_items or get_item).")
                    ]),
                    "max_chars": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum characters in this chunk (default 8000, maximum 20000).")
                    ]),
                    "offset": .object([
                        "type": .string("integer"),
                        "description": .string("Character offset for paging through a long document (default 0).")
                    ])
                ]),
                "required": .array([.string("id")])
            ])
        ),
        Tool(
            name: "search_text",
            description: "Full-text search INSIDE file contents (not just names), with snippets. Only covers files already read via read_item or bulk-indexed via index_course. Diacritic-insensitive.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("Words to find inside documents.")
                    ]),
                    "course": .object([
                        "type": .string("integer"),
                        "description": .string("Optional course id to restrict the search.")
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum number of results (default 10).")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        ),
        Tool(
            name: "semantic_search",
            description: "Concept search over file contents using on-device embeddings — finds passages by meaning even when they don't share the query's words. Requires index_course first. Returns ranked passages with similarity scores.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("A concept or question to find related passages for.")
                    ]),
                    "course": .object([
                        "type": .string("integer"),
                        "description": .string("Optional course id to restrict the search.")
                    ]),
                    "k": .object([
                        "type": .string("integer"),
                        "description": .string("Number of passages to return (default 6).")
                    ])
                ]),
                "required": .array([.string("query")])
            ])
        ),
        Tool(
            name: "index_course",
            description: "Download and extract the text of every file in a course to make its contents searchable via search_text and semantic_search. This materializes files (one-time download cost).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "course": .object([
                        "type": .string("integer"),
                        "description": .string("The course id (from list_courses).")
                    ])
                ]),
                "required": .array([.string("course")])
            ])
        ),
        Tool(
            name: "get_item",
            description: "Get full metadata for one synced item by id: file name, course, size, sync state, and Moodle URL.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("The item id (as returned by search_items or list_courses).")
                    ])
                ]),
                "required": .array([.string("id")])
            ])
        ),
        Tool(
            name: "get_moodle_url",
            description: "Get the canonical Moodle URL for a synced item by id.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object([
                        "type": .string("string"),
                        "description": .string("The item id.")
                    ])
                ]),
                "required": .array([.string("id")])
            ])
        ),
        Tool(
            name: "trigger_sync",
            description: "Ask the Findle app to pull fresh content from Moodle (the app holds the token; this server never syncs directly). Fire-and-forget — re-query after a few seconds. Findle must be installed and signed in.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "course": .object([
                        "type": .string("integer"),
                        "description": .string("Optional course id to sync just that course; omit to sync all enabled courses.")
                    ])
                ])
            ])
        ),
        Tool(
            name: "list_deadlines",
            description: "Upcoming assignment due dates and quiz close dates across courses (with submission state for assignments), sorted soonest-first.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "course": .object([
                        "type": .string("integer"),
                        "description": .string("Optional course id to restrict to one course.")
                    ]),
                    "within_days": .object([
                        "type": .string("integer"),
                        "description": .string("Only include deadlines within this many days from now.")
                    ])
                ])
            ])
        ),
        Tool(
            name: "get_submission_status",
            description: "Submission and grading state for one assignment: submitted, graded, and grade.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "assignment_id": .object([
                        "type": .string("integer"),
                        "description": .string("The assignment id (from list_deadlines).")
                    ])
                ]),
                "required": .array([.string("assignment_id")])
            ])
        ),
        Tool(
            name: "get_grades",
            description: "Grade-book items (scores, percentages, feedback) for all courses or one course.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "course": .object([
                        "type": .string("integer"),
                        "description": .string("Optional course id to restrict to one course.")
                    ])
                ])
            ])
        ),
        Tool(
            name: "get_quiz_attempts",
            description: "The user's past attempts at a quiz, with state and score.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "quiz_id": .object([
                        "type": .string("integer"),
                        "description": .string("The quiz id.")
                    ])
                ]),
                "required": .array([.string("quiz_id")])
            ])
        )
    ]

    /// Tools not exposed over HTTP (local side effects that make no sense to a
    /// remote client and that the model can't observe the result of anyway).
    static let httpExcludedTools: Set<String> = ["trigger_sync"]

    /// Parse a request body (single message or batch), dispatch each, and
    /// serialize the response(s). Returns nil when there's nothing to send back
    /// (e.g. only notifications).
    static func processHTTPBody(_ body: Data, catalog: Catalog, tools: [Tool]) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            let parseError: [String: Any] = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]
            return try? JSONSerialization.data(withJSONObject: parseError)
        }
        if let batch = json as? [[String: Any]] {
            let responses = batch.compactMap { handleRPC($0, catalog: catalog, tools: tools) }
            guard !responses.isEmpty else { return nil }
            return try? JSONSerialization.data(withJSONObject: responses)
        }
        if let single = json as? [String: Any], let response = handleRPC(single, catalog: catalog, tools: tools) {
            return try? JSONSerialization.data(withJSONObject: response)
        }
        return nil
    }

    /// Process a single JSON-RPC message for the HTTP transport. Returns the
    /// response object, or nil for notifications (which get no response).
    static func handleRPC(_ message: [String: Any], catalog: Catalog, tools: [Tool]) -> [String: Any]? {
        let method = message["method"] as? String
        let id = message["id"]

        // No "id" → notification: act on it but send no response.
        guard id != nil else { return nil }

        func ok(_ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id!, "result": result] }
        func fail(_ code: Int, _ msg: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id!, "error": ["code": code, "message": msg]]
        }

        switch method {
        case "initialize":
            return ok([
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "findle", "version": "0.1.0"]
            ])
        case "ping":
            return ok([String: Any]())
        case "tools/list":
            let toolsJSON = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(tools))) ?? []
            return ok(["tools": toolsJSON])
        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            guard let name = params["name"] as? String else { return fail(-32602, "Missing tool name") }
            if httpExcludedTools.contains(name) {
                return fail(-32601, "Tool '\(name)' is not available over HTTP")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let reader = ArgReader(
                string: { arguments[$0] as? String },
                int: { key in
                    if let i = arguments[key] as? Int { return i }
                    if let d = arguments[key] as? Double { return Int(d) }
                    if let s = arguments[key] as? String { return Int(s) }
                    return nil
                }
            )
            let result = catalog.callTool(named: name, args: reader)
            return ok(["content": [["type": "text", "text": result.text]], "isError": result.isError])
        default:
            return fail(-32601, "Method not found: \(method ?? "nil")")
        }
    }
}

// MARK: - Helpers

/// HTTP serving options parsed from `--http <port> --token <secret>` (token may
/// also come from `FINDLE_MCP_TOKEN`). Refuses to run unauthenticated.
struct HTTPOptions {
    let port: UInt16
    let token: String

    static func fromArguments() -> HTTPOptions? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--http"), index + 1 < args.count else { return nil }

        var portString = args[index + 1]
        if portString.hasPrefix(":") { portString.removeFirst() }
        guard let port = UInt16(portString) else {
            failStartup("--http needs a port, e.g. --http 8080")
        }

        let flagToken = args.firstIndex(of: "--token").flatMap { i in i + 1 < args.count ? args[i + 1] : nil }
        let token = flagToken ?? ProcessInfo.processInfo.environment["FINDLE_MCP_TOKEN"]
        guard let token, !token.isEmpty else {
            failStartup("HTTP mode requires --token <secret> (or FINDLE_MCP_TOKEN) — refusing to serve unauthenticated")
        }
        return HTTPOptions(port: port, token: token)
    }
}

/// Resolve the database path: `FINDLE_DB_PATH` env, then a `--db-path` argument,
/// then the default shared App Group container location.
private func resolveDatabasePath() -> String? {
    let env = ProcessInfo.processInfo.environment
    let args = CommandLine.arguments
    let configuredPath = env["FINDLE_DB_PATH"].flatMap { $0.isEmpty ? nil : $0 }
        ?? args.firstIndex(of: "--db-path").flatMap { index in
            index + 1 < args.count ? args[index + 1] : nil
        }
    let defaultPath = Database.sharedContainerDatabasePath
    let candidates = [configuredPath, defaultPath].compactMap { $0 }

    for path in candidates where isUsableDatabase(at: path) {
        return path
    }

    return nil
}

private func isUsableDatabase(at path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path),
          let database = try? Database(path: path, readOnly: true),
          let accounts = try? database.fetchAccounts(),
          accounts.contains(where: { $0.state.isConnected }) else {
        return false
    }

    // State-directory databases are explicitly marked complete by the app.
    // If an update/reset left the configured path stale or half-seeded, fall
    // back to the bootstrap App Group snapshot instead of feeding an agent an
    // empty or partial catalog.
    return (try? database.isSeedComplete()) == true
}

private func stringArg(_ args: [String: Value]?, _ key: String) -> String? {
    args?[key]?.stringValue
}

private func intArg(_ args: [String: Value]?, _ key: String) -> Int? {
    guard let value = args?[key] else { return nil }
    if let int = value.intValue { return int }
    if let double = value.doubleValue { return Int(double) }
    if let string = value.stringValue { return Int(string) }
    return nil
}

private func failStartup(_ message: String) -> Never {
    FileHandle.standardError.write(Data("findle-mcp: \(message)\n".utf8))
    exit(1)
}
