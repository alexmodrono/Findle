import Foundation
import Security
import SharedDomain

enum SSONonce {
    static func generate(
        fill: (UnsafeMutableRawBufferPointer) -> OSStatus = {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
    ) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes(fill)
        guard status == errSecSuccess else {
            throw FindleError.ssoSessionStartFailed(
                detail: "A secure sign-in code could not be generated. Try again."
            )
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
