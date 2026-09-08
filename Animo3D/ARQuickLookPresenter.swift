//
//  ARQuickLookPresenter.swift
//  Animo3D
//
//  Presents AR Quick Look (QLPreviewController) the native UIKit way.
//  It deliberately avoids SwiftUI's .fullScreenCover: the detail page is already a fullScreenCover,
//  and nesting another one often fails to appear on iOS 16. A UIKit modal stacks reliably.
//

import UIKit
import SwiftUI
import QuickLook

final class ARQuickLookPresenter: NSObject, QLPreviewControllerDataSource {
    static let shared = ARQuickLookPresenter()
    private var item: PreviewItem?   // Needs a strong reference: QLPreviewController's dataSource is weak

    /// A downloaded local USDZ -> lightweight in-app 3D preview, with an "AR" button that hands off
    /// to the system Quick Look for real-world placement.
    ///
    /// The AR button used to be hidden entirely below 4GB of RAM, which meant every 3GB device -
    /// an iPhone X, XR or 8, i.e. exactly the iOS 16 phones this build still supports - had no way
    /// to reach AR from the community feed at all. "AR does not show up" was that gate, not a
    /// failure.
    ///
    /// The gate was protecting against a real crash, but it was aimed at the wrong thing: what
    /// blows past the memory limit and reboots the phone is `USDZOpacityFixer`'s **re-export**,
    /// which loads the whole textured model and re-encodes it. That function already refuses to run
    /// below 4GB or above 20MB on its own - its comment even says slight translucency beats
    /// rebooting the phone - so the safe split is to always offer AR and let the fixer decide for
    /// itself whether to touch the file.
    func presentPreview(url: URL, title: String) {
        let onAR: (() -> Void)? = { [weak self] in
            // No-op on low-memory devices and large files; see USDZOpacityFixer.
            let display = USDZOpacityFixer.makeOpaqueIfNeeded(url)
            self?.present(url: display, title: title)
        }
        let host = UIHostingController(rootView:
            ModelPreviewView(url: url, title: title, onOpenAR: onAR))
        host.modalPresentationStyle = .fullScreen
        topViewController()?.present(host, animated: true)
    }

    /// A downloaded local USDZ -> full-screen native AR Quick Look.
    func present(url: URL, title: String?) {
        item = PreviewItem(url: url, title: title)
        let vc = QLPreviewController()
        vc.dataSource = self
        vc.modalPresentationStyle = .fullScreen
        topViewController()?.present(vc, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController,
                           previewItemAt index: Int) -> QLPreviewItem {
        item ?? PreviewItem(url: URL(fileURLWithPath: ""), title: nil)
    }

    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let key = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = key?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    /// Show the model name as the preview title instead of the cache file name (uid).
    final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(url: URL, title: String?) { previewItemURL = url; previewItemTitle = title }
    }
}
