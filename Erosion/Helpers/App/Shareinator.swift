//
//  Shareinator.swift
//  PartyUI
//
//  Created by lunginspector on 2/12/26.
//

import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
public func presentShareSheet(with url: URL) {
    presentShareActivity(items: [url])
}

/// Shares multiple staged files/folders in one activity sheet.
@MainActor
public func presentShareSheet(with urls: [URL]) {
    guard !urls.isEmpty else { return }
    presentShareActivity(items: urls)
}


/// Shares an in-memory file snapshot. No temporary file is created by Erosion.
@MainActor
public func presentShareSheet(with data: Data, fileName: String) {
    let fileExtension = URL(fileURLWithPath: fileName).pathExtension
    let typeIdentifier = (UTType(filenameExtension: fileExtension) ?? .data).identifier
    let provider = NSItemProvider(item: data as NSData, typeIdentifier: typeIdentifier)
    provider.suggestedName = fileName
    presentShareActivity(items: [provider])
}

@MainActor
private func presentShareActivity(items: [Any]) {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first,
          var topController = window.rootViewController else { return }

    while let presentedViewController = topController.presentedViewController {
        topController = presentedViewController
    }

    let activityViewController = UIActivityViewController(activityItems: items, applicationActivities: nil)
    if let popover = activityViewController.popoverPresentationController {
        let sourceView = topController.view!
        popover.sourceView = sourceView
        popover.sourceRect = CGRect(x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }
    topController.present(activityViewController, animated: true)
}
