import AppKit
import SwiftUI

/// A plain macOS text editor without the always-visible white scroll bar.
struct NoteTextView: NSViewRepresentable {
    @ObservedObject var store: NoteStore

    private var showsHoverControls: Bool {
        store.isHovering || store.showingAppearance || store.showingSettings
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let editor = NoteEditor(frame: scrollView.contentView.bounds)
        editor.replaceContent(with: store.text)
        editor.font = .systemFont(ofSize: 17)
        editor.drawsBackground = false
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 2, height: 4)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.applyTextColor(store.textColor)
        editor.completedLineIndexes = store.completedLineIndexes
        editor.taskLinksEnabled = store.taskLinksEnabled
        editor.taskLinks = store.taskLinks
        editor.textIsLocked = store.isTextLocked
        editor.showCompletionButtons = showsHoverControls
        editor.onCompleteLine = { [weak coordinator = context.coordinator, weak editor] lineIndex in
            guard let editor else { return }
            coordinator?.completeLine(lineIndex, in: editor)
        }
        editor.onOpenTaskLink = { [weak coordinator = context.coordinator] lineIndex in
            coordinator?.store.openTaskLink(at: lineIndex)
        }
        editor.onRestoreTaskLink = { [weak coordinator = context.coordinator, weak editor] lineIndex, url in
            guard let profileID = editor?.profileID else { return }
            DispatchQueue.main.async {
                coordinator?.store.setTaskLink(url, for: lineIndex, profileID: profileID)
            }
        }
        editor.onUndoStrikethrough = { [weak coordinator = context.coordinator, weak editor] lineIndex in
            guard let coordinator, let editor else { return }
            coordinator.undoStrikethrough(lineIndex, in: editor)
        }
        editor.delegate = context.coordinator
        editor.profileID = store.activeProfileID
        scrollView.documentView = editor
        store.editorSnapshot = { [weak editor] in
            guard let editor, let id = editor.profileID else { return nil }
            return (id, editor.string)
        }
        store.clearTransientTaskUndo = { [weak editor] in
            editor?.clearTransientTaskUndo()
        }
        store.performTransientTaskUndo = { [weak editor] in
            editor?.performTransientTaskUndo() ?? false
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let editor = scrollView.documentView as? NoteEditor else { return }
        if editor.profileID != store.activeProfileID {
            editor.undoManager?.removeAllActions()
        }
        if editor.string != store.text {
            editor.replaceContent(with: store.text)
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.scrollToBeginningOfDocument(nil)
        }
        editor.profileID = store.activeProfileID
        editor.applyTextColor(store.textColor)
        editor.completedLineIndexes = store.completedLineIndexes
        editor.taskLinksEnabled = store.taskLinksEnabled
        editor.taskLinks = store.taskLinks
        editor.textIsLocked = store.isTextLocked
        editor.showCompletionButtons = showsHoverControls
        editor.applyCompletionStyles()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let store: NoteStore
        init(store: NoteStore) { self.store = store }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NoteEditor,
                  !editor.isApplyingStoredContent,
                  let profileID = editor.profileID else { return }
            store.setText(editor.string, for: profileID)
            editor.applyTextColor(store.textColor)
            editor.completedLineIndexes = store.completedLineIndexes
            editor.applyCompletionStyles()
        }

        fileprivate func completeLine(_ lineIndex: Int, in editor: NoteEditor) {
            switch store.completionBehavior {
            case .strikethrough:
                editor.recordStrikethroughToggle(lineIndex)
                store.toggleCompletedLine(lineIndex)
                editor.completedLineIndexes = store.completedLineIndexes
                editor.applyCompletionStyles()
            case .delete:
                editor.deleteLogicalLine(lineIndex, taskLink: store.taskLinks[lineIndex])
            }
        }

