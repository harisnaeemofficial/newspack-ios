import Foundation
import WordPressFlux

struct PostFetchedApiAction: ApiAction {
    var payload: RemotePost?
    var error: Error?
    var postID: Int64
}

struct PostIDsFetchedApiAction: ApiAction {
    var payload: [RemotePostID]?
    var error: Error?
    var count: Int
    var filter: [String: AnyObject]
    var page: Int
    var hasMore: Bool
}

struct AutosaveApiAction: ApiAction {
    var payload: RemoteRevision?
    var error: Error?
    var postID: Int64
}

struct PostCreatedApiAction: ApiAction {
    var payload: RemotePost?
    var error: Error?
    var uuid: UUID
}

struct PostUpdatedApiAction: ApiAction {
    var payload: RemotePost?
    var error: Error?
    var postID: Int64
}
