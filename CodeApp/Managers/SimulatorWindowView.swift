//
//  SimulatorWindowView.swift
//  Code
//

import SwiftUI
import WebKit
import UIKit

// MARK: - Interactive WebView

private struct SimulatorWebCanvas: UIViewRepresentable {
    @ObservedObject var window: SimulatorWindowState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> CanvasView {
        let canvas = CanvasView()
        canvas.backgroundColor = .clear
        canvas.clipsToBounds = true
        context.coordinator.install(in: canvas, window: window)
        return canvas
    }

    func updateUIView(_ canvas: CanvasView, context: Context) {
        context.coordinator.update(in: canvas, window: window)
    }

    final class Coordinator {
        private(set) var webView: WKWebView?
        private var lastURL: URL?
        private var lastReloadToken: UUID?

        func install(in canvas: CanvasView, window: SimulatorWindowState) {
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

            canvas.addSubview(web)
            canvas.webView = web
            webView = web

            applyLayout(canvas: canvas, window: window)
            loadIfNeeded(window: window)
        }

        func update(in canvas: CanvasView, window: SimulatorWindowState) {
            guard webView != nil else {
                install(in: canvas, window: window)
                return
            }

            applyLayout(canvas: canvas, window: window)
            loadIfNeeded(window: window)
        }

        private func loadIfNeeded(window: SimulatorWindowState) {
            guard let webView else { return }

            if lastURL != window.url || lastReloadToken != window.reloadToken {
                lastURL = window.url
                lastReloadToken = window.reloadToken
                webView.load(
                    URLRequest(
                        url: window.url,
                        cachePolicy: .useProtocolCachePolicy,
                        timeoutInterval: 30
                    )
                )
            }
        }

        private func applyLayout(canvas: CanvasView, window: SimulatorWindowState) {
            let frameSize = SimulatorLayout.frameSize(for: window)
            let hole = SimulatorLayout.screenRect(for: window)
            // Keep WKWebView in the real portrait device viewport. In landscape
            // the entire viewport is rotated together with the frame artwork.
            // This prevents the WebView from sticking out of the frame or using
            // swapped coordinates.
            let viewport = window.deviceType.viewportSize

            canvas.frame = CGRect(origin: .zero, size: frameSize)
            canvas.bounds = CGRect(origin: .zero, size: frameSize)
            canvas.clipsToBounds = true

            guard let webView else { return }

            // V4 layout system: keep the WKWebView in the device's actual
            // logical viewport and only scale it to the frame's screen hole.
            // In landscape the viewport itself is swapped; the frame artwork
            // is rotated separately, so no WebView rotation is applied here.
            let nativeViewport: CGSize = window.orientation == .portrait
                ? viewport
                : CGSize(width: viewport.height, height: viewport.width)

            webView.transform = .identity
            webView.bounds = CGRect(origin: .zero, size: nativeViewport)

            let fitX = hole.width / nativeViewport.width
            let fitY = hole.height / nativeViewport.height
            let fit = min(fitX, fitY)
            webView.transform = CGAffineTransform(scaleX: fit, y: fit)
            webView.center = CGPoint(x: hole.midX, y: hole.midY)

            webView.layer.cornerRadius = min(hole.width, hole.height) * 0.028
            webView.clipsToBounds = true
            webView.layer.masksToBounds = true

            canvas.bringSubviewToFront(webView)
        }
    }

    final class CanvasView: UIView {
        weak var webView: WKWebView?
    }
}

// MARK: - Simulator window

struct SimulatorDeviceFrameView: View {
    @ObservedObject var window: SimulatorWindowState
    let onClose: () -> Void

    @State private var showSettings = false
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var minimizedDragTranslation: CGSize = .zero
    @EnvironmentObject private var simulatorManager: SimulatorManager

    private static let minScale: CGFloat = 0.38
    private static let maxScale: CGFloat = 1.25
    private static let resizeStep: CGFloat = 0.05
    private static let controlHeight: CGFloat = 30

    private var frameSize: CGSize {
        SimulatorLayout.frameSize(for: window)
    }

    private var portraitFrameSize: CGSize {
        SimulatorLayout.portraitFrameSize(for: window)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 4) {
                titleBar
                controlBar
                zoomBar
                deviceView
            }
            .frame(width: frameSize.width, alignment: .center)
            .background(Color.clear)
            .opacity(window.isMinimized ? 0 : 1)
            .allowsHitTesting(!window.isMinimized)

