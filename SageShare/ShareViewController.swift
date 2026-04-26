import UIKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ShareViewController
//
// Entry point for the SageShare extension.
// Responsibilities:
//   1. Extract shared content (URL, text, or image) from extensionContext.
//   2. Present ShareView as a SwiftUI hosting controller.
//   3. On Save: write the item to the App Group container and complete.
//   4. On Cancel: complete without writing.
//
// Memory budget: extensions are limited to ~120 MB. We decode only the
// first attachment of each type and downsample images before storing.

final class ShareViewController: UIViewController {

    // Populated after async extraction in viewDidLoad.
    private var pendingItem: SharedItem?
    private var pendingImage: UIImage?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        extractContent()
    }

    // MARK: - Content extraction

    private func extractContent() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            showError("Nothing to save.")
            return
        }

        // Flatten all item providers from all extension items.
        let providers = items.flatMap { $0.attachments ?? [] }

        // Priority: URL → image → plain text
        if let urlProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            load(urlProvider, typeID: UTType.url.identifier) { [weak self] value in
                if let url = value as? URL {
                    let sourceApp = self?.sourceAppName() ?? ""
                    let item = SharedItem(type: .url, content: url.absoluteString, sourceApp: sourceApp)
                    self?.present(item: item, image: nil)
                } else {
                    self?.showError("Couldn't read the link.")
                }
            }
        } else if let imgProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) {
            load(imgProvider, typeID: UTType.image.identifier) { [weak self] value in
                let uiImage: UIImage?
                if let img = value as? UIImage {
                    uiImage = img
                } else if let data = value as? Data {
                    uiImage = UIImage(data: data)
                } else if let url = value as? URL, let data = try? Data(contentsOf: url) {
                    uiImage = UIImage(data: data)
                } else {
                    uiImage = nil
                }

                guard let image = uiImage else {
                    self?.showError("Couldn't read the image.")
                    return
                }
                // Downsample to 1024px on the long edge to stay within memory budget.
                let thumb = image.downsampled(maxDimension: 1024)
                // Save the image file and store its filename as content.
                let filename = SharedItemStore.shared.saveImage(thumb) ?? ""
                let sourceApp = self?.sourceAppName() ?? ""
                let item = SharedItem(type: .image, content: filename, sourceApp: sourceApp)
                self?.present(item: item, image: thumb)
            }
        } else if let txtProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) {
            load(txtProvider, typeID: UTType.plainText.identifier) { [weak self] value in
                if let text = value as? String, !text.isEmpty {
                    let sourceApp = self?.sourceAppName() ?? ""
                    let item = SharedItem(type: .text, content: text, sourceApp: sourceApp)
                    self?.present(item: item, image: nil)
                } else {
                    self?.showError("Couldn't read the text.")
                }
            }
        } else {
            showError("Sage can save links, text, and images.")
        }
    }

    private func load(_ provider: NSItemProvider, typeID: String, completion: @escaping (Any?) -> Void) {
        provider.loadItem(forTypeIdentifier: typeID, options: nil) { item, _ in
            DispatchQueue.main.async { completion(item) }
        }
    }

    // MARK: - Presentation

    private func present(item: SharedItem, image: UIImage?) {
        self.pendingItem  = item
        self.pendingImage = image

        let shareView = ShareView(
            item: item,
            image: image,
            onSave: { [weak self] in self?.complete() },
            onCancel: { [weak self] in self?.cancel() }
        )

        let host = UIHostingController(rootView: shareView)
        host.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    // MARK: - Completion

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: CancellationError())
    }

    // MARK: - Error UI

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Sage", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.cancel()
        })
        present(alert, animated: true)
    }

    // MARK: - Helpers

    private func sourceAppName() -> String {
        // The host app's bundle identifier is the last component of the
        // extension context's source application bundle identifier.
        // Not available via public API, so we return a generic fallback.
        return "Shared"
    }
}

// MARK: - UIImage downsampling

private extension UIImage {
    /// Returns a copy scaled so neither dimension exceeds `maxDimension`.
    func downsampled(maxDimension: CGFloat) -> UIImage {
        let longEdge = max(size.width, size.height)
        guard longEdge > maxDimension else { return self }
        let scale = maxDimension / longEdge
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
