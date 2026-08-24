//
//  SimulatorWindowView.swift
//  Code
//

import SwiftUI
import WebKit

// MARK: - Interactive WebView

private struct SimulatorWebView: UIViewRepresentable {

    @ObservedObject var window: SimulatorWindowState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(
        context: Context
    ) -> UIView {

        let container = UIView()
        container.backgroundColor = .clear
        container.clipsToBounds = true

        let webView = WKWebView(
            frame: .zero
        )

        webView.backgroundColor = .white
        webView.isOpaque = true

        // VERY IMPORTANT FOR TOUCH / JAVASCRIPT.
        webView.isUserInteractionEnabled = true
        webView.scrollView.isUserInteractionEnabled = true

        // Prevent weird automatic inset behaviour.
        webView.scrollView.contentInsetAdjustmentBehavior =
            .never

        // Normal mobile Safari-like viewport behaviour.
        webView.configuration.defaultWebpagePreferences
            .preferredContentMode = .mobile

        webView.autoresizingMask = []

        container.addSubview(webView)

        context.coordinator.webView = webView
        context.coordinator.lastURL = window.url
        context.coordinator.lastReloadToken =
            window.reloadToken

        webView.load(
            URLRequest(
                url: window.url,
                cachePolicy: .useProtocolCachePolicy,
                timeoutInterval: 30
            )
        )

        return container
    }

    func updateUIView(
        _ container: UIView,
        context: Context
    ) {

        guard let webView = context.coordinator.webView
        else {
            return
        }

        if context.coordinator.lastURL != window.url {

            context.coordinator.lastURL = window.url

            webView.load(
                URLRequest(
                    url: window.url,
                    cachePolicy: .useProtocolCachePolicy,
                    timeoutInterval: 30
                )
            )
        }

        if context.coordinator.lastReloadToken !=
            window.reloadToken {

            context.coordinator.lastReloadToken =
                window.reloadToken

            webView.reload()
        }

        context.coordinator.layout(
            webView: webView,
            window: window,
            containerBounds: container.bounds
        )
    }

    final class Coordinator {

        weak var webView: WKWebView?

        var lastURL: URL?
        var lastReloadToken: UUID?

        func layout(
            webView: WKWebView,
            window: SimulatorWindowState,
            containerBounds: CGRect
        ) {

            guard
                containerBounds.width > 0,
                containerBounds.height > 0
            else {
                return
            }

            let nativePortrait =
                window.deviceType.portraitSize

            let nativeSize: CGSize

            if window.orientation == .portrait {
                nativeSize = nativePortrait
            } else {
                nativeSize = CGSize(
                    width: nativePortrait.height,
                    height: nativePortrait.width
                )
            }

            let insets =
                window.deviceType.screenInsets

            // Screen hole dimensions in the frame.
            let holeWidth =
                containerBounds.width *
                (1.0 - insets.left - insets.right)

            let holeHeight =
                containerBounds.height *
                (1.0 - insets.top - insets.bottom)

            // WebView is ALWAYS based on the real viewport.
            //
            // iPhone 14 Pro:
            // 393 x 852
            //
            // We only visually scale it down so it fits inside
            // the physical screen hole.
            let scaleX =
                holeWidth / nativeSize.width

            let scaleY =
                holeHeight / nativeSize.height

            let visualScale =
                min(scaleX, scaleY)

            webView.transform = .identity

            webView.bounds = CGRect(
                origin: .zero,
                size: nativeSize
            )

            webView.center = CGPoint(
                x: containerBounds.midX,
                y: containerBounds.midY
            )

            webView.transform =
                CGAffineTransform(
                    scaleX: visualScale,
                    y: visualScale
                )
        }
    }
}

// MARK: - Device Frame

struct SimulatorDeviceFrameView: View {

    @ObservedObject var window: SimulatorWindowState

    let onClose: () -> Void

    @State private var showSettings = false

    @State private var dragStartPosition: CGPoint?

    @EnvironmentObject
    private var simulatorManager: SimulatorManager

    private static let resizeStep: CGFloat = 0.08

    private static let minScale: CGFloat = 0.28

    private static let maxScale: CGFloat = 1.30

    private static let defaultScale: CGFloat = 1.0

    private static let barWidth: CGFloat = 220

    private static let rowHeight: CGFloat = 30

    private var nativeSize: CGSize {
        window.deviceType.portraitSize
    }

