import AppKit
import SwiftUI
import Testing
@testable import CoSheepKit

// The chat box ("Chat with Sheep…"): a Liquid Glass panel with AppKit's own
// controls. These pin what a human relies on: a way out that needs no
// keyboard, a box that doesn't grow without end, and a tail that points down.
@Suite("input bubble")
struct InputBubbleTests {
    private func makeView() -> InputBubbleView {
        InputBubbleView(promptText: "Talk to me...", placeholder: "Say something...", buttonText: "Send")
    }

    @Test func theCloseButtonEndsTheChat() {
        let view = makeView()
        var closed = 0
        view.onEscape = { closed += 1 }

        view.closeButton.performClick(nil)

        #expect(closed == 1)
        #expect(view.closeButton.accessibilityLabel() == "Close chat")
        #expect(view.closeButton.image != nil)
    }

    @Test func theButtonsAreGlass() {
        let view = makeView()
        #expect(view.closeButton.bezelStyle == .glass)
        #expect(view.sendButton.bezelStyle == .glass)
        #expect(view.sendButton.title == "Send")
        #expect(view.sendButton.bezelColor == BubbleStyle.accent)
    }

    @Test func theBoxKeepsItsWidthAndALongReplyScrollsInsteadOfGrowingForever() {
        let view = makeView()
        view.layoutSubtreeIfNeeded()
        let empty = view.fittingSize
        #expect(empty.width == BubbleStyle.width)

        view.showReply("Baaa. A short one.", isError: false)
        view.layoutSubtreeIfNeeded()
        let short = view.fittingSize
        #expect(short.width == BubbleStyle.width)

        view.showReply(String(repeating: "Baaa baaa baaa baaa baaa baaa. ", count: 80), isError: false)
        view.layoutSubtreeIfNeeded()
        let long = view.fittingSize
        #expect(long.width == BubbleStyle.width)
        #expect(long.height > short.height)
        // The reply is clipped to its scroll height, whatever its length.
        #expect(long.height <= empty.height + BubbleStyle.replyMaxHeight)
    }

    @Test func sendingWaitsWhileTheSheepThinks() {
        let view = makeView()
        view.setLoading(true, promptText: "Talk to me...")
        #expect(!view.sendButton.isEnabled)
        #expect(view.closeButton.isEnabled) // closing is always allowed
        view.showReply("Baaa.", isError: false)
        #expect(view.sendButton.isEnabled)
    }

    @Test func theShapeIsABoxWithATailAtTheBottomCentre() {
        let shape = ChatBubbleShape(radius: 20, tail: 11, tailWidth: 26)
        let rect = CGRect(x: 0, y: 0, width: 320, height: 100)
        let path = shape.path(in: rect)
        #expect(path.boundingRect.integral == rect)
        // Inside the box, inside the tail's tip, outside beside the tail.
        #expect(path.contains(CGPoint(x: 160, y: 50)))
        #expect(path.contains(CGPoint(x: 160, y: 97)))
        #expect(!path.contains(CGPoint(x: 60, y: 97)))
        // Rounded corners: the very corner is not part of it.
        #expect(!path.contains(CGPoint(x: 1, y: 1)))
    }
}
