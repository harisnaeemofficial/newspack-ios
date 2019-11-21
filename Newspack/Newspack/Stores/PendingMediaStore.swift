import Foundation
import CoreImage
import MobileCoreServices
import Photos
import WordPressFlux

enum WriteError: Error {
    case unableToWrite
}

class PendingMediaStore: Store {

    private class Constants {
        static let stagedMediaFolderName = "StagedMedia"
        static let utiHEIC = "public.heic"
        static let utiJPG = kUTTypeJPEG as String
        static let utiPNG = kUTTypePDF as String
        static let utiGIF = kUTTypeGIF as String
        static let utiLivePhoto = kUTTypeLivePhoto as String
        static let iptcDictionaryKey = kCGImagePropertyIPTCDictionary as String
        static let tiffDictionaryKey = kCGImagePropertyTIFFDictionary as String
        static let gpsDictionaryKey = kCGImagePropertyGPSDictionary as String
        static let iptcOrientationKey = kCGImagePropertyIPTCImageOrientation as String
        static let tiffOrientationKey = kCGImagePropertyTIFFOrientation as String
        static let jpgExt = ".jpg"
        static let pngExt = ".png"
        static let heicExt = ".heic"
    }

    private(set) var currentSiteID: UUID?

    init(dispatcher: ActionDispatcher = .global, siteID: UUID? = nil) {
        currentSiteID = siteID
    }

    /// Action handler
    ///
    override func onDispatch(_ action: Action) {
        if let action = action as? PendingMediaAction {
            switch action {
            case .enqueueMedia(let assetIdentifier):
                enqueueAsset(identifier: assetIdentifier)
            }
        }
    }

}

extension PendingMediaStore {

    /// Creates a new StagedMedia instance for the specified PHAsset.identifier.
    /// - Parameter identifier: A string representing a PHAsset.identifier
    ///
    func enqueueAsset(identifier: String) {
        if let _ = getPendingMedia(assetIdentifier: identifier) {
            LogWarn(message: "enqueueAsset: Attempted to enque and already enqueued asset.")
            return
        }

        guard
            let siteID = currentSiteID,
            let siteObjID = StoreContainer.shared.siteStore.getSiteByUUID(siteID)?.objectID
        else {
            LogError(message: "handleMediaFetchedAction: A value was unexpectedly nil.")
            return
        }

        CoreDataManager.shared.performOnWriteContext { (context) in
            let site = context.object(with: siteObjID) as! Site
            let stagedMedia = StagedMedia(context: context)

            stagedMedia.uuid = UUID()
            stagedMedia.assetIdentifier = identifier
            stagedMedia.site = site

            CoreDataManager.shared.saveContext(context: context)
        }
    }

    /// Get a StagedMedia instance by its asset identifier.
    /// - Parameter assetIdentifier: A string. Expected to be a PHAsset.identifier.
    ///
    func getPendingMedia(assetIdentifier: String) -> StagedMedia? {
        guard
            let siteID = currentSiteID,
            let site = StoreContainer.shared.siteStore.getSiteByUUID(siteID)
        else {
            LogError(message: "getPendingMedia: could not retrieve current site.")
            return nil
        }

        let request = StagedMedia.defaultFetchRequest()
        request.predicate = NSPredicate(format: "assetIdentifier == %@ AND site == %@", assetIdentifier, site)

        let context = CoreDataManager.shared.mainContext
        do {
            if let stagedMedia = try context.fetch(request).first {
                return stagedMedia
            }
        } catch {
            // TODO: Handle Error.
            let error = error as NSError
            LogError(message: "getPendingMedia: " + error.localizedDescription)
        }
        return nil
    }
}


// MARK: - Asset Management
extension PendingMediaStore {

    /// Delete any files staged for upload.
    ///
    func purgeStagedMediaFiles() {
        guard let path = directoryPath() else {
            return
        }
        let fileManager = FileManager()
        if fileManager.fileExists(atPath: path.absoluteString) {
            try? fileManager.removeItem(at: path)
        }
    }