    private var orientedNativeSize: CGSize {

        if window.orientation == .portrait {
            return nativeSize
        }

        return CGSize(
            width: nativeSize.height,
            height: nativeSize.width
        )
    }

    private var scaledBezelSize: CGSize {

        CGSize(
            width:
                orientedNativeSize.width *
                window.displayScale,

            height:
                orientedNativeSize.height *
                window.displayScale
        )
    }

    var body: some View {

        VStack(spacing: 6) {

            titleBar

            buttonRow

            deviceBezel

            sizeControls
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    Color(
                        "sideBar.background"
                    )
                )
                .shadow(
                    color: .black.opacity(0.25),
                    radius: 10,
                    y: 4
                )
        )
        .offset(
            x: window.position.x,
            y: window.position.y
        )
        .zIndex(1000)
        .sheet(
            isPresented: $showSettings
        ) {

            SimulatorSettingsView(
                deviceType: window.deviceType
            )
            .environmentObject(
                simulatorManager
            )
        }
    }

    // MARK: - Drag Title Bar

    private var titleBar: some View {

        HStack(spacing: 7) {

            Image(
                systemName:
                    "line.3.horizontal"
            )
            .font(
                .system(size: 11)
            )
            .foregroundColor(
                .white.opacity(0.55)
            )

            Text(
                window.deviceType.displayName
            )
            .font(
                .system(
                    size: 12,
                    weight: .semibold
                )
            )
            .foregroundColor(
                .white.opacity(0.9)
            )

            Spacer()

            Image(
                systemName: "hand.draw"
            )
            .font(
                .system(size: 10)
            )
            .foregroundColor(
                .white.opacity(0.45)
            )
        }
        .padding(.horizontal, 10)
        .frame(
            width:
                max(
                    Self.barWidth,
                    scaledBezelSize.width
                ),
            height: Self.rowHeight
        )
        .background(
            Color.black.opacity(0.9)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 8
            )
        )
        .contentShape(Rectangle())
        .gesture(

            DragGesture(
                minimumDistance: 2
            )

            .onChanged { value in

                if dragStartPosition == nil {

                    dragStartPosition =
                        window.position
                }

                guard let start =
                    dragStartPosition
                else {
                    return
                }

                window.position = CGPoint(
                    x:
                        start.x +
                        value.translation.width,

                    y:
                        start.y +
                        value.translation.height
                )
            }

            .onEnded { _ in

                dragStartPosition = nil
            }
        )
    }

    // MARK: - Buttons

    private var buttonRow: some View {

        HStack(spacing: 16) {

            simulatorButton(
                "gearshape.fill"
            ) {
                showSettings = true
            }

            simulatorButton(
                "arrow.clockwise"
            ) {
                window.reloadToken = UUID()
            }

            simulatorButton(
                "rotate.right"
            ) {

                window.orientation =
                    window.orientation == .portrait
                    ? .landscape
                    : .portrait
            }

            // MAXIMIZE / RESET
            simulatorButton(
                "arrow.up.left.and.arrow.down.right"
            ) {

                withAnimation(
                    .easeOut(duration: 0.15)
                ) {
                    window.displayScale =
                        Self.maxScale
                }
            }

            // MINIMIZE
            simulatorButton(
                "minus.circle.fill"
            ) {

                simulatorManager.minimize(
                    window
                )
            }

            // CLOSE
            simulatorButton(
                "xmark.circle.fill"
            ) {
                onClose()
            }
        }
        .frame(
            width:
                max(
                    Self.barWidth,
                    scaledBezelSize.width
                ),
            height: Self.rowHeight
        )
        .background(
            Color.black.opacity(0.78)
        )
        .clipShape(
            RoundedRectangle(
                cornerRadius: 8
            )
        )
    }

    private func simulatorButton(
        _ systemImage: String,
        action: @escaping () -> Void
    ) -> some View {

        Button(
            action: action
        ) {

            Image(
                systemName: systemImage
            )
            .font(
                .system(size: 13)
            )
            .foregroundColor(.white)
            .frame(
                width: 27,
                height: 27
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Device

    private var deviceBezel: some View {

        let frameSize =
            orientedNativeSize

        return ZStack {

            // WEBVIEW
            //
            // This view gets the complete device frame area.
            // The UIKit coordinator places the 393x852 WebView
            // inside the actual screen hole.
            SimulatorWebView(
                window: window
            )
            .frame(
                width: frameSize.width,
                height: frameSize.height
            )
            .clipped()

            // DEVICE FRAME
            //
            // VERY IMPORTANT:
            // The frame image must NEVER receive touches.
            // Otherwise it sits above WKWebView and steals taps.
            Image(
                window.deviceType.frameImageName
            )
            .resizable()
            .frame(
                width: nativeSize.width,
                height: nativeSize.height
            )
            .rotationEffect(
                .degrees(
                    window.orientation == .landscape
                    ? -90
                    : 0
                )
            )
            .frame(
                width: frameSize.width,
                height: frameSize.height
            )
            .allowsHitTesting(false)

        }
        .frame(
            width:
                frameSize.width *
                window.displayScale,

            height:
                frameSize.height *
                window.displayScale
        )
        .scaleEffect(
            window.displayScale
        )
        .shadow(
            color: .black.opacity(0.3),
            radius: 12,
            y: 6
        )
        .zIndex(1)
    }

    // MARK: - Size Controls
// MARK: - Size Controls

private var sizeControls: some View {

    HStack(spacing: 16) {

        simulatorButton(
            "minus.magnifyingglass"
        ) {

            withAnimation(
                .easeOut(duration: 0.12)
            ) {

                window.displayScale =
                    max(
                        Self.minScale,
                        window.displayScale -
                            Self.resizeStep
                    )
            }
        }

        Text(
            "\(Int(window.displayScale * 100))%"
        )
        .font(
            .system(
                size: 11,
                weight: .medium
            )
        )
        .foregroundColor(
            .white.opacity(0.8)
        )
        .frame(
            minWidth: 40
        )

        simulatorButton(
            "plus.magnifyingglass"
        ) {

            withAnimation(
                .easeOut(duration: 0.12)
            ) {

                window.displayScale =
                    min(
                        Self.maxScale,
                        window.displayScale +
                            Self.resizeStep
                    )
            }
        }

        // RESET TO DEFAULT FRAME SIZE
        simulatorButton(
            "1.circle"
        ) {

            withAnimation(
                .easeOut(duration: 0.12)
            ) {

                window.displayScale =
                    Self.defaultScale
            }
        }
    }
    .padding(.horizontal, 10)
    .frame(
        width:
            max(
                Self.barWidth,
                scaledBezelSize.width
            ),
        height: Self.rowHeight
    )
    .background(
        Color.black.opacity(0.78)
    )
    .clipShape(
        RoundedRectangle(
            cornerRadius: 8
        )
    )
}

// MARK: - Minimized Simulator

private struct SimulatorMinimizedDockView: View {

    @ObservedObject
    var window: SimulatorWindowState

    @EnvironmentObject
    private var simulatorManager: SimulatorManager

    var body: some View {

        Button {

            simulatorManager.restore(
                window
            )

        } label: {

            VStack(spacing: 3) {

                Image(
                    systemName:
                        window.deviceType.sfSymbol
                )
                .font(
                    .system(size: 20)
                )

                Text(
                    window.deviceType.displayName
                )
                .font(
                    .system(size: 9)
                )
                .lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(10)
            .frame(width: 75)
            .background(
                Color.black.opacity(0.88)
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 12
                )
            )
            .shadow(
                radius: 6
            )
        }
        .buttonStyle(.plain)
        .offset(
            x: window.position.x,
            y: window.position.y
        )
        .zIndex(2000)
    }
}

// MARK: - Overlay

struct SimulatorWindowsOverlay: View {

    @ObservedObject
    var manager =
        SimulatorManager.shared

    var body: some View {

        ZStack(
            alignment: .topLeading
        ) {

            ForEach(
                manager.windows
            ) { window in

                if window.isMinimized {

                    SimulatorMinimizedDockView(
                        window: window
                    )
                    .environmentObject(
                        manager
                    )

                } else {

                    SimulatorDeviceFrameView(
                        window: window,

                        onClose: {
                            manager.close(
                                window
                            )
                        }
                    )
                    .environmentObject(
                        manager
                    )
                }
            }
        }

        // Don't put a global allowsHitTesting(false)
        // here. It would disable WKWebView interaction.
        .confirmationDialog(
            "Open Simulator",

            isPresented:
                $manager.showDevicePicker,

            titleVisibility:
                .visible
        ) {

            Button("iPhone 14 Pro") {

                manager.open(
                    deviceType:
                        .iPhone14Pro
                )
            }

            Button("iPad Pro") {

                manager.open(
                    deviceType:
                        .iPadPro
                )
            }

            Button(
                "Cancel",
                role: .cancel
            ) {}
        }
    }
}