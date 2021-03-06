import Foundation
import UIKit

class MainStoryboard {

    enum Identifier: String {
        typealias RawValue = String
        case initial = "InitialViewController"
        case siteMenu = "SiteMenuViewController"
        case postList = "PostListViewController"
        case editor = "EditorViewController"
        case mediaDetail = "MediaDetailViewController"
    }

    static func instantiateViewController(withIdentifier identifier: Identifier) -> UIViewController {
        return UIStoryboard.init(name: "Main", bundle: nil).instantiateViewController(withIdentifier: identifier.rawValue)
    }
}
