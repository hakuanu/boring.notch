//
//  DragDetector.swift
//  boringNotch
//
//  Created by Alexander on 2025-11-20.
//

import Cocoa
import UniformTypeIdentifiers

final class DragDetector {

    // MARK: - Callbacks

    typealias VoidCallback = () -> Void
    typealias PositionCallback = (_ globalPoint: CGPoint) -> Void

    var onDragEntersNotchRegion: VoidCallback?
    var onApplicationDragEntersNotchRegion: VoidCallback?
    var onDragExitsNotchRegion: VoidCallback?
    var onDragMove: PositionCallback?


    private var mouseDownMonitor: Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor: Any?
    private var localMouseDownMonitor: Any?
    private var localMouseDraggedMonitor: Any?
    private var localMouseUpMonitor: Any?

    private var pasteboardChangeCount: Int = -1
    private var isDragging: Bool = false
    private var isContentDragging: Bool = false
    private var hasEnteredNotchRegion: Bool = false

    private let notchRegion: CGRect
    private let dragPasteboard = NSPasteboard(name: .drag)

    init(notchRegion: CGRect) {
        self.notchRegion = notchRegion
    }

    // MARK: - Private Helpers
    
    /// Checks if the drag pasteboard contains valid content types that can be dropped on the shelf
    private func hasValidDragContent() -> Bool {
        let validTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType(UTType.url.identifier),
            .string
        ]
        return dragPasteboard.types?.contains(where: validTypes.contains) ?? false
    }
    
    /// Checks if the drag pasteboard contains an application bundle or an alias
    /// resolving to one (e.g. an item dragged from `/Applications` or a Dock folder).
    private func hasApplicationDragContent() -> Bool {
        // 1) Look at every item on the drag pasteboard individually — `.types` only
        //    reports the first item's types, so multi-item Dock drags were missed.
        if let items = dragPasteboard.pasteboardItems {
            for item in items {
                let raw = item.types.map(\.rawValue)
                if raw.contains("com.apple.dock.bundle-id") || raw.contains("com.apple.application-bundle") || raw.contains("com.apple.application-file"){
                    return true
                }
            }
        }

        // 2) Promised-file drags (Dock stacks, certain Finder sources) publish
        //    the UTI of the forthcoming file under this pasteboard key well
        //    before the actual fileURL is materialized. We only route to
        //    `.apps` when that promised UTI conforms to an application bundle.
        let promisedTypeKey = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
        if let promisedUTI = dragPasteboard.string(forType: promisedTypeKey),
           let type = UTType(promisedUTI),
           type.conforms(to: .application) || type.conforms(to: .applicationBundle) {
            return true
        }

        // 3) Standard file-URL drags. `readObjects(forClasses:)` handles bookmark
        //    data, promised URLs, and the various encodings we'd otherwise miss
        //    when reading raw `.fileURL` strings off pasteboard items.
        let urls = (dragPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []

        for url in urls {
            // Resolve Finder aliases first, then fall back to symlink resolution.
            let resolvedURL = (try? URL(resolvingAliasFileAt: url)) ?? url.resolvingSymlinksInPath()

            // Prefer UTI-based detection so we catch app bundles without relying on extensions.
            if let contentType = (try? resolvedURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
                if contentType.conforms(to: .application) || contentType.conforms(to: .applicationBundle) {
                    return true
                }
            }

            // Fallback: explicit `.app` path extension.
            if resolvedURL.pathExtension.lowercased() == "app" {
                return true
            }
        }

        return false
    }

    func startMonitoring() {
        stopMonitoring()

        // Shared handlers — installed as both global (events in other apps)
        // and local (events in our own app) monitors so we don't lose track
        // of the drag session when the cursor crosses our own window.
        let handleMouseDown: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.pasteboardChangeCount = self.dragPasteboard.changeCount
            self.isDragging = true
            self.isContentDragging = false
            self.hasEnteredNotchRegion = false
        }

        let handleMouseDragged: () -> Void = { [weak self] in
            guard let self = self else { return }
            guard self.isDragging else { return }

            let newContent = self.dragPasteboard.changeCount != self.pasteboardChangeCount
            //self.isContentDragging = true
            
            // Detect if actual content is being dragged AND it's valid content
            if newContent && self.hasValidDragContent() {
                self.isContentDragging = true
            }
            
            // Allow the notch window to briefly become key so macOS grants
            // a sandbox extension on the dropped URL. See DragFocusBridge.
            DragFocusBridge.isDragActive = true

            // Only process position when content is being dragged
            if self.isContentDragging {
                let mouseLocation = NSEvent.mouseLocation
                self.onDragMove?(mouseLocation)

                // Track notch region entry/exit
                let containsMouse = self.notchRegion.contains(mouseLocation)
                if containsMouse && !self.hasEnteredNotchRegion {
                    self.hasEnteredNotchRegion = true

                    if self.hasApplicationDragContent() {
                        self.onApplicationDragEntersNotchRegion?()
                    }
                    else {
                        self.onDragEntersNotchRegion?()
                    }
                } else if !containsMouse && self.hasEnteredNotchRegion {
                    self.hasEnteredNotchRegion = false
                    self.onDragExitsNotchRegion?()
                }
            }
        }

        let handleMouseUp: () -> Void = { [weak self] in
            // Defer clearing drag-active to the next run-loop cycle so macOS's
            // drop-completion machinery (which queries `canBecomeKey` after
            // mouseUp to grant the sandbox extension) still sees `true`.
            DispatchQueue.main.async {
                DragFocusBridge.isDragActive = false
            }
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            
            guard let self = self else { return }
            guard self.isDragging else { return }

            self.isDragging = false
            self.isContentDragging = false
            self.hasEnteredNotchRegion = false
            self.pasteboardChangeCount = -1
        }

        // Global monitors — fire for events delivered to OTHER apps.
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
            handleMouseDown()
        }
        mouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { _ in
            handleMouseDragged()
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
            handleMouseUp()
        }

        // Local monitors — fire for events delivered to OUR app, including
        // drags that cross over the notch window and drops that land on it.
        // Without these, the drop's mouseUp is never observed here and the
        // drag-active flag would stay set until the next click elsewhere.
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            handleMouseDown()
            return event
        }
        localMouseDraggedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { event in
            handleMouseDragged()
            return event
        }
        localMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { event in
            handleMouseUp()
            return event
        }
    }

    func stopMonitoring() {
        [
            mouseDownMonitor, mouseDraggedMonitor, mouseUpMonitor,
            localMouseDownMonitor, localMouseDraggedMonitor, localMouseUpMonitor,
        ].forEach { monitor in
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        mouseDownMonitor = nil
        mouseDraggedMonitor = nil
        mouseUpMonitor = nil
        localMouseDownMonitor = nil
        localMouseDraggedMonitor = nil
        localMouseUpMonitor = nil
        isDragging = false
        isContentDragging = false
        hasEnteredNotchRegion = false
        DragFocusBridge.isDragActive = false
    }

    deinit {
        stopMonitoring()
    }
}
