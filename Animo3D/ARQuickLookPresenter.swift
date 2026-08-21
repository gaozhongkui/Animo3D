//
//  ARQuickLookPresenter.swift
//  Animo3D
//
//  用 UIKit 原生方式弹出 AR Quick Look（QLPreviewController）。
//  不走 SwiftUI 的 .fullScreenCover：详情页本身已是 fullScreenCover，
//  再嵌套一层在 iOS 16 上经常弹不出来。UIKit modal 可以稳定叠加。
//

import UIKit
import SwiftUI
import QuickLook

final class ARQuickLookPresenter: NSObject, QLPreviewControllerDataSource {
    static let shared = ARQuickLookPresenter()
    private var item: PreviewItem?   // 需强引用：QLPreviewController 的 dataSource 是 weak

    /// 下载好的本地 USDZ → App 内轻量 3D 预览（运行时不透明、低内存）。
    /// 高内存设备(4GB+)在预览里额外提供「AR」按钮跳系统 Quick Look 做实景放置；
    /// 低内存设备(如 iPhone X 3GB)不提供 AR，避免重模型 + AR 顶爆内存导致设备重启。
    func presentPreview(url: URL, title: String) {
        let ram = ProcessInfo.processInfo.physicalMemory
        let onAR: (() -> Void)? = ram >= 4_000_000_000 ? { [weak self] in
            let display = USDZOpacityFixer.makeOpaqueIfNeeded(url)   // 高内存设备才重导出
            self?.present(url: display, title: title)
        } : nil
        let host = UIHostingController(rootView:
            ModelPreviewView(url: url, title: title, onOpenAR: onAR))
        host.modalPresentationStyle = .fullScreen
        topViewController()?.present(host, animated: true)
    }

    /// 下载好的本地 USDZ → 全屏原生 AR Quick Look。
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

    /// 让预览标题显示模型名，而不是缓存文件名（uid）。
    final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(url: URL, title: String?) { previewItemURL = url; previewItemTitle = title }
    }
}
