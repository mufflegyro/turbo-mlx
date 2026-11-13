import SwiftUI

/// The prompts the user saved: search, use, delete, and save the current one. Using a prompt
/// fills the controls' prompt in and changes nothing else.
struct PromptLibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var query = ""
    @State private var showsSave = false
    @State private var newName = ""
    @State private var pendingDelete: SavedPrompt?

    private var filtered: [SavedPrompt] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return app.promptLibrary.prompts }
        return app.promptLibrary.prompts.filter {
            $0.name.lowercased().contains(q) || $0.preview.lowercased().contains(q)
        }
    }

    /// Whether the controls hold anything worth saving.
    private var promptIsEmpty: Bool {
        !app.settings.blocks.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && app.settings.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let problem = app.promptLibrary.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
            }
            content
            Divider()
            Text("A saved prompt keeps its blocks and negative prompt. Using one changes nothing else: not the model, size, steps, seed or LoRAs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 520, minHeight: 380)
        .alert("Save Current Prompt", isPresented: $showsSave) {
            TextField("Name", text: $newName, prompt: Text("Untitled Prompt"))
            Button("Save") { save() }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Keeps the prompt's blocks and its negative prompt.")
        }
        .confirmationDialog("Delete this saved prompt?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { saved in
            Button("Delete", role: .destructive) { app.promptLibrary.delete(saved.id) }
        } message: { saved in
            Text("“\(saved.name)” will be removed.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.book.closed.fill")
                .font(.system(size: 24))
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text("Prompt Library")
                    .font(.title3.weight(.semibold))
                Text("\(app.promptLibrary.prompts.count) saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            searchField
            Button {
                newName = suggestedName
                showsSave = true
            } label: {
                Label("Save Current…", systemImage: "plus")
            }
            .disabled(promptIsEmpty)
            .help("Save the prompt in the controls")
            Button("Done") { dismissWindow(id: WindowID.prompts) }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search saved prompts", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 200)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var content: some View {
        if app.promptLibrary.prompts.isEmpty {
            ContentUnavailableView {
                Label("No Saved Prompts", systemImage: "text.book.closed")
            } description: {
                Text("Write a prompt, then press Save Current… to keep it here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filtered) { saved in
                row(saved)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ saved: SavedPrompt) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(saved.name)
                    .font(.headline)
                Text(saved.preview.isEmpty ? "No prompt text" : saved.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !saved.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Negative: \(saved.negativePrompt)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(saved.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Use") { app.use(saved) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Put this prompt in the controls, changing nothing else")
            Button {
                pendingDelete = saved
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this saved prompt")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Use Prompt") { app.use(saved) }
            Divider()
            Button("Delete", role: .destructive) { pendingDelete = saved }
        }
    }

    /// A name to start from: the prompt's first words.
    private var suggestedName: String {
        let text = app.settings.blocks
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return String(text.prefix(40))
    }

    private func save() {
        app.promptLibrary.save(
            name: newName,
            blocks: app.settings.blocks,
            negativePrompt: app.settings.negativePrompt
        )
        newName = ""
        query = ""
    }
}
