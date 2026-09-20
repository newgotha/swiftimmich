import Foundation

/// Uploads a multipart form by running the system `curl`, instead of using URLSession.
///
/// Why not URLSession: for this server (behind Cloudflare, which advertises HTTP/3)
/// URLSession picks QUIC for uploads, and on the user's network that connection stalls
/// until the request time-out — measured: a 5 MB upload that `curl` completes in half
/// a second took 61 seconds in URLSession, with `protocol=h3`, and the same with
/// URLSession's plain `upload(fromFile:)`, so it isn't anything the app does. URLSession
/// has no switch to turn HTTP/3 off. macOS's bundled curl speaks HTTP/2 over TCP only,
/// which is what browsers and every other client fall back to, and it streams the file
/// straight from disk. It is always present at /usr/bin/curl.
///
/// The API key goes in via curl's config on stdin, not the command line, so it never
/// appears in the process list.
enum CurlUploader {
    enum Field {
        case text(name: String, value: String)
        case file(name: String, path: URL, filename: String)
    }

    struct Response {
        let statusCode: Int
        let body: Data
    }

    enum Failure: LocalizedError {
        case couldNotStart(String)
        case transport(exitCode: Int32, detail: String)

        var errorDescription: String? {
            switch self {
            case .couldNotStart(let reason):
                return "Couldn't start the upload helper: \(reason)"
            case .transport(let exitCode, let detail):
                let reason: String
                switch exitCode {
                case 6: reason = "couldn't find the server's address"
                case 7: reason = "couldn't connect to the server"
                case 28: reason = "the upload timed out"
                case 35, 51, 58, 60: reason = "the secure connection failed"
                case 52: reason = "the server closed the connection without replying"
                case 55, 56: reason = "the connection dropped during the upload"
                default: reason = detail.isEmpty ? "curl error \(exitCode)" : detail
                }
                return "Upload failed: \(reason)."
            }
        }

        /// Worth trying again: the network or server hiccupped, as opposed to the
        /// server having understood the request and refused it.
        var isTransient: Bool {
            guard case .transport(let exitCode, _) = self else { return false }
            return [5, 6, 7, 18, 28, 35, 52, 55, 56, 92].contains(exitCode)
        }
    }

    /// HTTP statuses that mean "try again shortly" (rate limits, gateway errors, and
    /// Cloudflare's origin-unreachable / timeout codes) rather than "this can't work".
    static func isTransient(status: Int) -> Bool {
        [408, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524].contains(status)
    }

    /// Posts the form, retrying transient failures after each delay in `retryDelays`.
    static func post(
        url: URL,
        headers: [String: String],
        fields: [Field],
        retryDelays: [Double] = [4, 15]
    ) async throws -> Response {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let response = try await postOnce(url: url, headers: headers, fields: fields)
                if isTransient(status: response.statusCode), attempt < retryDelays.count {
                    try await Task.sleep(for: .seconds(retryDelays[attempt]))
                    attempt += 1
                    continue
                }
                return response
            } catch let failure as Failure where failure.isTransient && attempt < retryDelays.count {
                try await Task.sleep(for: .seconds(retryDelays[attempt]))
                attempt += 1
            }
        }
    }

    static func postOnce(url: URL, headers: [String: String], fields: [Field]) async throws -> Response {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--silent", "--show-error",
            "--config", "-",
            "--write-out", "\n%{http_code}",
            "--connect-timeout", "30",
            // Give up on a genuine stall (under 2 KB/s for 3 minutes) rather than a
            // slow-but-moving upload of a large video.
            "--speed-limit", "2048", "--speed-time", "180",
            "--max-time", "43200",
        ]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let config = makeConfig(url: url, headers: headers, fields: fields)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                process.terminationHandler = { finished in
                    // The child has exited and closed its ends, so these return at once
                    // with whatever it wrote (a small JSON body / one error line).
                    let out = stdout.fileHandleForReading.readDataToEndOfFile()
                    let err = stderr.fileHandleForReading.readDataToEndOfFile()
                    if finished.terminationStatus != 0 {
                        let detail = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: Failure.transport(exitCode: finished.terminationStatus, detail: detail))
                        return
                    }
                    // Output is the response body, a newline, then the status code.
                    guard let newline = out.lastIndex(of: UInt8(ascii: "\n")),
                          let status = Int(String(decoding: out[(newline + 1)...], as: UTF8.self))
                    else {
                        continuation.resume(throwing: Failure.transport(exitCode: 0, detail: "the server sent an unreadable reply"))
                        return
                    }
                    continuation.resume(returning: Response(statusCode: status, body: Data(out[..<newline])))
                }
                do {
                    try process.run()
                    try stdin.fileHandleForWriting.write(contentsOf: Data(config.utf8))
                    try stdin.fileHandleForWriting.close()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: Failure.couldNotStart(error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - curl config

    private static func makeConfig(url: URL, headers: [String: String], fields: [Field]) -> String {
        var lines = ["url = \(quoted(url.absoluteString))", "request = \"POST\""]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("header = \(quoted("\(name): \(value)"))")
        }
        for field in fields {
            switch field {
            case .text(let name, let value):
                // `form-string` takes the value literally — no `@file` / `<file` magic.
                lines.append("form-string = \(quoted("\(name)=\(value)"))")
            case .file(let name, let path, let filename):
                lines.append("form = \(quoted("\(name)=@\(formQuoted(path.path));filename=\(formQuoted(filename));type=application/octet-stream"))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A value inside curl's `-F` syntax: quoted so spaces, semicolons and commas in
    /// a filename can't be read as separators.
    private static func formQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A value inside a curl config file line.
    private static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
