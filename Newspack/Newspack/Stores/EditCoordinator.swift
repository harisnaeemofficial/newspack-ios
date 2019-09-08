import Foundation
import WordPressFlux
import Gutenberg
import Aztec

/// Provides a bridge between the Editor, and the content being edited.
///
class EditCoordinator: Store {

    private let currentSiteID: UUID
    var postItem: PostListItem?
    let stagedEdits: StagedEdits
    var createdPostUUID: UUID? // An identifier used to pair an api action to edits being made.

    var hasLocalChanges: Bool {
        if stagedEdits.title == "" && stagedEdits.content == "" {
            return false
        }

        if let post = stagedEdits.postListItem?.post {
            return stagedEdits.title != post.title || stagedEdits.content != post.content
        }

        return true
    }

    init(postItem: PostListItem?, dispatcher: ActionDispatcher, siteID: UUID) {
        self.currentSiteID = siteID
        self.postItem = postItem
        self.stagedEdits = postItem?.stagedEdits ?? StagedEdits(context: CoreDataManager.shared.mainContext)
        super.init(dispatcher: dispatcher)
    }

    override func onDispatch(_ action: Action) {
        // API Actions
        if let apiAction = action as? PostCreatedApiAction {
            handlePostCreatedApiAction(action: apiAction)
            return
        } else if let apiAction = action as? AutosaveApiAction {
            handleAutosaveApiAction(action: apiAction)
            return
        } else if let apiAction = action as? PostUpdatedApiAction {
            handlePostUpdatedApiAction(action: apiAction)
            return
        }

        // Save Actions
        if let saveAction = action as? PostSaveAction {
            handlePostSaveAction(action: saveAction)
            return
        }

        // Edit Actions
        guard let editAction = action as? EditAction else {
            return
        }

        switch editAction {
        case .autosave(let title, let content):
            handleAutosaveAction(title: title, content: content)
        case .stageChanges(let title, let content):
            handleStageChangesAction(title: title, content: content)
        case .discardChanges:
            handleDiscardChangesAction()
        }
    }

}

// MARK: - Edit and Save Action Handlers
extension EditCoordinator {

    func handlePostSaveAction(action: PostSaveAction) {
        switch action {
        case .publish:
            createOrUpdatePostWithStatus(status: "publish")
        case .publishPrivately:
            createOrUpdatePostWithStatus(status: "private")
        case .saveAsDraft:
            createOrUpdatePostWithStatus(status: "draft")
        case .saveAsPending:
            createOrUpdatePostWithStatus(status: "pending")
        case .trash:
            createOrUpdatePostWithStatus(status: "trash")
            break
        }
    }

    func handleStageChangesAction(title: String, content: String) {
        guard title != stagedEdits.title || content != stagedEdits.content else {
            return
        }
        stagedEdits.title = title
        stagedEdits.content = content
        stagedEdits.lastModified = Date()

        CoreDataManager.shared.saveContext()
    }

    func handleAutosaveAction(title: String, content: String) {
        handleStageChangesAction(title: title, content: content)

        guard let item = stagedEdits.postListItem else {
            // This is our first remote autosave, so create a new draft post and post list item.
            createPostWithStatus(status: "draft")
            return
        }

        if item.modifiedGMT > stagedEdits.lastModified {
            // No changes.
            return
        }

        autosave()
    }

    func handleDiscardChangesAction() {
        // TODO: This will need also need to clean up a "local" post list item if we go that route.
        let context = CoreDataManager.shared.mainContext
        context.delete(stagedEdits)
        CoreDataManager.shared.saveContext()
    }
}

// MARK: - API Calls
extension EditCoordinator {

    func autosave() {
        guard let postID = stagedEdits.postListItem?.postID else {
            // TODO: Log this
            return
        }

        let title = stagedEdits.title ?? ""
        let content = stagedEdits.content ?? ""
        let postService = ApiService.shared.postServiceRemote()
        postService.autosave(postID: postID, title: title, content: content)
    }

