import AppKit
import SwiftUI

struct RuleSettingsView: View {
    @ObservedObject var store: NoteStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("便签与 App 关联")
                    .font(.headline)
                Toggle("始终置顶", isOn: $store.alwaysOnTop)
                    .font(.caption)
                Toggle("在所有桌面显示", isOn: $store.showOnAllSpaces)
                    .font(.caption)
                Toggle("在菜单栏显示便签图标", isOn: $store.showStatusItem)
                    .font(.caption)
                Toggle("登录时自动启动", isOn: $store.launchAtLogin)
                    .font(.caption)
                if let message = store.launchAtLoginMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Picker("任务完成后", selection: $store.completionBehavior) {
                    ForEach(CompletionBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }
                .pickerStyle(.segmented)
                .font(.caption)
                Toggle("点击任务文字打开链接", isOn: Binding(
                    get: { store.taskLinksEnabled },
                    set: { store.setTaskLinksEnabled($0) }
                ))
                .font(.caption)
                if store.taskLinksEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前便签的任务链接")
                            .font(.caption.weight(.semibold))
                        Text("网址可以省略 https://。没有填写网址的任务仍可正常编辑。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(taskLines, id: \.index) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.text)
                                    .font(.caption)
                                    .lineLimit(1)
                                HStack(spacing: 5) {
                                    TextField("网址", text: Binding(
                                        get: { store.taskLinks[item.index] ?? "" },
                                        set: { store.setTaskLink($0, for: item.index) }
                                    ))
                                    let link = store.taskLinks[item.index] ?? ""
                                    if !link.isEmpty {
                                        Image(systemName: store.isValidTaskLink(link)
                                              ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                            .foregroundStyle(store.isValidTaskLink(link) ? .green : .orange)
                                            .help(store.isValidTaskLink(link) ? "网址有效" : "请输入有效的网址")
                                    }
                                }
                            }
                        }
                        if taskLines.isEmpty {
                            Text("先在便签正文中写下任务。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(9)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                }
                Toggle("建议为新 App 创建便签", isOn: $store.suggestionsEnabled)
                    .font(.caption)
                Toggle("未关联 App 全屏时显示便签", isOn: $store.defaultShowInFullscreen)
                    .font(.caption)

                Text("便签")
                    .font(.subheadline.weight(.semibold))
                ForEach(store.profiles) { profile in
                    HStack {
                        Button {
                            store.selectProfile(profile.id)
                        } label: {
                            Image(systemName: store.activeProfileID == profile.id ? "largecircle.fill.circle" : "circle")
                        }
                        .buttonStyle(.plain)
                        TextField("便签名称", text: Binding(
                            get: { store.profiles.first(where: { $0.id == profile.id })?.name ?? profile.name },
                            set: { store.renameProfile(profile.id, to: $0) }
                        ))
                        if profile.id == store.defaultProfileID {
                            Text("默认").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button(role: .destructive) { store.deleteProfile(profile.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .disabled(!store.canDeleteProfile(profile.id))
                            .help(store.canDeleteProfile(profile.id) ? "删除此便签" : "先将关联的 App 改为其他便签")
                        }
                    }
                }
                HStack {
                    TextField("新便签名称", text: $store.newProfileName)
                    Button("添加便签") { store.addProfile() }
                }

                Divider()
                HStack {
                    Text("App 关联")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("添加 App…") { store.addAppRule() }
                }
                if store.rules.isEmpty {
                    Text("还没有关联。先选中上方便签，再添加 App。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.rules) { rule in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: rule.appPath))
                                .resizable().frame(width: 20, height: 20)
                            Text(rule.appName).font(.subheadline.weight(.medium))
                            Text(rule.source == .suggested ? "建议" : "手动")
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) { store.deleteRule(rule.id) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        Text(rule.bundleIdentifier)
                            .font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Picker("关联便签", selection: Binding(
                                get: { store.rules.first(where: { $0.id == rule.id })?.profileID ?? rule.profileID },
                                set: { store.setRuleProfile(rule.id, profileID: $0) }
                            )) {
                                ForEach(store.profiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            Toggle("启用", isOn: Binding(
                                get: { store.rules.first(where: { $0.id == rule.id })?.enabled ?? rule.enabled },
                                set: { store.setRuleEnabled(rule.id, enabled: $0) }
                            ))
                            .toggleStyle(.switch)
                        }
                        Toggle("此 App 全屏时显示便签", isOn: Binding(
                            get: { store.rules.first(where: { $0.id == rule.id })?.showInFullscreen ?? true },
                            set: { store.setRuleShowInFullscreen(rule.id, show: $0) }
                        ))
                        .font(.caption)
                    }
                    .padding(9)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                }

                Divider()
                Text("数据安全")
                    .font(.subheadline.weight(.semibold))
                Text("备份包含所有便签文字、背景、App 关联和常用设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("导出备份…") { store.exportBackup() }
                    Button("从备份恢复…") { store.restoreBackup() }
                }
            }
            .padding(16)
        }
        .frame(width: 370, height: 440)
        .background(ArrowCursorBackground())
        .onAppear {
            DispatchQueue.main.async { NSCursor.arrow.set() }
        }
        .onHover { hovering in
            if hovering { NSCursor.arrow.set() }
        }
    }

    private var taskLines: [(index: Int, text: String)] {
        store.text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : (index, trimmed)
        }
    }
}

private struct ArrowCursorBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ArrowCursorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ArrowCursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .arrow)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
