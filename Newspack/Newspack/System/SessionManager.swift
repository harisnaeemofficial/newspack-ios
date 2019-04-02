import Foundation
import WordPressKit
import WordPressFlux

/// SessionManager is responsible for defining the current session for the
/// current account.  It serves to decouple the API and Store layers.
///
class SessionManager {

    /// Singleon reference
    ///
    static let shared = SessionManager()

    /// A readonly reference to the api.
    /// The API is an anonymous API until initialzed with an Account
    ///
    private(set) var api = WordPressComRestApi(oAuthToken: nil, userAgent: UserAgent.defaultUserAgent)

    private var accountStoreSubscription: Receipt?

    private init() {
        let store = StoreContainer.shared.accountStore
        accountStoreSubscription = store.accountChangeDispatcher.subscribe(accountStoreChangeHandler(_:))
    }

    /// Initialize the session with the specified account.  Typically this will
    /// be the current account from the AccountStore
    ///
    /// - Parameter account: The account for the session. All api calls will be made
    /// on behalf of the account.
    ///
    @discardableResult
    func initialize(account: Account?) -> Bool {
        var token: String?
        if let account = account {
            let store = StoreContainer.shared.accountStore
            token = store.getAuthTokenForAccount(account)
        }
        api = WordPressComRestApi(oAuthToken: token, userAgent: UserAgent.defaultUserAgent)
        return token != nil
    }

    /// Handle changes broacast by the account store.  Primarily used to re-initialize
    /// the api in the event the current account changes.
    ///
    /// - Parameter accountChange: An AccountChange enum.
    ///
    func accountStoreChangeHandler(_ accountChange: AccountChange) {
        switch accountChange {
        case .currentAccountChanged:
            initialize(account: StoreContainer.shared.accountStore.currentAccount)
        default:
            break
        }
    }
}