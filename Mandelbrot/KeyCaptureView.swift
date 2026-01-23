//
//  KeyCaptureView.swift
//  Mandelbrot
//
//  Created by Jules Bean on 20/01/2026.
//

#if os(macOS)
import AppKit
import SwiftUI

struct KeyCaptureView: NSViewRepresentable {
    var onTab: () -> Void
    var onIncrement: () -> Void
    var onDecrement: () -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onTab = onTab
        view.onIncrement = onIncrement
        view.onDecrement = onDecrement
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onTab = onTab
        nsView.onIncrement = onIncrement
        nsView.onDecrement = onDecrement
    }
}

final class KeyCaptureNSView: NSView {
    var onTab: (() -> Void)?
    var onIncrement: (() -> Void)?
    var onDecrement: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\t" {
            onTab?()
            return
        }
        if let chars = event.charactersIgnoringModifiers {
            if chars == "+" || chars == "=" {
                onIncrement?()
                return
            }
            if chars == "-" {
                onDecrement?()
                return
            }
        }
        super.keyDown(with: event)
    }
}
#endif
