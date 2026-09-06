//
//  SimulatorManager.swift
//  Code
//

import Foundation
import SwiftUI
import UIKit
import WebKit

// MARK: - Device

enum SimulatorDeviceType: String, CaseIterable, Identifiable {
    case iPhone14Pro
    case iPadPro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iPhone14Pro: return "iPhone 14 Pro"
        case .iPadPro: return "iPad (5th generation)"
        }
    }

    var sfSymbol: String {
        switch self {
        case .iPhone14Pro: return "iphone"
        case .iPadPro: return "ipad"
        }
    }

    var frameImageName: String {
        switch self {
        case .iPhone14Pro: return "SimulatorFrameiPhone14Pro"
        case .iPadPro: return "SimulatorFrameiPad"
        }
    }

    // The CSS/logical viewport of the simulated device.
    var viewportSize: CGSize {
        switch self {
        case .iPhone14Pro: return CGSize(width: 393, height: 852)
        case .iPadPro: return CGSize(width: 768, height: 1024)
        }
    }
}

enum SimulatorOrientation: String, CaseIterable {
    case portrait
    case landscape

    var title: String {
        self == .portrait ? "Portrait" : "Landscape"
    }
}


// MARK: - Persistent WebView store

/// Keeps one WKWebView per simulator window so moving between the framed
/// simulator and full-screen preview never reloads the page.
final class SimulatorWebViewStore {
    private(set) var webView: WKWebView?

