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
    var onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }
}

final class KeyCaptureNSView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if let onKeyDown, onKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }
}
#endif
