import AppKit
import SwiftUI

/// The Styles & Prompts browser: the bundled style catalog and the prompts the user saved.
/// A style appends to (or replaces) the prompt's Style block; a saved prompt puts its blocks and
/// negative prompt back. Neither changes how the next image is made.
struct PromptLibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// A category id, or nil for all styles.
    @State private var category: String?
    /// My prompts instead of the catalog.
    @State private var mine = false
    @State private var copied: String?
    @State private var showsSave = false
    @State private var newName = ""
    @State private var pendingDelete: SavedPrompt?

    private let columns = [GridItem(.adaptive(minimum: 290, maximum: 460), spacing: 14)]
    private let catalog = StyleCatalog.shared

    // MARK: Filtering

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredStyles: [StylePreset] {
        let order = Dictionary(uniqueKeysWithValues: catalog.categories.enumerated().map { ($0.element.id, $0.offset) })
        return catalog.styles.filter { style in
            (category == nil || style.category == category)
                && (trimmedQuery.isEmpty
                    || style.name.lowercased().contains(trimmedQuery)
                    || style.prompt.lowercased().contains(trimmedQuery)
                    || style.tags.lowercased().contains(trimmedQuery)
                    || style.categoryName.lowercased().contains(trimmedQuery))
        }.sorted {
            let a = order[$0.category] ?? 99, b = order[$1.category] ?? 99
            return a == b ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : a < b
        }
    }

    private var filteredSaved: [SavedPrompt] {
        guard !trimmedQuery.isEmpty else { return app.promptLibrary.prompts }
        return app.promptLibrary.prompts.filter {
            $0.name.lowercased().contains(trimmedQuery) || $0.preview.lowercased().contains(trimmedQuery)
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
            filters
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
            footer
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 600, idealHeight: 700)
        // .fitted opens the sheet at the frame's ideal: without it, macOS opens it at the
        // minimum width instead (900 wide, not the 1040 the ideal asks for).
        .presentationSizing(.fitted)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Save Current Prompt", isPresented: $showsSave) {
            TextField("Name", text: $newName, prompt: Text("Untitled Prompt"))
            Button("Save") { save() }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Keeps the prompt's blocks and its negative prompt. Using it later changes nothing else.")
        }
        .confirmationDialog("Delete this saved prompt?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { saved in
            Button("Delete", role: .destructive) { app.promptLibrary.delete(saved.id) }
        } message: { saved in
            Text("“\(saved.name)” will be removed.")
        }
        .onExitCommand { dismiss() }
    }

    // MARK: Header, filters, footer

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 26))
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Styles & Prompts")
                    .font(.title2.weight(.semibold))
                Text("\(catalog.styles.count) style prompts across \(catalog.categories.count) categories, plus your own reusable prompts.")
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
            Button("Close") { dismiss() }
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(mine ? "Search my prompts" : "Search styles and prompts", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 220)
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

    private var filters: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    chip("All styles", icon: "square.grid.2x2", selected: !mine && category == nil) {
                        mine = false; category = nil
                    }
                    chip("My prompts", icon: "bookmark", selected: mine) {
                        mine = true; category = nil
                    }
                    ForEach(catalog.categories) { item in
                        chip(StyleVisuals.shortName(item.id), icon: StyleVisuals.icon(item.id),
                             selected: !mine && category == item.id) {
                            mine = false; category = item.id
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            Spacer(minLength: 8)
            Text(mine ? "\(filteredSaved.count) saved" : "\(filteredStyles.count) shown")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 16)
        }
        .padding(.vertical, 9)
    }

    private func chip(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? .white : .primary)
                .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay(Capsule().stroke(selected ? .clear : .black.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !mine {
                Text("Style prompts: \(catalog.source) (\(catalog.license))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let url = URL(string: catalog.sourceURL), !catalog.sourceURL.isEmpty {
                    Link("Source", destination: url).font(.caption2)
                }
            } else {
                Text("Saved prompts keep their blocks and negative prompt.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Save Current…") {
                newName = suggestedName
                showsSave = true
            }
            .disabled(promptIsEmpty)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            if mine {
                savedGrid
            } else if filteredStyles.isEmpty {
                empty("No styles match “\(query)”", detail: "Try a different name, category or material.")
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filteredStyles) { style in styleCard(style) }
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "paintpalette")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var savedGrid: some View {
        Group {
            if app.promptLibrary.prompts.isEmpty {
                empty("No saved prompts yet",
                      detail: "Write a prompt, then press Save Current… to keep it here.")
            } else if filteredSaved.isEmpty {
                empty("No saved prompts match “\(query)”", detail: "Try a different name or prompt word.")
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filteredSaved) { saved in savedCard(saved) }
                }
                .padding(16)
            }
        }
    }

    // MARK: Cards

    private func styleCard(_ style: StylePreset) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBlock(gradient: StyleVisuals.gradient(style.category), icon: StyleVisuals.icon(style.category),
                        tag: style.categoryName.uppercased(), height: 76)
            VStack(alignment: .leading, spacing: 6) {
                Text(style.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(style.prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                HStack(spacing: 6) {
                    Button("Use") { useStyle(style) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Append the style to the prompt's Style block")
                    Button(copied == style.id ? "Copied" : "Copy") { copy(style.prompt, id: style.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer()
                    Menu {
                        Button("Append to Style Block") { useStyle(style) }
                        Button("Replace Style Block") { replaceStyle(style) }
                        Divider()
                        Button("Copy Style Prompt") { copy(style.prompt, id: style.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More ways to use this style")
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.black.opacity(0.08)))
        .contextMenu {
            Button("Append to Style Block") { useStyle(style) }
            Button("Replace Style Block") { replaceStyle(style) }
            Button("Copy Style Prompt") { copy(style.prompt, id: style.id) }
        }
    }

    private func savedCard(_ saved: SavedPrompt) -> some View {
        let tags = [
            saved.blocks.count == 1 ? "1 BLOCK" : "\(saved.blocks.count) BLOCKS",
            saved.negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "NEGATIVE",
        ].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 0) {
            headerBlock(gradient: StyleVisuals.savedGradient, icon: "bookmark.fill", tag: tags, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(saved.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(saved.preview.isEmpty ? "No prompt text" : saved.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                HStack(spacing: 6) {
                    Button("Use") { app.use(saved); dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Put this prompt in the controls, changing nothing else")
                    Button(copied == saved.id.uuidString ? "Copied" : "Copy") {
                        copy(saved.preview, id: saved.id.uuidString)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                    Button { pendingDelete = saved } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Delete this saved prompt")
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.black.opacity(0.08)))
        .contextMenu {
            Button("Use Prompt") { app.use(saved); dismiss() }
            Button("Copy Prompt") { copy(saved.preview, id: saved.id.uuidString) }
            Divider()
            Button("Delete", role: .destructive) { pendingDelete = saved }
        }
    }

    /// The coloured block at the top of a card: a gradient, the category's icon, and its tag.
    private func headerBlock(gradient: LinearGradient, icon: String, tag: String, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            gradient
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(tag)
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.28), in: Capsule())
                .padding(8)
        }
        .frame(height: height)
        .clipped()
    }

    // MARK: Actions

    private func useStyle(_ style: StylePreset) {
        app.appendStyle(style.prompt)
        dismiss()
    }

    private func replaceStyle(_ style: StylePreset) {
        app.replaceStyle(style.prompt)
        dismiss()
    }

    private func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == id { copied = nil }
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
        mine = true
        category = nil
    }
}

/// The catalog's categories, drawn: a short name, an icon and a gradient each.
enum StyleVisuals {
    static func shortName(_ category: String) -> String {
        switch category {
        case "anime": "Anime"
        case "western": "Western"
        case "drawing": "Drawing"
        case "digital": "3D & Digital"
        case "craft": "Craft"
        case "traditional": "Traditional"
        case "contemporary": "Contemporary"
        case "painting": "Painting"
        default: category
        }
    }

    static func icon(_ category: String) -> String {
        switch category {
        case "anime": "sparkles"
        case "western": "theatermasks"
        case "drawing": "pencil.and.scribble"
        case "digital": "cube.transparent"
        case "craft": "scissors"
        case "traditional": "building.columns"
        case "contemporary": "paintpalette"
        case "painting": "photo.artframe"
        default: "paintbrush"
        }
    }

    static func gradient(_ category: String) -> LinearGradient {
        let colors: [Color]
        switch category {
        case "anime": colors = [Color(red: 0.95, green: 0.43, blue: 0.33), Color(red: 0.55, green: 0.23, blue: 0.60)]
        case "western": colors = [Color(red: 0.95, green: 0.68, blue: 0.18), Color(red: 0.20, green: 0.45, blue: 0.72)]
        case "drawing": colors = [Color(red: 0.60, green: 0.45, blue: 0.30), Color(red: 0.30, green: 0.23, blue: 0.18)]
        case "digital": colors = [Color(red: 0.18, green: 0.35, blue: 0.75), Color(red: 0.10, green: 0.65, blue: 0.70)]
        case "craft": colors = [Color(red: 0.38, green: 0.60, blue: 0.35), Color(red: 0.72, green: 0.50, blue: 0.20)]
        case "traditional": colors = [Color(red: 0.72, green: 0.20, blue: 0.18), Color(red: 0.85, green: 0.56, blue: 0.16)]
        case "contemporary": colors = [Color(red: 0.50, green: 0.25, blue: 0.75), Color(red: 0.10, green: 0.60, blue: 0.58)]
        case "painting": colors = [Color(red: 0.20, green: 0.40, blue: 0.65), Color(red: 0.65, green: 0.30, blue: 0.35)]
        default: colors = [Color.accentColor, Color.accentColor.opacity(0.55)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let savedGradient = LinearGradient(
        colors: [Color(red: 0.20, green: 0.25, blue: 0.42), Color(red: 0.10, green: 0.12, blue: 0.22)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}
