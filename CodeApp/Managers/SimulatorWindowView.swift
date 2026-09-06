//
//  SimulatorWindowView.swift
//  Code
//

import SwiftUI
import WebKit
import UIKit

// MARK: - Shared WebView

/// The same WKWebView is moved between the framed simulator and the full
/// screen preview. It is never recreated just because the view is redrawn.
private struct SimulatorWebCanvas: UIViewRepresentable {
    @ObservedObject var window: SimulatorWindowState

    func makeUIView(context: Context) -> CanvasView {
        let canvas = CanvasView()
        canvas.backgroundColor = .clear
        canvas.clipsToBounds = true
        context.coordinator.update(canvas: canvas, window: window)
        return canvas
    }

    func updateUIView(_ canvas: CanvasView, context: Context) {
        context.coordinator.update(canvas: canvas, window: window)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        func update(canvas: CanvasView, window: SimulatorWindowState) {
            let webView = window.webViewStore.attach(to: canvas, for: window)
            applyV4Layout(webView: webView, canvas: canvas, window: window)
        }

        private func applyV4Layout(webView: WKWebView, canvas: CanvasView, window: SimulatorWindowState) {
            let viewport = window.deviceType.viewportSize
            let hole = SimulatorLayout.screenRect(for: window)
            let canvasSize = SimulatorLayout.frameSize(for: window)

            canvas.frame = CGRect(origin: .zero, size: canvasSize)
            canvas.bounds = CGRect(origin: .zero, size: canvasSize)
            canvas.clipsToBounds = true

            // V4 system: keep the real device CSS viewport in WKWebView
            // bounds, and only scale its visual presentation into the frame's
            // screen hole. This is important for both portrait and landscape.
            let nativeViewport = window.orientation == .portrait
                ? viewport
                : CGSize(width: viewport.height, height: viewport.width)

            webView.transform = .identity
            webView.bounds = CGRect(origin: .zero, size: nativeViewport)

            let fitX = hole.width / max(nativeViewport.width, 1)
            let fitY = hole.height / max(nativeViewport.height, 1)

            // The iPhone asset is already the exact 393:852 ratio. The
            // bundled iPad frame is a few pixels off the real 4:3 ratio, so
            // using independent X/Y fitting fills the actual transparent
            // screen opening instead of leaving a top/bottom gap or spilling
            // outside the frame. The WKWebView's logical bounds stay at the
            // real device viewport, so website CSS sizes do not change.
            webView.transform = CGAffineTransform(scaleX: fitX, y: fitY)
            webView.center = CGPoint(x: hole.midX, y: hole.midY)
            webView.layer.cornerRadius = min(hole.width, hole.height) * 0.035
            webView.clipsToBounds = true
            webView.layer.masksToBounds = true

            canvas.bringSubviewToFront(webView)
        }
    }

    final class CanvasView: UIView {}
}

// MARK: - Simulator window

struct SimulatorDeviceFrameView: View {
    @ObservedObject var window: SimulatorWindowState
    let onClose: () -> Void

    @State private var showSettings = false
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var minimizedDragTranslation: CGSize = .zero
    @EnvironmentObject private var simulatorManager: SimulatorManager
    @Environment(\.colorScheme) private var colorScheme

    private static let minScale: CGFloat = 0.38
    private static let maxScale: CGFloat = 1.25
    private static let resizeStep: CGFloat = 0.05
    private static let controlHeight: CGFloat = 30

    // Eight controls now fit even on the smallest visual iPhone size.
    private var controlButtonWidth: CGFloat {
        let available = max(160, frameSize.width - 12)
        return min(28, max(20, (available - 7) / 8))
    }

