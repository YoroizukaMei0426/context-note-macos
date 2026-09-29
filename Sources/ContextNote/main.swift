import AppKit
import CoreGraphics
import SwiftUI

private final class NotePanel: NSPanel {
    var handleLockedUndo: ((Bool) -> Bool)?
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.charactersIgnoringModifiers?.lowercased() == "z",
           modifiers.contains(.command),
           handleLockedUndo?(modifiers.contains(.shift)) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && level == .normal {
            orderFrontRegardless()
        }
        super.sendEvent(event)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let store = NoteStore()
    private var window: NSWindow!
    private var hoverTimer: Timer?
    private var statusItem: NSStatusItem?
    private var noteVisibilityMenuItem: NSMenuItem?
    private var visibilityTask: Task<Void, Never>?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var hiddenForFullscreen = true
    private var hiddenByUser = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        updateStatusItemVisibility()
        let startFrame = store.restoredFrame() ?? NSRect(x: 120, y: 320, width: 360, height: 440)
        let panel = NotePanel(
            contentRect: startFrame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.handleLockedUndo = { [weak self] isRedo in
            guard let self, store.isTextLocked else { return false }
            if !isRedo { _ = store.performTransientTaskUndo?() }
            return true
        }
        panel.title = "情境便签"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        // A nonactivating utility panel can join and stay above another app's full-screen Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                    .fullScreenAuxiliary, .stationary]
        panel.minSize = NSSize(width: 240, height: 200)
        panel.isMovableByWindowBackground = false
        window = panel
        store.panelWindow = panel
        store.updateBackgroundDecodeLimit(for: panel)
        panel.contentView = NSHostingView(rootView: NoteView(store: store))
        panel.delegate = self
        store.windowBehaviorChanged = { [weak self] in self?.refreshFullscreenVisibility() }
        store.statusItemVisibilityChanged = { [weak self] in self?.updateStatusItemVisibility() }
        store.noteHiddenByUser = { [weak self] in self?.hiddenByUser = true }
        let pressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        pressureSource.setEventHandler { [weak self] in
            Task { @MainActor in self?.store.handleMemoryPressure() }
        }
        pressureSource.resume()
        memoryPressureSource = pressureSource
        // Polling the pointer works even while this nonactivating panel is not the frontmost app.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateHover() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        store.refreshForFrontmostApp()
        refreshFullscreenVisibility()
    }

    private func updateHover() {
        guard let window else { return }
        let frame = store.isHovering ? window.frame.insetBy(dx: -10, dy: -10) : window.frame
        let hovering = frame.contains(NSEvent.mouseLocation)
        if store.isHovering != hovering { store.isHovering = hovering }
    }

    @objc private func frontmostAppChanged(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        store.handleActivatedApp(app)
        scheduleFullscreenVisibilityRefresh()
    }

    @objc private func activeSpaceChanged(_ notification: Notification) {
        // The new Space's windows may not be listed until its transition completes.
        scheduleFullscreenVisibilityRefresh()
    }

