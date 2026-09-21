import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct NoteProfile: Identifiable, Codable {
    var id: UUID
    var name: String
    var text: String
    var imageData: Data?
    var imageOpacity: Double
    // Optional fields keep profiles from earlier builds readable.
    var imageLayout: ImageLayout? = nil
    var imageZoom: Double? = nil
    var imageOffsetX: Double? = nil
    var imageOffsetY: Double? = nil
    var imageBrightness: Double? = nil
    var overlayOpacity: Double? = nil
    var appearanceMode: AppearanceMode? = nil
    var glassOpacity: Double? = nil
    var textColor: CodableColor? = nil
    var textColorMode: TextColorMode? = nil
    var imageBlur: Double? = nil
    var cornerRadius: Double? = nil
    var solidColor: CodableColor? = nil
    var glassStyle: GlassStyle? = nil
    var completedLineIndexes: [Int]? = nil
    var textLocked: Bool? = nil
}

struct CodableColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? .white
        red = Double(rgb.redComponent)
        green = Double(rgb.greenComponent)
        blue = Double(rgb.blueComponent)
        alpha = Double(rgb.alphaComponent)
    }

    var nsColor: NSColor {
        NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }
}

enum AppearanceMode: String, Codable {
    case glass, image, solid
}

enum GlassStyle: String, Codable {
    case dark, light
}

enum TextColorMode: String, Codable {
    case automatic, suggested, custom
}

enum CompletionBehavior: String, CaseIterable {
    case strikethrough, delete

    var title: String {
        switch self {
        case .strikethrough: "划掉文字"
        case .delete: "直接删除"
        }
    }
}

enum ImageLayout: String, Codable, CaseIterable {
    case fill, fit, stretch
    var title: String {
        switch self {
        case .fill: "铺满（裁剪）"
        case .fit: "完整显示"
        case .stretch: "拉伸"
        }
    }
}

struct AppRule: Identifiable, Codable {
    var id: UUID
    var bundleIdentifier: String
    var appName: String
    var appPath: String
    var profileID: UUID
    var enabled: Bool
    // Optional so rules saved by the previous build still decode as manual rules.
    var source: RuleSource?
    var showInFullscreen: Bool? = nil
}

enum RuleSource: String, Codable { case manual, suggested }

struct AppSuggestion: Identifiable {
    var id: String { bundleIdentifier }
    var bundleIdentifier: String
    var appName: String
    var appPath: String
}

private struct NoteBackup: Codable {
    var formatVersion: Int
    var exportedAt: Date
    var profiles: [NoteProfile]
    var rules: [AppRule]
    var preferences: BackupPreferences? = nil
}

private struct BackupPreferences: Codable {
    var alwaysOnTop: Bool
    var showOnAllSpaces: Bool
    var showStatusItem: Bool
    var defaultShowInFullscreen: Bool
    var suggestionsEnabled: Bool
    var completionBehavior: String
    var ignoredSuggestionIDs: [String]
    var windowFrame: String?
}