    private var frameSize: CGSize { SimulatorLayout.frameSize(for: window) }
    private var portraitFrameSize: CGSize { SimulatorLayout.portraitFrameSize(for: window) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if window.isMinimized {
                minimizedPhoneIcon
            } else {
                VStack(spacing: 4) {
                    titleBar
                    controlBar
                    zoomBar
                    deviceView
                }
                .frame(width: frameSize.width, alignment: .center)
            }
        }
        .frame(
            width: window.isMinimized ? 64 : frameSize.width,
            height: window.isMinimized ? 64 : frameSize.height + 3 * (Self.controlHeight + 4),
            alignment: .topLeading
        )
        .offset(
            x: window.position.x + dragTranslation.width,
            y: window.position.y + dragTranslation.height
        )
        .sheet(isPresented: $showSettings) {
            SimulatorSettingsView(deviceType: window.deviceType)
                .environmentObject(simulatorManager)
        }
    }

    // Minimized icon is independent of simulator Move/Lock mode.
    // No background: only the device symbol is visible.
    private var minimizedPhoneIcon: some View {
        Image(systemName: window.deviceType.sfSymbol)
            .font(.system(size: 29, weight: .semibold))
            .foregroundColor(colorScheme == .dark ? .white : .black)
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
            .offset(minimizedDragTranslation)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($minimizedDragTranslation) { value, state, _ in
                        state = value.translation
                    }
                    .onEnded { value in
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
        HStack(spacing: 1) {
            simulatorButton("gearshape.fill") {
                showSettings = true
            }

            simulatorButton("arrow.clockwise") {
                window.reloadToken = UUID()
                window.webViewStore.reload(for: window)
            }

            simulatorButton(
                "arrow.triangle.2.circlepath",
                accessibilityLabel: "Rotate simulator"
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    window.orientation = window.orientation == .portrait ? .landscape : .portrait
                }
            }

            Button(action: { simulatorManager.sendFlutterHotReload() }) {
                Text("R")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: controlButtonWidth, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Flutter hot reload")

            simulatorButton("eye.fill", accessibilityLabel: "Open full screen preview") {
                simulatorManager.openPreview(for: window)
            }

            simulatorButton(window.isMoveMode ? "lock.open.fill" : "location.fill") {
                window.isMoveMode.toggle()
            }

            // Minimize is before Close, as requested.
            simulatorButton("minus.circle.fill", accessibilityLabel: "Minimize simulator") {
                window.isMinimized = true
            }

            simulatorButton("xmark.circle.fill", accessibilityLabel: "Close simulator", action: onClose)
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
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: controlButtonWidth, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? image)
    }

    // MARK: Zoom

    private var zoomBar: some View {
        HStack(spacing: 5) {
            zoomButton("minus") {
                window.displayScale = max(Self.minScale, window.displayScale - Self.resizeStep)
            }

            Text("\(Int(window.displayScale * 100))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 42)

            zoomButton("plus") {
                window.displayScale = min(Self.maxScale, window.displayScale + Self.resizeStep)
            }
        }
        .foregroundColor(.white)
        .frame(width: frameSize.width, height: Self.controlHeight)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func zoomButton(_ image: String, action: @escaping () -> Void) -> some View {
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
            // V4 geometry: WebView has the real device viewport and is
            // visually fitted into the frame hole.
            SimulatorWebCanvas(window: window)

            Image(window.deviceType.frameImageName)
                .resizable()
                .frame(width: portraitFrameSize.width, height: portraitFrameSize.height)
                .rotationEffect(
                    window.orientation == .landscape ? .degrees(-90) : .zero
                )
                // rotationEffect does not change SwiftUI layout bounds by itself.
                // Give the rotated artwork its real landscape bounds so the
                // WebView and frame share exactly the same coordinate space.
                .frame(width: frameSize.width, height: frameSize.height)
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
            if let previewID = manager.previewWindowID,
               let window = manager.windows.first(where: { $0.id == previewID }) {
                SimulatorFullScreenPreview(
                    window: window,
                    onMinimize: { manager.closePreview() },
                    onClose: { manager.close(window) }
                )
                .environmentObject(manager)
                .zIndex(1000)
            } else {
                ForEach(manager.windows) { window in
                    SimulatorDeviceFrameView(
                        window: window,
                        onClose: { manager.close(window) }
                    )
                    .environmentObject(manager)
                    .zIndex(1)
                }
            }
        }
        .allowsHitTesting(!manager.windows.isEmpty)
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

// MARK: - Full-screen preview

/// This is deliberately NOT a device-frame preview. It is the live WKWebView
/// itself filling the whole CodeApp content area, matching the requested
/// "Preview" behavior. The exact same WKWebView instance is reused.
private struct SimulatorFullScreenPreview: View {
    @ObservedObject var window: SimulatorWindowState
    let onMinimize: () -> Void
    let onClose: () -> Void

    @State private var showActions = false
    @State private var floatingPosition = CGPoint(x: 42, y: 88)
    @GestureState private var dragTranslation: CGSize = .zero
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                FullScreenWebView(window: window)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(Color(uiColor: .systemBackground))

                floatingControl
                    .position(
                        x: min(max(floatingPosition.x + dragTranslation.width, 34), max(34, proxy.size.width - 34)),
                        y: min(max(floatingPosition.y + dragTranslation.height, 34), max(34, proxy.size.height - 34))
                    )
            }
            .onChange(of: proxy.size) { _ in
                floatingPosition = CGPoint(
                    x: min(max(floatingPosition.x, 34), max(34, proxy.size.width - 34)),
                    y: min(max(floatingPosition.y, 34), max(34, proxy.size.height - 34))
                )
            }
        }
        .ignoresSafeArea()
    }

    private var floatingControl: some View {
        VStack(spacing: 5) {
            if showActions {
                HStack(spacing: 2) {
                    Button(action: onMinimize) {
                        Image(systemName: "minus")
                            .foregroundColor(.white)
                            .frame(width: 42, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Return preview to simulator")

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                            .frame(width: 42, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close simulator and preview")
                }
                .background(Color.black.opacity(0.88))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            Image(systemName: window.deviceType.sfSymbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .frame(width: 58, height: 58)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .updating($dragTranslation) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            floatingPosition.x += value.translation.width
                            floatingPosition.y += value.translation.height
                        }
                )
                .onTapGesture {
                    showActions.toggle()
                }
        }
    }
}

// MARK: - Full-screen WKWebView

private struct FullScreenWebView: UIViewRepresentable {
    @ObservedObject var window: SimulatorWindowState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.backgroundColor = .systemBackground
        container.clipsToBounds = true
        let webView = window.webViewStore.attach(to: container, for: window)
        webView.transform = .identity
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        context.coordinator.lastURL = window.url
        context.coordinator.lastReloadToken = window.reloadToken
        return container
    }

    func updateUIView(_ container: ContainerView, context: Context) {
        let webView = window.webViewStore.attach(to: container, for: window)
        webView.transform = .identity
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        if context.coordinator.lastURL != window.url {
            context.coordinator.lastURL = window.url
            window.webViewStore.setURL(window.url, for: window)
        }

        if context.coordinator.lastReloadToken != window.reloadToken {
            context.coordinator.lastReloadToken = window.reloadToken
            window.webViewStore.reload(for: window)
        }
    }

    final class Coordinator {
        var lastURL: URL?
        var lastReloadToken: UUID?
    }

    final class ContainerView: UIView {}
}
