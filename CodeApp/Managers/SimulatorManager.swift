//
//  SimulatorManager.swift
//  Code
//

import Foundation
import SwiftUI

enum SimulatorDeviceType: String, CaseIterable, Hashable {
    case iPhone14Pro
    case iPadPro

    var displayName: String {
        switch self {
        case .iPhone14Pro:
            return "iPhone 14 Pro"
        case .iPadPro:
            return "iPad Pro"
        }
    }

    var sfSymbol: String {
        switch self {
        case .iPhone14Pro:
            return "iphone"
        case .iPadPro:
            return "ipad"
        }
    }

    var frameImageName: String {
        switch self {
        case .iPhone14Pro:
            return "SimulatorFrameiPhone14Pro"
        case .iPadPro:
            return "SimulatorFrameiPad"
        }
    }

    // IMPORTANT:
    // These are the browser/WebView viewport sizes.
    var portraitSize: CGSize {
        switch self {
        case .iPhone14Pro:
            return CGSize(width: 393, height: 852)

        case .iPadPro:
            return CGSize(width: 768, height: 1024)
        }
    }

    // Screen-hole inset as a fraction of the frame.
    var screenInsets: (
        left: CGFloat,
        right: CGFloat,
        top: CGFloat,
        bottom: CGFloat
    ) {
        switch self {
        case .iPhone14Pro:
            return (
                left: 0.0519,
                right: 0.0496,
                top: 0.0217,
                bottom: 0.0221
            )

        case .iPadPro:
            return (
                left: 0.073,
                right: 0.090,
                top: 0.091,
                bottom: 0.108
            )
        }
    }
}

enum SimulatorOrientation {
    case portrait
    case landscape
}

final class SimulatorWindowState: ObservableObject, Identifiable {

    let id: UUID
    let deviceType: SimulatorDeviceType

    @Published var url: URL
    @Published var orientation: SimulatorOrientation
    @Published var position: CGPoint

    @Published var displayScale: CGFloat
    @Published var isMinimized: Bool

    @Published var reloadToken: UUID

    init(
        deviceType: SimulatorDeviceType,
        url: URL,
        position: CGPoint,
        displayScale: CGFloat = 1.0
    ) {
        self.id = UUID()
        self.deviceType = deviceType
        self.url = url
        self.position = position

        // Every newly opened simulator starts portrait + 100%.
        self.orientation = .portrait
        self.displayScale = displayScale
        self.isMinimized = false

        self.reloadToken = UUID()
    }
}

final class SimulatorManager: ObservableObject {

    static let shared = SimulatorManager()

    private init() {
        for deviceType in SimulatorDeviceType.allCases {
            urlDrafts[deviceType] =
                savedURL(for: deviceType).absoluteString
        }
    }

    @Published var windows: [SimulatorWindowState] = []

    @Published var showDevicePicker = false

    @Published var urlDrafts: [
        SimulatorDeviceType: String
    ] = [:]

    private static let defaultURL =
        URL(string: "https://example.com")!

    private static func defaultsKey(
        for deviceType: SimulatorDeviceType
    ) -> String {
        "codeapp.simulator.url.\(deviceType.rawValue)"
    }

    func savedURL(
        for deviceType: SimulatorDeviceType
    ) -> URL {

        if let saved = UserDefaults.standard.string(
            forKey: Self.defaultsKey(for: deviceType)
        ),
        let url = URL(string: saved),
        url.scheme != nil {

            return url
        }

        return Self.defaultURL
    }

    func saveURL(
        _ url: URL,
        for deviceType: SimulatorDeviceType
    ) {

        UserDefaults.standard.set(
            url.absoluteString,
            forKey: Self.defaultsKey(for: deviceType)
        )

        urlDrafts[deviceType] = url.absoluteString

        if let window = windows.first(
            where: { $0.deviceType == deviceType }
        ) {

            window.url = url
            window.reloadToken = UUID()
        }
    }

    func open(
        deviceType: SimulatorDeviceType
    ) {

        // If simulator already exists, restore it instead of
        // creating another one.
        if let existing = windows.first(
            where: { $0.deviceType == deviceType }
        ) {

            existing.isMinimized = false

            // Restore default simulator scale when opening.
            existing.displayScale = 1.0
            existing.orientation = .portrait

            return
        }

        let offset = CGFloat(windows.count * 24)

        let window = SimulatorWindowState(
            deviceType: deviceType,
            url: savedURL(for: deviceType),

            position: CGPoint(
                x: 40 + offset,
                y: 60 + offset
            ),

            // DEFAULT SIZE = 100%
            displayScale: 1.0
        )

        windows.append(window)
    }

    func minimize(
        _ window: SimulatorWindowState
    ) {
        window.isMinimized = true
    }

    func restore(
        _ window: SimulatorWindowState
    ) {
        window.isMinimized = false
    }

    func close(
        _ window: SimulatorWindowState
    ) {
        windows.removeAll {
            $0.id == window.id
        }
    }
}