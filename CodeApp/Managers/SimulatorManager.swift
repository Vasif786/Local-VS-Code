//
//  SimulatorManager.swift
//  Code
//

import Foundation
import SwiftUI

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

    /// Real CSS/logical viewport used by the device.
    /// This stays FIXED while the on-screen simulator is zoomed.
    var viewportSize: CGSize {
        switch self {
        case .iPhone14Pro:
            return CGSize(width: 393, height: 852)
        case .iPadPro:
            // iPad 5th generation Safari viewport in portrait points.
            return CGSize(width: 768, height: 1024)
        }
    }

    /// The supplied frame image's aspect ratio.
    /// iPad uses the normal iPad portrait ratio as a fallback if its asset
    /// has a different physical resolution; the screen is still fitted to
    /// the same viewport aspect ratio.
    var frameAspectRatio: CGFloat {
        switch self {
        case .iPhone14Pro:
            return 1311.0 / 2672.0
        case .iPadPro:
            return 768.0 / 1024.0
        }
    }

    /// Screen-hole inset in the frame image.
    /// These are fractions of the portrait frame dimensions.
    var screenInsets: (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        switch self {
        case .iPhone14Pro:
            return (0.0519, 0.0496, 0.0217, 0.0221)
        case .iPadPro:
            // Matches the existing SimulatorFrameiPad asset used by CodeApp.
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
        displayScale: CGFloat = 0.70
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

/// All calculations are based on the PORTRAIT device. Landscape is produced
/// by rotating the complete device container. This avoids the old landscape
/// bug where the WebView and frame were using different coordinate systems.
enum SimulatorLayout {
    static func portraitFrameSize(for window: SimulatorWindowState) -> CGSize {
        let viewport = window.deviceType.viewportSize
        let frameAspect = window.deviceType.frameAspectRatio

        // The frame is scaled from the real viewport height. The viewport
        // itself remains logically fixed; only the visual device changes.
        let height = viewport.height * window.displayScale
        let width = height * frameAspect
        return CGSize(width: width, height: height)
    }

    static func frameSize(for window: SimulatorWindowState) -> CGSize {
        let portrait = portraitFrameSize(for: window)
        if window.orientation == .portrait {
            return portrait
        }
        return CGSize(width: portrait.height, height: portrait.width)
    }

    /// Screen hole in the portrait frame coordinate space.
    static func portraitScreenRect(for window: SimulatorWindowState) -> CGRect {
        let frame = portraitFrameSize(for: window)
        let inset = window.deviceType.screenInsets

        return CGRect(
            x: frame.width * inset.left,
            y: frame.height * inset.top,
            width: max(1, frame.width * (1 - inset.left - inset.right)),
            height: max(1, frame.height * (1 - inset.top - inset.bottom))
        )
    }

    /// Screen hole in the currently displayed orientation.
    static func screenRect(for window: SimulatorWindowState) -> CGRect {
        let portrait = portraitScreenRect(for: window)

        guard window.orientation == .landscape else {
            return portrait
        }

        // The whole portrait simulator rotates -90°. Convert the portrait
        // hole to the new landscape coordinate system.
        return CGRect(
            x: portrait.minY,
            y: portraitFrameSize(for: window).width - portrait.maxX,
            width: portrait.height,
            height: portrait.width
        )
    }
}
