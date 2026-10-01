//
//  IntelCrossSelectionTests.swift
//  osaurusTests
//
//  Cross-block chat selection on Intel (upstream #2247 + #2899;
//  docs/CROSS_SELECTION_INTEL.md). Upstream ships no tests for it. These
//  drive a drag across two block text views with synthetic mouse events
//  (one tick through the Intel seam), check that Copy stays enabled, window scoping and the RGBA hex fix that
//  made the selection colour visible.
//

import AppKit
import SwiftUI
import Testing

@testable import OsaurusCore

@MainActor
@Suite(.serialized)
struct IntelCrossSelectionTests {

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// A window with a scroll view whose document holds two stacked block
    /// text views, like two rows of the chat table.
    private func makeThread() -> (NSWindow, SelectableNSTextView, CodeNSTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.documentView = doc
        window.contentView = scroll

        let first = SelectableNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        first.string = "First block text"
        first.isEditable = false
        let second = CodeNSTextView(frame: NSRect(x: 0, y: 100, width: 400, height: 60))
        second.string = "let second = 2"
        second.isEditable = false
        doc.addSubview(first)
        doc.addSubview(second)
        return (window, first, second)
    }

    private func mouse(_ type: NSEvent.EventType, at docPoint: NSPoint, in window: NSWindow, view: NSView) -> NSEvent {
        let inWindow = view.enclosingScrollView!.documentView!.convert(docPoint, to: nil)
        return NSEvent.mouseEvent(
            with: type, location: inWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func dragAcrossBlocksSelectsBothAndCopiesTheJoinedText() throws {
        let (window, first, second) = makeThread()
        defer {
            ChatCrossSelection.shared.clear()
            window.close()
        }
        // Mouse-down at the start of the first block, drag into the second
        // block past its text, release.
        // (`beginDrag`'s tracking loop needs a running event loop, so the
        // test drives one drag tick through the Intel seam.)
        let down = mouse(.leftMouseDown, at: NSPoint(x: 1, y: 5), in: window, view: first)
        let drag = mouse(.leftMouseDragged, at: NSPoint(x: 399, y: 110), in: window, view: first)
        ChatCrossSelection.shared.dragForTesting(from: first, down: down, to: drag)

        #expect(first.crossSelectionRange == NSRange(location: 0, length: (first.string as NSString).length))
        #expect(second.crossSelectionRange?.location == 0)
        #expect(ChatCrossSelection.shared.selectionString.hasPrefix("First block text\nlet second"))
        #expect(ChatCrossSelection.shared.hasSelection(in: window))

        // Copy stays enabled for the context menu / Edit > Copy while the
        // selection is active. (The copy itself writes the system
        // pasteboard, which a test must not touch.)
        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        #expect(second.validateUserInterfaceItem(copyItem))

        // Another window can't copy this selection.
        let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        #expect(!ChatCrossSelection.shared.copyIfActive(window: other))

        // Clearing drops every painted slice.
        ChatCrossSelection.shared.clear()
        #expect(first.crossSelectionRange == nil)
        #expect(second.crossSelectionRange == nil)
        #expect(!ChatCrossSelection.shared.hasSelection)
    }

    @Test func eightDigitHexIsRGBA() {
        let color = NSColor(Color(hex: "#007aff26")).usingColorSpace(.sRGB)!
        #expect(abs(color.alphaComponent - CGFloat(0x26) / 255) < 0.01)
        #expect(abs(color.blueComponent - 1) < 0.01)
        #expect(color.redComponent < 0.01)
    }
}