@MainActor
final class NoteStore: ObservableObject {
    weak var panelWindow: NSWindow?
    var windowBehaviorChanged: (() -> Void)?
    var statusItemVisibilityChanged: (() -> Void)?
    var editorSnapshot: (() -> (UUID, String)?)?
    @Published var isHovering = false
    @Published var showingAppearance = false
    @Published var showingSettings = false
    @Published var alwaysOnTop: Bool {
        didSet {
            defaults.set(alwaysOnTop, forKey: "alwaysOnTop")
            windowBehaviorChanged?()
        }
    }
    @Published var showOnAllSpaces: Bool {
        didSet {
            defaults.set(showOnAllSpaces, forKey: "showOnAllSpaces")
            windowBehaviorChanged?()
        }
    }
    @Published var showStatusItem: Bool {
        didSet {
            defaults.set(showStatusItem, forKey: "showStatusItem")
            statusItemVisibilityChanged?()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { updateLaunchAtLoginRegistration() }
    }
    @Published var completionBehavior: CompletionBehavior {
        didSet { defaults.set(completionBehavior.rawValue, forKey: "completionBehavior") }
    }
    @Published private(set) var launchAtLoginMessage: String?
    @Published var defaultShowInFullscreen: Bool {
        didSet {
            defaults.set(defaultShowInFullscreen, forKey: "defaultShowInFullscreen")
            windowBehaviorChanged?()
        }
    }
    @Published var newProfileName = ""
    @Published var suggestion: AppSuggestion?
    @Published private(set) var contentOpacity = 1.0
    @Published var suggestionsEnabled: Bool {
        didSet {
            defaults.set(suggestionsEnabled, forKey: "suggestionsEnabled")
            if !suggestionsEnabled { suggestionTask?.cancel(); suggestion = nil }
        }
    }
    @Published private(set) var profiles: [NoteProfile] {
        didSet { if !deferringTextPersistence { persistProfiles() } }
    }
    @Published private(set) var rules: [AppRule] { didSet { persistRules() } }
    @Published private(set) var activeProfileID: UUID

    private let defaults: UserDefaults
    private let frameKey = "noteWindowFrame"
    private var suggestionTask: Task<Void, Never>?
    private var switchTask: Task<Void, Never>?
    private var lastActivatedBundleID: String?
    private var ignoredSuggestionIDs: Set<String>
    private var snoozedSuggestionIDs = Set<String>()
    private var imageCache: [UUID: NSImage] = [:]
    private var deferringTextPersistence = false
    private var textPersistenceTask: Task<Void, Never>?
    private var updatingLaunchAtLogin = false

    var defaultProfileID: UUID { profiles[0].id }
    var activeProfile: NoteProfile { profiles.first { $0.id == activeProfileID } ?? profiles[0] }
    var text: String { activeProfile.text }
    var completedLineIndexes: Set<Int> { Set(activeProfile.completedLineIndexes ?? []) }
    var isTextLocked: Bool { activeProfile.textLocked ?? false }
    var imageData: Data? { activeProfile.imageData }
    var backgroundImage: NSImage? {
        let profile = activeProfile
        guard let data = profile.imageData else { return nil }
        if let cached = imageCache[profile.id] { return cached }
        let image = NSImage(data: data)
        imageCache[profile.id] = image
        return image
    }
    var imageOpacity: Double { activeProfile.imageOpacity }
    var imageLayout: ImageLayout { activeProfile.imageLayout ?? .fill }
    var imageZoom: Double { activeProfile.imageZoom ?? 1 }
    var imageOffsetX: Double { activeProfile.imageOffsetX ?? 0 }
    var imageOffsetY: Double { activeProfile.imageOffsetY ?? 0 }
    var imageBrightness: Double { activeProfile.imageBrightness ?? 1 }
    var overlayOpacity: Double { activeProfile.overlayOpacity ?? 0.16 }
    var imageBlur: Double { activeProfile.imageBlur ?? 0 }
    var cornerRadius: Double { activeProfile.cornerRadius ?? 18 }
    var solidColor: NSColor {
        activeProfile.solidColor?.nsColor ?? NSColor(deviceRed: 0.12, green: 0.14, blue: 0.18, alpha: 1)
    }
    var appearanceMode: AppearanceMode {
        activeProfile.appearanceMode ?? (activeProfile.imageData == nil ? .glass : .image)
    }
    var glassOpacity: Double { activeProfile.glassOpacity ?? 1 }
    var glassStyle: GlassStyle { activeProfile.glassStyle ?? .dark }
    var textColorMode: TextColorMode { activeProfile.textColorMode ?? .custom }
    var textColor: NSColor {
        textColorMode == .automatic ? (recommendedTextColors.first ?? .white) :
            (activeProfile.textColor?.nsColor ?? .white)
    }
    var visibleBackgroundImage: NSImage? {
        appearanceMode == .image ? backgroundImage : nil
    }
    var recommendedTextColors: [NSColor] {
        if appearanceMode == .solid {
            return Self.coordinatedTextColors(for: solidColor)
        }
        if appearanceMode == .glass {
            let estimatedBackground = glassStyle == .light
                ? NSColor(deviceRed: 0.88, green: 0.90, blue: 0.94, alpha: 1)
                : NSColor(deviceRed: 0.12, green: 0.14, blue: 0.18, alpha: 1)
            return Self.coordinatedTextColors(for: estimatedBackground)
        }
        guard appearanceMode == .image, let image = backgroundImage else {
            return [
                NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1),
                NSColor(deviceRed: 0.94, green: 0.96, blue: 1, alpha: 1),
                NSColor(deviceRed: 1, green: 0.96, blue: 0.91, alpha: 1),
                NSColor(deviceRed: 0.86, green: 0.88, blue: 0.92, alpha: 1)
            ]
        }
        return Self.palette(for: image, brightness: imageBrightness, overlay: overlayOpacity)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        alwaysOnTop = defaults.object(forKey: "alwaysOnTop") as? Bool ?? true
        showOnAllSpaces = defaults.object(forKey: "showOnAllSpaces") as? Bool ?? true
        showStatusItem = defaults.object(forKey: "showStatusItem") as? Bool ?? true
        let loginStatus = SMAppService.mainApp.status
        launchAtLogin = loginStatus == .enabled || loginStatus == .requiresApproval
        launchAtLoginMessage = loginStatus == .requiresApproval ? "需要在系统设置的登录项中批准" : nil
        completionBehavior = CompletionBehavior(rawValue: defaults.string(forKey: "completionBehavior") ?? "") ?? .strikethrough
        defaultShowInFullscreen = defaults.object(forKey: "defaultShowInFullscreen") as? Bool ?? true
        suggestionsEnabled = defaults.object(forKey: "suggestionsEnabled") as? Bool ?? true
        ignoredSuggestionIDs = Set(defaults.stringArray(forKey: "ignoredSuggestionIDs") ?? [])
        let loadedProfiles: [NoteProfile]
        if let data = defaults.data(forKey: "profiles"),
           let saved = Self.decodeProfiles(from: data) {
            loadedProfiles = saved
        } else if let backupData = defaults.data(forKey: "profilesBackup"),
                  let saved = Self.decodeProfiles(from: backupData) {
            loadedProfiles = saved
            defaults.set(backupData, forKey: "profiles")
        } else {
            // Import the original MVP note on first launch after this upgrade.
            loadedProfiles = [NoteProfile(id: UUID(), name: "今日总计划",
                text: defaults.string(forKey: "noteText") ?? "今天：\n- 算法\n- Java\n- 作业",
                imageData: defaults.data(forKey: "backgroundImage"),
                imageOpacity: defaults.object(forKey: "imageOpacity") as? Double ?? 0.65)]
        }
        profiles = loadedProfiles
        if let data = defaults.data(forKey: "appRules"),
           let saved = try? JSONDecoder().decode([AppRule].self, from: data) {
            rules = saved
        } else if let backupData = defaults.data(forKey: "appRulesBackup"),
                  let saved = try? JSONDecoder().decode([AppRule].self, from: backupData) {
            rules = saved
            defaults.set(backupData, forKey: "appRules")
        } else {
            rules = []
        }
        activeProfileID = loadedProfiles[0].id
    }

