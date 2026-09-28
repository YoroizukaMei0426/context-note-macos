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
        editor.textIsLocked = store.isTextLocked
        editor.showCompletionButtons = showsHoverControls
        editor.onCompleteLine = { [weak coordinator = context.coordinator, weak editor] lineIndex in
            guard let editor else { return }
            coordinator?.completeLine(lineIndex, in: editor)
        }
        editor.delegate = context.coordinator
        editor.profileID = store.activeProfileID
        scrollView.documentView = editor
        store.editorSnapshot = { [weak editor] in
            guard let editor, let id = editor.profileID else { return nil }
            return (id, editor.string)
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
                store.toggleCompletedLine(lineIndex)
                editor.completedLineIndexes = store.completedLineIndexes
                editor.applyCompletionStyles()
            case .delete:
                editor.deleteLogicalLine(lineIndex)
            }
        }
    }

    fileprivate final class NoteEditor: NSTextView {
        var placeholderColor = NSColor.white.withAlphaComponent(0.5)
        var profileID: UUID?
        var isApplyingStoredContent: Bool { performingProgrammaticTextChange }
        var completedLineIndexes = Set<Int>() { didSet { needsDisplay = true } }
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
        private var completionControlsAreVisible: Bool { showCompletionButtons || pointerIsInside }
        var onCompleteLine: ((Int) -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }

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
                textStorage?.addAttribute(.foregroundColor, value: color, range: range)
            }
            needsDisplay = true
        }

        func applyCompletionStyles() {
            guard let textStorage else { return }
            let fullRange = NSRange(location: 0, length: (string as NSString).length)
            if fullRange.length > 0 {
                textStorage.removeAttribute(.strikethroughStyle, range: fullRange)
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
            needsDisplay = true
        }

        func deleteLogicalLine(_ lineIndex: Int) {
            let ranges = logicalLineRanges()
            guard ranges.indices.contains(lineIndex) else { return }
            var range = ranges[lineIndex]
            let length = (string as NSString).length
            if NSMaxRange(range) == length, range.location > 0 {
                range.location -= 1
                range.length += 1
            }
            performingTaskCompletionEdit = true
            let wasEditable = isEditable
            if textIsLocked { isEditable = true }
            defer {
                isEditable = wasEditable
                performingTaskCompletionEdit = false
            }
            guard shouldChangeText(in: range, replacementString: "") else { return }
            textStorage?.replaceCharacters(in: range, with: "")
            didChangeText()
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if completionControlsAreVisible,
               let lineIndex = completionButtonRects().first(where: { $0.rect.contains(point) })?.lineIndex {
                onCompleteLine?(lineIndex)
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
