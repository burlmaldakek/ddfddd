import Foundation
import UIKit

/// Read-only Swift facade for the Objective-C CoreUI bridge.
/// CoreUI objects are created, accessed, and released on its serial queue.
final class CARAssetCatalogSession: @unchecked Sendable {
    private let bridge: ErosionCARCatalog
    let assetNames: [String]

    init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CARAssetCatalogError.fileMissing
        }

        // The Objective-C initializer is imported as failable because the
        // bridging header does not provide a nonnull guarantee for init.
        // Unwrap it explicitly instead of assuming construction always works.
        guard let openedBridge = ErosionCARCatalog(url: url) else {
            throw CARAssetCatalogError.catalogFailure(
                "CoreUI could not initialize the asset catalog."
            )
        }

        if let error = openedBridge.openError {
            throw CARAssetCatalogError.catalogFailure(error.localizedDescription)
        }

        // The Objective-C property is imported as optional by Swift because
        // the implementation does not guarantee a nonnull value at the ABI
        // boundary. Treat a missing list as an empty catalog, without force
        // unwrapping an Objective-C object returned by a private API.
        guard let names = openedBridge.assetNames else {
            throw CARAssetCatalogError.catalogFailure(
                "CoreUI did not return an asset-name list."
            )
        }
        guard !names.isEmpty else {
            throw CARAssetCatalogError.noImageAssets
        }

        bridge = openedBridge
        assetNames = names
    }

    func image(named name: String) -> UIImage? {
        bridge.imageNamed(name)
    }

    func thumbnail(named name: String, maximumPixelSize: Int = 144) -> UIImage? {
        bridge.thumbnailNamed(name, maximumPixelSize: maximumPixelSize)
    }
}

enum CARAssetCatalogError: LocalizedError, Sendable {
    case fileMissing
    case noImageAssets
    case catalogFailure(String)

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "The .car file no longer exists."
        case .noImageAssets:
            return "No image assets were found in this catalog."
        case .catalogFailure(let message):
            return message
        }
    }
}
