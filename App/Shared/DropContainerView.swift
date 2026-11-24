import AppKit

/// Root view of the window: accepts a project dragged from Final Cut Pro's browser (which
/// arrives as FCPXML on the pasteboard) or an .fcpxml / .fcpxmld file dragged from Finder.
/// Being the root, it catches drops anywhere in the window.
final class DropContainerView: NSView {
    var onData: ((Data) -> Void)?
    var onFile: ((URL) -> Void)?
    var onHighlight: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(FinalCutPro.dragTypes + [.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func fcpxmlType(on pasteboard: NSPasteboard) -> NSPasteboard.PasteboardType? {
        pasteboard.availableType(from: FinalCutPro.dragTypes)
    }

    private func fileURL(on pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.first { ["fcpxml", "fcpxmld"].contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        guard fcpxmlType(on: pasteboard) != nil || fileURL(on: pasteboard) != nil else { return [] }
        onHighlight?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        return fcpxmlType(on: pasteboard) != nil || fileURL(on: pasteboard) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHighlight?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onHighlight?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHighlight?(false)
        let pasteboard = sender.draggingPasteboard
        if let type = fcpxmlType(on: pasteboard) {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                onData?(data)
                return true
            }
            if let string = pasteboard.string(forType: type), !string.isEmpty {
                onData?(Data(string.utf8))
                return true
            }
        }
        if let url = fileURL(on: pasteboard) {
            onFile?(url)
            return true
        }
        return false
    }
}
