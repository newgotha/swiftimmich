import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import ImmichAPI

enum ImmichServiceError: Error {
    case invalidServerURL
    case uploadFailed
    case requestFailed(statusCode: Int, message: String?)
}

/// State every copy of the (value-type) service needs to agree on: who you are, and
/// whether partners' photos are mixed into the Library timeline.
final class SharingState: @unchecked Sendable {
    var currentUserId: String?
    var includePartnerPhotos = false
    /// The smallest upload the server connection has turned away as too big (HTTP 413) —
    /// typically Cloudflare's 100 MB per-request limit. Later, bigger files aren't even tried.
    var rejectedUploadBytes: Int64?
    /// A signed-in session for the Locked Folder (Immich won't show locked photos to an
    /// API key), and whether requests should use it right now — only while it's open.
    var sessionToken: String?
    var useSession = false
}

struct ImmichService {
    let client: Client
    let apiURL: URL
    let apiKey: String
    let sharing = SharingState()

    init(serverURLString: String, apiKey: String) throws {
        let trimmed = ServerAddress.normalized(serverURLString)
        guard let base = URL(string: trimmed), base.scheme != nil else {
            throw ImmichServiceError.invalidServerURL
        }
        self.apiURL = base.appendingPathComponent("api")
        self.apiKey = apiKey
        self.client = Client(
            serverURL: apiURL,
            configuration: Configuration(dateTranscoder: LenientDateTranscoder()),
            transport: URLSessionTransport(),
            middlewares: [APIKeyMiddleware(apiKey: apiKey, sharing: sharing)]
        )
    }

    /// Adds credentials to a hand-built request: the API key, or the Locked Folder session
    /// while that's open (and marked as such, so cached copies can be kept off disk).
    func authorize(_ request: inout URLRequest) {
        if sharing.useSession, let token = sharing.sessionToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
    }

    /// Fetches the list of time buckets (dates) for a slice of the library, newest first.
    func fetchTimeBuckets(filter: TimelineFilter) async throws -> [Components.Schemas.TimeBucketsResponseDto] {
        let response = try await client.getTimeBuckets(query: .init(
            albumId: filter.albumId,
            bbox: filter.bbox,
            isFavorite: filter.isFavorite,
            isTrashed: filter.isTrashed,
            personId: filter.personId,
            tagId: filter.tagId,
            visibility: filter.visibility,
            withPartners: filter.includesPartnerPhotos && sharing.includePartnerPhotos,
            withStacked: filter.collapsesStacks
        ))
        return try response.ok.body.json
    }

    /// Fetches every asset in a given time bucket, decoded from Immich's columnar response.
    func fetchAssets(inBucket timeBucket: String, filter: TimelineFilter) async throws -> [AssetSummary] {
        let response = try await client.getTimeBucket(query: .init(
            albumId: filter.albumId,
            bbox: filter.bbox,
            isFavorite: filter.isFavorite,
            isTrashed: filter.isTrashed,
            personId: filter.personId,
            tagId: filter.tagId,
            timeBucket: timeBucket,
            visibility: filter.visibility,
            withPartners: filter.includesPartnerPhotos && sharing.includePartnerPhotos,
            withStacked: filter.collapsesStacks
        ))
        let dto = try response.ok.body.json
        return AssetSummary.makeSummaries(from: dto)
    }

    /// Builds an authenticated request for an asset's thumbnail image. `isImage`
    /// should be `false` for video assets — see `assetImageRequest`.
    func thumbnailRequest(assetId: String, isImage: Bool = true) -> URLRequest {
        assetImageRequest(assetId: assetId, size: "thumbnail", includeEditedFlag: isImage)
    }

    /// Builds an authenticated request for a larger, viewer-quality rendition of an
    /// asset. Only ever called for images (see `PhotoViewerView.preload`), so it
    /// always asks for the edited render.
    func previewRequest(assetId: String) -> URLRequest {
        assetImageRequest(assetId: assetId, size: "preview", includeEditedFlag: true)
    }

    private func assetImageRequest(assetId: String, size: String, includeEditedFlag: Bool) -> URLRequest {
        var url = apiURL.appendingPathComponent("assets/\(assetId)/thumbnail")
        var queryItems = [URLQueryItem(name: "size", value: size)]
        if includeEditedFlag {
            // Without `edited=true` this endpoint always serves the original,
            // unedited render — crop/rotate/mirror apply successfully server-side but
            // never show up anywhere in the app without this. Crop/rotate/mirror only
            // ever apply to images though (Immich has no such edits for video), and
            // passing `edited=true` for a video asset makes the server return
            // something `NSImage` can't decode, permanently showing the grid's gray
            // placeholder for every video thumbnail.
            queryItems.append(URLQueryItem(name: "edited", value: "true"))
        }
        url.append(queryItems: queryItems)
        var request = URLRequest(url: url)
        // The same URL's server-side content changes after an edit (crop/rotate/
        // mirror), but nothing about the URL itself does — URLSession's standard HTTP
        // cache has no way to know that and will happily keep serving the pre-edit
        // bytes for this exact URL indefinitely. Clearing our own in-memory
        // ThumbnailLoader cache isn't enough; this cache sits below it.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        authorize(&request)
        return request
    }

