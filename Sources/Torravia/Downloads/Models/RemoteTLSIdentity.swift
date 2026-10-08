import Foundation
import Security
import Network

/// Only a Keychain reference and public certificates are saved in preferences.
nonisolated struct RemoteTLSIdentity: Codable, Equatable, Sendable {
    let persistentReference: Data
    let certificateChain: [Data]
    let name: String

    static func importPKCS12(_ data: Data, password: String) throws -> RemoteTLSIdentity {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw RemoteTLSError.invalidFile }
        // Use the standard macOS Keychain, which works with the app's existing
        // signing setup and macOS 14. A nil trusted-app list grants this app access.
        var access: SecAccess?
        let accessStatus = SecAccessCreate("Torravia HTTPS" as CFString, nil, &access)
        guard accessStatus == errSecSuccess, let access else { throw RemoteTLSError.keychain(accessStatus) }
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportExportAccess as String: access
        ]
        var imported: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &imported)
        guard status == errSecSuccess else { throw RemoteTLSError.keychain(status) }
        guard let items = imported as? [[String: Any]], items.count == 1,
              let value = items.first?[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else {
            throw RemoteTLSError.invalidFile
        }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        let certificateStatus = SecIdentityCopyCertificate(identity, &certificate)
        guard certificateStatus == errSecSuccess, let certificate else { throw RemoteTLSError.keychain(certificateStatus) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: identity,
            kSecReturnPersistentRef as String: true
        ]
        var result: CFTypeRef?
        let referenceStatus = SecItemCopyMatching(query as CFDictionary, &result)
        guard referenceStatus == errSecSuccess, let reference = result as? Data else {
            throw RemoteTLSError.keychain(referenceStatus)
        }
        let chain = items.first?[kSecImportItemCertChain as String] as? [SecCertificate] ?? [certificate]
        return RemoteTLSIdentity(persistentReference: reference,
                                 certificateChain: chain.map { SecCertificateCopyData($0) as Data },
                                 name: SecCertificateCopySubjectSummary(certificate) as String? ?? "HTTPS certificate")
    }

    func protocolIdentity() throws -> sec_identity_t {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValuePersistentRef as String: persistentReference,
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw RemoteTLSError.keychain(status)
        }
        let certificates = certificateChain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard certificates.count == certificateChain.count, !certificates.isEmpty,
              let identity = sec_identity_create_with_certificates(result as! SecIdentity, certificates as CFArray) else {
            throw RemoteTLSError.invalidFile
        }
        return identity
    }
}

nonisolated enum RemoteTLSError: LocalizedError {
    case missingIdentity, invalidFile, invalidHostname, keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingIdentity: return "Import an HTTPS certificate before starting browser control."
        case .invalidFile: return "Choose a PKCS#12 (.p12 or .pfx) file containing one certificate and its private key, up to 4 MiB."
        case .invalidHostname: return "Enter a hostname such as torrents.example.com, without a scheme, port, or path."
        case .keychain(let status):
            if status == errSecAuthFailed { return "The certificate password is incorrect or the file is damaged."
            }
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
            return "The HTTPS certificate could not be accessed in Keychain: \(detail). Import the certificate again if it was removed."
        }
    }
}

nonisolated enum RemoteTLSConfiguration {
    static func parameters(useHTTPS: Bool, identity: RemoteTLSIdentity?) throws -> NWParameters {
        guard useHTTPS else { return .tcp }
        guard let identity else { throw RemoteTLSError.missingIdentity }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, try identity.protocolIdentity())
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    static func hostname(_ value: String) throws -> String? {
        let host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { throw RemoteTLSError.invalidHostname }
        return host
    }
}
