//
//  SimulatorWindowView.swift
//  Code
//

import SwiftUI
import WebKit
import UIKit

// MARK: - UIKit simulator canvas

/// The important part of this implementation is that SwiftUI never scales a
/// WKWebView. The WebView keeps a real-device logical bounds (393x852 or
/// 768x1024), while UIKit applies a visual transform to it. This keeps taps,
/// scrolling and text input reliable and prevents the WebView from escaping
/// the device screen area.
private struct SimulatorWebCanvas: UIViewRepresentable {
    @ObservedObject var window: SimulatorWindowState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView()
        context.coordinator.install(in: view, window: window)
        return view
    }

    func updateUIView(_ view: CanvasView, context: Context) {
        context.coordinator.update(in: view, window: window)
    }

    final class Coordinator {
        private var webView: WKWebView?
        private var lastURL: URL?
        private var lastReloadToken: UUID?
        private var lastDevice: SimulatorDeviceType?
        private var lastOrientation: SimulatorOrientation?

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
            lastDevice = window.deviceType
            lastOrientation = window.orientation
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
            lastDevice = window.deviceType
            lastOrientation = window.orientation
        }

        private func loadIfNeeded(window: SimulatorWindowState) {
            guard let webView else { return }
            if lastURL != window.url || lastReloadToken != window.reloadToken {
                lastURL = window.url
                lastReloadToken = window.reloadToken
                webView.load(URLRequest(url: window.url, cachePolicy: .useProtocolCachePolicy))
            }
        }

        private func applyLayout(canvas: CanvasView, window: SimulatorWindowState) {
            let viewport = window.deviceType.viewportSize
            let hole = SimulatorLayout.screenRect(for: window)
            let canvasSize = SimulatorLayout.frameSize(for: window)
            canvas.frame = CGRect(origin: .zero, size: canvasSize)
            canvas.bounds = CGRect(origin: .zero, size: canvasSize)
            canvas.clipsToBounds = true

            guard let webView else { return }

            let nativeViewport: CGSize = window.orientation == .portrait
                ? viewport
                : CGSize(width: viewport.height, height: viewport.width)

            // WebView has real logical bounds. Only its visual transform is
            // changed to fit the transparent screen hole.
            webView.transform = .identity
            webView.bounds = CGRect(origin: .zero, size: nativeViewport)

            let fitX = hole.width / nativeViewport.width
            let fitY = hole.height / nativeViewport.height
            let scale = min(fitX, fitY)
            webView.transform = CGAffineTransform(scaleX: scale, y: scale)
            webView.center = CGPoint(x: hole.midX, y: hole.midY)

            // For a landscape viewport the WebView itself is already
            // landscape, so there is no extra rotation or coordinate mismatch.
            webView.layer.cornerRadius = min(hole.width, hole.height) * 0.035
            webView.clipsToBounds = true

            canvas.bringSubviewToFront(webView)
        }
    }

    final class CanvasView: UIView {
        weak var webView: WKWebView?
        override func layoutSubviews() {
            super.layoutSubviews()
        }
    }
}

// MARK: - Simulator window

struct SimulatorDeviceFrameView: View {
    @ObservedObject var window: SimulatorWindowState
    let onClose: () -> Void

    @State private var showSettings = false
    @State private var dragStart: CGPoint?
    @EnvironmentObject private var simulatorManager: SimulatorManager

    private static let minScale: CGFloat = 0.38
    private static let maxScale: CGFloat = 1.25
    private static let resizeStep: CGFloat = 0.05
    private static let controlHeight: CGFloat = 30

    private var frameSize: CGSize { SimulatorLayout.frameSize(for: window) }
    private var portraitFrameSize: CGSize { SimulatorLayout.portraitFrameSize(for: window) }

    var body: some View {
        VStack(spacing: 5) {
            titleBar
            controlsBar
            zoomBar
            deviceView
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color("sideBar.background"))
                .shadow(color: .black.opacity(0.28), radius: 9, y: 4)
        )
        .offset(x: window.position.x, y: window.position.y)
        .sheet(isPresented: $showSettings) {
            SimulatorSettingsView(deviceType: window.deviceType)
                .environmentObject(simulatorManager)
        }
    }

    // MARK: Title / move handle

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

            // A visible white drag handle. It is the only area used for moving.
            Capsule()
                .fill(Color.white.opacity(window.isMoveMode ? 0.9 : 0.28))
                .frame(width: 42, height: 4)

            Spacer(minLength: 4)

            Text(window.orientation.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.52))
        }
        .padding(.horizontal, 9)
        .frame(height: Self.controlHeight)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .gesture(moveGesture)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard window.isMoveMode else { return }
                if dragStart == nil { dragStart = window.position }
                guard let start = dragStart else { return }
                window.position = CGPoint(
                    x: start.x + value.translation.width,
                    y: start.y + value.translation.height
                )
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    // MARK: Controls

    private var controlsBar: some View {
        HStack(spacing: 10) {
            simulatorButton("gearshape.fill") { showSettings = true }

            simulatorButton("arrow.clockwise") {
                window.reloadToken = UUID()
            }

            simulatorButton(
                window.orientation == .portrait
                    ? "rectangle.portrait.rotate"
                    : "rectangle.landscape.rotate"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    window.orientation = window.orientation == .portrait ? .landscape : .portrait
                }
            }

            // One button = unlock/move, press again = lock. No position menu.
            simulatorButton(window.isMoveMode ? "lock.open.fill" : "location.fill") {
                window.isMoveMode.toggle()
            }

            simulatorButton("xmark.circle.fill", action: onClose)
        }
        .frame(height: Self.controlHeight)
        .padding(.horizontal, 9)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func simulatorButton(_ image: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Zoom controls

    /// These controls live above the frame and are outside the scaled device,
    /// so their size never changes when the simulator is resized.
    private var zoomBar: some View {
        HStack(spacing: 7) {
            Button {
                window.displayScale = max(Self.minScale, window.displayScale - Self.resizeStep)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)

            Text("\(Int(window.displayScale * 100))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 42)

            Button {
                window.displayScale = min(Self.maxScale, window.displayScale + Self.resizeStep)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .frame(height: Self.controlHeight)
        .padding(.horizontal, 7)
        .background(Color.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Device

    private var deviceView: some View {
        ZStack {
            SimulatorWebCanvas(window: window)

            Image(window.deviceType.frameImageName)
                .resizable()
                .frame(width: portraitFrameSize.width, height: portraitFrameSize.height)
                .rotationEffect(window.orientation == .landscape ? .degrees(-90) : .zero)
                .allowsHitTesting(false)
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipped()
        .animation(.easeInOut(duration: 0.18), value: window.orientation)
        .animation(.easeInOut(duration: 0.12), value: window.displayScale)
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
                    Text("The viewport stays fixed. The +/− controls only change the visual simulator size.")
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