    func makeIfNeeded(for window: SimulatorWindowState) -> WKWebView {
        if let webView { return webView }

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = true
        web.backgroundColor = .systemBackground
        web.scrollView.backgroundColor = .systemBackground
        web.isUserInteractionEnabled = true
        web.scrollView.isUserInteractionEnabled = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.minimumZoomScale = 1
        web.scrollView.maximumZoomScale = 1
        web.scrollView.zoomScale = 1
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: window.url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
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

    func reload(for window: SimulatorWindowState) {
        makeIfNeeded(for: window).load(URLRequest(url: window.url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }

    func setURL(_ url: URL, for window: SimulatorWindowState) {
        let web = makeIfNeeded(for: window)
        web.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
    }
}

// MARK: - Window state

final class SimulatorWindowState: ObservableObject, Identifiable {
    let id = UUID()
    let deviceType: SimulatorDeviceType
    let webViewStore = SimulatorWebViewStore()

    @Published var url: URL
    @Published var orientation: SimulatorOrientation = .portrait
    @Published var position: CGPoint
    @Published var displayScale: CGFloat
    @Published var isMoveMode = false
    @Published var isMinimized = false
    @Published var isFullPreview = false
    @Published var reloadToken = UUID()

    init(
        deviceType: SimulatorDeviceType,
        url: URL,
        position: CGPoint,
        displayScale: CGFloat = 0.62
    ) {
        self.deviceType = deviceType
        self.url = url
        self.position = position
        self.displayScale = displayScale
    }
}

// MARK: - Manager

final class SimulatorManager: ObservableObject {
    static let shared = SimulatorManager()

    private init() {
        for type in SimulatorDeviceType.allCases {
            urlDrafts[type] = savedURL(for: type).absoluteString
        }
    }

    @Published var windows: [SimulatorWindowState] = []
    @Published var showDevicePicker = false
    @Published var urlDrafts: [SimulatorDeviceType: String] = [:]
    @Published var previewWindowID: UUID? = nil

    private static let defaultURL = URL(string: "https://example.com")!

    private static func defaultsKey(for type: SimulatorDeviceType) -> String {
        "codeapp.simulator.url.\(type.rawValue)"
    }

    func savedURL(for type: SimulatorDeviceType) -> URL {
        if let value = UserDefaults.standard.string(forKey: Self.defaultsKey(for: type)),
           let url = URL(string: value),
           url.scheme != nil {
            return url
        }
        return Self.defaultURL
    }

    func saveURL(_ url: URL, for type: SimulatorDeviceType) {
        UserDefaults.standard.set(url.absoluteString, forKey: Self.defaultsKey(for: type))
        urlDrafts[type] = url.absoluteString

        if let window = windows.first(where: { $0.deviceType == type }) {
            window.url = url
            window.reloadToken = UUID()
            window.webViewStore.setURL(url, for: window)
        }
    }

    func open(deviceType: SimulatorDeviceType) {
        if let existing = windows.first(where: { $0.deviceType == deviceType }) {
            existing.isMoveMode = false
            return
        }

        let offset = CGFloat(windows.count * 24)
        windows.append(
            SimulatorWindowState(
                deviceType: deviceType,
                url: savedURL(for: deviceType),
                position: CGPoint(x: 30 + offset, y: 50 + offset)
            )
        )
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

    /// Sends the single `r` key to Code App's currently active terminal.
    /// Flutter's running tool interprets this as hot reload. The terminal
    /// itself remains untouched; this is just the same input path used by
    /// its on-screen keyboard.
    func sendFlutterHotReload() {
        NotificationCenter.default.post(
            name: .codeAppSimulatorFlutterHotReload, object: nil)
    }
}

extension Notification.Name {
    static let codeAppSimulatorFlutterHotReload = Notification.Name(
        "codeapp.simulator.flutterHotReload")
}

// MARK: - Frame layout

/// Frame geometry is calculated once and then cached. The old implementation
/// flood-filled millions of pixels every SwiftUI update; during a drag that
/// made the entire editor appear frozen. This cache removes that bottleneck.
enum SimulatorLayout {
    struct FrameInfo {
        let imageSize: CGSize
        let screenRect: CGRect
    }

    private static let cache = FrameInfoCache()

    static func frameInfo(for type: SimulatorDeviceType) -> FrameInfo {
        cache.info(for: type)
    }

    static func portraitFrameSize(for window: SimulatorWindowState) -> CGSize {
        let info = frameInfo(for: window.deviceType)
        let baseHeight: CGFloat = 620
        let baseWidth = baseHeight * info.imageSize.width / info.imageSize.height
        let scaled = CGSize(width: baseWidth, height: baseHeight)
        return CGSize(width: scaled.width * window.displayScale,
                      height: scaled.height * window.displayScale)
    }

    static func frameSize(for window: SimulatorWindowState) -> CGSize {
        let portrait = portraitFrameSize(for: window)
        return window.orientation == .portrait
            ? portrait
            : CGSize(width: portrait.height, height: portrait.width)
    }

    static func portraitScreenRect(for window: SimulatorWindowState) -> CGRect {
        let info = frameInfo(for: window.deviceType)
        let baseHeight: CGFloat = 620
        let factor = baseHeight / info.imageSize.height
        let scale = factor * window.displayScale
        return CGRect(
            x: info.screenRect.minX * scale,
            y: info.screenRect.minY * scale,
            width: info.screenRect.width * scale,
            height: info.screenRect.height * scale
        )
    }

    static func screenRect(for window: SimulatorWindowState) -> CGRect {
        let portrait = portraitScreenRect(for: window)
        guard window.orientation == .landscape else { return portrait }

        let portraitFrame = portraitFrameSize(for: window)
        // The frame artwork is rotated -90 degrees around its centre.
        // Convert the portrait screen-hole coordinates into that rotated
        // coordinate system so the WKWebView remains exactly inside the hole.
        return CGRect(
            x: portrait.minY,
            y: portraitFrame.width - portrait.maxX,
            width: portrait.height,
            height: portrait.width
        )
    }

    private final class FrameInfoCache {
        private let lock = NSLock()
        private var values: [SimulatorDeviceType: FrameInfo] = [:]

        func info(for type: SimulatorDeviceType) -> FrameInfo {
            lock.lock()
            if let value = values[type] {
                lock.unlock()
                return value
            }
            lock.unlock()

            let value = makeInfo(for: type)

            lock.lock()
            values[type] = value
            lock.unlock()
            return value
        }

        private func makeInfo(for type: SimulatorDeviceType) -> FrameInfo {
            guard let image = UIImage(named: type.frameImageName),
                  let cgImage = image.cgImage else {
                return fallbackInfo(for: type)
            }

            let width = CGFloat(cgImage.width)
            let height = CGFloat(cgImage.height)

            // The supplied iPhone 14 Pro frame has an exact transparent screen
            // area of x=68, y=58, width=1179, height=2556 in its 1311x2672 PNG.
            // Using those coordinates avoids an expensive pixel scan on every
            // SwiftUI update and exactly matches the supplied frame asset.
            if type == .iPhone14Pro, width == 1311, height == 2672 {
                return FrameInfo(
                    imageSize: CGSize(width: width, height: height),
                    screenRect: CGRect(x: 68, y: 58, width: 1179, height: 2556)
                )
            }

            // Other supplied frame assets are detected only once and cached.
            let screen = transparentScreenRect(cgImage: cgImage)
            return FrameInfo(
                imageSize: CGSize(width: width, height: height),
                screenRect: screen
            )
        }

        private func fallbackInfo(for type: SimulatorDeviceType) -> FrameInfo {
            switch type {
            case .iPhone14Pro:
                return FrameInfo(
                    imageSize: CGSize(width: 1311, height: 2672),
                    screenRect: CGRect(x: 68, y: 58, width: 1179, height: 2556)
                )
            case .iPadPro:
                // Exact geometry of the bundled 708x1020 iPad frame. The
                // transparent display opening is 593x818 at (52,93). Keeping
                // this exact rect avoids the old 5% fallback which left visible
                // gaps above/below the simulated screen.
                let size = CGSize(width: 708, height: 1020)
                return FrameInfo(
                    imageSize: size,
                    screenRect: CGRect(x: 52, y: 93, width: 593, height: 818)
                )
            }
        }

        private func transparentScreenRect(cgImage: CGImage) -> CGRect {
            let width = cgImage.width
            let height = cgImage.height
            let bytesPerPixel = 4
            let bytesPerRow = width * bytesPerPixel
            var data = [UInt8](repeating: 0, count: height * bytesPerRow)

            guard let context = CGContext(
                data: &data,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return CGRect(x: 0, y: 0, width: width, height: height)
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            let centerX = min(max(width / 2, 0), width - 1)
            let centerY = min(max(height / 2, 0), height - 1)
            let start = Int(centerY) * bytesPerRow + Int(centerX) * bytesPerPixel
            let centerAlpha = data[start + 3]

            // If the centre isn't transparent, use the viewport-sized fallback.
            guard centerAlpha < 128 else {
                let insetX = CGFloat(width) * 0.05
                let insetY = CGFloat(height) * 0.05
                return CGRect(
                    x: insetX,
                    y: insetY,
                    width: CGFloat(width) - insetX * 2,
                    height: CGFloat(height) - insetY * 2
                )
            }

            var queue = [(Int, Int)]()
            queue.reserveCapacity(min(width * height / 4, 1_000_000))
            queue.append((Int(centerY), Int(centerX)))

            var visited = [UInt8](repeating: 0, count: width * height)
            visited[Int(centerY) * width + Int(centerX)] = 1

            var minX = width
            var minY = height
            var maxX = 0
            var maxY = 0
            var index = 0

            while index < queue.count {
                let (y, x) = queue[index]
                index += 1

                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)

                let neighbors = ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1))
                for (ny, nx) in [neighbors.0, neighbors.1, neighbors.2, neighbors.3] {
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let vi = ny * width + nx
                    guard visited[vi] == 0 else { continue }
                    let alpha = data[ny * bytesPerRow + nx * bytesPerPixel + 3]
                    guard alpha < 128 else { continue }
                    visited[vi] = 1
                    queue.append((ny, nx))
                }
            }

            return CGRect(
                x: CGFloat(minX),
                y: CGFloat(minY),
                width: CGFloat(maxX - minX + 1),
                height: CGFloat(maxY - minY + 1)
            )
        }
    }
}
