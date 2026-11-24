import AppKit
import SwiftUI

/// Hosts the interface. Used as the window content of the app and as the principal view
/// controller of the Final Cut Pro workflow extension.
class RemoverViewController: NSViewController {
    let model = RemoverModel()
    private let dropState = DropState()

    static let preferredSize = NSSize(width: 420, height: 640)

    override func loadView() {
        let container = DropContainerView(frame: NSRect(origin: .zero, size: Self.preferredSize))
        let host = NSHostingView(rootView: RemoverView(model: model, dropState: dropState))
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.onData = { [weak self] data in self?.model.load(data: data) }
        container.onFile = { [weak self] url in self?.model.load(url: url) }
        container.onHighlight = { [weak self] on in self?.dropState.isTargeted = on }
        view = container
        preferredContentSize = Self.preferredSize
    }
}

final class DropState: ObservableObject {
    @Published var isTargeted = false
}
