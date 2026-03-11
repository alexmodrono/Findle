import Foundation

/// Token endpoint response.
struct TokenResponse: Decodable {
    let token: String?
    let privatetoken: String?
    let error: String?
    let errorcode: String?
}

/// Site info response from core_webservice_get_site_info.
struct SiteInfoResponse: Decodable {
    let sitename: String
    let username: String
    let fullname: String
    let userid: Int
    let siteurl: String
    let userpictureurl: String?
    let lang: String?
    let release: String?
    let version: String?
}

/// Course response from core_enrol_get_users_courses.
struct CourseResponse: Decodable {
    let id: Int
    let shortname: String
    let fullname: String
    let summary: String?
    let category: Int?
    let startdate: Int?
    let enddate: Int?
    let lastaccess: Int?
    let visible: Int?
}

/// Section response from core_course_get_contents.
struct SectionResponse: Decodable {
    let id: Int
    let name: String
    let summary: String?
    let section: Int
    let visible: Int?
    let modules: [ModuleResponse]
}

/// Module response within a section.
struct ModuleResponse: Decodable {
    let id: Int
    let name: String
    let modname: String
    let modicon: String?
    let visible: Int?
    let contents: [ContentResponse]?
}

/// File content response within a module.
struct ContentResponse: Decodable {
    let type: String
    let filename: String
    let filepath: String?
    let filesize: Int64?
    let fileurl: String?
    let timecreated: Int?
    let timemodified: Int?
    let mimetype: String?
    let author: String?
    let sortorder: Int?
}

/// Moodle error response structure.
struct MoodleErrorResponse: Decodable {
    let errorcode: String?
    let message: String?
    let exception: String?
    let debuginfo: String?
}
