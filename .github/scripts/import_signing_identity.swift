import CoreFoundation
import Darwin
import Foundation
import Security

enum SigningImportFailure: Error {
    case arguments
    case missingPassphrase
    case data
    case keychain
    case trustedApplication
    case access
    case importFailed
}

func importIdentity(from p12Path: String, into keychainPath: String, passphrase: String) throws {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: p12Path))
    } catch {
        throw SigningImportFailure.data
    }

    var keychain: SecKeychain?
    let keychainStatus = keychainPath.withCString { path in
        SecKeychainOpen(path, &keychain)
    }
    guard keychainStatus == errSecSuccess, let keychain else {
        throw SigningImportFailure.keychain
    }

    func trustedApplication(at path: String) throws -> SecTrustedApplication {
        var application: SecTrustedApplication?
        let status = path.withCString { applicationPath in
            SecTrustedApplicationCreateFromPath(applicationPath, &application)
        }
        guard status == errSecSuccess, let application else {
            throw SigningImportFailure.trustedApplication
        }
        return application
    }

    let trustedApplications = [
        try trustedApplication(at: "/usr/bin/codesign"),
        try trustedApplication(at: "/usr/bin/security"),
    ]
    var access: SecAccess?
    let accessStatus = SecAccessCreate(
        "Health Nutrition signing identity" as CFString,
        trustedApplications as CFArray,
        &access)
    guard accessStatus == errSecSuccess, let access else {
        throw SigningImportFailure.access
    }

    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.flags = SecKeyImportExportFlags(rawValue: 0)
    // Apple specifies a CFString for PKCS#12 passphrases and documents accessRef as the imported key's
    // initial ACL. Keep both choices explicit; see the Apple Security headers at:
    // https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/keychain/headers/SecImportExport.h
    // https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/include/security_keychain/SecAccess.h
    // https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/include/security_keychain/SecTrustedApplication.h
    let cfPassphrase = passphrase as CFString
    parameters.passphrase = cfPassphrase
    parameters.accessRef = access

    var format = kSecFormatPKCS12
    var itemType = kSecItemTypeAggregate
    var importedItems: CFArray?
    // The C parameter struct contains borrowed CF references. Keep their owners alive through the call.
    let status = withExtendedLifetime((cfPassphrase, access)) {
        SecItemImport(
            data as CFData,
            ".p12" as CFString,
            &format,
            &itemType,
            SecItemImportExportFlags(rawValue: 0),
            &parameters,
            keychain,
            &importedItems)
    }
    guard status == errSecSuccess, let importedItems, CFArrayGetCount(importedItems) > 0 else {
        throw SigningImportFailure.importFailed
    }
}

func fail(_ message: StaticString) -> Never {
    fputs("\(message)\n", stderr)
    exit(EXIT_FAILURE)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("Expected a P12 file path and a keychain path.")
}
guard let passphrase = ProcessInfo.processInfo.environment["SIGNING_CERT_PASSWORD"], !passphrase.isEmpty else {
    fail("SIGNING_CERT_PASSWORD is missing.")
}

do {
    try importIdentity(from: arguments[1], into: arguments[2], passphrase: passphrase)
    print("Imported the signing identity.")
} catch {
    fail("The signing identity could not be imported.")
}
