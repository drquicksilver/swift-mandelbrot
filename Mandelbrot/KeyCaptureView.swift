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

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onTab = onTab
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onTab = onTab
    }
}

final class KeyCaptureNSView: NSView {
    var onTab: (() -> Void)?

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
        super.keyDown(with: event)
    }
}
#endif
