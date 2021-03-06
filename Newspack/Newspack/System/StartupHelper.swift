import Foundation
import CoreData

/// A helper class for wrangling tasks that should happen whenever the app is
/// launched or a new session is started.
///
class StartupHelper {

    /// Resets flags related to syncing on the PostList and PostListItem models.
    ///
    static func resetSyncFlags() {
        let queryRequest = NSBatchUpdateRequest(entityName: "PostQuery")
        queryRequest.propertiesToUpdate = ["hasMore": true]

        let itemRequest = NSBatchUpdateRequest(entityName: "PostItem")
        itemRequest.propertiesToUpdate = ["syncing": false]
        do {
            try CoreDataManager.shared.mainContext.execute(queryRequest)
            try CoreDataManager.shared.mainContext.execute(itemRequest)
        } catch {
            LogError(message: "resetSyncFlags: Error updating hasMore and/or syncing fields on lists and list items.")
        }
    }

    /// This mimics the behavior of the web editor. When the web editor is opened an auto-draft is created
    /// to get a post ID for the changes. Many auto-drafts go unused (they are never made into posts).  For
    /// these there is a process that runs periodically to find unused auto-drafts and delete them.
    ///
    /// Simiilarly, this process is ran to git rid of any StagedEdit that does not have an associated
    /// PostListItem.
    ///
    static func purgeStaleStagedEdits() {
        let fetch = StagedEdits.defaultFetchRequest()
        fetch.predicate = NSPredicate(format: "postItem == NULL")
        let req = NSBatchDeleteRequest(fetchRequest: fetch as! NSFetchRequest<NSFetchRequestResult>)

        let context = CoreDataManager.shared.mainContext
        do{
            try context.execute(req)
            let result = try context.execute(req) as? NSBatchDeleteResult
            let changes: [AnyHashable: Any] = [NSDeletedObjectsKey: result?.result as? [NSManagedObjectID] ?? []]
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
        } catch {
            LogError(message: "purgeStaleStagedEdits: Error purging stale staged edits.")
        }

    }

}
