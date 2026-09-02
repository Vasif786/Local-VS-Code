//
//  SimulatorManager.swift
//  Code
//
//  A floating "device simulator" window — a device-frame-styled WebView
//  showing a fixed, user-configurable URL. Independent of local vs. SSH
//  projects (it's just a web view in a frame), so it's available either
//  way from a single toolbar button.
//

import Foundation
import SwiftUI
import WebKit

enum SimulatorDeviceType: String, CaseIterable {
    case iPhone14Pro
    case iPadPro

    var displayName: String {
        switch self {
        case .iPhone14Pro: return "iPhone 14 Pro"
        case .iPadPro: return "iPad Pro"
        }
    }

    var sfSymbol: String {
        switch self {
        case .iPhone14Pro: return "iphone"
        case .iPadPro: return "ipad"
        }
    }

    /// Asset catalog name of the real device-frame image (see
    /// Assets.xcassets/SimulatorFrameiPhone14Pro.imageset and
    /// .../SimulatorFrameiPad.imageset).
    var frameImageName: String {
        switch self {
        case .iPhone14Pro: return "SimulatorFrameiPhone14Pro"
        case .iPadPro: return "SimulatorFrameiPad"
        }
    }

    /// The REAL device's own logical point resolution — what Safari on an
    /// actual device reports as its viewport (e.g. `window.innerWidth`).
    /// This is what the web view is built at, so pages get a genuine
    /// mobile viewport and render exactly as they would on a real device.
    /// (Previously this used the frame image's own pixel dimensions
    /// instead, which don't match any real device's viewport — that
    /// mismatch was the actual root cause of content looking too
    /// big/zoomed, regardless of on-screen scaling.)
    var portraitSize: CGSize {
        switch self {
        case .iPhone14Pro: return CGSize(width: 393, height: 852)
        case .iPadPro: return CGSize(width: 768, height: 1024)
        }
    }

    /// Where the real screen content goes inside the frame image, as a
    /// fraction of the frame's own width/height — measured directly from
    /// the transparent "screen hole" in the actual provided frame images
    /// (flood-filled from the center to find its exact bounding box), not
    /// guessed. These are fractions, so they apply correctly regardless of
    /// portraitSize being different from the image's own pixel dimensions.
    var screenInsets: (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        switch self {
        case .iPhone14Pro: return (0.0519, 0.0496, 0.0217, 0.0221)
        case .iPadPro: return (0.073, 0.090, 0.091, 0.108)
        }
    }
}

enum SimulatorOrientation {
    case portrait, landscape
}

/// One open simulator window's live state. A class (not a struct) so the
/// SwiftUI view holding a reference to it survives minimize/restore
/// without losing its identity — which is what keeps the WKWebView alive
/// (see SimulatorWindowView.swift) instead of reloading the page.
final class SimulatorWebViewStore {
    private(set) var webView: WKWebView?

    func makeIfNeeded(for window: SimulatorWindowState) -> WKWebView {
        if let webView { return webView }

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.isUserInteractionEnabled = true
        web.scrollView.isUserInteractionEnabled = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.minimumZoomScale = 1
        web.scrollView.maximumZoomScale = 1
        web.scrollView.zoomScale = 1
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: window.url))
        webView = web
        return web
    }

    func attach(to container: UIView, for window: SimulatorWindowState) -> WKWebView {
        let web = makeIfNeeded(for: window)
        if web.superview !== container {
            web.removeFromSuperview()
            container.addSubview(web)
        }
        return web
    }

    func load(_ url: URL, for window: SimulatorWindowState) {
        let web = makeIfNeeded(for: window)
        web.load(URLRequest(url: url))
    }
}

final class SimulatorWindowState: ObservableObject, Identifiable {
    let id: UUID
    let deviceType: SimulatorDeviceType
    let webViewStore = SimulatorWebViewStore()

    @Published var url: URL
    @Published var orientation: SimulatorOrientation = .portrait
    @Published var position: CGPoint
    /// Plain (non-@Published) scratch value the drag gesture uses as its
    /// baseline — deliberately not @Published, since it's write-only
    /// bookkeeping for the gesture and shouldn't trigger a view refresh by
    /// itself.
    var dragStartPosition: CGPoint = .zero
    @Published var displayScale: CGFloat
    @Published var isMinimized: Bool = false
    /// Bumped to request a reload; the web view's Coordinator watches this
    /// specifically so ordinary re-renders (drag, resize, orientation)
    /// never trigger an unwanted reload.
    @Published var reloadToken = UUID()

    init(deviceType: SimulatorDeviceType, url: URL, position: CGPoint, displayScale: CGFloat = 1.0) {
        self.id = UUID()
        self.deviceType = deviceType
        self.url = url
        self.position = position
        self.displayScale = displayScale
    }
}

final class SimulatorManager: ObservableObject {
    static let shared = SimulatorManager()
    private init() {
        for deviceType in SimulatorDeviceType.allCases {
            urlDrafts[deviceType] = savedURL(for: deviceType).absoluteString
        }
    }

    @Published var windows: [SimulatorWindowState] = []
    @Published var showDevicePicker: Bool = false
    @Published var previewWindowID: UUID? = nil
    /// Per-device draft text for the settings field, kept here (not per
    /// window) so it survives even before a window has been opened.
    @Published var urlDrafts: [SimulatorDeviceType: String] = [:]

    private static let defaultURL = URL(string: "https://example.com")!
    private static func defaultsKey(for deviceType: SimulatorDeviceType) -> String {
        "codeapp.simulator.url.\(deviceType.rawValue)"
    }

    func savedURL(for deviceType: SimulatorDeviceType) -> URL {
        if let saved = UserDefaults.standard.string(forKey: Self.defaultsKey(for: deviceType)),
            let url = URL(string: saved), url.scheme != nil
        {
            return url
        }
        return Self.defaultURL
    }

    /// Persists the URL (survives app relaunch) and, if a window for this
    /// device type is already open, updates and reloads it immediately.
    func saveURL(_ url: URL, for deviceType: SimulatorDeviceType) {
        UserDefaults.standard.set(url.absoluteString, forKey: Self.defaultsKey(for: deviceType))
        urlDrafts[deviceType] = url.absoluteString
        if let window = windows.first(where: { $0.deviceType == deviceType }) {
            window.url = url
            window.reloadToken = UUID()
        }
    }

    /// Opens a new window, or un-minimizes the existing one of the same
    /// device type instead of creating a duplicate — whatever was already
    /// loaded there keeps showing, nothing reloads.
    func open(deviceType: SimulatorDeviceType) {
        if let existing = windows.first(where: { $0.deviceType == deviceType }) {
            existing.isMinimized = false
            return
        }
        let offset = CGFloat(windows.count * 24)
        let window = SimulatorWindowState(
            deviceType: deviceType,
            url: savedURL(for: deviceType),
            position: CGPoint(x: 40 + offset, y: 60 + offset)
        )
        windows.append(window)
    }

    func close(_ window: SimulatorWindowState) {
        if previewWindowID == window.id { previewWindowID = nil }
        windows.removeAll { $0.id == window.id }
    }

    func openPreview(for window: SimulatorWindowState) {
        guard windows.contains(where: { $0.id == window.id }) else { return }
        previewWindowID = window.id
    }

    func closePreview() {
        previewWindowID = nil
    }
}