    /// Builds an authenticated request for a video asset's playable file.
    func videoPlaybackRequest(assetId: String) -> URLRequest {
        let url = apiURL.appendingPathComponent("assets/\(assetId)/video/playback")
        var request = URLRequest(url: url)
        authorize(&request)
        return request
    }

    /// Builds an authenticated request for an asset's full-resolution original file.
    /// Used when baking edits Immich can't represent natively (e.g. color adjustments)
    /// into a real exported image — the thumbnail/preview renditions are downscaled and
    /// would bake a permanently lower-quality copy.
    func originalFileRequest(assetId: String, edited: Bool) -> URLRequest {
        var url = apiURL.appendingPathComponent("assets/\(assetId)/original")
        url.append(queryItems: [URLQueryItem(name: "edited", value: edited ? "true" : "false")])
        var request = URLRequest(url: url)
        authorize(&request)
        return request
    }

    func fetchAssetInfo(assetId: String) async throws -> Components.Schemas.AssetResponseDto {
        let response = try await client.getAssetInfo(.init(path: .init(id: assetId)))
        return try response.ok.body.json
    }

    /// Copies albums/favorite/stack membership from one asset to another. Immich has no
    /// endpoint to replace an existing asset's original file content in place, so
    /// "replacing" an asset with a color-adjusted export means uploading it as a new
    /// asset and using this to carry its associations over before trashing the old one.
    func copyAssetMetadata(sourceId: String, targetId: String) async throws {
        let response = try await client.copyAsset(.init(body: .json(.init(
            albums: true,
            favorite: true,
            sharedLinks: false,
            sidecar: false,
            sourceId: sourceId,
            stack: true,
            targetId: targetId
        ))))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Sets an asset's favorite status. Uses Immich's bulk update endpoint (deprecated
    /// as of v3.2.0 in favor of a not-yet-published replacement) since it's still the
    /// only way to change isFavorite for a single asset today.
    func setFavorite(assetId: String, isFavorite: Bool) async throws {
        let response = try await client.updateAssets(body: .json(.init(ids: [assetId], isFavorite: isFavorite)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Favorites or unfavorites several assets in one request.
    func setFavorite(assetIds: [String], isFavorite: Bool) async throws {
        let response = try await client.updateAssets(body: .json(.init(ids: assetIds, isFavorite: isFavorite)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Moves assets into (or back out of) the Archive, which hides them from the main
    /// timeline without deleting anything.
    func setArchived(assetIds: [String], archived: Bool) async throws {
        let response = try await client.updateAssets(body: .json(.init(ids: assetIds, visibility: archived ? .archive : .timeline)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    // MARK: - Details

    /// Changes the description, date and/or location of one or several assets. Only the
    /// values passed are touched. A date is either absolute (`dateTimeOriginal`, an ISO
    /// 8601 string) or a shift in minutes (`dateTimeRelative`).
    func updateMetadata(
        assetIds: [String],
        description: String?,
        dateTimeOriginal: String?,
        dateTimeRelative: Int?,
        timeZone: String?,
        latitude: Double?,
        longitude: Double?
    ) async throws {
        let response = try await client.updateAssets(body: .json(.init(
            dateTimeOriginal: dateTimeOriginal,
            dateTimeRelative: dateTimeRelative,
            description: description,
            ids: assetIds,
            latitude: latitude,
            longitude: longitude,
            timeZone: timeZone
        )))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    func searchPlaces(name: String) async throws -> [Components.Schemas.PlacesResponseDto] {
        let response = try await client.searchPlaces(query: .init(name: name))
        return try response.ok.body.json
    }

    // MARK: - Map

    struct MapMarker {
        let id: String
        let latitude: Double
        let longitude: Double
    }

    /// Every photo that has a location, for the map.
    func fetchMapMarkers(favoritesOnly: Bool) async throws -> [MapMarker] {
        let response = try await client.getMapMarkers(query: .init(
            isArchived: false,
            isFavorite: favoritesOnly ? true : nil,
            withPartners: sharing.includePartnerPhotos
        ))
        return try response.ok.body.json.map { MapMarker(id: $0.id, latitude: $0.lat, longitude: $0.lon) }
    }

    /// One photo as the viewer needs it, for opening it from a map pin.
    func fetchSummary(assetId: String) async throws -> AssetSummary {
        let info = try await fetchAssetInfo(assetId: assetId)
        return AssetSummary.makeSummaries(from: [info])[0]
    }

    // MARK: - Locked Folder

    struct AuthState {
        let hasPIN: Bool
        let isElevated: Bool
    }

    func authStatus() async throws -> AuthState {
        let response = try await client.getAuthStatus()
        let status = try response.ok.body.json
        return AuthState(hasPIN: status.pinCode, isElevated: status.isElevated)
    }

    func setupPIN(_ pin: String) async throws {
        let response = try await client.setupPinCode(body: .json(.init(pinCode: pin)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    func unlockSession(pin: String) async throws {
        let response = try await client.unlockAuthSession(body: .json(.init(pinCode: pin)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    func lockSession() async {
        _ = try? await client.lockAuthSession()
    }

    /// Signs in with the account's email and password to get a session. The password is
    /// used for this one request and never kept; only the session token it returns is.
    func signIn(email: String, password: String) async throws -> String {
        let response = try await client.login(body: .json(.init(email: email, password: password)))
        switch response {
        case .created(let created):
            return try created.body.json.accessToken
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    func signOut() async {
        _ = try? await client.logout()
    }

    /// Moves photos into (or back out of) the Locked Folder.
    func setLocked(assetIds: [String], locked: Bool) async throws {
        let response = try await client.updateAssets(body: .json(.init(ids: assetIds, visibility: locked ? .locked : .timeline)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    // MARK: - Shared links

    /// Creates a public link to some photos, or to a whole album.
    func createSharedLink(
        assetIds: [String]?,
        albumId: String?,
        expiresAt: Date?,
        password: String?,
        allowDownload: Bool,
        allowUpload: Bool,
        showMetadata: Bool
    ) async throws -> Components.Schemas.SharedLinkResponseDto {
        let response = try await client.createSharedLink(body: .json(.init(
            albumId: albumId,
            allowDownload: allowDownload,
            allowUpload: allowUpload,
            assetIds: assetIds,
            expiresAt: expiresAt,
            password: (password?.isEmpty ?? true) ? nil : password,
            showMetadata: showMetadata,
            _type: albumId != nil ? .ALBUM : .INDIVIDUAL
        )))
        switch response {
        case .created(let created):
            return try created.body.json
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    func fetchSharedLinks() async throws -> [Components.Schemas.SharedLinkResponseDto] {
        let response = try await client.getAllSharedLinks(query: .init())
        return try response.ok.body.json
    }

    func removeSharedLink(id: String) async throws {
        let response = try await client.removeSharedLink(.init(path: .init(id: id)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// The address to give people: the server's own share page.
    func sharedLinkURL(_ link: Components.Schemas.SharedLinkResponseDto) -> URL {
        let base = apiURL.deletingLastPathComponent()
        if let slug = link.slug, !slug.isEmpty { return base.appendingPathComponent("s").appendingPathComponent(slug) }
        return base.appendingPathComponent("share").appendingPathComponent(link.key)
    }

    // MARK: - Ratings

    /// Sets a 1–5 star rating (or -1 to reject) on assets.
    func setRating(assetIds: [String], rating: Int) async throws {
        let response = try await client.updateAssets(body: .json(.init(ids: assetIds, rating: rating)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Removes the rating. The server wants an explicit `null` for this, which the
    /// generated request type can't express (a nil field is simply left out), so this
    /// one small request is built by hand.
    func clearRating(assetIds: [String]) async throws {
        var request = URLRequest(url: apiURL.appendingPathComponent("assets"))
        request.httpMethod = "PUT"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ids": assetIds, "rating": NSNull()] as [String: Any])
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ImmichServiceError.requestFailed(statusCode: http.statusCode, message: text.isEmpty ? nil : text)
        }
    }

    // MARK: - Tags

    func fetchTags() async throws -> [Components.Schemas.TagResponseDto] {
        let response = try await client.getAllTags()
        return try response.ok.body.json
    }

    func createTag(name: String) async throws -> Components.Schemas.TagResponseDto {
        let response = try await client.createTag(body: .json(.init(name: name)))
        switch response {
        case .created(let created):
            return try created.body.json
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    func tagAssets(_ assetIds: [String], with tagId: String) async throws {
        let response = try await client.tagAssets(.init(path: .init(id: tagId), body: .json(.init(ids: assetIds))))
        switch response {
        case .ok(let ok):
            let results = try ok.body.json
            // "Already has this tag" is fine; anything else that failed is not.
            if let failure = results.first(where: { !$0.success && $0.error != .duplicate }) {
                throw ImmichServiceError.requestFailed(statusCode: 200, message: failure.errorMessage ?? failure.error.map { "\($0)" })
            }
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    func untagAssets(_ assetIds: [String], from tagId: String) async throws {
        let response = try await client.untagAssets(.init(path: .init(id: tagId), body: .json(.init(ids: assetIds))))
        switch response {
        case .ok(let ok):
            try Self.checkBulkResult(try ok.body.json)
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    func deleteTag(id: String) async throws {
        let response = try await client.deleteTag(.init(path: .init(id: id)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    // MARK: - Sharing

    func fetchMe() async throws -> Components.Schemas.UserAdminResponseDto {
        let response = try await client.getMyUser()
        return try response.ok.body.json
    }

    /// Everyone on the server, for choosing who to share with.
    func fetchUsers() async throws -> [Components.Schemas.UserResponseDto] {
        let response = try await client.searchUsers()
        return try response.ok.body.json
    }

    func fetchAlbum(id: String) async throws -> Components.Schemas.AlbumResponseDto {
        let response = try await client.getAlbumInfo(.init(path: .init(id: id)))
        return try response.ok.body.json
    }

    func addUsers(_ users: [(id: String, role: Components.Schemas.AlbumUserRole)], toAlbum albumId: String) async throws {
        let dtos = users.map { Components.Schemas.AlbumUserAddDto(role: $0.role, userId: $0.id) }
        let response = try await client.addUsersToAlbum(.init(path: .init(id: albumId), body: .json(.init(albumUsers: dtos))))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    func setRole(_ role: Components.Schemas.AlbumUserRole, forUser userId: String, inAlbum albumId: String) async throws {
        let response = try await client.updateAlbumUser(.init(path: .init(id: albumId, userId: userId), body: .json(.init(role: role))))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    func removeUser(_ userId: String, fromAlbum albumId: String) async throws {
        let response = try await client.removeUserFromAlbum(.init(path: .init(id: albumId, userId: userId)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// People you share your whole library with (`sharedBy`), or who share theirs with you.
    func fetchPartners(sharedByMe: Bool) async throws -> [Components.Schemas.PartnerResponseDto] {
        let response = try await client.getPartners(query: .init(direction: sharedByMe ? .shared_hyphen_by : .shared_hyphen_with))
        return try response.ok.body.json
    }

    func addPartner(userId: String) async throws {
        let response = try await client.createPartner(body: .json(.init(sharedWithId: userId)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    func removePartner(userId: String) async throws {
        let response = try await client.removePartner(.init(path: .init(id: userId)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    func setPartnerInTimeline(userId: String, _ inTimeline: Bool) async throws {
        let response = try await client.updatePartner(.init(path: .init(id: userId), body: .json(.init(inTimeline: inTimeline))))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Reads who you are and which partners' photos belong in the Library, so the
    /// timeline and the read-only checks are right from the start.
    func refreshSharingState() async {
        if let me = try? await fetchMe() { sharing.currentUserId = me.id }
        if let partners = try? await fetchPartners(sharedByMe: false) {
            sharing.includePartnerPhotos = partners.contains { $0.inTimeline == true }
        }
    }

    /// True unless the asset is known to belong to someone else (a partner's photo),
    /// which you can look at but not change.
    func isMine(_ asset: AssetSummary) -> Bool {
        guard let owner = asset.ownerId, let me = sharing.currentUserId else { return true }
        return owner == me
    }

    // MARK: - Duplicates and stacks

    func fetchDuplicates() async throws -> [Components.Schemas.DuplicateResponseDto] {
        let response = try await client.getAssetDuplicates()
        return try response.ok.body.json
    }

    /// Applies keep/trash decisions to duplicate groups. Anything in `trash` goes to the
    /// trash (recoverable), and the group stops being reported as duplicates.
    func resolveDuplicates(_ groups: [(id: String, keep: [String], trash: [String])]) async throws {
        let dtos = groups.map { Components.Schemas.DuplicateResolveGroupDto(duplicateId: $0.id, keepAssetIds: $0.keep, trashAssetIds: $0.trash) }
        let response = try await client.resolveDuplicates(body: .json(.init(groups: dtos)))
        switch response {
        case .ok(let ok):
            try Self.checkBulkResult(try ok.body.json)
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Marks duplicate groups as "not duplicates", keeping every photo.
    func dismissDuplicates(ids: [String]) async throws {
        let response = try await client.deleteDuplicates(body: .json(.init(ids: ids)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Groups photos into a stack; the first becomes the cover.
    func createStack(assetIds: [String]) async throws {
        let response = try await client.createStack(body: .json(.init(assetIds: assetIds)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    func fetchStack(id: String) async throws -> Components.Schemas.StackResponseDto {
        let response = try await client.getStack(.init(path: .init(id: id)))
        return try response.ok.body.json
    }

    /// Dissolves stacks; the photos themselves stay.
    func deleteStacks(ids: [String]) async throws {
        let response = try await client.deleteStacks(body: .json(.init(ids: ids)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    func removeAsset(_ assetId: String, fromStack stackId: String) async throws {
        let response = try await client.removeAssetFromStack(.init(path: .init(assetId: assetId, id: stackId)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Takes assets back out of the trash.
    func restoreAssets(_ assetIds: [String]) async throws {
        let response = try await client.restoreAssets(body: .json(.init(ids: assetIds)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Deletes assets for good — not recoverable. Only ever used from the trash.
    func deleteAssetsPermanently(_ assetIds: [String]) async throws {
        let response = try await client.deleteAssets(.init(body: .json(.init(force: true, ids: assetIds))))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Permanently deletes everything in the trash.
    func emptyTrash() async throws {
        let response = try await client.emptyTrash()
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Moves an asset to trash (recoverable), matching Photos.app's "Delete" behavior.
    func trashAsset(assetId: String) async throws {
        try await trashAssets([assetId])
    }

    /// Moves several assets to trash in one request (recoverable, not a hard delete).
    func trashAssets(_ assetIds: [String]) async throws {
        let response = try await client.deleteAssets(.init(body: .json(.init(force: false, ids: assetIds))))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Immich's only supported edits today: crop, rotate, and mirror — applied
    /// non-destructively (the original file is untouched; `DELETE /assets/{id}/edits`
    /// reverts them). Confirmed by testing: `PUT /assets/{id}/edits` *replaces* the
    /// asset's whole edit state rather than accumulating, so applying rotate then
    /// mirror as two separate one-action calls silently discarded the rotation. Every
    /// caller must therefore always send the *complete* set of edits that should be
    /// active, not just the one the user just changed.
    enum EditAction {
        case rotate(degrees: Int)
        case mirror(axis: Components.Schemas.MirrorAxis)
        case crop(x: Int, y: Int, width: Int, height: Int)
    }

    /// Applies exactly the given set of edits, replacing whatever was there before.
    /// An empty set removes all edits instead of sending a request the API would
    /// reject (`edits` requires at least one item).
    func applyEdits(assetId: String, actions: [EditAction]) async throws {
        guard !actions.isEmpty else {
            let response = try await client.removeAssetEdits(.init(path: .init(id: assetId)))
            if case .undocumented(let statusCode, let payload) = response {
                throw await Self.failure(statusCode, payload)
            }
            return
        }
        let items = actions.map { action -> Components.Schemas.AssetEditActionItemDto in
            switch action {
            case .rotate(let degrees):
                return .init(action: .rotate, parameters: .init(value2: .init(angle: degrees)))
            case .mirror(let axis):
                return .init(action: .mirror, parameters: .init(value3: .init(axis: axis)))
            case .crop(let x, let y, let width, let height):
                return .init(action: .crop, parameters: .init(value1: .init(height: height, width: width, x: x, y: y)))
            }
        }
        // The generated client only throws for transport-level failures (no
        // connection, etc.) — a non-2xx HTTP response still comes back as a normal,
        // non-throwing `.undocumented` case, so a rejected edit (bad request,
        // validation failure, etc.) was previously being silently discarded and
        // treated as success by `_ = try await ...`.
        let response = try await client.editAsset(.init(path: .init(id: assetId), body: .json(.init(edits: items))))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// The error for a response the API description didn't expect (any non-success status),
    /// recorded in the log with the calling operation's name.
    static func failure(
        _ statusCode: Int,
        _ payload: OpenAPIRuntime.UndocumentedPayload,
        function: String = #function
    ) async -> ImmichServiceError {
        let text = (try? await message(from: payload)) ?? nil
        AppLog.error("\(function) → HTTP \(statusCode)" + (text.map { ": \($0.prefix(300))" } ?? ""))
        return .requestFailed(statusCode: statusCode, message: text)
    }

    private static func message(from payload: OpenAPIRuntime.UndocumentedPayload) async throws -> String? {
        guard let body = payload.body else { return nil }
        return try? await String(collecting: body, upTo: 16 * 1024)
    }

    /// Builds an authenticated request for a person's face thumbnail image.
    func personThumbnailRequest(personId: String) -> URLRequest {
        let url = apiURL.appendingPathComponent("people/\(personId)/thumbnail")
        var request = URLRequest(url: url)
        authorize(&request)
        return request
    }

    func fetchAlbums() async throws -> [Components.Schemas.AlbumResponseDto] {
        let name = "albums|\(apiURL.absoluteString)"
        do {
            let response = try await client.getAllAlbums(query: .init())
            let albums = try response.ok.body.json
            TimelineCache.save(albums, name: name)
            return albums
        } catch {
            // Offline: fall back to the list as last seen, so the sidebar isn't empty.
            if let saved = TimelineCache.load([Components.Schemas.AlbumResponseDto].self, name: name) { return saved }
            throw error
        }
    }

    /// The albums a single asset belongs to.
    func fetchAlbums(containing assetId: String) async throws -> [Components.Schemas.AlbumResponseDto] {
        let response = try await client.getAllAlbums(query: .init(assetId: assetId))
        return try response.ok.body.json
    }

    func createAlbum(name: String, initialAssetId: String? = nil) async throws -> Components.Schemas.AlbumResponseDto {
        try await createAlbum(name: name, assetIds: initialAssetId.map { [$0] } ?? [])
    }

    func createAlbum(name: String, assetIds: [String]) async throws -> Components.Schemas.AlbumResponseDto {
        let response = try await client.createAlbum(body: .json(.init(
            albumName: name,
            assetIds: assetIds.isEmpty ? nil : assetIds
        )))
        return try response.created.body.json
    }

    func deleteAlbum(id: String) async throws {
        let response = try await client.deleteAlbum(.init(path: .init(id: id)))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    func addAsset(_ assetId: String, toAlbum albumId: String) async throws {
        let response = try await client.addAssetsToAlbum(.init(path: .init(id: albumId), body: .json(.init(ids: [assetId]))))
        switch response {
        case .ok(let ok):
            try Self.checkBulkResult(try ok.body.json)
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    func removeAsset(_ assetId: String, fromAlbum albumId: String) async throws {
        let response = try await client.removeAssetFromAlbum(.init(path: .init(id: albumId), body: .json(.init(ids: [assetId]))))
        switch response {
        case .ok(let ok):
            try Self.checkBulkResult(try ok.body.json)
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    func removeAssets(_ assetIds: [String], fromAlbum albumId: String) async throws {
        let response = try await client.removeAssetFromAlbum(.init(path: .init(id: albumId), body: .json(.init(ids: assetIds))))
        switch response {
        case .ok(let ok):
            try Self.checkBulkResult(try ok.body.json)
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Renames an album and/or changes its cover photo; returns the album as it now is.
    func updateAlbum(id: String, name: String? = nil, thumbnailAssetId: String? = nil, description: String? = nil) async throws -> Components.Schemas.AlbumResponseDto {
        let response = try await client.updateAlbumInfo(.init(
            path: .init(id: id),
            body: .json(.init(albumName: name, albumThumbnailAssetId: thumbnailAssetId, description: description))
        ))
        switch response {
        case .ok(let ok):
            return try ok.body.json
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    struct AddToAlbumResult {
        var added = 0
        var alreadyInAlbum = 0
        var failed = 0
    }

    /// Adds several assets to an album at once. Immich reports each asset separately
    /// (inside an HTTP 200), and "already in this album" comes back as a per-item
    /// `duplicate` — for a multi-select that's a normal outcome to report, not a
    /// failure, so it's counted separately rather than thrown.
    func addAssets(_ assetIds: [String], toAlbum albumId: String) async throws -> AddToAlbumResult {
        let response = try await client.addAssetsToAlbum(.init(path: .init(id: albumId), body: .json(.init(ids: assetIds))))
        switch response {
        case .ok(let ok):
            var result = AddToAlbumResult()
            for item in try ok.body.json {
                if item.success {
                    result.added += 1
                } else if item.error == .duplicate {
                    result.alreadyInAlbum += 1
                } else {
                    result.failed += 1
                }
            }
            return result
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Album add/remove return HTTP 200 even when the operation itself failed —
    /// success/failure is reported per item in the body instead.
    private static func checkBulkResult(_ items: [Components.Schemas.BulkIdResponseDto]) throws {
        guard let failure = items.first(where: { !$0.success }) else { return }
        throw ImmichServiceError.requestFailed(statusCode: 200, message: failure.errorMessage ?? failure.error.map { "\($0)" })
    }

    /// Every person, following the server's pages — a library with lots of unnamed face
    /// clusters can easily have more than one page (500) of them.
    func fetchPeople(includeHidden: Bool = false) async throws -> [Components.Schemas.PersonResponseDto] {
        var people: [Components.Schemas.PersonResponseDto] = []
        var page = 1
        while true {
            try Task.checkCancellation()
            let response = try await client.getAllPeople(query: .init(page: page, size: 1000, withHidden: includeHidden))
            let result = try response.ok.body.json
            people += result.people
            guard result.hasNextPage == true else { return people }
            page += 1
        }
    }

    /// The faces Immich found in one photo, each with the person it was matched to (nil
    /// if it hasn't been assigned to anyone).
    func fetchFaces(assetId: String) async throws -> [Components.Schemas.AssetFaceResponseDto] {
        let response = try await client.getFaces(.init(query: .init(id: assetId)))
        return try response.ok.body.json
    }

    /// Sets a person's name. A person is a cluster of matching faces, so this names that
    /// person in every photo they appear in.
    func renamePerson(id: String, name: String) async throws -> Components.Schemas.PersonResponseDto {
        let response = try await client.updatePerson(.init(path: .init(id: id), body: .json(.init(name: name))))
        switch response {
        case .ok(let ok): return try ok.body.json
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Changes only the fields given: favorite, hidden, birthday, or the photo whose face is
    /// the person's cover.
    func updatePerson(
        id: String,
        isFavorite: Bool? = nil,
        isHidden: Bool? = nil,
        birthDate: Date? = nil,
        featureFaceAssetId: String? = nil
    ) async throws -> Components.Schemas.PersonResponseDto {
        let response = try await client.updatePerson(.init(
            path: .init(id: id),
            body: .json(.init(
                birthDate: birthDate.map(PersonBirthday.string(from:)),
                featureFaceAssetId: featureFaceAssetId,
                isFavorite: isFavorite,
                isHidden: isHidden
            ))
        ))
        switch response {
        case .ok(let ok): return try ok.body.json
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    func createPerson(name: String) async throws -> Components.Schemas.PersonResponseDto {
        let response = try await client.createPerson(.init(body: .json(.init(name: name))))
        switch response {
        case .created(let created): return try created.body.json
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Moves one face to a different person, without touching that person's other faces.
    func assignFace(_ faceId: String, toPerson personId: String) async throws {
        let response = try await client.reassignFacesById(.init(path: .init(id: personId), body: .json(.init(id: faceId))))
        if case .undocumented(let statusCode, let payload) = response {
            throw await Self.failure(statusCode, payload)
        }
    }

    /// Folds one person into another: all of `sourceId`'s faces become `targetId`'s, and
    /// the source person disappears. Immich reports the outcome per person inside a 200.
    func mergePerson(_ sourceId: String, into targetId: String) async throws {
        let response = try await client.mergePersonLegacy(.init(path: .init(id: targetId), body: .json(.init(ids: [sourceId]))))
        switch response {
        case .ok(let ok):
            try Self.checkBulkResult(try ok.body.json)
        case .undocumented(let statusCode, let payload):
            throw await Self.failure(statusCode, payload)
        }
    }

    func fetchMemories() async throws -> [Components.Schemas.MemoryResponseDto] {
        let response = try await client.searchMemories(query: .init())
        return try response.ok.body.json
    }

    /// Cities to browse by, each represented by one sample asset (Immich's `/search/cities`).
    func fetchCityHighlights() async throws -> [(city: String, asset: AssetSummary)] {
        let response = try await client.getAssetsByCity()
        let assets = try response.ok.body.json
        return assets.compactMap { asset in
            guard let city = asset.exifInfo?.city else { return nil }
            return (city, AssetSummary.makeSummaries(from: [asset])[0])
        }
    }

    /// All assets taken in a given city. Uses the metadata search endpoint's `city`
    /// filter, which Immich has marked deprecated (as of v3.2.0) in favor of map/bbox
    /// browsing, but which remains the simplest way to browse by place today.
    func fetchAssets(inCity city: String) async throws -> [AssetSummary] {
        let response = try await client.searchAssets(body: .json(.init(city: city)))
        let assets = try response.ok.body.json.assets.items
        return AssetSummary.makeSummaries(from: assets)
    }

    /// Natural-language photo search via Immich's CLIP-based smart search.
    func searchSmart(query: String) async throws -> [AssetSummary] {
        let response = try await client.searchSmart(body: .json(.init(query: query)))
        let assets = try response.ok.body.json.assets.items
        return AssetSummary.makeSummaries(from: assets)
    }

    enum UploadResult {
        case created(assetId: String)
        case duplicate(assetId: String)
    }

    private static let uploadDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Optional extras for an upload.
    struct UploadOptions {
        var isFavorite = false
        /// Links this upload (a still) to an already-uploaded Live Photo motion video.
        var livePhotoVideoId: String?
    }

    /// Uploads in-memory data as a new asset. `checksum` (SHA1, hex-encoded) lets the
    /// server recognize a file that's already in the library and report it back as a
    /// duplicate instead of storing a second copy.
    func uploadAsset(
        data: Data,
        filename: String,
        createdAt: Date,
        modifiedAt: Date,
        checksum: String,
        options: UploadOptions = UploadOptions()
    ) async throws -> UploadResult {
        // The uploader streams from a file, so in-memory data goes via a temporary one.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try await uploadAsset(
            fileURL: temp, filename: filename, createdAt: createdAt,
            modifiedAt: modifiedAt, checksum: checksum, options: options
        )
    }

    // MARK: - Large uploads

    /// UserDefaults key for the optional address that skips Cloudflare (see Settings).
    static let directUploadKey = "directUploadURL"
    /// Files at least this big go to the direct address when one is set. A little under
    /// Cloudflare's 100 MB request limit, which includes the upload's own framing.
    static let directUploadThreshold: Int64 = 95 * 1_048_576

    /// The API address of the direct (un-proxied) server, if one is set.
    static var directUploadBase: URL? {
        guard let text = UserDefaults.standard.string(forKey: directUploadKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            !text.isEmpty, let url = URL(string: text), url.scheme != nil, url.host != nil
        else { return nil }
        return url.lastPathComponent == "api" ? url : url.appendingPathComponent("api")
    }

    static func tooLargeMessage(bytes: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "This file (\(size)) is bigger than your server connection accepts — Cloudflare limits uploads to about 100 MB. "
            + "Add a direct server address under Settings > Large files to upload files like this."
    }

    /// Where an upload of this size should be sent, or an error if it's known to be
    /// turned away — so a file that can't go up isn't downloaded from iCloud or sent first.
    func uploadTarget(forBytes bytes: Int64) throws -> URL {
        if bytes >= Self.directUploadThreshold, let direct = Self.directUploadBase { return direct }
        if let rejected = sharing.rejectedUploadBytes, bytes >= rejected {
            throw ImmichServiceError.requestFailed(statusCode: 413, message: Self.tooLargeMessage(bytes: bytes))
        }
        return apiURL
    }

    /// Uploads a file on disk, streamed straight from disk (originals exported from
    /// Photos can be multi-gigabyte videos). Goes through `CurlUploader` rather than the
    /// generated client — see there for why URLSession can't be used for uploads to
    /// this server. Transient failures are retried; the result is judged by status
    /// code, so a rejected upload is thrown rather than mistaken for success.
    func uploadAsset(
        fileURL: URL,
        filename: String,
        createdAt: Date,
        modifiedAt: Date,
        checksum: String,
        options: UploadOptions = UploadOptions()
    ) async throws -> UploadResult {
        var fields: [CurlUploader.Field] = [
            .file(name: "assetData", path: fileURL, filename: filename),
            .text(name: "fileCreatedAt", value: Self.uploadDateFormatter.string(from: createdAt)),
            .text(name: "fileModifiedAt", value: Self.uploadDateFormatter.string(from: modifiedAt)),
            .text(name: "filename", value: filename),
        ]
        if options.isFavorite { fields.append(.text(name: "isFavorite", value: "true")) }
        if let livePhotoVideoId = options.livePhotoVideoId {
            fields.append(.text(name: "livePhotoVideoId", value: livePhotoVideoId))
        }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let target = try uploadTarget(forBytes: bytes)

        let response = try await CurlUploader.post(
            url: target.appendingPathComponent("assets"),
            headers: ["x-api-key": apiKey, "x-immich-checksum": checksum, "Accept": "application/json"],
            fields: fields
        )

        guard response.statusCode == 200 || response.statusCode == 201 else {
            let text = String(decoding: response.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.error("uploadAsset(\(filename), \(bytes) bytes) → HTTP \(response.statusCode)" + (text.isEmpty ? "" : ": \(text.prefix(300))"))
            if response.statusCode == 413 {
                // Remember it, so bigger files fail at once instead of being sent first.
                sharing.rejectedUploadBytes = min(sharing.rejectedUploadBytes ?? .max, bytes)
                throw ImmichServiceError.requestFailed(statusCode: 413, message: Self.tooLargeMessage(bytes: bytes))
            }
            throw ImmichServiceError.requestFailed(statusCode: response.statusCode, message: text.isEmpty ? nil : text)
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let assetId = json["id"] as? String
        else { throw ImmichServiceError.uploadFailed }
        return response.statusCode == 201 ? .created(assetId: assetId) : .duplicate(assetId: assetId)
    }
}


/// Immich stores a birthday as a plain calendar date ("1985-03-27"), with no time zone.
enum PersonBirthday {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
    static func date(from text: String) -> Date? { formatter.date(from: String(text.prefix(10))) }
}
