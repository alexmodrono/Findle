import Foundation

/// Top-level error domain for the Foodle app.
public enum FoodleError: Error, Sendable, LocalizedError {
    // Authentication
    case invalidCredentials
    case tokenExpired
    case tokenRefreshFailed(underlying: String)
    case authenticationRequired

    // Site compatibility
    case siteUnreachable(url: URL)
    case siteIncompatible(reason: String)
    case webServicesDisabled
    case insufficientPermissions(detail: String)

    // Network
    case networkUnavailable
    case requestFailed(statusCode: Int, detail: String)
    case invalidResponse(detail: String)
    case timeout

    // Sync
    case syncFailed(courseID: Int, reason: String)
    case conflictDetected(itemID: String)
    case itemNotFound(itemID: String)
    case downloadFailed(itemID: String, reason: String)

    // Persistence
    case databaseError(detail: String)
    case migrationFailed(version: Int)

    // File Provider
    case domainSetupFailed(detail: String)
    case enumerationFailed(detail: String)

    // General
    case internalError(detail: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid username or password."
        case .tokenExpired:
            return "Your session has expired. Please sign in again."
        case .tokenRefreshFailed(let underlying):
            return "Could not refresh your session: \(underlying)"
        case .authenticationRequired:
            return "Authentication is required to access this content."
        case .siteUnreachable(let url):
            return "Could not reach \(url.host ?? "the server")."
        case .siteIncompatible(let reason):
            return "This server is not compatible: \(reason)"
        case .webServicesDisabled:
            return "Web services are not enabled on this Moodle site."
        case .insufficientPermissions(let detail):
            return "Insufficient permissions: \(detail)"
        case .networkUnavailable:
            return "No network connection available."
        case .requestFailed(let statusCode, let detail):
            return "Request failed (HTTP \(statusCode)): \(detail)"
        case .invalidResponse(let detail):
            return "Unexpected server response: \(detail)"
        case .timeout:
            return "The request timed out."
        case .syncFailed(let courseID, let reason):
            return "Sync failed for course \(courseID): \(reason)"
        case .conflictDetected(let itemID):
            return "A conflict was detected for item \(itemID)."
        case .itemNotFound(let itemID):
            return "Item \(itemID) was not found."
        case .downloadFailed(let itemID, let reason):
            return "Download failed for \(itemID): \(reason)"
        case .databaseError(let detail):
            return "Database error: \(detail)"
        case .migrationFailed(let version):
            return "Database migration failed at version \(version)."
        case .domainSetupFailed(let detail):
            return "File provider setup failed: \(detail)"
        case .enumerationFailed(let detail):
            return "Could not enumerate items: \(detail)"
        case .internalError(let detail):
            return "Internal error: \(detail)"
        case .cancelled:
            return "The operation was cancelled."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .timeout, .requestFailed:
            return true
        case .tokenExpired, .tokenRefreshFailed:
            return false
        default:
            return false
        }
    }

    public var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
