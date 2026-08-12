//
//  WebView.swift
//  Animo3D
//
//  用于嵌入网页（如 Sketchfab 预览页）。
//

import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.backgroundColor = .clear
        webView.isOpaque = false
        // 允许内联播放视频，这在某些 3D 预览中很有用
        webView.configuration.allowsInlineMediaPlayback = true
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        uiView.load(request)
    }
}
