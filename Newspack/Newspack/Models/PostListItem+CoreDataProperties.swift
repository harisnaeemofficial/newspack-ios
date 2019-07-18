import Foundation
import CoreData


extension PostListItem {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<PostListItem> {
        return NSFetchRequest<PostListItem>(entityName: "PostListItem")
    }

    @NSManaged public var postID: Int64
    @NSManaged public var date: NSDate!
    @NSManaged public var modified: NSDate!
    @NSManaged public var versionCount: Int16
    @NSManaged public var syncing: Bool

    @NSManaged public var post: Post!
    @NSManaged public var postLists: Set<PostList>!

}

// MARK: Generated accessors for postList
extension PostListItem {

    @objc(addPostListObject:)
    @NSManaged public func addToPostLists(_ value: PostList)

    @objc(removePostListObject:)
    @NSManaged public func removeFromPostLists(_ value: PostList)

    @objc(addPostList:)
    @NSManaged public func addToPostLists(_ values: Set<PostList>)

    @objc(removePostList:)
    @NSManaged public func removeFromPostLists(_ values: Set<PostList>)

}