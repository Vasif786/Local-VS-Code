//
// SimulatorWindowView.swift
// CodeApp
//

import SwiftUI
import WebKit
import UIKit

// MARK: - Shared WKWebView canvas

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
        private var lastURL: URL?
        private var lastReloadToken: UUID?

        func update(canvas: CanvasView, window: SimulatorWindowState) {
            let frameSize = SimulatorLayout.frameSize(for: window)
            let hole = SimulatorLayout.screenRect(for: window)
            canvas.frame = CGRect(origin: .zero, size: frameSize)
            canvas.bounds = CGRect(origin: .zero, size: frameSize)
            canvas.clipsToBounds = true

            let web = window.webViewStore.attach(to: canvas)
            web.transform = .identity

            // V4 geometry: keep a real device logical viewport and visually fit
            // it into the supplied frame's screen hole. Landscape swaps the
            // logical viewport dimensions but does not rotate the WebView a
            // second time.
            let viewport = window.deviceType.viewportSize
            let nativeViewport = window.orientation == .portrait
                ? viewport
                : CGSize(width: viewport.height, height: viewport.width)

            web.bounds = CGRect(origin: .zero, size: nativeViewport)
            let scaleX = hole.width / max(nativeViewport.width, 1)
            let scaleY = hole.height / max(nativeViewport.height, 1)
            let scale = min(scaleX, scaleY)
            web.transform = CGAffineTransform(scaleX: scale, y: scale)
            web.center = CGPoint(x: hole.midX, y: hole.midY)
            web.layer.cornerRadius = min(hole.width, hole.height) * 0.035
            web.clipsToBounds = true
            canvas.bringSubviewToFront(web)

            if lastURL != window.url {
                lastURL = window.url
                lastReloadToken = window.reloadToken
                window.webViewStore.load(window.url)
            } else if lastReloadToken != window.reloadToken {
                lastReloadToken = window.reloadToken
                window.webViewStore.load(window.url)
            }
        }
    }

    final class CanvasView: UIView {}
}

// MARK: - Main simulator

struct SimulatorDeviceFrameView: View {
    @ObservedObject var window: SimulatorWindowState
    let onClose: () -> Void

    @EnvironmentObject private var simulatorManager: SimulatorManager
    @State private var showSettings = false
    @State private var showPreview = false
    @State private var previewMinimized = false
    @State private var previewActions = false
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var minimizedDragTranslation: CGSize = .zero

    private static let minScale: CGFloat = 0.38
    private static let maxScale: CGFloat = 1.25
    private static let resizeStep: CGFloat = 0.05
    private static let controlHeight: CGFloat = 30

    private var frameSize: CGSize { SimulatorLayout.frameSize(for: window) }
    private var portraitFrameSize: CGSize { SimulatorLayout.portraitFrameSize(for: window) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // The simulator itself is positioned inside the editor.
                if !window.isMinimized && !showPreview {
                    VStack(spacing: 5) {
                        titleBar
                        controlsBar
                        zoomBar
                        deviceView
                    }
                    .frame(width: frameSize.width)
                    .offset(x: window.position.x + dragTranslation.width,
                            y: window.position.y + dragTranslation.height)
                    .allowsHitTesting(true)
                }

                if window.isMinimized && !showPreview {
                    SimulatorFloatingIcon(device: window.deviceType) {
                        window.isMinimized = false
                    }
                    .offset(x: window.position.x + minimizedDragTranslation.width,
                            y: window.position.y + minimizedDragTranslation.height)
                    .gesture(minimizedDrag)
                }

                // Full Preview is deliberately NOT offset by simulator.position.
                // It occupies the complete editor area, exactly like the video:
                // one tap turns the device simulation into a full-screen preview.
                if showPreview {
                    FullDevicePreview(
                        window: window,
                        onMinimize: {
                            showPreview = false
                            previewMinimized = true
                            previewActions = false
                        },
                        onClose: {
                            showPreview = false
                            previewMinimized = false
                            previewActions = false
                            onClose()
                        }
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .zIndex(100)
                } else if previewMinimized {
                    PreviewFloatingButton(
                        device: window.deviceType,
                        showActions: $previewActions,
                        onMinimize: {
                            // Return from the full preview to the normal simulator.
                            previewMinimized = false
                            previewActions = false
                        },
                        onClose: {
                            previewMinimized = false
                            previewActions = false
                            onClose()
                        }
                    )
                    .zIndex(110)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .sheet(isPresented: $showSettings) {
            SimulatorSettingsView(deviceType: window.deviceType)
                .environmentObject(simulatorManager)
        }
    }

    // MARK: Main movement

    private var titleBar: some View {
        HStack(spacing: 7) {
            Image(systemName: window.isMoveMode ? "hand.draw.fill" : "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(window.deviceType.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Capsule()
                .fill(Color.white.opacity(window.isMoveMode ? 0.95 : 0.28))
                .frame(width: 42, height: 4)
            Spacer(minLength: 4)
            Text(window.orientation.title)
                .font(.system(size: 10, weight: .medium))
                .opacity(0.55)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 9)
        .frame(width: frameSize.width, height: Self.controlHeight)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .gesture(mainDrag)
    }

    private var mainDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in
                guard window.isMoveMode else { return }
                state = value.translation
            }
            .onEnded { value in
                guard window.isMoveMode else { return }
                window.position.x += value.translation.width
                window.position.y += value.translation.height
            }
    }

    // MARK: Controls

    private var controlsBar: some View {
        HStack(spacing: 3) {
            simButton("gearshape.fill", "Settings") { showSettings = true }
            simButton("arrow.clockwise", "Reload") { window.reloadToken = UUID() }
            simButton("rotate.right", "Rotate") {
                window.orientation = window.orientation == .portrait ? .landscape : .portrait
            }
            simButton("eye.fill", "Full preview") {
                previewActions = false
                previewMinimized = false
                showPreview = true
            }
            simButton(window.isMoveMode ? "lock.open.fill" : "location.fill", "Move/Lock") {
                window.isMoveMode.toggle()
            }
            simButton("minus.circle.fill", "Minimize") { window.isMinimized = true }
            simButton("xmark.circle.fill", "Close", action: onClose)
        }
        .frame(width: frameSize.width, height: Self.controlHeight)
        .padding(.horizontal, 7)
        .background(Color.black.opacity(0.80))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func simButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
        .background(Color.black.opacity(0.80))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func zoomButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 26)
        }
        .buttonStyle(.plain)
    }

    // MARK: Device frame

    private var deviceView: some View {
        ZStack {
            // V4 WebView system restored: the WKWebView keeps the real device
            // viewport and gets a visual fit transform. The frame PNG is on top.
            SimulatorWebCanvas(window: window)

            Image(window.deviceType.frameImageName)
                .resizable()
                .frame(width: portraitFrameSize.width, height: portraitFrameSize.height)
                .rotationEffect(window.orientation == .landscape ? .degrees(-90) : .zero)
                .allowsHitTesting(false)
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .clipped()
        .animation(.easeInOut(duration: 0.16), value: window.orientation)
        .animation(.easeInOut(duration: 0.12), value: window.displayScale)
    }

    private var minimizedDrag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($minimizedDragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                window.position.x += value.translation.width
                window.position.y += value.translation.height
            }
    }
}

