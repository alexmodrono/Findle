// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import MCP
import FoodlePersistence

/// Findle's MCP server: a local, stdio, read-only bridge that lets an agent
/// query the user's synced Moodle coursework without manual uploads.
///
/// It opens the same database the app and File Provider extension use, but
/// read-only — the app remains the single writer. The Moodle token never enters
/// this process.
@main
struct FindleMCP {
    static func main() async {
        let dbPath = resolveDatabasePath()

        guard FileManager.default.fileExists(atPath: dbPath) else {
            failStartup("database not found at \(dbPath)\nOpen Findle and sign in first.")
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
            let text: String
            switch params.name {
            case "list_courses":
                text = catalog.listCourses()
            case "get_item":
                text = catalog.getItem(id: stringArg(args, "id") ?? "")
            case "read_item":
                text = catalog.readItem(
                    id: stringArg(args, "id") ?? "",
                    maxChars: intArg(args, "max_chars") ?? 100_000
                )
            case "search_items":
                text = catalog.searchItems(
                    query: stringArg(args, "query") ?? "",
                    courseID: intArg(args, "course"),
                    limit: intArg(args, "limit") ?? 20
                )
            case "get_course_contents":
                text = catalog.getCourseContents(courseID: intArg(args, "course") ?? -1)
            case "search_text":
                text = catalog.searchText(
                    query: stringArg(args, "query") ?? "",
                    courseID: intArg(args, "course"),
                    limit: intArg(args, "limit") ?? 10
                )
            case "index_course":
                text = catalog.indexCourse(courseID: intArg(args, "course") ?? -1)
            case "semantic_search":
                text = catalog.semanticSearch(
                    query: stringArg(args, "query") ?? "",
                    courseID: intArg(args, "course"),
                    k: intArg(args, "k") ?? 6
                )
            case "get_moodle_url":
                text = catalog.getMoodleURL(id: stringArg(args, "id") ?? "")
            case "trigger_sync":
                text = catalog.triggerSync(courseID: intArg(args, "course"))
            case "list_deadlines":
                text = catalog.listDeadlines(courseID: intArg(args, "course"), withinDays: intArg(args, "within_days"))
            case "get_submission_status":
                text = catalog.getSubmissionStatus(assignmentID: intArg(args, "assignment_id") ?? -1)
            case "get_grades":
                text = catalog.getGrades(courseID: intArg(args, "course"))
            case "get_quiz_attempts":
                text = catalog.getQuizAttempts(quizID: intArg(args, "quiz_id") ?? -1)
            default:
                return .init(content: [.text("Unknown tool: \(params.name)")], isError: true)
            }
            return .init(content: [.text(text)], isError: false)
        }

        do {
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
        } catch {
            failStartup("server error: \(error.localizedDescription)")
        }
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
                        "description": .string("Maximum characters of text to return (default 100000).")
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
}

// MARK: - Helpers

/// Resolve the database path: `FINDLE_DB_PATH` env, then a `--db-path` argument,
/// then the default shared App Group container location.
private func resolveDatabasePath() -> String {
    let env = ProcessInfo.processInfo.environment
    if let path = env["FINDLE_DB_PATH"], !path.isEmpty {
        return path
    }
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--db-path"), index + 1 < args.count {
        return args[index + 1]
    }
    return Database.sharedContainerDatabasePath
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
