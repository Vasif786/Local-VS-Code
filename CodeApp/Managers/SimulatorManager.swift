//
//  SimulatorManager.swift
//  Code
//

import Foundation
import SwiftUI

enum SimulatorDeviceType: String, CaseIterable, Identifiable {
    case iPhone14Pro
    case iPadPro

    var id: String { rawValue }

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

    var frameImageName: String {
        switch self {
        case .iPhone14Pro: return "SimulatorFrameiPhone14Pro"
        case .iPadPro: return "SimulatorFrameiPad"
        }
    }

    // CSS/layout viewport used by the simulator.
    var viewportSize: CGSize {
        switch self {
        case .iPhone14Pro: return CGSize(width: 393, height: 852)
        case .iPadPro: return CGSize(width: 1024, height: 1366)
        }
    }

    // Aspect ratio of the device-frame PNG.
    // iPhone value matches the supplied 1311 x 2672 frame.
    var frameAspectRatio: CGFloat {
        switch self {
        case .iPhone14Pro: return 1311.0 / 2672.0
        case .iPadPro: return 2048.0 / 2732.0
        }
    }

    // Screen-hole inset as a fraction of the frame image.
    // These values are for the supplied frame assets.
    var screenInsets: (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        switch self {
        case .iPhone14Pro:
            return (0.0519, 0.0496, 0.0217, 0.0221)
        case .iPadPro:
            return (0.073, 0.090, 0.091, 0.108)
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

enum SimulatorPositionPreset: String, CaseIterable, Identifiable {
    case topLeft, topRight, center, bottomLeft, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .center: return "Center"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

final class SimulatorWindowState: ObservableObject, Identifiable {
    let id = UUID()
    let deviceType: SimulatorDeviceType

    @Published var url: URL
    @Published var orientation: SimulatorOrientation = .portrait
    @Published var position: CGPoint
    @Published var displayScale: CGFloat
    @Published var isMinimized = false
    @Published var reloadToken = UUID()

    init(
        deviceType: SimulatorDeviceType,
        url: URL,
        position: CGPoint,
        displayScale: CGFloat = 0.70
    ) {
        self.deviceType = deviceType
        self.url = url
        self.position = position
        self.displayScale = displayScale
    }
}

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
            existing.isMinimized = false
            return
        }

        let offset = CGFloat(windows.count * 24)
        let window = SimulatorWindowState(
            deviceType: deviceType,
            url: savedURL(for: deviceType),
            position: CGPoint(x: 30 + offset, y: 50 + offset)
        )
        windows.append(window)
    }

    func close(_ window: SimulatorWindowState) {
        windows.removeAll { $0.id == window.id }
    }

    func setPosition(_ preset: SimulatorPositionPreset, for window: SimulatorWindowState, in size: CGSize) {
        let frame = SimulatorLayout.frameSize(for: window)
        let margin: CGFloat = 24

        let x: CGFloat
        let y: CGFloat

        switch preset {
        case .topLeft:
            x = margin
            y = margin
        case .topRight:
            x = max(margin, size.width - frame.width - margin)
            y = margin
        case .center:
            x = max(margin, (size.width - frame.width) / 2)
            y = max(margin, (size.height - frame.height) / 2)
        case .bottomLeft:
            x = margin
            y = max(margin, size.height - frame.height - margin)
        case .bottomRight:
            x = max(margin, size.width - frame.width - margin)
            y = max(margin, size.height - frame.height - margin)
        }

        window.position = CGPoint(x: x, y: y)
    }
}

enum SimulatorLayout {
    static func orientedViewport(_ window: SimulatorWindowState) -> CGSize {
        let size = window.deviceType.viewportSize
        if window.orientation == .landscape {
            return CGSize(width: size.height, height: size.width)
        }
        return size
    }

    static func frameSize(for window: SimulatorWindowState) -> CGSize {
        let viewport = orientedViewport(window)
        let aspect = window.deviceType.frameAspectRatio
        let height = viewport.height * window.displayScale
        let width = height * aspect
        return CGSize(width: width, height: height)
    }

    static func screenRect(for window: SimulatorWindowState) -> CGRect {
        let frame = frameSize(for: window)
        let insets = window.deviceType.screenInsets

        let portraitInsets = (
            left: frame.width * insets.left,
            right: frame.width * insets.right,
            top: frame.height * insets.top,
            bottom: frame.height * insets.bottom
        )

        if window.orientation == .portrait {
            return CGRect(
                x: portraitInsets.left,
                y: portraitInsets.top,
                width: max(1, frame.width - portraitInsets.left - portraitInsets.right),
                height: max(1, frame.height - portraitInsets.top - portraitInsets.bottom)
            )
        }

        // The frame rotates -90 degrees. Remap the hole accordingly.
        return CGRect(
            x: portraitInsets.top,
            y: portraitInsets.right,
            width: max(1, frame.width - portraitInsets.top - portraitInsets.bottom),
            height: max(1, frame.height - portraitInsets.right - portraitInsets.left)
        )
    }
}
