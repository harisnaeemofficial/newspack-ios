import UIKit
import CoreData
import WordPressFlux
import WordPressUI

/// Displays a list of posts for the current PostQuery.
/// State is divided between the PostItemStore which is responsible for syncing,
/// and identifying the current post list being worked on, and CoreData via an
/// NSFetchedResultsControllerDelegate which is responsible for detecting and
/// responding to changes in the data model.
///
class PostListViewController: UITableViewController {

    let cellIdentifier = "PostCellIdentifier"
    let sortField = "postID"

    // PostItemStore receipt.
    var postItemReceipt: Receipt?

    lazy var resultsController: NSFetchedResultsController<PostItem> = {
        let fetchRequest = PostItem.defaultFetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: sortField, ascending: false)]
        return NSFetchedResultsController(fetchRequest: fetchRequest,
                                          managedObjectContext: CoreDataManager.shared.mainContext,
                                          sectionNameKeyPath: nil,
                                          cacheName: nil)
    }()

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)

        resultsController.delegate = self
        postItemReceipt = StoreContainer.shared.postItemStore.onStateChange({ [weak self] state in
            self?.handlePostItemStoreStateChanged(oldState: state.0, newState: state.1)
        })
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(handleRefreshControl), for: .valueChanged)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        configureResultsController()
        syncIfNeeded()
    }

    func configureResultsController() {
        if let postQuery = StoreContainer.shared.postItemStore.currentQuery {
            resultsController.fetchRequest.predicate = NSPredicate(format: "%@ in postQueries", postQuery)
        }
        try? resultsController.performFetch()

        tableView.reloadData()
    }

    @IBAction func handleCreatePostButtonTapped() {
        guard let site = StoreContainer.shared.postItemStore.currentQuery?.site else {
            return
        }
        let coordinator = EditCoordinator(postItem: nil, dispatcher: SessionManager.shared.sessionDispatcher, siteID: site.uuid)
        let controller = MainStoryboard.instantiateViewController(withIdentifier: .editor) as! EditorViewController
        controller.coordinator = coordinator
        navigationController?.pushViewController(controller, animated: true)
    }
}

// MARK: - Sync related methods.
extension PostListViewController {

    @objc func handleRefreshControl() {
        let dispatcher = SessionManager.shared.sessionDispatcher
        dispatcher.dispatch(PostAction.syncItems(force: true))
    }

    func syncIfNeeded() {
        let dispatcher = SessionManager.shared.sessionDispatcher
        dispatcher.dispatch(PostAction.syncItems(force: false))
    }
}

// MARK: - PostList State Related methods
extension PostListViewController {

    func handlePostItemStoreStateChanged(oldState: PostItemStoreState, newState: PostItemStoreState) {
        if oldState == .syncing {
            refreshControl?.endRefreshing()

        } else if oldState == .changingCurrentQuery {
            configureResultsController()
        }
    }
}

// MARK: - Table view data source
extension PostListViewController {

    override func numberOfSections(in tableView: UITableView) -> Int {
        // #warning Incomplete implementation, return the number of sections
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // #warning Incomplete implementation, return the number of rows
        return resultsController.fetchedObjects?.count ?? 0
    }

    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let listItem = resultsController.object(at: indexPath)
        let dispatcher = SessionManager.shared.sessionDispatcher
        dispatcher.dispatch(PostAction.syncPost(postID: listItem.postID))

        let count = resultsController.fetchedObjects?.count ?? 0
        if count > 0 && indexPath.row > (count - 5)  {
            dispatcher.dispatch(PostAction.syncNextPage)
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier, for: indexPath)

        configureCell(cell, atIndexPath: indexPath)

        return cell
    }

    func configureCell(_ cell: UITableViewCell, atIndexPath indexPath: IndexPath) {
        let listItem = resultsController.object(at: indexPath)

        cell.accessoryView = nil
        cell.accessoryType = .disclosureIndicator

        if let post = listItem.post {
            cell.textLabel?.text = post.titleRendered
            if listItem.syncing {
                cell.accessoryView = UIActivityIndicatorView(style: .medium)
            }
        } else {
            cell.textLabel?.text = ""
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let listItem = resultsController.object(at: indexPath)
        let coordinator = EditCoordinator.init(postItem: listItem, dispatcher: SessionManager.shared.sessionDispatcher, siteID: listItem.site.uuid)
        let controller = MainStoryboard.instantiateViewController(withIdentifier: .editor) as! EditorViewController
        controller.coordinator = coordinator
        navigationController?.pushViewController(controller, animated: true)
    }
}

// MARK: - NSFetchedResultsController Methods
extension PostListViewController: NSFetchedResultsControllerDelegate {

    func controllerWillChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        tableView.beginUpdates()
    }

    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange sectionInfo: NSFetchedResultsSectionInfo, atSectionIndex sectionIndex: Int, for type: NSFetchedResultsChangeType) {
        switch type {
        case .insert:
            tableView.insertSections(IndexSet.init(integer: sectionIndex), with: .automatic)
        case .delete:
            tableView.deleteSections(IndexSet.init(integer: sectionIndex), with: .automatic)
        default:
            break;
        }
    }

    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>, didChange anObject: Any, at indexPath: IndexPath?, for type: NSFetchedResultsChangeType, newIndexPath: IndexPath?) {
        // Seriously, Apple?
        // https://developer.apple.com/library/archive/releasenotes/iPhone/NSFetchedResultsChangeMoveReportedAsNSFetchedResultsChangeUpdate/index.html
        //
        let fixedType: NSFetchedResultsChangeType = {
            guard type == .update && newIndexPath != nil && newIndexPath != indexPath else {
                return type
            }
            return .move
        }()

        let animation = UITableView.RowAnimation.none

        switch fixedType {
        case .insert:
            tableView.insertRows(at: [newIndexPath!], with: animation)
        case .delete:
            tableView.deleteRows(at: [indexPath!], with: animation)
        case .move:
            tableView.deleteRows(at: [indexPath!], with: animation)
            tableView.insertRows(at: [newIndexPath!], with: animation)
        case .update:
            tableView.reloadRows(at: [indexPath!], with: animation)
        @unknown default:
            LogWarn(message: "Unhandled NSFetchedResultsChangeType")
        }
    }

    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        tableView.endUpdates()
    }
}
