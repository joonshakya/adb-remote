import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension View {
    /// Picks files from the Files app as copies. SwiftUI's `fileImporter` opens files in place,
    /// which doesn't respond to taps when the app runs inside LiveContainer; copies always work.
    /// The copies are temporary: delete them when done.
    func documentPicker(isPresented: Binding<Bool>, types: [UTType], multiple: Bool = false,
                        onPick: @escaping ([URL]) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            DocumentPicker(types: types, multiple: multiple, onPick: onPick)
                .ignoresSafeArea()
        }
    }
}

private struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let multiple: Bool
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = multiple
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if !urls.isEmpty { onPick(urls) }
        }
    }
}
