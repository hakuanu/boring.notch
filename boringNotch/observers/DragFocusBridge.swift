//
//  DragFocusBridge.swift
//  boringNotch
//
//  Bridges the drag pipeline and the notch window's `canBecomeKey` override
//  so macOS can temporarily make the notch key during a file drop.
//
//  Background: a sandboxed app only receives a sandbox extension for a
//  dropped file when the drop-target window can become key. The notch's
//  window deliberately returns `false` from `canBecomeKey` at all other
//  times to avoid stealing focus from the user's active app.
//

import Foundation

enum DragFocusBridge {
    /// Set to `true` by `DragDetector` while a valid content drag is in
    /// flight, and back to `false` as soon as the mouse is released (or the
    /// detector is torn down). The notch window's `canBecomeKey` reads this
    /// value so that AppKit can install a sandbox extension on the drop
    /// target — without which dragged URLs arrive unopenable and
    /// `bookmarkData(.withSecurityScope)` fails.
    ///
    /// Accessed only from the main thread (NSEvent global monitors and
    /// AppKit window queries), so no synchronization is required.
    static var isDragActive: Bool = false
}
