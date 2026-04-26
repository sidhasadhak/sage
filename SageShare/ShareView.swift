import SwiftUI
import UIKit

// MARK: - ShareView
//
// The sheet the user sees when they tap "Sage" in the iOS share sheet.
// Displays a preview of the shared content (URL, text, or image),
// an optional annotation field, and Save / Cancel buttons.

struct ShareView: View {
    let item: SharedItem
    let image: UIImage?
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var note = ""

    private var typeLabel: String {
        switch item.type {
        case .url:   return "Save link to Sage"
        case .text:  return "Save text to Sage"
        case .image: return "Save image to Sage"
        }
    }

    private var previewText: String {
        switch item.type {
        case .url, .text: return item.content
        case .image:      return "Image from \(item.sourceApp)"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // ── Preview ──────────────────────────────────────────
                Section {
                    if item.type == .image, let img = image {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .listRowInsets(EdgeInsets())
                    } else {
                        Text(previewText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                } header: {
                    Text(typeLabel)
                }

                // ── Optional note ─────────────────────────────────────
                Section {
                    TextField("Add a note (optional)", text: $note, axis: .vertical)
                        .lineLimit(3, reservesSpace: false)
                } header: {
                    Text("Note")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Save to Sage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        // Rebuild the item with the user's note before saving.
                        let final = SharedItem(
                            type: item.type,
                            content: item.content,
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                            sourceApp: item.sourceApp
                        )
                        SharedItemStore.shared.append(final)
                        onSave()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
