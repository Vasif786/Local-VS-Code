import SwiftUI
import WebKit

struct IPhone13WebViewTest: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)

        webView.allowsBackForwardNavigationGestures = true

        webView.load(
            URLRequest(url: url)
        )

        return webView
    }

    func updateUIView(
        _ webView: WKWebView,
        context: Context
    ) {
        if webView.url != url {
            webView.load(
                URLRequest(url: url)
            )
        }
    }
}