private struct SimulatorFloatingIcon: View {
    let device: SimulatorDeviceType
    let onRestore: () -> Void

    var body: some View {
        Image(systemName: device.sfSymbol)
            .font(.system(size: 24, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: 58, height: 58)
            .background(Color.black.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .shadow(radius: 8)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onRestore)
    }
}

// MARK: - Full preview

private struct FullDevicePreview: View {
    @ObservedObject var window: SimulatorWindowState
    let onMinimize: () -> Void
    let onClose: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                FullPreviewCanvas(window: window)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                HStack(spacing: 8) {
                    Image(systemName: window.deviceType.sfSymbol)
                        .foregroundColor(.white)
                    Text("Preview • \(window.deviceType.displayName)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: onMinimize) {
                        Image(systemName: "minus")
                            .foregroundColor(.white)
                            .frame(width: 34, height: 30)
                    }
                    .buttonStyle(.plain)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                            .frame(width: 34, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 40)
                .background(Color.black.opacity(0.88))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .padding(.top, 10)
                .padding(.horizontal, 10)
            }
        }
        .ignoresSafeArea()
    }
}

private struct FullPreviewCanvas: View {
    @ObservedObject var window: SimulatorWindowState

    var body: some View {
        GeometryReader { proxy in
            let base = SimulatorLayout.frameSize(for: window)
            let availableWidth = max(1, proxy.size.width - 32)
            let availableHeight = max(1, proxy.size.height - 72)
            let scale = min(availableWidth / max(base.width, 1),
                            availableHeight / max(base.height, 1))

            ZStack {
                SimulatorWebCanvas(window: window)
                    .frame(width: base.width, height: base.height)

                Image(window.deviceType.frameImageName)
                    .resizable()
                    .frame(width: SimulatorLayout.portraitFrameSize(for: window).width,
                           height: SimulatorLayout.portraitFrameSize(for: window).height)
                    .rotationEffect(window.orientation == .landscape ? .degrees(-90) : .zero)
                    .allowsHitTesting(false)
            }
            .frame(width: base.width, height: base.height)
            .scaleEffect(scale)
            .position(x: proxy.size.width / 2,
                      y: proxy.size.height / 2 + 18)
        }
    }
}

// MARK: - Preview floating control

private struct PreviewFloatingButton: View {
    let device: SimulatorDeviceType
    @Binding var showActions: Bool
    let onMinimize: () -> Void
    let onClose: () -> Void

    @State private var baseOffset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        VStack(spacing: 6) {
            if showActions {
                HStack(spacing: 6) {
                    Button(action: onMinimize) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 29))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Minimize preview")

                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 29))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close simulator and preview")
                }
                .padding(5)
                .background(Color.black.opacity(0.90))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Image(systemName: device.sfSymbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 58, height: 58)
                .background(Color.black.opacity(0.94))
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                .shadow(radius: 8)
                .contentShape(Rectangle())
                .offset(drag)
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            baseOffset.width += value.translation.width
                            baseOffset.height += value.translation.height
                        }
                )
                .offset(baseOffset)
                .onTapGesture(count: 2) { showActions.toggle() }
        }
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
                        guard let url = URL(string: value), url.scheme != nil else { return }
                        simulatorManager.saveURL(url, for: deviceType)
                        dismiss()
                    }
                }

                Section("Simulator") {
                    Text("Device: \(deviceType.displayName)")
                    Text("Viewport: \(Int(deviceType.viewportSize.width)) × \(Int(deviceType.viewportSize.height))")
                        .font(.caption)
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
                SimulatorDeviceFrameView(window: window, onClose: { manager.close(window) })
                    .environmentObject(manager)
            }
        }
        .allowsHitTesting(true)
        .confirmationDialog("Open Simulator",
                            isPresented: $manager.showDevicePicker,
                            titleVisibility: .visible) {
            Button("iPhone 14 Pro") { manager.open(deviceType: .iPhone14Pro) }
            Button("iPad (5th generation)") { manager.open(deviceType: .iPadPro) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
