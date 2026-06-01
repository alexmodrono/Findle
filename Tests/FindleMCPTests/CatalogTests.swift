// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
import FoodlePersistence
import SharedDomain

final class CatalogTests: XCTestCase {
    private func makeCatalog(seed: Bool = true) throws -> Catalog {
        Catalog(database: try TestDB.make(seed: seed), indexStore: nil, embedder: nil)
    }

    func testListCourses() throws {
        let courses = parseJSON(try makeCatalog().listCourses()) as! [[String: Any]]
        XCTAssertEqual(courses.count, 2)
        let calc = try XCTUnwrap(courses.first { $0["id"] as? Int == 100 })
        XCTAssertEqual(calc["shortName"] as? String, "CALC")
        XCTAssertEqual(calc["fileCount"] as? Int, 2)
        XCTAssertEqual(calc["syncEnabled"] as? Bool, true)
        XCTAssertEqual(calc["lastSynced"] as? String, "2023-11-14T22:13:20Z")
    }

    func testSearchItemsIsDiacriticInsensitiveAndIncludesFolders() throws {
        let results = parseJSON(try makeCatalog().searchItems(query: "examen", courseID: nil, limit: 20)) as! [[String: Any]]
        let names = results.compactMap { $0["filename"] as? String }
        XCTAssertTrue(names.contains("Exámenes"), "should match the accented folder name")
        XCTAssertTrue(names.contains("Examen Final.pdf"), "should match the file too")
    }

    func testSearchItemsCourseFilterAndLimit() throws {
        let results = parseJSON(try makeCatalog().searchItems(query: "pdf", courseID: 100, limit: 1)) as! [[String: Any]]
        XCTAssertEqual(results.count, 1, "limit should cap results")
    }

    func testGetCourseContentsTree() throws {
        let object = parseJSON(try makeCatalog().getCourseContents(courseID: 100)) as! [String: Any]
        XCTAssertEqual(object["course"] as? String, "Cálculo")
        let contents = object["contents"] as! [[String: Any]]
        let folder = try XCTUnwrap(contents.first { $0["name"] as? String == "Exámenes" })
        XCTAssertEqual(folder["type"] as? String, "folder")
        let children = folder["children"] as! [[String: Any]]
        XCTAssertEqual(children.count, 2)
    }

    func testGetItemAndMoodleURL() throws {
        let catalog = try makeCatalog()
        let item = parseJSON(catalog.getItem(id: "f1")) as! [String: Any]
        XCTAssertEqual(item["filename"] as? String, "Examen Final.pdf")
        XCTAssertEqual(item["downloaded"] as? Bool, true)

        let url = parseJSON(catalog.getMoodleURL(id: "f1")) as! [String: Any]
        XCTAssertEqual(url["moodleURL"] as? String, "https://moodle/file/2")
    }

    func testListDeadlinesKeepsOnlyUpcoming() throws {
        let deadlines = parseJSON(try makeCatalog().listDeadlines(courseID: nil, withinDays: nil)) as! [[String: Any]]
        let names = deadlines.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("Entrega 1"), "future assignment included")
        XCTAssertTrue(names.contains("Test 1"), "open quiz included")
        XCTAssertFalse(names.contains("Entrega 2 (past)"), "past assignment excluded")
    }

    func testGradesAndSubmissionStatus() throws {
        let catalog = try makeCatalog()
        let grades = parseJSON(catalog.getGrades(courseID: 100)) as! [[String: Any]]
        XCTAssertEqual(grades.first?["grade"] as? String, "7.0")

        let submission = parseJSON(catalog.getSubmissionStatus(assignmentID: 902)) as! [String: Any]
        XCTAssertEqual(submission["submitted"] as? Bool, true)
        XCTAssertEqual(submission["graded"] as? Bool, true)
        XCTAssertEqual(submission["grade"] as? String, "8.5")
    }

    func testQuizAttempts() throws {
        let object = parseJSON(try makeCatalog().getQuizAttempts(quizID: 701)) as! [String: Any]
        XCTAssertEqual(object["quiz"] as? String, "Test 1")
        let attempts = object["attempts"] as! [[String: Any]]
        XCTAssertEqual(attempts.first?["state"] as? String, "finished")
        XCTAssertEqual(attempts.first?["attempt"] as? Int, 1)
    }

    func testCallToolDispatch() throws {
        let catalog = try makeCatalog()
        let empty = ArgReader(string: { _ in nil }, int: { _ in nil })

        let listed = catalog.callTool(named: "list_courses", args: empty)
        XCTAssertFalse(listed.isError)
        XCTAssertTrue(listed.text.contains("CALC"))

        let unknown = catalog.callTool(named: "does_not_exist", args: empty)
        XCTAssertTrue(unknown.isError)

        let search = catalog.callTool(named: "search_items", args: ArgReader(string: { $0 == "query" ? "examen" : nil }, int: { _ in nil }))
        XCTAssertFalse(search.isError)
        XCTAssertTrue(search.text.contains("Exámenes"))
    }

    func testNoAccountYieldsError() throws {
        let object = parseJSON(try makeCatalog(seed: false).listCourses()) as! [String: Any]
        XCTAssertNotNil(object["error"])
    }
}