    /// Fetch a PHAsset by its localIdentifier.
    /// - Parameter identifier: An asset's localIdentifier.
    ///
    func fetchAssetByIdentifier(identifier: String) -> PHAsset? {
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    /// Imports an PHAsset to a local folder for uploading.
    /// - Parameter asset: A PHAsset instance.
    /// - Parameter onComplete: A completion handler called when the import is complete.
    ///
    func importAsset(asset: PHAsset, onComplete: @escaping ((PHAsset, URL?, String?, Error?) -> Void)) {
        // TODO: Need to segment on mediaType. For now, assume image.

        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true

        asset.requestContentEditingInput(with: options) { (contentEditingInput, info) in
            guard let contentEditingInput = contentEditingInput else {
                onComplete(asset, nil, nil, nil)
                return
            }

            do {
                let originalFileName = contentEditingInput.fullSizeImageURL?.pathComponents.last
                let fileURL = try self.copyAssetToFile(asset: asset, contentEditingInput: contentEditingInput)
                onComplete(asset, fileURL, originalFileName, nil)
            } catch {
                onComplete(asset, nil, nil, error)
            }
        }
    }

    /// Removes GPS data.
    /// Fixes or removes orientation flags
    /// - Parameter metaData: Dictionary of image meta data.
    ///
    func sanitizeImageMetaData(metaData: [String: Any]) -> [String: Any] {
        var properties = metaData
        // Remove GPS data
        properties.removeValue(forKey: Constants.gpsDictionaryKey)

        // Remove Orientation data
        if var tiffProps = properties[Constants.tiffDictionaryKey] as? [String: Any] {
            tiffProps.removeValue(forKey: Constants.tiffOrientationKey)
            properties[Constants.tiffDictionaryKey] = tiffProps
        }

        if var iptcProps = properties[Constants.iptcDictionaryKey] as? [String: Any] {
            iptcProps.removeValue(forKey: Constants.iptcOrientationKey)
            properties[Constants.iptcDictionaryKey] = iptcProps
        }

        return properties
    }

    /// Returns a new, prepared, instance of the supplied CIImage instance.
    /// - Parameter image: The image to sanitize.
    ///
    func prepareImage(image: CIImage) -> CIImage {
        let properties = sanitizeImageMetaData(metaData: image.properties)
        return image.settingProperties(properties)
    }

    /// A file URL to the upload directory.  Creates the directory if it doesn't exist.
    ///
    func directoryPath() -> URL? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directoryPath = documentDirectory.appendingPathComponent(Constants.stagedMediaFolderName, isDirectory: true)
        if !fileManager.fileExists(atPath: directoryPath.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            do {
                try fileManager.createDirectory(at: directoryPath, withIntermediateDirectories: true, attributes: nil)
            } catch {
                // TODO:
                return nil
            }
        }

        return directoryPath
    }

    /// Copy the file backing a PHAsset to a local directory in preparation for uploading.
    /// - Parameter asset: A PHAsset instance.  An image is expected.
    /// - Parameter contentEditingInput: A PHContentEditingInput instance
    ///
    func copyAssetToFile(asset: PHAsset, contentEditingInput: PHContentEditingInput) throws -> URL? {
        guard
            let directoryPath = directoryPath(),
            let originalFileURL = contentEditingInput.fullSizeImageURL,
            let originalImage = CIImage(contentsOf: originalFileURL),
            let uti = contentEditingInput.uniformTypeIdentifier
        else {
            throw WriteError.unableToWrite
        }

        let image = prepareImage(image: originalImage)
        let fileURL = directoryPath.appendingPathExtension(UUID().uuidString)

        try writeImage(image: image, withUTI: uti, toFile: fileURL)

        return fileURL
    }

    /// Create a new image file from the provided CIImage at the specified location.
    /// - Parameter image: A CIImage instance
    /// - Parameter uti: The universal type identifier for the image.
    /// - Parameter fileURL: The location to save the file.
    ///
    func writeImage(image: CIImage, withUTI uti: String, toFile fileURL: URL) throws {
        if uti == Constants.utiJPG {
            try writeJPGImage(image: image, toFile: fileURL)

        } else if uti == Constants.utiPNG {
            try writePNGImage(image: image, fileURL: fileURL)

        } else if uti == Constants.utiLivePhoto {
            // Needs special handling. TBD

        } else if uti == Constants.utiGIF {
            // Needs special handling. TBD

        } else if uti == Constants.utiHEIC {
            try writeHEICImage(image: image, fileURL: fileURL)

        } else {
            // Treat as JPG
            try writeJPGImage(image: image, toFile: fileURL)
        }
    }

    /// Create an JPG image.
    /// - Parameter image: A CIImage instance
    /// - Parameter fileURL: The location to save the file.
    ///
    func writeJPGImage(image: CIImage, toFile fileURL: URL) throws {
        let context = CIContext()
        let options = [CIImageRepresentationOption: Any]()

        try context.writeJPEGRepresentation(of: image,
                                            to: fileURL.appendingPathExtension(Constants.jpgExt),
                                            colorSpace: image.colorSpace!,
                                            options: options)
    }

    /// Create an PNG image.
    /// - Parameter image: A CIImage instance
    /// - Parameter fileURL: The location to save the file.
    ///
    func writePNGImage(image: CIImage, fileURL: URL) throws {
        let context = CIContext()
        let options = [CIImageRepresentationOption: Any]()

        try context.writePNGRepresentation(of: image,
                                           to: fileURL.appendingPathExtension(Constants.pngExt),
                                           format: CIFormat.RGBA8,
                                           colorSpace: image.colorSpace!,
                                           options: options)
    }

    /// Create an HEIF image.
    /// - Parameter image: A CIImage instance
    /// - Parameter fileURL: The location to save the file.
    ///
    func writeHEICImage(image: CIImage, fileURL: URL) throws {
        let context = CIContext()
        let options = [CIImageRepresentationOption: Any]()

        try context.writeHEIFRepresentation(of: image,
                                            to: fileURL.appendingPathExtension(Constants.heicExt),
                                            format: CIFormat.RGBA8,
                                            colorSpace: context.workingColorSpace!,
                                            options: options)
    }

}