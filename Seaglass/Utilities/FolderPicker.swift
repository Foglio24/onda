import UIKit
import UniformTypeIdentifiers

/// The Files app's folder picker, presented straight from UIKit. SwiftUI's `fileImporter` stops
/// answering ("Apri" does nothing) when another one sits in the same navigation stack, and the Library
/// has its own, for playlists; this one doesn't depend on any view.
@MainActor
final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FolderPicker()

    private var completion: ((URL) -> Void)?
    private var filesCompletion: (([URL]) -> Void)?

    /// Shows the picker over whatever is on screen; `completion` gets the folder the user opened (a URL
    /// with the access the picker gave, which `LocalMusic` turns into a bookmark).
    func present(_ completion: @escaping (URL) -> Void) {
        guard let top = Self.topViewController() else { return }
        self.completion = completion
        filesCompletion = nil
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        top.present(picker, animated: true)
    }

    /// Shows the picker for audio files, which the system COPIES for the app (no access to the place they
    /// are in is needed): `completion` gets the copies, for `LocalMusic.importCopies`.
    func presentFiles(_ completion: @escaping ([URL]) -> Void) {
        guard let top = Self.topViewController() else { return }
        filesCompletion = completion
        self.completion = nil
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        top.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let done = completion
        let doneFiles = filesCompletion
        completion = nil
        filesCompletion = nil
        if let doneFiles { doneFiles(urls) } else if let url = urls.first { done?(url) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        completion = nil
        filesCompletion = nil
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
