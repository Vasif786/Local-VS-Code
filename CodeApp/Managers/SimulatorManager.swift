//
//  SimulatorManager.swift
//  Code
//

import Foundation
import SwiftUI
import UIKit

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

    /// CSS/logical viewport of the real device. This is NOT used as the
    /// visual frame size. The WebView keeps these bounds and is transformed
    /// only for display, so zooming the simulator doesn't change the page UI.
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

// MARK: - Window state

final class SimulatorWindowState: ObservableObject, Identifiable {
    let id = UUID()
    let deviceType: SimulatorDeviceType

    @Published var url: URL
    @Published var orientation: SimulatorOrientation = .portrait
    @Published var position: CGPoint
    @Published var displayScale: CGFloat
    @Published var isMoveMode = false
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
        windows.removeAll { $0.id == window.id }
    }
}

// MARK: - Layout

/// Layout deliberately uses the actual frame asset rather than guessing its
/// aspect ratio. The transparent area around the screen is detected from the
/// asset at runtime, which makes the WebView line up with the supplied frame.
enum SimulatorLayout {
    struct FrameInfo {
        let size: CGSize
        let screenRect: CGRect
    }

    static func frameInfo(for type: SimulatorDeviceType) -> FrameInfo {
        guard let image = UIImage(named: type.frameImageName),
              let cgImage = image.cgImage else {
            return fallbackInfo(for: type)
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let screen = transparentScreenRect(cgImage: cgImage)

        // UIImage may carry a scale. The normalized rect is what matters,
        // while the final visual size is chosen below.
        let normalized = CGRect(
            x: screen.minX / width,
            y: screen.minY / height,
            width: screen.width / width,
            height: screen.height / height
        )

        let baseHeight: CGFloat = type == .iPhone14Pro ? 620 : 620
        let visualHeight = baseHeight
        let visualWidth = visualHeight * (width / height)
        let visualScreen = CGRect(
            x: visualWidth * normalized.minX,
            y: visualHeight * normalized.minY,
            width: visualWidth * normalized.width,
            height: visualHeight * normalized.height
        )

        return FrameInfo(
            size: CGSize(width: visualWidth, height: visualHeight),
            screenRect: visualScreen
        )
    }

    static func portraitFrameSize(for window: SimulatorWindowState) -> CGSize {
        let base = frameInfo(for: window.deviceType).size
        return CGSize(width: base.width * window.displayScale,
                      height: base.height * window.displayScale)
    }

    static func frameSize(for window: SimulatorWindowState) -> CGSize {
        let portrait = portraitFrameSize(for: window)
        return window.orientation == .portrait
            ? portrait
            : CGSize(width: portrait.height, height: portrait.width)
    }

    static func portraitScreenRect(for window: SimulatorWindowState) -> CGRect {
        let base = frameInfo(for: window.deviceType)
        let scale = window.displayScale
        return CGRect(
            x: base.screenRect.minX * scale,
            y: base.screenRect.minY * scale,
            width: base.screenRect.width * scale,
            height: base.screenRect.height * scale
        )
    }

    static func screenRect(for window: SimulatorWindowState) -> CGRect {
        let p = portraitScreenRect(for: window)
        guard window.orientation == .landscape else { return p }

        let portrait = portraitFrameSize(for: window)
        // Coordinate conversion for a -90° rotated portrait frame.
        return CGRect(
            x: p.minY,
            y: portrait.width - p.maxX,
            width: p.height,
            height: p.width
        )
    }

    private static func fallbackInfo(for type: SimulatorDeviceType) -> FrameInfo {
        let height: CGFloat = 620
        let aspect = type == .iPhone14Pro ? (1311.0 / 2672.0) : (768.0 / 1024.0)
        let width = height * aspect
        let inset = type == .iPhone14Pro
            ? (0.052, 0.050, 0.022, 0.022)
            : (0.073, 0.090, 0.091, 0.108)
        return FrameInfo(
            size: CGSize(width: width, height: height),
            screenRect: CGRect(
                x: width * inset.0,
                y: height * inset.2,
                width: width * (1 - inset.0 - inset.1),
                height: height * (1 - inset.2 - inset.3)
            )
        )
    }

    /// Finds the transparent connected component containing the image centre.
    /// Device frame assets normally leave the screen itself transparent, while
    /// the bezel remains opaque. This avoids hard-coded pixel offsets.
    private static func transparentScreenRect(cgImage: CGImage) -> CGRect {
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

        let sx = min(width - 1, max(0, width / 2))
        let sy = min(height - 1, max(0, height / 2))
        let start = sy * bytesPerRow + sx * bytesPerPixel
        let startAlpha = data[start + 3]

        // If centre isn't transparent, use the alpha-0 component nearest the
        // centre by scanning a small grid first, then fall back to full image.
        var seedX = sx
        var seedY = sy
        if startAlpha > 8 {
            var found = false
            for radius in stride(from: 1, through: min(width, height) / 3, by: 2) where !found {
                let candidates = [
                    (sx, max(0, sy - radius)),
                    (sx, min(height - 1, sy + radius)),
                    (max(0, sx - radius), sy),
                    (min(width - 1, sx + radius), sy)
                ]
                for (x, y) in candidates {
                    if data[y * bytesPerRow + x * bytesPerPixel + 3] <= 8 {
                        seedX = x; seedY = y; found = true; break
                    }
                }
            }
            if !found {
                return CGRect(x: 0, y: 0, width: width, height: height)
            }
        }

        // Flood fill can be expensive for a huge asset, so sample at most
        // 1/2 resolution. This is more than enough for a frame inset.
        let step = max(1, Int(max(width, height) / 900))
        let sw = (width + step - 1) / step
        let sh = (height + step - 1) / step
        var visited = [UInt8](repeating: 0, count: sw * sh)
        func alphaAt(_ x: Int, _ y: Int) -> UInt8 {
            data[y * bytesPerRow + x * bytesPerPixel + 3]
        }
        func transparent(_ x: Int, _ y: Int) -> Bool {
            alphaAt(min(width - 1, x * step), min(height - 1, y * step)) <= 8
        }

        let qx = min(sw - 1, max(0, seedX / step))
        let qy = min(sh - 1, max(0, seedY / step))
        guard transparent(qx, qy) else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }

        var queueX = [Int](); queueX.reserveCapacity(sw * sh / 2)
        var queueY = [Int](); queueY.reserveCapacity(sw * sh / 2)
        queueX.append(qx); queueY.append(qy)
        visited[qy * sw + qx] = 1

        var minX = qx, maxX = qx, minY = qy, maxY = qy
        var head = 0
        let dirs = [(1,0),(-1,0),(0,1),(0,-1)]
        while head < queueX.count {
            let x = queueX[head]
            let y = queueY[head]
            head += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            for (dx,dy) in dirs {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < sw, ny >= 0, ny < sh else { continue }
                let idx = ny * sw + nx
                guard visited[idx] == 0, transparent(nx, ny) else { continue }
                visited[idx] = 1
                queueX.append(nx); queueY.append(ny)
            }
        }

        return CGRect(
            x: CGFloat(minX * step),
            y: CGFloat(minY * step),
            width: CGFloat((maxX - minX + 1) * step),
            height: CGFloat((maxY - minY + 1) * step)
        ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
}