    func createOrUpdatePostWithStatus(status: String) {
        guard let post = stagedEdits.postListItem?.post else {
            createPostWithStatus(status: status)
            return
        }
        updatePost(post: post, withStatus: status)
    }

    func createPostWithStatus(status: String) {
        let postService = ApiService.shared.postServiceRemote()

        let title = stagedEdits.title ?? ""
        let content = stagedEdits.content ?? ""
        let params = [
            "title": title,
            "content" : content,
            "status" : status,
            ] as [String: AnyObject]
        createdPostUUID = UUID()
        postService.createPost(uuid: createdPostUUID!, postParams: params)
    }

    func updatePost(post: Post, withStatus status: String) {
        var params = parametersFromPost(post: post)
        params["status"] = status as AnyObject

        let postService = ApiService.shared.postServiceRemote()
        postService.updatePost(postID: post.postID, postParams: params)
    }

    func parametersFromPost(post: Post) -> [String: AnyObject] {
        var dict = [String: Any]()
        dict["title"] = post.title
        dict["content"] = post.content
        dict["date"] = post.date
        // TODO: Flesh this out as other properties are editable.
        return dict as [String: AnyObject]
    }
}

// MARK: - API action handlers
extension EditCoordinator {

    func handleAutosaveApiAction(action: AutosaveApiAction) {
        if action.isError() {
            // TODO: Handle error
            return
        }

        guard
            let remoteRevision = action.payload,
            let post = stagedEdits.postListItem?.post
        else {
            // This is a critical error and should not be able to happen.
            return
        }

        if remoteRevision.parentID == 0 {
            // we're updating a draft/pending post directly.
            updatePost(post: post, with: remoteRevision)

        } else if remoteRevision.revisionID == post.postID {
            // we're updating an autosave on published/scheduled/private post.
            createOrUpdateAutosaveRevisionForPost(post: post, with: remoteRevision)
        } else {
            // TODO: Handle error.
            assertionFailure()
        }
    }

    func updatePost(post: Post, with remoteRevision: RemoteRevision) {
        guard post.postID == remoteRevision.revisionID else {
            return
        }

        // Update a draft/pending post with remote post.
        // Autosaves should only update title, content, exerpt and modified.
        // However, update the date also in case it should match date modified.
        post.title = remoteRevision.title
        post.titleRendered = remoteRevision.titleRendered
        post.content = remoteRevision.content
        post.contentRendered = remoteRevision.contentRendered
        post.excerpt = remoteRevision.excerpt
        post.excerptRendered = remoteRevision.excerptRendered
        post.date = remoteRevision.date
        post.dateGMT = remoteRevision.dateGMT
        post.modified = remoteRevision.modified
        post.modifiedGMT = remoteRevision.modifiedGMT

        // Enusre the post list item reflects the updated date.
        post.item.dateGMT = post.dateGMT
        post.item.modifiedGMT = post.modifiedGMT

        CoreDataManager.shared.saveContext()
    }

    func createOrUpdateAutosaveRevisionForPost(post: Post, with remoteRevision: RemoteRevision) {
        // create or update autosave revision
        let context = CoreDataManager.shared.mainContext
        let fetchRequest = Revision.defaultFetchRequest()
        fetchRequest.predicate = NSPredicate(format: "post == %@ AND revisionID == %ld", post, remoteRevision.revisionID)

        let revision: Revision
        do {
            revision = try context.fetch(fetchRequest).first ?? Revision(context: context)
        } catch {
            revision = Revision(context: context)
            // TODO: properly log this
        }

        updateRevision(revision: revision, with: remoteRevision)
        revision.post = post

        CoreDataManager.shared.saveContext()
    }

