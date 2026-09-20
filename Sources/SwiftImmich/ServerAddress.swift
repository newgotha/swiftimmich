import Foundation
import OpenAPIRuntime

/// Tidying and judging the server address the user types.
enum ServerAddress {
    /// Trims the text and assumes https:// when no scheme was given, so `photos.example.com`
    /// works. A trailing slash is dropped.
    static func normalized(_ text: String) -> String {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return address }
        if !address.contains("://") { address = "https://" + address }
        while address.hasSuffix("/") { address.removeLast() }
        return address
    }

    /// True for an address starting with http:// that points somewhere beyond your own
    /// network — the API key would cross the internet unencrypted.
    static func isInsecureRemote(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "http", let host = url.host, !host.isEmpty
        else { return false }
        return !isPrivateHost(host)
    }

    /// Localhost, `.local` names, single-label names, and the private IPv4 ranges.
    static func isPrivateHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        if !host.contains(".") && !host.contains(":") { return true }   // e.g. "nas"
        if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") { return host.contains(":") }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}

/// Plain-English text for a failed request, instead of the framework's multi-paragraph dump.
enum FriendlyError {
    static func message(for error: Error) -> String {
        AppLog.error("request failed", error)

        var underlying: Error = error
        if let client = error as? ClientError { underlying = client.underlyingError }
        let ns = underlying as NSError

        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
                return "You're offline."
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "Couldn't find that server. Check the address in the connection settings."
            case NSURLErrorCannotConnectToHost:
                return "Couldn't connect to the server. Check the address and port, and that the server is running."
            case NSURLErrorTimedOut:
                return "The server took too long to answer."
            case NSURLErrorNetworkConnectionLost:
                return "The connection to the server was lost."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
                return "Couldn't make a secure connection — the server's certificate isn't trusted."
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return "macOS blocked an http:// address. Use https://, or update SwiftImmich."
            default:
                return ns.localizedDescription
            }
        }
        if case ImmichServiceError.requestFailed(let status, let message) = error {
            switch status {
            case 401, 403: return "The server refused the request (\(status)) — check the API key and its permissions."
            default: return "The server said \(status)" + (message.map { ": \($0.prefix(140))" } ?? "")
            }
        }
        // Anything else: the first line only, not the whole dump.
        let text = String(describing: error)
        return String(text.split(separator: "\n").first.map(String.init)?.prefix(200) ?? "Something went wrong.")
    }
}
