//
//  WebView.swift
//  Animo3D
//
//  Used to embed web pages (such as the Sketchfab preview page).
//

import SwiftUI
import WebKit

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.backgroundColor = .clear
        webView.isOpaque = false
        // Allow inline video playback, which helps in some 3D previews
        webView.configuration.allowsInlineMediaPlayback = true
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Only load when the target actually changes - updateUIView runs on every
        // SwiftUI update, and reloading each time restarted the embed mid-view.
        guard uiView.url != url, !uiView.isLoading else { return }
        uiView.load(URLRequest(url: url))
    }
}
