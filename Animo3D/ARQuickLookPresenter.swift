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

    /// A downloaded local USDZ -> lightweight in-app 3D preview (opaque at runtime, low memory).
    /// High-memory devices (4GB+) additionally get an "AR" button in the preview that jumps to the system Quick Look for real-world placement;
    /// low-memory devices (such as the 3GB iPhone X) do not offer AR, so a heavy model plus AR cannot blow past the memory limit and reboot the device.
    func presentPreview(url: URL, title: String) {
        let ram = ProcessInfo.processInfo.physicalMemory
        let onAR: (() -> Void)? = ram >= 4_000_000_000 ? { [weak self] in
            let display = USDZOpacityFixer.makeOpaqueIfNeeded(url)   // Only high-memory devices re-export
            self?.present(url: display, title: title)
        } : nil
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