    func setText(_ value: String, for profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[index].text != value else { return }
        let reconciled = Self.reconcileCompletedLines(
            oldText: profiles[index].text,
            newText: value,
            completed: Set(profiles[index].completedLineIndexes ?? [])
        )
        deferringTextPersistence = true
        profiles[index].text = value
        profiles[index].completedLineIndexes = reconciled.sorted()
        deferringTextPersistence = false
        textPersistenceTask?.cancel()
        textPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistProfiles()
        }
    }

    func flushText() {
        if let (id, value) = editorSnapshot?() { setText(value, for: id) }
        guard textPersistenceTask != nil else { return }
        textPersistenceTask?.cancel()
        textPersistenceTask = nil
        persistProfiles()
    }
    func hideNote() {
        flushText()
        showingAppearance = false
        showingSettings = false
        panelWindow?.orderOut(nil)
    }
    func toggleCompletedLine(_ lineIndex: Int) {
        updateActive { profile in
            var completed = Set(profile.completedLineIndexes ?? [])
            if !completed.insert(lineIndex).inserted { completed.remove(lineIndex) }
            profile.completedLineIndexes = completed.sorted()
        }
    }

    func toggleTextLock() {
        flushText()
        updateActive { $0.textLocked = !($0.textLocked ?? false) }
    }

    private func updateLaunchAtLoginRegistration() {
        guard !updatingLaunchAtLogin else { return }
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status == .notRegistered { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            launchAtLoginMessage = service.status == .requiresApproval
                ? "需要在系统设置的登录项中批准" : nil
        } catch {
            launchAtLoginMessage = "无法修改登录项：\(error.localizedDescription)"
            updatingLaunchAtLogin = true
            launchAtLogin = service.status == .enabled || service.status == .requiresApproval
            updatingLaunchAtLogin = false
        }
    }

    private static func reconcileCompletedLines(oldText: String, newText: String,
                                                completed: Set<Int>) -> Set<Int> {
        guard !completed.isEmpty else { return [] }
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")
        let rows = oldLines.count, columns = newLines.count
        var table = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
        if rows > 0 && columns > 0 {
            for oldIndex in stride(from: rows - 1, through: 0, by: -1) {
                for newIndex in stride(from: columns - 1, through: 0, by: -1) {
                    table[oldIndex][newIndex] = oldLines[oldIndex] == newLines[newIndex]
                        ? table[oldIndex + 1][newIndex + 1] + 1
                        : max(table[oldIndex + 1][newIndex], table[oldIndex][newIndex + 1])
                }
            }
        }
        var result = Set<Int>(), oldIndex = 0, newIndex = 0
        while oldIndex < rows && newIndex < columns {
            if oldLines[oldIndex] == newLines[newIndex] {
                if completed.contains(oldIndex) { result.insert(newIndex) }
                oldIndex += 1; newIndex += 1
            } else if table[oldIndex + 1][newIndex] >= table[oldIndex][newIndex + 1] {
                oldIndex += 1
            } else {
                newIndex += 1
            }
        }
        return result
    }
    func setImageOpacity(_ value: Double) { updateActive { $0.imageOpacity = value } }
    func setImageLayout(_ value: ImageLayout) { updateActive { $0.imageLayout = value } }
    func setImageZoom(_ value: Double) { updateActive { $0.imageZoom = value } }
    func setImageOffsetX(_ value: Double) { updateActive { $0.imageOffsetX = value } }
    func setImageOffsetY(_ value: Double) { updateActive { $0.imageOffsetY = value } }
    func setImageBrightness(_ value: Double) { updateActive { $0.imageBrightness = value } }
    func setOverlayOpacity(_ value: Double) { updateActive { $0.overlayOpacity = value } }
    func setImageBlur(_ value: Double) { updateActive { $0.imageBlur = value } }
    func setCornerRadius(_ value: Double) { updateActive { $0.cornerRadius = value } }
    func setSolidColor(_ color: NSColor) { updateActive { $0.solidColor = CodableColor(color) } }
    func setAppearanceMode(_ mode: AppearanceMode) {
        guard mode != .image || imageData != nil else { return }
        updateActive { $0.appearanceMode = mode }
    }
    func setGlassOpacity(_ value: Double) { updateActive { $0.glassOpacity = value } }
    func setGlassStyle(_ style: GlassStyle) { updateActive { $0.glassStyle = style } }
    func setTextColorMode(_ mode: TextColorMode) { updateActive { $0.textColorMode = mode } }
    func setTextColor(_ color: NSColor, mode: TextColorMode = .custom) {
        updateActive { $0.textColor = CodableColor(color); $0.textColorMode = mode }
    }
    func removeImage() {
        imageCache.removeValue(forKey: activeProfileID)
        updateActive { $0.imageData = nil; $0.appearanceMode = .glass }
    }

    private func updateActive(_ change: (inout NoteProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
        change(&profiles[index])
    }

    private static func palette(for image: NSImage, brightness: Double, overlay: Double) -> [NSColor] {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return [.white] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24),
                   from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        struct Bucket { var count = 0; var red = 0.0; var green = 0.0; var blue = 0.0 }
        var buckets: [Int: Bucket] = [:]
        for y in 0..<24 {
            for x in 0..<24 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.1 else { continue }
                let r = Double(color.redComponent), g = Double(color.greenComponent), b = Double(color.blueComponent)
                let key = Int(r * 3) * 16 + Int(g * 3) * 4 + Int(b * 3)
                var bucket = buckets[key] ?? Bucket()
                bucket.count += 1; bucket.red += r; bucket.green += g; bucket.blue += b
                buckets[key] = bucket
            }
        }
        guard let dominant = buckets.values.max(by: { $0.count < $1.count }), dominant.count > 0 else {
            return [.white]
        }
        let shade = max(0, 1 - overlay)
        let r = min(1, dominant.red / Double(dominant.count) * brightness) * shade
        let g = min(1, dominant.green / Double(dominant.count) * brightness) * shade
        let b = min(1, dominant.blue / Double(dominant.count) * brightness) * shade
        let background = NSColor(deviceRed: r, green: g, blue: b, alpha: 1)
        return coordinatedTextColors(for: background)
    }

    private static func coordinatedTextColors(for backgroundColor: NSColor) -> [NSColor] {
        let background = backgroundColor.usingColorSpace(.deviceRGB) ?? backgroundColor
        let r = Double(background.redComponent)
        let g = Double(background.greenComponent)
        let b = Double(background.blueComponent)
        var hue: CGFloat = 0, saturation: CGFloat = 0, value: CGFloat = 0, alpha: CGFloat = 0
        background.getHue(&hue, saturation: &saturation, brightness: &value, alpha: &alpha)
        let luminance = relativeLuminance(r: r, g: g, b: b)
        let lightText = luminance < 0.40
        let values: [CGFloat] = lightText ? [0.99, 0.94, 0.88, 0.92] : [0.04, 0.10, 0.16, 0.12]
        let hues: [CGFloat] = [hue, hue + 0.06, hue - 0.08, hue + 0.5]
        let saturations: [CGFloat] = [0.03, min(0.22, saturation * 0.45),
                                     min(0.30, saturation * 0.6), min(0.18, saturation * 0.35)]
        var result: [NSColor] = []
        for index in 0..<4 {
            let wrappedHue = hues[index] - floor(hues[index])
            let candidate = NSColor(deviceHue: wrappedHue, saturation: saturations[index],
                                    brightness: values[index], alpha: 1)
            if contrast(candidate, background) >= 4.5 { result.append(candidate) }
        }
        let fallback: NSColor = lightText ? .white : .black
        while result.count < 4 { result.append(fallback.withAlphaComponent(1)) }
        return result
    }

    private static func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            return relativeLuminance(r: Double(rgb.redComponent), g: Double(rgb.greenComponent),
                                     b: Double(rgb.blueComponent))
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    func addProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = NoteProfile(id: UUID(), name: name.isEmpty ? "新便签 \(profiles.count)" : name,
                                  text: "", imageData: nil, imageOpacity: 0.65)
        profiles.append(profile)
        newProfileName = ""
        switchProfile(to: profile.id)
    }

    func selectProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        switchProfile(to: id)
    }

    func canDeleteProfile(_ id: UUID) -> Bool {
        id != defaultProfileID && !rules.contains(where: { $0.profileID == id })
    }

    func deleteProfile(_ id: UUID) {
        guard canDeleteProfile(id), let profile = profiles.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "删除“\(profile.name)”？"
        alert.informativeText = "此便签的文字和背景会被删除。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard runSystemModal({ alert.runModal() }) == .alertFirstButtonReturn else { return }
        flushText()
        switchTask?.cancel()
        contentOpacity = 1
        if activeProfileID == id {
            activeProfileID = defaultProfileID
        }
        profiles.removeAll { $0.id == id }
    }

    private func switchProfile(to id: UUID) {
        switchTask?.cancel()
        flushText()
        guard activeProfileID != id else {
            contentOpacity = 1
            return
        }
        activeProfileID = id
        contentOpacity = 1
    }

    func renameProfile(_ id: UUID, to name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
    }

    func addAppRule() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.message = "选择要关联便签的 App"
        guard runSystemModal({ panel.runModal() }) == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        if let index = rules.firstIndex(where: { $0.bundleIdentifier == bundleID }) {
            rules[index].profileID = activeProfileID
            rules[index].enabled = true
            rules[index].appPath = url.path
            rules[index].appName = name
            rules[index].source = .manual
        } else {
            rules.append(AppRule(id: UUID(), bundleIdentifier: bundleID, appName: name,
                                 appPath: url.path, profileID: activeProfileID, enabled: true, source: .manual))
        }
        suggestionTask?.cancel()
        suggestion = nil
        refreshForFrontmostApp()
        windowBehaviorChanged?()
    }

    func setRuleProfile(_ id: UUID, profileID: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }),
              profiles.contains(where: { $0.id == profileID }) else { return }
        rules[index].profileID = profileID
        rules[index].source = .manual
        refreshForFrontmostApp()
    }

    func setRuleEnabled(_ id: UUID, enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled = enabled
        rules[index].source = .manual
        refreshForFrontmostApp()
        windowBehaviorChanged?()
    }

    func setRuleShowInFullscreen(_ id: UUID, show: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].showInFullscreen = show
        rules[index].source = .manual
        windowBehaviorChanged?()
    }

    func showInFullscreen(for bundleID: String?) -> Bool {
        guard let bundleID,
              let rule = rules.first(where: { rule in
                  rule.enabled && rule.bundleIdentifier == bundleID &&
                  profiles.contains(where: { $0.id == rule.profileID })
              }) else {
            return defaultShowInFullscreen
        }
        return rule.showInFullscreen ?? true
    }

    func deleteRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
        refreshForFrontmostApp()
        windowBehaviorChanged?()
    }

    func handleActivatedApp(_ app: NSRunningApplication?) {
        guard let bundleID = app?.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else { return }
        lastActivatedBundleID = bundleID
        suggestionTask?.cancel()
        suggestion = nil
        let existingRule = rules.first { $0.bundleIdentifier == bundleID }
        let match = rules.first { rule in
            rule.enabled && rule.bundleIdentifier == bundleID &&
            profiles.contains(where: { $0.id == rule.profileID })
        }
        switchProfile(to: match?.profileID ?? defaultProfileID)
        guard existingRule == nil, suggestionsEnabled,
              bundleID != "com.apple.finder",
              !ignoredSuggestionIDs.contains(bundleID),
              !snoozedSuggestionIDs.contains(bundleID) else { return }
        let candidate = AppSuggestion(bundleIdentifier: bundleID,
            appName: app?.localizedName ?? bundleID,
            appPath: app?.bundleURL?.path ?? "")
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  self?.lastActivatedBundleID == bundleID,
                  self?.rules.contains(where: { $0.bundleIdentifier == bundleID }) == false else { return }
            self?.suggestion = candidate
        }
    }

    func createSuggestedAssociation() {
        guard let suggestion else { return }
        guard !rules.contains(where: { $0.bundleIdentifier == suggestion.bundleIdentifier }) else {
            self.suggestion = nil
            return
        }
        let profile = NoteProfile(id: UUID(), name: "\(suggestion.appName) 便签",
                                  text: "", imageData: nil, imageOpacity: 0.65)
        profiles.append(profile)
        rules.append(AppRule(id: UUID(), bundleIdentifier: suggestion.bundleIdentifier,
                             appName: suggestion.appName, appPath: suggestion.appPath,
                             profileID: profile.id, enabled: true, source: .suggested))
        switchProfile(to: profile.id)
        self.suggestion = nil
        windowBehaviorChanged?()
    }

    func snoozeSuggestion() {
        if let suggestion { snoozedSuggestionIDs.insert(suggestion.bundleIdentifier) }
        suggestion = nil
    }

    func neverSuggestCurrentApp() {
        if let suggestion {
            ignoredSuggestionIDs.insert(suggestion.bundleIdentifier)
            defaults.set(Array(ignoredSuggestionIDs), forKey: "ignoredSuggestionIDs")
        }
        suggestion = nil
    }

    func refreshForFrontmostApp() { handleActivatedApp(NSWorkspace.shared.frontmostApplication) }

    func save(frame: NSRect) { defaults.set(NSStringFromRect(frame), forKey: frameKey) }

    func restoredFrame() -> NSRect? {
        guard let value = defaults.string(forKey: frameKey) else { return nil }
        return Self.validatedFrame(value)
    }

    private static func validatedFrame(_ value: String) -> NSRect? {
        let frame = NSRectFromString(value)
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width >= 220, frame.height >= 180 else { return nil }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main {
            let bounds = screen.visibleFrame
            if frame.width >= bounds.width - 20 || frame.height >= bounds.height - 20 {
                return nil
            }
        }
        return frame
    }

    func exportBackup() {
        flushText()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "情境便签备份-\(Self.backupDateString()).json"
        panel.message = "备份包含所有便签文字、背景、App 关联与常用设置。"
        guard runSystemModal({ panel.runModal() }) == .OK, let url = panel.url else { return }

        do {
            let preferences = BackupPreferences(
                alwaysOnTop: alwaysOnTop,
                showOnAllSpaces: showOnAllSpaces,
                showStatusItem: showStatusItem,
                defaultShowInFullscreen: defaultShowInFullscreen,
                suggestionsEnabled: suggestionsEnabled,
                completionBehavior: completionBehavior.rawValue,
                ignoredSuggestionIDs: Array(ignoredSuggestionIDs),
                windowFrame: panelWindow.map { NSStringFromRect($0.frame) }
                    ?? defaults.string(forKey: frameKey)
            )
            let backup = NoteBackup(formatVersion: 1, exportedAt: Date(),
                                    profiles: profiles, rules: rules,
                                    preferences: preferences)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(backup).write(to: url, options: .atomic)
        } catch {
            showBackupAlert(title: "无法导出备份", message: error.localizedDescription)
        }
    }

    func restoreBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "选择由情境便签导出的备份文件。"
        guard runSystemModal({ panel.runModal() }) == .OK, let url = panel.url else { return }

        let backup: NoteBackup
        do {
            backup = try JSONDecoder().decode(NoteBackup.self, from: Data(contentsOf: url))
        } catch {
            showBackupAlert(title: "无法读取备份", message: "文件不是有效的情境便签备份。")
            return
        }

        let profileIDs = Set(backup.profiles.map(\.id))
        guard backup.formatVersion == 1, !backup.profiles.isEmpty,
              profileIDs.count == backup.profiles.count else {
            showBackupAlert(title: "无法读取备份", message: "备份内容不完整或版本不受支持。")
            return
        }

        let confirmation = NSAlert()
        confirmation.messageText = "恢复这个备份？"
        confirmation.informativeText = "当前便签、App 关联和备份中包含的常用设置会被替换。恢复前会自动保留当前便签数据作为内部回退。"
        confirmation.addButton(withTitle: "恢复")
        confirmation.addButton(withTitle: "取消")
        guard runSystemModal({ confirmation.runModal() }) == .alertFirstButtonReturn else { return }

        flushText()
        textPersistenceTask?.cancel()
        textPersistenceTask = nil
        switchTask?.cancel()
        suggestionTask?.cancel()
        suggestion = nil
        imageCache.removeAll()
        activeProfileID = backup.profiles[0].id
        profiles = backup.profiles
        rules = backup.rules.filter { profileIDs.contains($0.profileID) }
        if let preferences = backup.preferences {
            alwaysOnTop = preferences.alwaysOnTop
            showOnAllSpaces = preferences.showOnAllSpaces
            showStatusItem = preferences.showStatusItem
            defaultShowInFullscreen = preferences.defaultShowInFullscreen
            suggestionsEnabled = preferences.suggestionsEnabled
            completionBehavior = CompletionBehavior(rawValue: preferences.completionBehavior)
                ?? .strikethrough
            ignoredSuggestionIDs = Set(preferences.ignoredSuggestionIDs)
            defaults.set(Array(ignoredSuggestionIDs), forKey: "ignoredSuggestionIDs")
            if let value = preferences.windowFrame,
               let frame = Self.validatedFrame(value) {
                defaults.set(value, forKey: frameKey)
                panelWindow?.setFrame(frame, display: true)
            }
        }
        contentOpacity = 1
        windowBehaviorChanged?()
        showBackupAlert(title: "备份已恢复", message: "已恢复 \(profiles.count) 个便签。")
    }

    private static func backupDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func decodeProfiles(from data: Data) -> [NoteProfile]? {
        guard let profiles = try? JSONDecoder().decode([NoteProfile].self, from: data),
              !profiles.isEmpty,
              Set(profiles.map(\.id)).count == profiles.count else { return nil }
        return profiles
    }

    private func showBackupAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        _ = runSystemModal { alert.runModal() }
    }

    func chooseBackground() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if runSystemModal({ panel.runModal() }) == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url) {
            imageCache.removeValue(forKey: activeProfileID)
            updateActive { $0.imageData = data; $0.appearanceMode = .image }
        }
    }

    private func runSystemModal<T>(_ action: () -> T) -> T {
        let previousLevel = panelWindow?.level
        panelWindow?.level = .floating
        defer {
            if let previousLevel { panelWindow?.level = previousLevel }
        }
        return action()
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        if let previous = defaults.data(forKey: "profiles"), previous != data {
            defaults.set(previous, forKey: "profilesBackup")
        }
        defaults.set(data, forKey: "profiles")
    }

    private func persistRules() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        if let previous = defaults.data(forKey: "appRules"), previous != data {
            defaults.set(previous, forKey: "appRulesBackup")
        }
        defaults.set(data, forKey: "appRules")
    }
}