            if window.isMinimized {
                minimizedPhoneIcon
            }
        }
        .frame(width: window.isMinimized ? 64 : frameSize.width,
               height: window.isMinimized ? 64 : frameSize.height + 3 * (Self.controlHeight + 4),
               alignment: .topLeading)
        .offset(
            x: window.position.x + dragTranslation.width,
            y: window.position.y + dragTranslation.height
        )
        .sheet(isPresented: $showSettings) {
            SimulatorSettingsView(deviceType: window.deviceType)
                .environmentObject(simulatorManager)
        }
    }

    private var minimizedPhoneIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .frame(width: 58, height: 58)
                .shadow(radius: 8)

            Image(systemName: window.deviceType.sfSymbol)
                .font(.system(size: 25, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: 64, height: 64)
        .contentShape(Rectangle())
        .offset(minimizedDragTranslation)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .updating($minimizedDragTranslation) { value, state, _ in
                    guard window.isMoveMode else { return }
                    state = value.translation
                }
                .onEnded { value in
                    guard window.isMoveMode else { return }
                    window.position = CGPoint(
                        x: window.position.x + value.translation.width,
                        y: window.position.y + value.translation.height
                    )
                }
        )
        .onTapGesture(count: 2) {
            window.isMinimized = false
        }
        .accessibilityLabel("Minimized \(window.deviceType.displayName) simulator")
        .accessibilityHint("Double tap to restore")
    }

    // MARK: Title / drag handle

    private var titleBar: some View {
        HStack(spacing: 7) {
            Image(systemName: window.isMoveMode ? "hand.draw.fill" : "lock.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(window.isMoveMode ? 0.95 : 0.55))

            Text(window.deviceType.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)

            Spacer(minLength: 4)

            Capsule()
                .fill(Color.white.opacity(window.isMoveMode ? 0.95 : 0.28))
                .frame(width: 42, height: 4)

            Spacer(minLength: 4)

            Text(window.orientation.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.52))
        }
        .padding(.horizontal, 9)
        .frame(width: frameSize.width, height: Self.controlHeight)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .gesture(moveGesture)
    }

    /// The gesture only changes a local @GestureState while dragging. The
    /// published window position is committed once, on release. This avoids
    /// the feedback loop that previously made the whole CodeApp editor freeze.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in
                guard window.isMoveMode else { return }
                state = value.translation
            }
            .onEnded { value in
                guard window.isMoveMode else { return }
                window.position = CGPoint(
                    x: window.position.x + value.translation.width,
                    y: window.position.y + value.translation.height
                )
            }
    }

    // MARK: Controls

    private var controlBar: some View {
        HStack(spacing: 4) {
            simulatorButton("gearshape.fill") {
                showSettings = true
            }

            simulatorButton("arrow.clockwise") {
                window.reloadToken = UUID()
            }

            simulatorButton(
                "rotate.right",
                accessibilityLabel: "Rotate simulator"
            ) {
                window.orientation = window.orientation == .portrait
                    ? .landscape
                    : .portrait
            }

            simulatorButton(window.isMoveMode ? "lock.open.fill" : "location.fill") {
                window.isMoveMode.toggle()
            }

            simulatorButton("minus.circle.fill", accessibilityLabel: "Minimize simulator") {
                window.isMinimized = true
            }

            simulatorButton("xmark.circle.fill", action: onClose)
        }
        .frame(width: frameSize.width, height: Self.controlHeight)
        .padding(.horizontal, 8)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func simulatorButton(
        _ image: String,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? image)
    }

    // MARK: Zoom

    private var zoomBar: some View {
        HStack(spacing: 5) {
            zoomButton("minus") {
                window.displayScale = max(
                    Self.minScale,
                    window.displayScale - Self.resizeStep
                )
            }

            Text("\(Int(window.displayScale * 100))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 42)

            zoomButton("plus") {
                window.displayScale = min(
                    Self.maxScale,
                    window.displayScale + Self.resizeStep
                )
            }
        }
        .foregroundColor(.white)
        .frame(width: frameSize.width, height: Self.controlHeight)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func zoomButton(
        _ image: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Device

    private var deviceView: some View {
        ZStack {
            // Web content is below the frame, so the transparent screen hole
            // in the PNG reveals it while the bezel/dynamic-island remains on top.
            SimulatorWebCanvas(window: window)

            Image(window.deviceType.frameImageName)
                .resizable()
                .frame(
                    width: portraitFrameSize.width,
                    height: portraitFrameSize.height
                )
                .rotationEffect(
                    window.orientation == .landscape
                        ? .degrees(-90)
                        : .zero
                )
                .allowsHitTesting(false)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .center)
        .clipped()
    }
}

// MARK: - Settings

private struct SimulatorSettingsView: View {
    let deviceType: SimulatorDeviceType

    @EnvironmentObject private var simulatorManager: SimulatorManager
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Web URL") {
                    TextField("https://example.com", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)

                    Button("Save & Reload") {
                        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard let url = URL(string: value),
                              let scheme = url.scheme,
                              !scheme.isEmpty else { return }
                        simulatorManager.saveURL(url, for: deviceType)
                        dismiss()
                    }
                    .disabled(
                        URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme == nil
                    )
                }

                Section("Simulator") {
                    Text("Device: \(deviceType.displayName)")
                    Text("Viewport: \(Int(deviceType.viewportSize.width)) × \(Int(deviceType.viewportSize.height))")
                    Text("The viewport stays fixed. + / − changes only the simulator's visual size.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Simulator Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SwiftUI.ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            urlText = simulatorManager.urlDrafts[deviceType]
                ?? simulatorManager.savedURL(for: deviceType).absoluteString
        }
    }
}

// MARK: - Overlay

struct SimulatorWindowsOverlay: View {
    @ObservedObject var manager = SimulatorManager.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(manager.windows) { window in
                SimulatorDeviceFrameView(
                    window: window,
                    onClose: { manager.close(window) }
                )
                .environmentObject(manager)
            }
        }
        .allowsHitTesting(true)
        .confirmationDialog(
            "Open Simulator",
            isPresented: $manager.showDevicePicker,
            titleVisibility: .visible
        ) {
            Button("iPhone 14 Pro") {
                manager.open(deviceType: .iPhone14Pro)
            }

            Button("iPad (5th generation)") {
                manager.open(deviceType: .iPadPro)
            }

            Button("Cancel", role: .cancel) {}
        }
    }
}
