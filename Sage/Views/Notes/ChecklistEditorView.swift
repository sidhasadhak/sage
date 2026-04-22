import SwiftUI

struct ChecklistEditorView: View {
    @Environment(\.dismiss) var dismiss
    let note: Note?
    var viewModel: NotesViewModel?

    @State private var title = ""
    @State private var items: [ChecklistItem] = [ChecklistItem(text: "")]
    @FocusState private var focusedIndex: Int?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("List title", text: $title)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                } header: { Text("Title") }

                Section {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 12) {
                            Button {
                                items[index].isDone.toggle()
                            } label: {
                                Image(systemName: items[index].isDone ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(items[index].isDone ? Color.accentColor : .secondary)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)

                            TextField("Item", text: $items[index].text)
                                .strikethrough(items[index].isDone, color: .secondary)
                                .foregroundStyle(items[index].isDone ? .secondary : .primary)
                                .focused($focusedIndex, equals: index)
                                .onSubmit { addItem(after: index) }
                        }
                    }
                    .onDelete { offsets in items.remove(atOffsets: offsets) }
                    .onMove { from, to in items.move(fromOffsets: from, toOffset: to) }

                    Button {
                        addItem(after: items.count - 1)
                    } label: {
                        Label("Add Item", systemImage: "plus")
                            .foregroundStyle(Color.accentColor)
                    }
                } header: { Text("Items") }
            }
            .navigationTitle(note == nil ? "New List" : "Edit List")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(title.isEmpty && items.allSatisfy { $0.text.isEmpty })
                }
            }
            .onAppear { loadNote() }
        }
    }

    private func loadNote() {
        title = note?.title ?? ""
        if let data = note?.checklistData,
           let decoded = try? JSONDecoder().decode([ChecklistItem].self, from: data) {
            items = decoded
        }
        if items.isEmpty { items = [ChecklistItem(text: "")] }
    }

    private func addItem(after index: Int) {
        let newItem = ChecklistItem(text: "")
        let insertAt = min(index + 1, items.count)
        items.insert(newItem, at: insertAt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedIndex = insertAt
        }
    }

    private func save() {
        let cleanItems = items.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let data = try? JSONEncoder().encode(cleanItems)
        let body = cleanItems.map { ($0.isDone ? "☑ " : "☐ ") + $0.text }.joined(separator: "\n")

        if let note {
            note.title = title
            note.body = body
            note.checklistData = data
            note.updatedAt = Date()
            Task { await viewModel?.indexNote(note) }
        } else {
            viewModel?.createChecklist(title: title, items: cleanItems)
        }
        dismiss()
    }
}
