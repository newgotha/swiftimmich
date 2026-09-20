import ImmichAPI

/// Which slice of the library a timeline grid should show. Immich's timeline endpoints
/// take an optional albumId/personId/isFavorite/visibility, so albums, people,
/// favorites, and archive all reuse the same bucketed grid as the main library
/// rather than needing their own asset-listing endpoints.
enum TimelineFilter: Hashable {
    case none
    case album(id: String, name: String)
    case person(id: String, name: String)
    case tag(id: String, name: String)
    /// Everything whose location falls inside a box (used by the map).
    case area(west: Double, south: Double, east: Double, north: Double)
    case favorites
    case archive
    case trash
    case locked

    var albumId: String? {
        if case let .album(id, _) = self { return id }
        return nil
    }

    var personId: String? {
        if case let .person(id, _) = self { return id }
        return nil
    }

    var bbox: String? {
        if case let .area(west, south, east, north) = self { return "\(west),\(south),\(east),\(north)" }
        return nil
    }

    var tagId: String? {
        if case let .tag(id, _) = self { return id }
        return nil
    }

    var isFavorite: Bool? {
        if case .favorites = self { return true }
        return nil
    }

    var visibility: Components.Schemas.AssetVisibility? {
        if case .archive = self { return .archive }
        if case .locked = self { return .locked }
        return nil
    }

    /// The main timelines show a stack as just its cover photo, like Immich's own web
    /// app; album and person pages list every photo.
    var collapsesStacks: Bool {
        switch self {
        case .none, .favorites, .archive: return true
        case .album, .person, .tag, .area, .trash, .locked: return false
        }
    }

    /// Only the main Library mixes in photos partners share with you.
    var includesPartnerPhotos: Bool {
        if case .none = self { return true }
        return false
    }

    var isLocked: Bool {
        if case .locked = self { return true }
        return false
    }

    var isTrashed: Bool {
        if case .trash = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .none: return "Library"
        case .album(_, let name): return name
        case .person(_, let name): return name
        case .tag(_, let name): return name
        case .area: return "This Area"
        case .favorites: return "Favorites"
        case .archive: return "Archive"
        case .trash: return "Recently Deleted"
        case .locked: return "Locked Folder"
        }
    }
}
