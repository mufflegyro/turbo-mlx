import AppKit
import SwiftUI

/// The history as a grid: everything the strip holds, filtered by the model that made it and by
/// what it is, and searched by prompt. A click puts the item on the stage — its settings back in
/// the controls, as a strip thumbnail does — and closes the sheet. The padlock still decides which
/// history is browsed: the gallery shows what the strip shows.
struct GalleryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    /// A media kind, or nil for every kind.
    @State private var kind: MediaKind?
    @State private var query = ""
    /// True once the stored position has been scrolled back to (or there was none to restore):
    /// until then the visibility tracking below stays off, so it does not record the top the
    /// sheet starts at before the restore lands.
    @State private var hasRestored = false

    /// The presenting window's content size, so the sheet opens relative to it rather than at one
    /// fixed size: nine tenths of the window, kept between the limits below — big enough to be
    /// worth browsing, small enough to fit a window that is not maximized.
    let windowSize: CGSize

    /// The item that was first showing when the gallery last closed. Kept as it was at
    /// construction — before any layout, so nothing can have overwritten it — and scrolled back
    /// to once the grid has appeared (a ScrollPosition seeded at init does not restore on this
    /// macOS; an id-targeted scroll after the first layout does).
    let initiallyShowing: HistoryItem.ID?

    /// The smallest and largest the gallery opens at, and can be dragged to: the minimum the
    /// sheet had before it followed the window, and a ceiling for big displays.
    private static let sheetMinimum = CGSize(width: 900, height: 600)
    private static let sheetMaximum = CGSize(width: 1600, height: 1040)

    /// Nine tenths of the presenting window, clamped to those limits.
    private var sheetSize: CGSize {
        CGSize(
            width: min(max(windowSize.width * 0.9, Self.sheetMinimum.width), Self.sheetMaximum.width),
            height: min(max(windowSize.height * 0.9, Self.sheetMinimum.height), Self.sheetMaximum.height)
        )
    }

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 320), spacing: 12)]

    /// The kind menu's rows: what the history holds, as the empty states name them.
    private static let kinds: [GalleryKind] = [
        GalleryKind(kind: .image, title: "Images", icon: "photo", noun: "images"),
        GalleryKind(kind: .video, title: "Clips", icon: "film", noun: "clips"),
        GalleryKind(kind: .model3D, title: "3D Objects", icon: "cube", noun: "3D objects"),
        GalleryKind(kind: .audio, title: "Songs & Sounds", icon: "music.note", noun: "songs & sounds"),
    ]

    // MARK: Filtering

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The items the kind and search filters leave — what the model filter then narrows. The
    /// model menu's counts and the "3 shown of 42" beside them come from it, so the menu only
    /// offers models with something to show under the other filters.
    private var otherFiltered: [HistoryItem] {
        app.visibleHistory.filter { item in
            (kind == nil || item.kind == kind)
                && (trimmedQuery.isEmpty
                    || item.prompt.lowercased().contains(trimmedQuery)
                    || item.caption.lowercased().contains(trimmedQuery))
        }
    }

    /// The filter that counts: the model picked, while the browsed history still holds its
    /// items. One whose last item was deleted while the sheet is open stops filtering, rather
    /// than leave a grid that is empty while "All Models" shows.
    private var effectiveModelID: String? {
        guard let id = app.galleryModelFilter else { return nil }
        return app.visibleHistory.contains { $0.modelID == id } ? id : nil
    }

    private var filtered: [HistoryItem] {
        guard let id = effectiveModelID else { return otherFiltered }
        return otherFiltered.filter { $0.modelID == id }
    }

    /// A model's name as the menu and the empty state show it, listed or not: the catalog's
    /// short name, then the name its items were saved with, then the id itself.
    private func modelName(_ id: String) -> String {
        app.models.first { $0.id == id }?.shortName
            ?? app.visibleHistory.first { $0.modelID == id }?.modelName
            ?? id
    }

    /// The models the other filters leave, each with how many of the items it made also match
    /// them, by name.
    private var models: [GalleryModel] {
        Dictionary(grouping: otherFiltered, by: \.modelID)
            .map { GalleryModel(id: $0.key, name: modelName($0.key), count: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The model menu's title: the model picked, or "All Models".
    private var modelLabel: String {
        effectiveModelID.map(modelName) ?? "All Models"
    }

    /// The kind menu's title and icon, or "All Kinds".
    private var kindLabel: String {
        kind.flatMap { k in Self.kinds.first { $0.kind == k }?.title } ?? "All Kinds"
    }

    private var kindIcon: String {
        kind.flatMap { k in Self.kinds.first { $0.kind == k }?.icon } ?? "square.grid.2x2"
    }

    /// How the empty state names the kind picked: "No 3D objects", not "No 3d objects".
    private var kindNoun: String {
        kind.flatMap { k in Self.kinds.first { $0.kind == k }?.noun } ?? ""
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filters
            Divider()
            content
            Divider()
            footer
        }
        .frame(
            minWidth: Self.sheetMinimum.width, idealWidth: sheetSize.width, maxWidth: Self.sheetMaximum.width,
            minHeight: Self.sheetMinimum.height, idealHeight: sheetSize.height, maxHeight: Self.sheetMaximum.height
        )
        // A plain sheet opens at the frame's minimum width on this macOS, whatever its ideal:
        // .fitted makes it open (and, when the window behind it is resized, stay) at the ideal
        // the frame above computes from the presenting window.
        .presentationSizing(.fitted)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { dismiss() }
    }

    // MARK: Header, filters, footer

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 26))
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Gallery")
                    .font(.title2.weight(.semibold))
                Text(app.showsPrivateHistory
                     ? "The private history, as the strip’s padlock shows it."
                     : "Everything the history holds, newest first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            searchField
            Button("Close") { dismiss() }
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search prompts", text: $query)
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
        @Bindable var app = app
        return HStack(spacing: 8) {
            Menu {
                // The selection reads through the effective filter, so a model whose last item
                // was deleted while the sheet is open reads as "All Models" here too.
                Picker("Model", selection: Binding(
                    get: { effectiveModelID },
                    set: { app.galleryModelFilter = $0 }
                )) {
                    Text("All Models").tag(String?.none)
                    ForEach(models) { model in
                        Text("\(model.name) · \(model.count)").tag(String?.some(model.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(modelLabel, systemImage: "cpu")
                    .font(.callout)
            }
            .fixedSize()
            .help("Show only what one model made")

            Menu {
                Picker("Kind", selection: $kind) {
                    Text("All Kinds").tag(MediaKind?.none)
                    ForEach(Self.kinds) { entry in
                        Label(entry.title, systemImage: entry.icon).tag(MediaKind?.some(entry.kind))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(kindLabel, systemImage: kindIcon)
                    .font(.callout)
            }
            .fixedSize()
            .help("Show only images, clips, 3D objects or songs")

            Spacer(minLength: 8)
            Text(filtered.count == otherFiltered.count
                 ? "\(filtered.count) shown"
                 : "\(filtered.count) shown of \(otherFiltered.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.trailing, 16)
        }
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Click an image to put it on the stage, with its settings back in the controls.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if app.visibleHistory.isEmpty {
                    empty(app.showsPrivateHistory ? "Nothing Private Yet" : "Nothing to Browse Yet",
                          detail: app.showsPrivateHistory
                          ? "Turn the padlock off to browse the whole history, or move images here from their menus."
                          : "Generate an image, and everything you make stays here, in the history.")
                } else if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Nothing Matches").font(.headline)
                        Text(emptyDetail).font(.caption).foregroundStyle(.secondary)
                        Button("Show Everything") {
                            app.galleryModelFilter = nil
                            kind = nil
                            query = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filtered) { item in
                            GalleryTile(item: item) {
                                app.select(item, undoManager: undoManager)
                                dismiss()
                            }
                            .id(item.id)
                        }
                    }
                    .padding(16)
                    .scrollTargetLayout()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Back where the gallery was last left, its tile at the top. One runloop after
            // appearing — the layout has to exist before a scroll can land in it.
            .onAppear {
                if let initiallyShowing {
                    DispatchQueue.main.async {
                        proxy.scrollTo(initiallyShowing, anchor: .top)
                        hasRestored = true
                    }
                } else {
                    hasRestored = true
                }
            }
            // The first item showing, kept as it changes: closing with Done, Close or Esc keeps
            // the position too, not only picking an image — and the next open starts here again.
            .onScrollTargetVisibilityChange(idType: HistoryItem.ID.self) { visible in
                guard hasRestored else { return }
                if let first = filtered.first(where: { visible.contains($0.id) }) {
                    app.galleryScrollsTo = first.id
                }
            }
        }
    }

    /// "No clips from Krea 2 Turbo matching “A cat”" — the kind as its noun, the search as it
    /// was typed, the model by name whether or not it is still listed.
    private var emptyDetail: String {
        let subject = kind != nil ? "No \(kindNoun)" : "Nothing"
        let source = effectiveModelID != nil ? " from \(modelLabel)" : ""
        let search = !trimmedQuery.isEmpty
            ? " matching “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”" : ""
        return "\(subject)\(source)\(search) — try another filter, or clear them all."
    }

    private func empty(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

/// One row of the model menu: a model the history holds, and how many items it made.
private struct GalleryModel: Identifiable {
    let id: String
    let name: String
    let count: Int
}

/// One row of the kind menu: a media kind, named as the empty states name it.
private struct GalleryKind: Identifiable {
    let kind: MediaKind
    let title: String
    let icon: String
    /// Its plural as a sentence has it: "No 3D objects", not "No 3d objects".
    let noun: String

    var id: MediaKind { kind }
}

/// One item in the grid: the poster as a square — the picture itself, a clip's first frame or a
/// song's waveform — with the badges the strip's thumbnails carry and the same context menu.
private struct GalleryTile: View {
    @Environment(AppModel.self) private var app
    let item: HistoryItem
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            // A square cell: the base sizes it, the image fills it and is clipped, so the grid
            // lines up whatever each item's own shape is (the stage shows it whole once clicked).
            Group {
                if item.request.transparentBackground {
                    Checkerboard(squareSize: 6)
                } else {
                    Color.clear
                }
            }
            .overlay(FileImage(url: app.posterURL(for: item), maxPixelSize: 320).aspectRatio(contentMode: .fill))
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .video || item.kind == .audio {
                        Image(systemName: item.isSoundEffect ? "waveform" : item.kind == .audio ? "music.note" : "play.fill")
                            .font(.caption)
                            .padding(5)
                            .background(.black.opacity(0.5), in: Circle())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Which engine on the render Mac produced it; local items are this Mac's
                    // native engine and carry no tag.
                    if let engine = item.engine {
                        Text(engine == "mflux" ? "mflux" : "native")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(6)
                            .help(engine == "mflux"
                                  ? "Rendered by the render Mac's mflux engine"
                                  : "Rendered by the render Mac's native engine")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // An upscale of another picture, as its factor ("2×").
                    if let factor = item.request.upscale {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                            Text(upscaleTag(factor))
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(6)
                        .help("Upscaled \(upscaleTag(factor))")
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isHovered ? Color.active : Color.primary.opacity(0.1),
                                      lineWidth: isHovered ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { HistoryItemMenu(item: item) }
        .onHover { isHovered = $0 }
        .help(item.caption)
        .accessibilityLabel(item.caption)
    }
}

/// "2×": an upscale's factor, as the badges show it.
private func upscaleTag(_ factor: Double) -> String {
    let value = factor.rounded() == factor
        ? "\(Int(factor))"
        : factor.formatted(.number.precision(.fractionLength(1)))
    return "\(value)×"
}
