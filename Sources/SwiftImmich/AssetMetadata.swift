import Foundation
import ImmichAPI

/// Immich keeps small key -> JSON pairs on each photo (`/assets/{id}/metadata`). The app uses one key
/// to remember how a photo was edited, so the edit can be reopened and changed later.
extension ImmichService {
    struct MetadataItem: Sendable {
        let key: String
        let updatedAt: String
        /// The stored JSON object, as text.
        let json: String
    }

    private func metadataRequest(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: apiURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        authorize(&request)
        return request
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
        throw ImmichServiceError.requestFailed(statusCode: http.statusCode, message: message)
    }

    /// Stores `value` under `key` on the photo, replacing what was there.
    func setAssetMetadata<T: Encodable>(_ value: T, key: String, assetId: String) async throws {
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value))
        let body = try JSONSerialization.data(withJSONObject: ["items": [["key": key, "value": object]]])
        let (data, response) = try await URLSession.shared.data(for: metadataRequest("assets/\(assetId)/metadata", method: "PUT", body: body))
        try Self.check(response, data)
    }

    /// What's stored under `key`, or nil if the photo has nothing there.
    func assetMetadata<T: Decodable>(_ type: T.Type, key: String, assetId: String) async throws -> T? {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let (data, response) = try await URLSession.shared.data(for: metadataRequest("assets/\(assetId)/metadata/\(encodedKey)"))
        // Immich answers 400 "...not found" (not 404) when the photo has nothing under that key.
        if let status = (response as? HTTPURLResponse)?.statusCode {
            let message = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String)?.lowercased() ?? ""
            if status == 404 || (status == 400 && message.contains("not found")) { return nil }
        }
        try Self.check(response, data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["value"] else { return nil }
        return try JSONDecoder().decode(type, from: try JSONSerialization.data(withJSONObject: value))
    }

    /// Everything stored on the photo.
    func allAssetMetadata(assetId: String) async throws -> [MetadataItem] {
        let (data, response) = try await URLSession.shared.data(for: metadataRequest("assets/\(assetId)/metadata"))
        try Self.check(response, data)
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.map { item in
            let value = (try? JSONSerialization.data(withJSONObject: item["value"] ?? [:])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return MetadataItem(key: item["key"] as? String ?? "", updatedAt: item["updatedAt"] as? String ?? "", json: value)
        }
    }

    func deleteAssetMetadata(key: String, assetId: String) async throws {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        let (data, response) = try await URLSession.shared.data(for: metadataRequest("assets/\(assetId)/metadata/\(encodedKey)", method: "DELETE"))
        try Self.check(response, data)
    }

    // MARK: - Stacks

    /// Groups photos into a stack and reports the stack that was made.
    @discardableResult
    func createStackInfo(assetIds: [String]) async throws -> Components.Schemas.StackResponseDto {
        let response = try await client.createStack(body: .json(.init(assetIds: assetIds)))
        switch response {
        case .created(let created): return try created.body.json
        case .undocumented(let statusCode, let payload): throw await Self.failure(statusCode, payload)
        }
    }

    /// Chooses which photo of a stack is shown as its cover.
    @discardableResult
    func setStackPrimary(stackId: String, primaryAssetId: String) async throws -> Components.Schemas.StackResponseDto {
        let response = try await client.updateStack(.init(path: .init(id: stackId), body: .json(.init(primaryAssetId: primaryAssetId))))
        switch response {
        case .ok(let ok): return try ok.body.json
        case .undocumented(let statusCode, let payload): throw await Self.failure(statusCode, payload)
        }
    }
}