        fileprivate func undoStrikethrough(_ lineIndex: Int, in editor: NoteEditor) {
            store.toggleCompletedLine(lineIndex)
            editor.completedLineIndexes = store.completedLineIndexes
            editor.applyCompletionStyles()
        }
    }

    fileprivate final class NoteEditor: NSTextView {
        var placeholderColor = NSColor.white.withAlphaComponent(0.5)
        var profileID: UUID?
        var isApplyingStoredContent: Bool { performingProgrammaticTextChange }
        var completedLineIndexes = Set<Int>() { didSet { needsDisplay = true } }
        var taskLinksEnabled = false { didSet { refreshCompletionControls() } }
        var taskLinks: [Int: String] = [:] { didSet { refreshCompletionControls() } }
        var showCompletionButtons = false {
            didSet { refreshCompletionControls() }
        }
        var textIsLocked = false {
            didSet {
                if textIsLocked { lockedTextSnapshot = string }
                isEditable = !textIsLocked
                isSelectable = !textIsLocked
                if textIsLocked, window?.firstResponder === self {
                    window?.makeFirstResponder(nil)
                }
                refreshCompletionControls()
            }
        }
        private var pointerIsInside = false
        private var hoverTrackingArea: NSTrackingArea?
        private var performingTaskCompletionEdit = false
        private var performingProgrammaticTextChange = false
        private var lockedTextSnapshot = ""
        private var pendingLockedDeletion: PendingLockedDeletion?
        private var pendingLockedStrikethrough: PendingLockedStrikethrough?
        private var completionControlsAreVisible: Bool { showCompletionButtons || pointerIsInside }
        var onCompleteLine: ((Int) -> Void)?
        var onOpenTaskLink: ((Int) -> Void)?
        var onRestoreTaskLink: ((Int, String) -> Void)?
        var onUndoStrikethrough: ((Int) -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }

        private struct PendingLockedDeletion {
            var lineIndex: Int
            var insertionLocation: Int
            var text: String
            var taskLink: String?
            var deletedAt: Date
        }

        private struct PendingLockedStrikethrough {
            var lineIndex: Int
            var changedAt: Date
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override var string: String {
            get { super.string }
            set {
                guard !textIsLocked || performingProgrammaticTextChange || performingTaskCompletionEdit else {
                    return
                }
                super.string = newValue
                if textIsLocked { lockedTextSnapshot = newValue }
            }
        }

        func replaceContent(with value: String) {
            let previousDelegate = delegate
            delegate = nil
            performingProgrammaticTextChange = true
            string = value
            performingProgrammaticTextChange = false
            delegate = previousDelegate
            if textIsLocked { lockedTextSnapshot = value }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                          .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            hoverTrackingArea = trackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            pointerIsInside = true
            refreshCompletionControls()
        }

        override func mouseExited(with event: NSEvent) {
            pointerIsInside = false
            refreshCompletionControls()
            NSCursor.arrow.set()
        }

        override func mouseMoved(with event: NSEvent) {
            if !pointerIsInside {
                pointerIsInside = true
                refreshCompletionControls()
            }
            super.mouseMoved(with: event)
            updateCursor(for: event)
        }

        override func cursorUpdate(with event: NSEvent) {
            updateCursor(for: event)
        }

        override func keyDown(with event: NSEvent) {
            guard !textIsLocked else { return }
            super.keyDown(with: event)
        }

        override func shouldChangeText(in affectedCharRange: NSRange,
                                       replacementString: String?) -> Bool {
            guard !textIsLocked || performingTaskCompletionEdit else { return false }
            return super.shouldChangeText(in: affectedCharRange,
                                          replacementString: replacementString)
        }

        override func didChangeText() {
            if textIsLocked && !performingTaskCompletionEdit && !performingProgrammaticTextChange {
                if string != lockedTextSnapshot {
                    performingProgrammaticTextChange = true
                    super.string = lockedTextSnapshot
                    performingProgrammaticTextChange = false
                    needsDisplay = true
                }
                return
            }
            super.didChangeText()
            if textIsLocked { lockedTextSnapshot = string }
        }

        private func updateCursor(for event: NSEvent) {
            if let contentView = window?.contentView,
               let hitView = contentView.hitTest(event.locationInWindow),
               hitView !== self, !hitView.isDescendant(of: self) {
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            if completionControlsAreVisible,
               completionButtonRects().contains(where: { $0.rect.contains(point) }) {
                NSCursor.pointingHand.set()
            } else if linkedLine(at: point) != nil {
                NSCursor.pointingHand.set()
            } else {
                (textIsLocked ? NSCursor.arrow : NSCursor.iBeam).set()
            }
        }

        private func refreshCompletionControls() {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }

        func applyTextColor(_ color: NSColor) {
            textColor = color
            insertionPointColor = color
            placeholderColor = color.withAlphaComponent(0.5)
            typingAttributes[.foregroundColor] = color
            let range = NSRange(location: 0, length: (string as NSString).length)
            if range.length > 0 {
                withoutUndoRegistration {
                    textStorage?.addAttribute(.foregroundColor, value: color, range: range)
                }
            }
            needsDisplay = true
        }

        func applyCompletionStyles() {
            guard let textStorage else { return }
            withoutUndoRegistration {
                let fullRange = NSRange(location: 0, length: (string as NSString).length)
                if fullRange.length > 0 {
                    textStorage.removeAttribute(.strikethroughStyle, range: fullRange)
                    textStorage.removeAttribute(.underlineStyle, range: fullRange)
                }
                if taskLinksEnabled {
                    for (lineIndex, range) in logicalLineRanges().enumerated()
                        where taskLinks[lineIndex] != nil && !completedLineIndexes.contains(lineIndex) {
                        let contentRange = rangeWithoutLineBreak(range)
                        if contentRange.length > 0 {
                            textStorage.addAttribute(.underlineStyle,
                                                     value: NSUnderlineStyle.single.rawValue,
                                                     range: contentRange)
                        }
                    }
                }
                for (lineIndex, range) in logicalLineRanges().enumerated()
                    where completedLineIndexes.contains(lineIndex) {
                    let contentRange = rangeWithoutLineBreak(range)
                    if contentRange.length > 0 {
                        textStorage.addAttribute(.strikethroughStyle,
                                                 value: NSUnderlineStyle.single.rawValue,
                                                 range: contentRange)
                    }
                }
            }
            needsDisplay = true
        }

        private func withoutUndoRegistration(_ changes: () -> Void) {
            guard let undoManager, undoManager.isUndoRegistrationEnabled else {
                changes()
                return
            }
            undoManager.disableUndoRegistration()
            defer { undoManager.enableUndoRegistration() }
            changes()
        }

        func deleteLogicalLine(_ lineIndex: Int, taskLink: String?) {
            let ranges = logicalLineRanges()
            guard ranges.indices.contains(lineIndex) else { return }
            var range = ranges[lineIndex]
            let length = (string as NSString).length
            if NSMaxRange(range) == length, range.location > 0 {
                range.location -= 1
                range.length += 1
            }
            let deletedText = (string as NSString).substring(with: range)
            pendingLockedDeletion = nil
            pendingLockedStrikethrough = nil
            performingTaskCompletionEdit = true
            let wasEditable = isEditable
            if textIsLocked { isEditable = true }
            defer {
                isEditable = wasEditable
                performingTaskCompletionEdit = false
            }
            var changed = false
            withoutUndoRegistration {
                guard shouldChangeText(in: range, replacementString: "") else { return }
                textStorage?.replaceCharacters(in: range, with: "")
                didChangeText()
                changed = true
            }
            guard changed else { return }
            let deletion = PendingLockedDeletion(
                lineIndex: lineIndex,
                insertionLocation: range.location,
                text: deletedText,
                taskLink: taskLink,
                deletedAt: Date()
            )
            if textIsLocked {
                pendingLockedDeletion = deletion
            } else {
                registerUnlockedDeletionUndo(deletion)
            }
        }

        func clearTransientTaskUndo() {
            pendingLockedDeletion = nil
            pendingLockedStrikethrough = nil
        }

        func recordStrikethroughToggle(_ lineIndex: Int) {
            if textIsLocked {
                pendingLockedDeletion = nil
                pendingLockedStrikethrough = PendingLockedStrikethrough(
                    lineIndex: lineIndex,
                    changedAt: Date()
                )
            } else {
                registerUnlockedStrikethroughUndo(lineIndex)
            }
        }

        func performTransientTaskUndo() -> Bool {
            if pendingLockedDeletion != nil { return restorePendingLockedDeletion() }
            guard let pending = pendingLockedStrikethrough else { return false }
            pendingLockedStrikethrough = nil
            guard Date().timeIntervalSince(pending.changedAt) <= 5 else { return false }
            onUndoStrikethrough?(pending.lineIndex)
            return true
        }

        private func restorePendingLockedDeletion() -> Bool {
            guard let pending = pendingLockedDeletion else { return false }
            pendingLockedDeletion = nil
            guard Date().timeIntervalSince(pending.deletedAt) <= 5,
                  pending.insertionLocation <= (string as NSString).length else { return false }
            let range = NSRange(location: pending.insertionLocation, length: 0)
            performingTaskCompletionEdit = true
            let wasEditable = isEditable
            isEditable = true
            undoManager?.disableUndoRegistration()
            defer {
                undoManager?.enableUndoRegistration()
                isEditable = wasEditable
                performingTaskCompletionEdit = false
            }
            guard shouldChangeText(in: range, replacementString: pending.text) else { return false }
            textStorage?.replaceCharacters(in: range, with: pending.text)
            let restoredRange = NSRange(location: range.location,
                                        length: (pending.text as NSString).length)
            didChangeText()
            if restoredRange.length > 0 {
                let bodyFont = NSFont.systemFont(ofSize: 17)
                textStorage?.addAttributes(
                    [.font: bodyFont,
                     .foregroundColor: textColor ?? NSColor.white],
                    range: restoredRange
                )
                typingAttributes[.font] = bodyFont
                needsLayout = true
                needsDisplay = true
            }
            if let taskLink = pending.taskLink {
                onRestoreTaskLink?(pending.lineIndex, taskLink)
            }
            return true
        }

        private func registerUnlockedDeletionUndo(_ deletion: PendingLockedDeletion) {
            undoManager?.registerUndo(withTarget: self) { editor in
                editor.restoreUnlockedDeletion(deletion)
            }
            undoManager?.setActionName("完成任务")
        }

        private func restoreUnlockedDeletion(_ deletion: PendingLockedDeletion) {
            guard deletion.insertionLocation <= (string as NSString).length else { return }
            let range = NSRange(location: deletion.insertionLocation, length: 0)
            performingTaskCompletionEdit = true
            defer { performingTaskCompletionEdit = false }
            withoutUndoRegistration {
                guard shouldChangeText(in: range, replacementString: deletion.text) else { return }
                textStorage?.replaceCharacters(in: range, with: deletion.text)
                let restoredRange = NSRange(location: range.location,
                                            length: (deletion.text as NSString).length)
                didChangeText()
                if restoredRange.length > 0 {
                    textStorage?.addAttributes(
                        [.font: NSFont.systemFont(ofSize: 17),
                         .foregroundColor: textColor ?? NSColor.white],
                        range: restoredRange
                    )
                }
            }
            if let taskLink = deletion.taskLink {
                onRestoreTaskLink?(deletion.lineIndex, taskLink)
            }
            undoManager?.registerUndo(withTarget: self) { editor in
                editor.redoUnlockedDeletion(deletion)
            }
            undoManager?.setActionName("完成任务")
        }

        private func redoUnlockedDeletion(_ deletion: PendingLockedDeletion) {
            let range = NSRange(location: deletion.insertionLocation,
                                length: (deletion.text as NSString).length)
            guard NSMaxRange(range) <= (string as NSString).length else { return }
            performingTaskCompletionEdit = true
            defer { performingTaskCompletionEdit = false }
            withoutUndoRegistration {
                guard shouldChangeText(in: range, replacementString: "") else { return }
                textStorage?.replaceCharacters(in: range, with: "")
                didChangeText()
            }
            registerUnlockedDeletionUndo(deletion)
        }

        private func registerUnlockedStrikethroughUndo(_ lineIndex: Int) {
            undoManager?.registerUndo(withTarget: self) { editor in
                editor.onUndoStrikethrough?(lineIndex)
                editor.registerUnlockedStrikethroughUndo(lineIndex)
            }
            undoManager?.setActionName("完成任务")
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if completionControlsAreVisible,
               let lineIndex = completionButtonRects().first(where: { $0.rect.contains(point) })?.lineIndex {
                clearTransientTaskUndo()
                onCompleteLine?(lineIndex)
                return
            }
            if textIsLocked { clearTransientTaskUndo() }
            if let lineIndex = linkedLine(at: point) {
                onOpenTaskLink?(lineIndex)
                return
            }
            if textIsLocked {
                NSCursor.arrow.set()
                return
            }
            window?.makeKey()
            window?.makeFirstResponder(self)
            super.mouseDown(with: event)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if string.isEmpty {
                ("写点什么……" as NSString).draw(
                    at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
                    withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 17),
                                     .foregroundColor: placeholderColor]
                )
            } else if completionControlsAreVisible {
                drawCompletionButtons()
            }
        }

        override func resetCursorRects() {
            let visibleWidth = enclosingScrollView?.contentSize.width ?? bounds.width
            guard completionControlsAreVisible else {
                addCursorRect(bounds, cursor: textIsLocked ? .arrow : .iBeam)
                return
            }
            let buttonStripX = max(bounds.minX, visibleWidth - 24)
            let textRect = NSRect(x: bounds.minX, y: bounds.minY,
                                  width: max(0, buttonStripX - bounds.minX),
                                  height: bounds.height)
            let buttonStrip = NSRect(x: buttonStripX, y: bounds.minY,
                                     width: max(0, bounds.maxX - buttonStripX),
                                     height: bounds.height)
            addCursorRect(textRect, cursor: textIsLocked ? .arrow : .iBeam)
            addCursorRect(buttonStrip, cursor: .arrow)
            if taskLinksEnabled {
                for item in linkedLineRects() {
                    addCursorRect(item.rect, cursor: .pointingHand)
                }
            }
            for button in completionButtonRects() {
                addCursorRect(button.rect, cursor: .pointingHand)
            }
        }

        private func drawCompletionButtons() {
            let buttonColor = textColor ?? .white
            for button in completionButtonRects() {
                let completed = completedLineIndexes.contains(button.lineIndex)
                let circle = NSBezierPath(ovalIn: button.rect.insetBy(dx: 1, dy: 1))
                circle.lineWidth = 1.5
                if completed {
                    buttonColor.withAlphaComponent(0.85).setFill()
                    circle.fill()
                } else {
                    buttonColor.withAlphaComponent(0.65).setStroke()
                    circle.stroke()
                }
                if completed {
                    let check = NSBezierPath()
                    check.lineWidth = 1.6
                    check.lineCapStyle = .round
                    check.lineJoinStyle = .round
                    NSColor.windowBackgroundColor.setStroke()
                    check.move(to: NSPoint(x: button.rect.minX + 4, y: button.rect.midY))
                    check.line(to: NSPoint(x: button.rect.minX + 7, y: button.rect.minY + 4))
                    check.line(to: NSPoint(x: button.rect.maxX - 3, y: button.rect.maxY - 4))
                    check.stroke()
                }
            }
        }

        private func completionButtonRects() -> [(lineIndex: Int, rect: NSRect)] {
            guard let layoutManager, let textContainer else { return [] }
            layoutManager.ensureLayout(for: textContainer)
            let origin = textContainerOrigin
            let text = string as NSString
            let visibleWidth = enclosingScrollView?.contentSize.width ?? bounds.width
            return logicalLineRanges().enumerated().compactMap { lineIndex, range in
                let contentRange = rangeWithoutLineBreak(range)
                guard contentRange.length > 0,
                      !text.substring(with: contentRange).trimmingCharacters(in: .whitespaces).isEmpty else {
                    return nil
                }
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: contentRange.location)
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                let size: CGFloat = 16
                return (lineIndex, NSRect(x: max(0, visibleWidth - size - 4),
                                          y: fragment.midY + origin.y - size / 2,
                                          width: size, height: size))
            }
        }

        private func linkedLine(at point: NSPoint) -> Int? {
            guard taskLinksEnabled else { return nil }
            return linkedLineRects().first(where: { $0.rect.contains(point) })?.lineIndex
        }

        private func linkedLineRects() -> [(lineIndex: Int, rect: NSRect)] {
            guard taskLinksEnabled, let layoutManager, let textContainer else { return [] }
            layoutManager.ensureLayout(for: textContainer)
            let origin = textContainerOrigin
            return logicalLineRanges().enumerated().compactMap { lineIndex, range in
                guard taskLinks[lineIndex] != nil,
                      !completedLineIndexes.contains(lineIndex) else { return nil }
                let contentRange = rangeWithoutLineBreak(range)
                guard contentRange.length > 0 else { return nil }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: contentRange,
                                                          actualCharacterRange: nil)
                var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                rect.origin.x += origin.x
                rect.origin.y += origin.y
                return (lineIndex, rect.insetBy(dx: -2, dy: -2))
            }
        }

        private func logicalLineRanges() -> [NSRange] {
            let text = string as NSString
            guard text.length > 0 else { return [] }
            var result: [NSRange] = []
            var location = 0
            while location < text.length {
                let range = text.lineRange(for: NSRange(location: location, length: 0))
                result.append(range)
                let next = NSMaxRange(range)
                guard next > location else { break }
                location = next
            }
            return result
        }

        private func rangeWithoutLineBreak(_ range: NSRange) -> NSRange {
            let text = string as NSString
            var result = range
            while result.length > 0 {
                let scalar = text.character(at: NSMaxRange(result) - 1)
                guard scalar == 10 || scalar == 13 else { break }
                result.length -= 1
            }
            return result
        }
    }
}
