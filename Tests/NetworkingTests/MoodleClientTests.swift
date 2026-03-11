import XCTest
@testable import FoodleNetworking
@testable import SharedDomain

final class MoodleClientTests: XCTestCase {

    func testURLNormalization() {
        let url1 = MoodleClient.normalizeURL(URL(string: "https://moodle.example.edu/")!)
        XCTAssertEqual(url1.absoluteString, "https://moodle.example.edu")

        let url2 = MoodleClient.normalizeURL(URL(string: "https://moodle.example.edu///")!)
        XCTAssertEqual(url2.absoluteString, "https://moodle.example.edu")
    }

    func testAuthenticatedFileURL() {
        let client = MoodleClient()
        let token = AuthToken(token: "testtoken123")
        let fileURL = URL(string: "https://moodle.example.edu/pluginfile.php/123/mod_resource/content/1/file.pdf")!

        let result = client.authenticatedFileURL(fileURL: fileURL, token: token)

        XCTAssertTrue(result.absoluteString.contains("token=testtoken123"))
    }

    func testTokenResponseDecoding() throws {
        let json = """
        {"token": "abc123", "privatetoken": "xyz789"}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)

        XCTAssertEqual(response.token, "abc123")
        XCTAssertEqual(response.privatetoken, "xyz789")
        XCTAssertNil(response.error)
    }

    func testTokenResponseErrorDecoding() throws {
        let json = """
        {"error": "Invalid login", "errorcode": "invalidlogin", "stacktrace": null, "debuginfo": null, "reproductionlink": null}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)

        XCTAssertNil(response.token)
        XCTAssertEqual(response.error, "Invalid login")
        XCTAssertEqual(response.errorcode, "invalidlogin")
    }

    func testSiteInfoResponseDecoding() throws {
        let url = Bundle.module.url(forResource: "mock_site_info_response", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: "Fixtures/mock_site_info_response.json")

        guard let data = try? Data(contentsOf: url) else {
            // Skip if fixture not available in test bundle
            return
        }

        let response = try JSONDecoder().decode(SiteInfoResponse.self, from: data)
        XCTAssertEqual(response.userid, 42)
        XCTAssertEqual(response.username, "jdoe")
        XCTAssertEqual(response.fullname, "Jane Doe")
    }

    func testCourseResponseDecoding() throws {
        let json = """
        [
          {
            "id": 101,
            "shortname": "CS101",
            "fullname": "Introduction to Computer Science",
            "summary": "<p>A course.</p>",
            "category": 5,
            "startdate": 1693526400,
            "enddate": 1701302400,
            "lastaccess": 1700000000,
            "visible": 1
          }
        ]
        """
        let data = json.data(using: .utf8)!
        let courses = try JSONDecoder().decode([CourseResponse].self, from: data)

        XCTAssertEqual(courses.count, 1)
        XCTAssertEqual(courses[0].id, 101)
        XCTAssertEqual(courses[0].shortname, "CS101")
    }

    func testModuleResponseDecoding() throws {
        let json = """
        {
          "id": 2001,
          "name": "Course Syllabus",
          "modname": "resource",
          "modicon": null,
          "visible": 1,
          "contents": [
            {
              "type": "file",
              "filename": "syllabus.pdf",
              "filepath": "/",
              "filesize": 245760,
              "fileurl": "https://moodle.example.edu/file.php/1/syllabus.pdf",
              "timecreated": 1693526400,
              "timemodified": 1693526400,
              "mimetype": "application/pdf",
              "author": "Prof. Smith",
              "sortorder": 0
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let module = try JSONDecoder().decode(ModuleResponse.self, from: data)

        XCTAssertEqual(module.id, 2001)
        XCTAssertEqual(module.modname, "resource")
        XCTAssertEqual(module.contents?.count, 1)
        XCTAssertEqual(module.contents?[0].filename, "syllabus.pdf")
    }
}
