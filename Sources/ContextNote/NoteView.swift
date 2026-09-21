import AppKit
import SwiftUI

struct NoteView: View {
    @ObservedObject var store: NoteStore
    private var showToolbar: Bool {
        store.isHovering || store.showingAppearance || store.showingSettings
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                    Button {
                        store.hideNote()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .background(.black.opacity(0.4), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .help("隐藏便签（App 继续运行）")
                    .allowsHitTesting(showToolbar)

                    ZStack(alignment: .leading) {
                        WindowDragArea()
                        Text(store.activeProfile.name)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.leading, 6)
                            .shadow(color: .black.opacity(0.8), radius: 2)
                            .opacity(store.contentOpacity)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    .frame(minWidth: 64)
                    WindowDragArea()
                        .frame(minWidth: 24, maxWidth: .infinity)
                    Button {
                        store.toggleTextLock()
                    } label: {
                        Image(systemName: store.isTextLocked ? "lock.fill" : "lock.open")
                            .frame(width: 24, height: 24)
                            .accessibilityLabel(store.isTextLocked ? "解锁文字" : "锁定文字")
                    }
                    .buttonStyle(.plain)
                    .help(store.isTextLocked ? "解锁文字编辑" : "锁定文字，防止误编辑")
                    .allowsHitTesting(showToolbar)
                    Button {
                        store.showingAppearance.toggle()
                    } label: {
                        Image(systemName: "paintbrush")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("背景设置")
                    .allowsHitTesting(showToolbar)
                    Button {
                        store.showingSettings.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("便签与 App 关联")
                    .allowsHitTesting(showToolbar)
                }
                .foregroundStyle(.white)
                .frame(height: 30)
                .opacity(showToolbar ? 1 : 0)

                NoteTextView(store: store)
                    .id(store.activeProfileID)
                    .background(.black.opacity(store.appearanceMode == .image ? 0.12 : 0))
                    .opacity(store.contentOpacity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { geometry in
                ZStack {
                    VisualEffectBackground(opacity: store.glassOpacity, style: store.glassStyle)
                    if store.appearanceMode == .solid {
                        Color(nsColor: store.solidColor)
                            .opacity(store.contentOpacity)
                    }
                    if let image = store.visibleBackgroundImage {
                        Group {
                            switch store.imageLayout {
                            case .fill:
                                Image(nsImage: image).resizable().scaledToFill()
                            case .fit:
                                Image(nsImage: image).resizable().scaledToFit()
                            case .stretch:
                                Image(nsImage: image).resizable()
                            }
                        }
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .scaleEffect(store.imageZoom)
                            .offset(x: store.imageOffsetX * geometry.size.width * 0.5,
                                    y: store.imageOffsetY * geometry.size.height * 0.5)
                            .clipped()
                            .brightness(store.imageBrightness - 1)
                            .blur(radius: store.imageBlur)
                            .opacity(store.imageOpacity * store.contentOpacity)
                    }
                    // The tint affects the background only; editing controls stay above it.
                    Color.black.opacity(store.appearanceMode == .glass ? 0.08 :
                        (store.appearanceMode == .image ? store.overlayOpacity * store.contentOpacity : 0))
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: store.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: store.cornerRadius)
                .strokeBorder(.white.opacity(0.24))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            WindowDragArea()
                .frame(height: 14)
        }
        .overlay(alignment: .bottomTrailing) {
            ResizeHandle()
                .frame(width: 26, height: 26)
                .padding(4)
                .help("拖动调整便签大小")
        }
        .overlay(alignment: .bottom) {
            if let suggestion = store.suggestion {
                VStack(alignment: .leading, spacing: 8) {
                    Text("检测到 \(suggestion.appName)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("要为它创建专属便签吗？")
                        .font(.caption)
                    HStack(spacing: 10) {
                        Button("创建关联") { store.createSuggestedAssociation() }
                        Button("暂不") { store.snoozeSuggestion() }
                        Button("不再提示") { store.neverSuggestCurrentApp() }
                    }
                    .font(.caption)
                }
                .foregroundStyle(.white)
                .padding(12)
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
                .background(SuggestionCursorBackground())
                .onAppear {
                    DispatchQueue.main.async { NSCursor.arrow.set() }
                }
                .onContinuousHover { phase in
                    if case .active = phase { NSCursor.arrow.set() }
                }
                .padding(12)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.suggestion?.bundleIdentifier)
        .popover(isPresented: $store.showingAppearance) {
            VStack(alignment: .leading, spacing: 14) {
                Text("背景").font(.headline)
                Picker("显示", selection: Binding(
                    get: { store.appearanceMode },
                    set: { store.setAppearanceMode($0) }
                )) {
                    Text("毛玻璃").tag(AppearanceMode.glass)
                    Text("纯色").tag(AppearanceMode.solid)
                    if store.imageData != nil {
                        Text("图片").tag(AppearanceMode.image)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Button("选择图片…") { store.chooseBackground() }
                    if store.imageData != nil {
                        Button("移除图片") { store.removeImage() }
                    }
                }
                if store.appearanceMode == .glass {
                    Picker("毛玻璃样式", selection: Binding(
                        get: { store.glassStyle },
                        set: { store.setGlassStyle($0) }
                    )) {
                        Text("深色").tag(GlassStyle.dark)
                        Text("浅色").tag(GlassStyle.light)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("毛玻璃透明度")
                        Slider(value: Binding(get: { store.glassOpacity }, set: { store.setGlassOpacity($0) }), in: 0.2...1)
                        Text("\(Int(store.glassOpacity * 100))%")
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                } else if store.appearanceMode == .image {
                    HStack {
                        Text("图片透明度")
                        Slider(value: Binding(get: { store.imageOpacity }, set: { store.setImageOpacity($0) }), in: 0...1)
                            .frame(width: 140)
                        Text("\(Int(store.imageOpacity * 100))%")
                            .monospacedDigit()
                    }
                } else if store.appearanceMode == .solid {
                    ColorPicker("背景颜色", selection: Binding(
                        get: { Color(nsColor: store.solidColor) },
                        set: { store.setSolidColor(NSColor($0)) }
                    ), supportsOpacity: false)
                }
                if store.imageData != nil && store.appearanceMode == .image {
                    Picker("填充方式", selection: Binding(get: { store.imageLayout }, set: { store.setImageLayout($0) })) {
                        ForEach(ImageLayout.allCases, id: \.self) { layout in
                            Text(layout.title).tag(layout)
                        }
                    }
                    HStack {
                        Text("图片大小")
                        Slider(value: Binding(get: { store.imageZoom }, set: { store.setImageZoom($0) }), in: 0.5...2)
                        Text("\(Int(store.imageZoom * 100))%")
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                    HStack {
                        Text("亮度")
                        Slider(value: Binding(get: { store.imageBrightness }, set: { store.setImageBrightness($0) }), in: 0.5...1.5)
                        Text("\(Int(store.imageBrightness * 100))%")
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                    HStack {
                        Text("模糊")
                        Slider(value: Binding(get: { store.imageBlur }, set: { store.setImageBlur($0) }), in: 0...16)
                        Text("\(Int(store.imageBlur))")
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                    HStack {
                        Text("遮罩")
                        Slider(value: Binding(get: { store.overlayOpacity }, set: { store.setOverlayOpacity($0) }), in: 0...0.6)
                        Text("\(Int(store.overlayOpacity * 100))%")
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                    HStack {
                        Text("水平位置")
                        Slider(value: Binding(get: { store.imageOffsetX }, set: { store.setImageOffsetX($0) }), in: -1...1)
                    }
                    HStack {
                        Text("垂直位置")
                        Slider(value: Binding(get: { store.imageOffsetY }, set: { store.setImageOffsetY($0) }), in: -1...1)
                    }
                    Button("位置与大小复位") {
                        store.setImageZoom(1)
                        store.setImageOffsetX(0)
                        store.setImageOffsetY(0)
                    }
                }
                HStack {
                    Text("圆角")
                    Slider(value: Binding(get: { store.cornerRadius }, set: { store.setCornerRadius($0) }), in: 6...32)
                    Text("\(Int(store.cornerRadius))")
                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                Divider()
                Picker("文字颜色模式", selection: Binding(
                    get: { store.textColorMode },
                    set: { store.setTextColorMode($0) }
                )) {
                    Text("自动").tag(TextColorMode.automatic)
                    Text("推荐").tag(TextColorMode.suggested)
                    Text("自定义").tag(TextColorMode.custom)
                }
                .pickerStyle(.segmented)
                if store.textColorMode == .automatic {
                    Text("随当前背景、亮度和遮罩自动选择高对比度文字色。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("推荐文字颜色")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ForEach(Array(store.recommendedTextColors.enumerated()), id: \.offset) { index, color in
                            Button {
                                store.setTextColor(color, mode: .suggested)
                            } label: {
                                Circle()
                                    .fill(Color(nsColor: color))
                                    .frame(width: 25, height: 25)
                                    .overlay(Circle().strokeBorder(.primary.opacity(0.35)))
                                    .overlay {
                                        if CodableColor(store.textColor) == CodableColor(color) {
                                            Circle().strokeBorder(.primary, lineWidth: 2).padding(-3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help("应用推荐颜色 \(index + 1)")
                        }
                    }
                }
                ColorPicker("文字颜色", selection: Binding(
                    get: { Color(nsColor: store.textColor) },
                    set: { store.setTextColor(NSColor($0), mode: .custom) }
                ), supportsOpacity: false)
            }
            .padding(18)
            .frame(width: 320)
        }
        .popover(isPresented: $store.showingSettings) {
            RuleSettingsView(store: store)
        }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

private struct ResizeHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { GripView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class GripView: NSView {
        private var startingFrame: NSRect?
        private var startingMouse: NSPoint?

        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.65).setStroke()
            for offset in [0.0, 5.0, 10.0] {
                let line = NSBezierPath()
                line.lineWidth = 1.5
                line.move(to: NSPoint(x: 10 + offset, y: 4))
                line.line(to: NSPoint(x: 22, y: 16 - offset))
                line.stroke()
            }
        }

        override func mouseDown(with event: NSEvent) {
            startingFrame = window?.frame
            startingMouse = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let start = startingFrame, let mouse = startingMouse else { return }
            let point = NSEvent.mouseLocation
            let width = max(window.minSize.width, start.width + point.x - mouse.x)
            let height = max(window.minSize.height, start.height - point.y + mouse.y)
            window.setFrame(NSRect(x: start.minX, y: start.maxY - height,
                                   width: width, height: height), display: true)
        }

        override func mouseUp(with event: NSEvent) {
            startingFrame = nil
            startingMouse = nil
        }
    }
}

private struct SuggestionCursorBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SuggestionCursorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SuggestionCursorView: NSView {
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                          .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }

        override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
        override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
        override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    let opacity: Double
    let style: GlassStyle
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        configure(view)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }
    private func configure(_ view: NSVisualEffectView) {
        view.material = style == .dark ? .hudWindow : .sidebar
        view.appearance = NSAppearance(named: style == .dark ? .darkAqua : .aqua)
        view.alphaValue = opacity
    }
}