    func handlePostCreatedApiAction(action: PostCreatedApiAction) {
        if action.isError() {
            // TODO:
            return
        }

        guard
            let remotePost = action.payload,
            action.uuid == createdPostUUID
        else {
            return
        }

        createdPostUUID = nil

        // Use the payload to create a new Post and PostListItem.
        // The item should be assigned to the "ALL" PostList.

        guard let list = StoreContainer.shared.postListStore.postListByName(name: "all", siteUUID: currentSiteID) else {
            return
        }

        let context = CoreDataManager.shared.mainContext

        let postStore = StoreContainer.shared.postStore
        let post = Post(context: context)
        postStore.updatePost(post, with: remotePost)
        post.site = list.site

        let postItem = PostListItem(context: context)
        postItem.postID = post.postID
        postItem.dateGMT = post.dateGMT
        postItem.modifiedGMT = post.modifiedGMT
        postItem.revisionCount = 0

        postItem.stagedEdits = stagedEdits
        postItem.post = post
        postItem.site = list.site
        postItem.addToPostLists(list)

        CoreDataManager.shared.saveContext()
    }

    func handlePostUpdatedApiAction(action: PostUpdatedApiAction) {
        // TODO:
        if action.isError() {
            // TODO:
            return
        }

        guard
            let remotePost = action.payload,
            let postItem = postItem,
            let post = postItem.post,
            post.postID == remotePost.postID
        else {
            return
        }

        let postStore = StoreContainer.shared.postStore
        postStore.updatePost(post, with: remotePost)

        // TODO: This work could be moved into postStore.updatePost provided
        // there is always a postItem.
        postItem.dateGMT = post.dateGMT
        postItem.modifiedGMT = post.modifiedGMT
        postItem.revisionCount = post.revisionCount

        CoreDataManager.shared.saveContext()
    }

    func updateRevision(revision: Revision, with remoteRevision: RemoteRevision) {
        revision.authorID = remoteRevision.authorID
        revision.content = remoteRevision.content
        revision.contentRendered = remoteRevision.contentRendered
        revision.date = remoteRevision.date
        revision.dateGMT = remoteRevision.dateGMT
        revision.excerpt = remoteRevision.excerpt
        revision.excerptRendered = remoteRevision.excerptRendered
        revision.modified = remoteRevision.modified
        revision.modifiedGMT = remoteRevision.modifiedGMT
        revision.parentID = remoteRevision.parentID
        revision.revisionID = remoteRevision.revisionID
        revision.slug = remoteRevision.slug
        revision.title = remoteRevision.title
        revision.titleRendered = remoteRevision.titleRendered
    }
}

// MARK: - Gutenberg related
extension EditCoordinator: GutenbergBridgeDataSource {
    func gutenbergInitialContent() -> String? {
        if
            let edits = postItem?.stagedEdits,
            let content = edits.content
        {
            return content
        }
        return postItem?.post?.content ?? ""
    }

    func gutenbergInitialTitle() -> String? {
        if
            let edits = postItem?.stagedEdits,
            let title = edits.title
        {
            return title
        }
        return postItem?.post?.title ?? ""
    }

    func aztecAttachmentDelegate() -> TextViewAttachmentDelegate {
        return EditorAttachmentDelegate()
    }

    func gutenbergLocale() -> String? {
        // TODO: Use system locale
        return "en"
    }

    func gutenbergTranslations() -> [String : [String]]? {
        return nil
    }
}

// MARK: - UIAlertController related / Save options.
extension EditCoordinator {

    func getSaveAlertController() -> UIAlertController {
        var canUpdate = false
        if let post = postItem?.post {
            canUpdate = postCanUpdate(post: post)
        }
        return EditorSaveAlertControllerFactory().controllerForStagedEdits(stagedEdits: stagedEdits, canUpdate: canUpdate, for: postItem?.post)
    }

    func postCanUpdate(post: Post) -> Bool {
        return stagedEdits.title != post.title || stagedEdits.content != post.content
    }
}
