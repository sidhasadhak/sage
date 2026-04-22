import SwiftUI
import UIKit
import Contacts
import ContactsUI

struct ContactViewerView: UIViewControllerRepresentable {
    let contactID: String
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let store = CNContactStore()
        let keys = [CNContactViewController.descriptorForRequiredKeys()] as [CNKeyDescriptor]
        let vc: UIViewController
        if let contact = try? store.unifiedContact(withIdentifier: contactID, keysToFetch: keys) {
            let cvc = CNContactViewController(for: contact)
            cvc.allowsEditing = false
            cvc.navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .close,
                target: context.coordinator,
                action: #selector(Coordinator.close)
            )
            vc = cvc
        } else {
            vc = UIViewController()
        }
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    class Coordinator: NSObject {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        @objc func close() { dismiss() }
    }
}
