//
// SimulatorManager.swift
// CodeApp
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

    // Real logical viewport used by the web page.
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

// MARK: - Persistent WebView

/// One WKWebView belongs to one simulator for its whole lifetime. The same
/// object is moved between the normal simulator and Full Preview, so preview
/// never starts a second page or refreshes the current page.
final class SimulatorWebViewStore {
    private(set) var webView: WKWebView?

    func makeIfNeeded() -> WKWebView {
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

        webView = web
        return web
    }

    func attach(to canvas: UIView) -> WKWebView {
        let web = makeIfNeeded()
        if web.superview !== canvas {
            web.removeFromSuperview()
            canvas.addSubview(web)
        }
        return web
    }

    func load(_ url: URL) {
        let web = makeIfNeeded()
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
    @Published var reloadToken = UUID()

    init(deviceType: SimulatorDeviceType, url: URL, position: CGPoint, displayScale: CGFloat = 0.62) {
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

    private static let defaultURL = URL(string: "https://example.com")!

    private static func defaultsKey(for type: SimulatorDeviceType) -> String {
        "codeapp.simulator.url.\(type.rawValue)"
    }

    func savedURL(for type: SimulatorDeviceType) -> URL {
        if let value = UserDefaults.standard.string(forKey: Self.defaultsKey(for: type)),
           let url = URL(string: value), url.scheme != nil {
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
        }
    }

    func open(deviceType: SimulatorDeviceType) {
        if let existing = windows.first(where: { $0.deviceType == deviceType }) {
            existing.isMinimized = false
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
        windows.removeAll { $0.id == window.id }
    }
}

// MARK: - Layout

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
        return CGSize(width: baseWidth * window.displayScale,
                      height: baseHeight * window.displayScale)
    }

    static func frameSize(for window: SimulatorWindowState) -> CGSize {
        let p = portraitFrameSize(for: window)
        return window.orientation == .portrait ? p : CGSize(width: p.height, height: p.width)
    }

    static func portraitScreenRect(for window: SimulatorWindowState) -> CGRect {
        let info = frameInfo(for: window.deviceType)
        let baseHeight: CGFloat = 620
        let scale = baseHeight / info.imageSize.height * window.displayScale
        return CGRect(x: info.screenRect.minX * scale,
                      y: info.screenRect.minY * scale,
                      width: info.screenRect.width * scale,
                      height: info.screenRect.height * scale)
    }

    /// This is the V4 coordinate system: portrait screen-hole is converted to
    /// the coordinates of the -90° rotated frame. The WebView is then fitted
    /// inside this rectangle with its real device viewport, without any extra
    /// rotation of the web content.
    static func screenRect(for window: SimulatorWindowState) -> CGRect {
        let p = portraitScreenRect(for: window)
        guard window.orientation == .landscape else { return p }
        let portraitFrame = portraitFrameSize(for: window)
        return CGRect(x: p.minY,
                      y: portraitFrame.width - p.maxX,
                      width: p.height,
                      height: p.width)
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
            guard let image = UIImage(named: type.frameImageName), let cg = image.cgImage else {
                return fallbackInfo(for: type)
            }

            let w = CGFloat(cg.width)
            let h = CGFloat(cg.height)

            // Exact screen hole of the supplied iPhone 14 Pro asset.
            if type == .iPhone14Pro && cg.width == 1311 && cg.height == 2672 {
                return FrameInfo(imageSize: CGSize(width: w, height: h),
                                 screenRect: CGRect(x: 68, y: 58, width: 1179, height: 2556))
            }

            return FrameInfo(imageSize: CGSize(width: w, height: h),
                             screenRect: detectScreenRect(cg))
        }

        private func fallbackInfo(for type: SimulatorDeviceType) -> FrameInfo {
            switch type {
            case .iPhone14Pro:
                return FrameInfo(imageSize: CGSize(width: 1311, height: 2672),
                                 screenRect: CGRect(x: 68, y: 58, width: 1179, height: 2556))
            case .iPadPro:
                // Used only if the iPad frame asset is unavailable.
                let size = CGSize(width: 1024, height: 1366)
                return FrameInfo(imageSize: size,
                                 screenRect: CGRect(x: 35, y: 40, width: 954, height: 1286))
            }
        }

        /// Runs only once per device type, never during dragging/resizing.
        private func detectScreenRect(_ cg: CGImage) -> CGRect {
            let width = cg.width
            let height = cg.height
            let bpp = 4
            let row = width * bpp
            var pixels = [UInt8](repeating: 0, count: height * row)

            guard let context = CGContext(data: &pixels,
                                           width: width,
                                           height: height,
                                           bitsPerComponent: 8,
                                           bytesPerRow: row,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return CGRect(x: 0, y: 0, width: width, height: height)
            }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

            // Sample the asset down to <= 900 pixels on its longest edge.
            let step = max(1, max(width, height) / 900)
            let sw = (width + step - 1) / step
            let sh = (height + step - 1) / step
            func transparent(_ x: Int, _ y: Int) -> Bool {
                let px = min(width - 1, x * step)
                let py = min(height - 1, y * step)
                return pixels[py * row + px * bpp + 3] < 32
            }

            let sx = sw / 2
            let sy = sh / 2
            guard transparent(sx, sy) else {
                let ix = CGFloat(width) * 0.05
                let iy = CGFloat(height) * 0.05
                return CGRect(x: ix, y: iy, width: CGFloat(width) - ix * 2, height: CGFloat(height) - iy * 2)
            }

            var visited = [Bool](repeating: false, count: sw * sh)
            var q: [(Int, Int)] = [(sx, sy)]
            visited[sy * sw + sx] = true
            var head = 0
            var minX = sx, maxX = sx, minY = sy, maxY = sy

            while head < q.count {
                let (x, y) = q[head]
                head += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < sw, ny >= 0, ny < sh else { continue }
                    let index = ny * sw + nx
                    guard !visited[index], transparent(nx, ny) else { continue }
                    visited[index] = true
                    q.append((nx, ny))
                }
            }

            return CGRect(x: CGFloat(minX * step),
                          y: CGFloat(minY * step),
                          width: CGFloat((maxX - minX + 1) * step),
                          height: CGFloat((maxY - minY + 1) * step))
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}