    private func scheduleFullscreenVisibilityRefresh() {
        visibilityTask?.cancel()
        visibilityTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.refreshFullscreenVisibility()
        }
    }

    private func refreshFullscreenVisibility() {
        let app = NSWorkspace.shared.frontmostApplication
        let fullscreen = isFullscreen(app)
        let policy = store.showInFullscreen(for: app?.bundleIdentifier)
        let shouldHide = fullscreen && !policy
        // Follow regular desktops only when requested; a visible full-screen note
        // still joins that App's Space under its separate per-App policy.
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllApplications,
                                                     .fullScreenAuxiliary, .stationary]
        if store.showOnAllSpaces || (fullscreen && policy) {
            behavior.insert(.canJoinAllSpaces)
        }
        if window.collectionBehavior != behavior { window.collectionBehavior = behavior }
        // The full-screen display choice takes priority over normal desktop stacking.
        let level: NSWindow.Level = fullscreen && policy ? .screenSaver :
            (store.alwaysOnTop ? .floating : .normal)
        if window.level != level { window.level = level }
        guard shouldHide != hiddenForFullscreen else { return }
        hiddenForFullscreen = shouldHide
        if shouldHide {
            store.suspendBackgroundRendering()
            window.orderOut(nil)
        } else if !hiddenByUser {
            store.resumeBackgroundRendering()
            window.orderFrontRegardless()
        }
    }

    private func isFullscreen(_ app: NSRunningApplication?) -> Bool {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let displays: [CGRect] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
        guard !displays.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return false }
            let windowFrame = CGRect(x: x, y: y, width: width, height: height)
            return displays.contains { display in
                let intersection = windowFrame.intersection(display)
                return !intersection.isNull &&
                    intersection.width / display.width >= 0.95 &&
                    intersection.height / display.height >= 0.90
            }
        }
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "关于情境便签",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "便签与 App 关联…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出情境便签", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key, modifiers): (String, Selector, String, NSEvent.ModifierFlags) in [
            ("撤销", Selector(("undo:")), "z", [.command]),
            ("重做", Selector(("redo:")), "z", [.command, .shift]),
            ("剪切", #selector(NSText.cut(_:)), "x", [.command]),
            ("复制", #selector(NSText.copy(_:)), "c", [.command]),
            ("粘贴", #selector(NSText.paste(_:)), "v", [.command]),
            ("全选", #selector(NSText.selectAll(_:)), "a", [.command])
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "帮助")
        let guideItem = NSMenuItem(title: "情境便签使用说明…", action: #selector(showHelp(_:)), keyEquivalent: "")
        guideItem.target = self
        helpMenu.addItem(guideItem)
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.mainMenu = mainMenu
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "情境便签")
        let menu = NSMenu()
        menu.delegate = self
        let visibilityItem = NSMenuItem(title: "隐藏便签", action: #selector(toggleNoteVisibility(_:)), keyEquivalent: "")
        visibilityItem.target = self
        menu.addItem(visibilityItem)
        noteVisibilityMenuItem = visibilityItem
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings(_:)), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出情境便签", action: #selector(quit(_:)), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    private func updateStatusItemVisibility() {
        if store.showStatusItem {
            if statusItem == nil { installStatusItem() }
            NSApp.setActivationPolicy(.accessory)
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            noteVisibilityMenuItem = nil
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        noteVisibilityMenuItem?.title = window.isVisible ? "隐藏便签" : "显示便签"
    }

    @objc private func toggleNoteVisibility(_ sender: Any?) {
        if window.isVisible {
            store.hideNote()
        } else {
            showNote(sender)
        }
    }

    @objc private func showNote(_ sender: Any?) {
        hiddenByUser = false
        store.resumeBackgroundRendering()
        window.orderFrontRegardless()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showNote(nil) }
        return true
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    @objc private func showSettings(_ sender: Any?) {
        hiddenByUser = false
        store.showingSettings = true
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func showHelp(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "情境便签使用说明"
        alert.informativeText = """
        • 点击正文即可编辑；文字会自动保存。
        • 从便签顶部拖动窗口，从右下角调整大小。
        • 锁定按钮只锁定正文，任务完成按钮仍可使用。
        • 齿轮用于管理便签和 App 关联，画笔用于调整外观。
        • 左上角叉号只隐藏便签；右键叉号可以退出 App。
        • 显示菜单栏图标时会隐藏 Dock 图标；关闭菜单栏图标时会恢复 Dock 图标。
        • 按 Command-Q，或从 Dock、菜单栏菜单中退出 App。
        """
        alert.addButton(withTitle: "知道了")
        alert.window.level = .floating
        alert.runModal()
    }

    func windowDidMove(_ notification: Notification) { persistFrame() }
    func windowDidResize(_ notification: Notification) {
        if let window { store.updateBackgroundDecodeLimit(for: window) }
        persistFrame()
    }
    func applicationWillTerminate(_ notification: Notification) { store.flushText() }

    private func persistFrame() {
        guard let window else { return }
        store.save(frame: window.frame)
    }
}

@main
enum ContextNoteApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
