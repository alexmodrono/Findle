#!/usr/bin/env swift
// Verify the exact archive against the public key shipped in the application.
import CryptoKit
import Foundation

do {
    guard CommandLine.arguments.count == 4 else {
        throw NSError(domain: "UpdateValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: verify-update.swift ARCHIVE SIGNATURE APP_INFO_PLIST"])
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    let signatureText = CommandLine.arguments[2]
    let plistData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
    guard let encodedKey = plist?["SUPublicEDKey"] as? String,
          let keyData = Data(base64Encoded: encodedKey), keyData.count == 32,
          let signature = Data(base64Encoded: signatureText), signature.count == 64 else {
        throw NSError(domain: "UpdateValidation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing or malformed update signature/public key"])
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard key.isValidSignature(signature, for: archive) else {
        throw NSError(domain: "UpdateValidation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Update signature does not match the archive and shipped public key"])
    }
    print("Verified update signature against the application's public key.")
} catch {
    FileHandle.standardError.write(Data("Update validation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
