import Foundation
import CoreData
import WordPressFlux

/// Responsible for managing site related things.
///
class AccountDetailsStore: Store {

    private(set) var currentAccountID: UUID?

    init(dispatcher: ActionDispatcher = .global, accountID: UUID? = nil) {
        currentAccountID = accountID
        super.init(dispatcher: dispatcher)
    }

    /// Action handler
    ///
    override func onDispatch(_ action: Action) {
        if let apiAction = action as? AccountFetchedApiAction {
            handleAccountFetched(action: apiAction)
        }
    }
}

extension AccountDetailsStore {

    /// Handles the accountFetched action.
    ///
    /// - Parameters:
    ///     - user: The remote user
    ///     - error: Any error.
    ///
    func handleAccountFetched(action: AccountFetchedApiAction) {
        guard !action.isError() else {
            // TODO: Handle error.
            if let error = action.error as NSError? {
                LogError(message: "handleAccountFetched: " + error.localizedDescription)
            }
            return
        }

        let accountStore = StoreContainer.shared.accountStore
        guard
            let user = action.payload,
            let accountID = currentAccountID,
            let accountObjID = accountStore.getAccountByUUID(accountID)?.objectID
            else {
                LogError(message: "handleAccountFetched: A value was unexpectedly nil.")
                return
        }

        CoreDataManager.shared.performOnWriteContext { [weak self] context in
            let account = context.object(with: accountObjID) as! Account
            let details = account.details ?? AccountDetails(context: context)

            details.userID = user.id
            details.name = user.name
            details.firstName = user.firstName
            details.lastName = user.lastName
            details.nickname = user.nickname
            details.email = user.email
            details.avatarUrls = user.avatarUrls
            details.link = user.link
            details.locale = user.locale
            details.slug = user.slug
            details.summary = user.description
            details.url = user.url
            details.username = user.username
            details.registeredDate = user.registeredDate

            account.details = details

            CoreDataManager.shared.saveContext(context: context)

            DispatchQueue.main.async {
                self?.emitChange()
            }
        }
    }
}
