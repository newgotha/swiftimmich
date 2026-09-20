import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Authenticates every generated-client request: with the API key normally, or — while the
/// Locked Folder is open — with the signed-in session, which is the only thing Immich lets
/// see locked photos.
struct APIKeyMiddleware: ClientMiddleware {
    let apiKey: String
    let sharing: SharingState

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        if sharing.useSession, let token = sharing.sessionToken {
            // Only the session: the server prefers it over an API key when both are sent.
            request.headerFields[.init("authorization")!] = "Bearer \(token)"
        } else {
            request.headerFields[.init("x-api-key")!] = apiKey
        }
        return try await next(request, body, baseURL)
    }
}
