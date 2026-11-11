import UIKit
import UniformTypeIdentifiers

/// The Files app's folder picker, presented straight from UIKit. SwiftUI's `fileImporter` stops
/// answering ("Apri" does nothing) when another one sits in the same navigation stack, and the Library
/// has its own, for playlists; this one doesn't depend on any view.
@MainActor
final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FolderPicker()

    private var completion: ((URL) -> Void)?

    /// Shows the picker over whatever is on screen; `completion` gets the folder the user opened (a URL
    /// with the access the picker gave, which `LocalMusic` turns into a bookmark).
    func present(_ completion: @escaping (URL) -> Void) {
        guard let top = Self.topViewController() else { return }
        self.completion = completion
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        top.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let done = completion
        completion = nil
        if let url = urls.first { done?(url) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion = nil
    }

    /// The view controller on top of the app's key window, whatever has been presented over it (the
    /// player's cover, a sheet).
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
