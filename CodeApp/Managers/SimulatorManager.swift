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

enum SimulatorDeviceType: String, CaseIterable {
    case iPhone13Pro
    case iPadPro

    var displayName: String {
        switch self {
        case .iPhone13Pro: return "iPhone 13 Pro"
        case .iPadPro: return "iPad Pro"
        }
    }

    var sfSymbol: String {
        switch self {
        case .iPhone13Pro: return "iphone"
        case .iPadPro: return "ipad"
        }
    }

    /// Asset catalog name of the real device-frame image (see
    /// Assets.xcassets/SimulatorFrameiPhone.imageset and
    /// .../SimulatorFrameiPad.imageset).
    var frameImageName: String {
        switch self {
        case .iPhone13Pro: return "SimulatorFrameiPhone"
        case .iPadPro: return "SimulatorFrameiPad"
        }
    }

    /// The frame image's own pixel size, in portrait — used as the aspect
    /// ratio basis so the frame image is never stretched/distorted.
    var portraitSize: CGSize {
        switch self {
        case .iPhone13Pro: return CGSize(width: 536, height: 1008)
        case .iPadPro: return CGSize(width: 708, height: 1020)
        }
    }

    /// Where the real screen content goes inside the frame image, as a
    /// fraction of the frame's own width/height — measured directly from
    /// the transparent "screen hole" in the actual provided frame images
    /// (flood-filled from the center to find its exact bounding box), not
    /// guessed.
    var screenInsets: (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        switch self {
        case .iPhone13Pro: return (0.099, 0.103, 0.047, 0.054)
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
final class SimulatorWindowState: ObservableObject, Identifiable {
    let id: UUID
    let deviceType: SimulatorDeviceType

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

    init(deviceType: SimulatorDeviceType, url: URL, position: CGPoint, displayScale: CGFloat = 0.45) {
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
        windows.removeAll { $0.id == window.id }
    }
}
