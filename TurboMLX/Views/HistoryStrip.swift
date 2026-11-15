import SwiftUI
import UniformTypeIdentifiers

/// Film strip of past images and clips, by date (the newest on the right) or in the order the user
/// dragged them into, then the running and queued jobs; a "+" that sets up the next one stays at its
/// right end, however far the strip is scrolled. A click shows an item or a job and puts its settings
/// on the left.
struct HistoryStrip: View {
    @Environment(AppModel.self) private var app
    @Binding var isCollapsed: Bool
    @State private var confirmsClear = false
    /// At the end, where the newest are, until the user scrolls away.
    @State private var position = ScrollPosition(edge: .trailing)
    /// What moves the "+" in line with the thumbnails: a scroll bar that is always shown takes room
    /// under the row, which then centers them in less than their height and padding, a little higher.
    @State private var rowOffset: CGFloat = 0

    private let headerHeight: CGFloat = 38
    private let rowPadding: CGFloat = 10
    /// The thumbnails' height: dragged from the header, and kept across launches.
    @AppStorage("historyThumbnailHeight") private var thumbnailHeightValue: Double = 92
    /// The drag in progress. A transient gesture value (as the prompt blocks use) keeps the
    /// resize out of the defaults until it is let go, which avoids re-laying out twice per event.
    @GestureState private var stretch: CGFloat = 0

    private var thumbnailHeight: CGFloat {
        thumbnailHeight(stretchedBy: stretch)
    }

    private func thumbnailHeight(stretchedBy amount: CGFloat) -> CGFloat {
        let stored = CGFloat(min(max(thumbnailHeightValue, 64), 200))
        // Dragging up (a negative translation) makes the thumbnails taller.
        return min(max(stored - amount, 64), 200)
    }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("History").font(.headline)
                    .allowsHitTesting(false)
                Text("\(app.visibleHistory.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                // The padlock: on, the strip shows the private history and the next generations
                // are kept there; off, the normal history and its generations.
                Button {
                    app.setPrivateHistory(!app.showsPrivateHistory)
                } label: {
                    Image(systemName: app.showsPrivateHistory ? "lock.fill" : "lock.open")
                        .foregroundStyle(app.showsPrivateHistory ? Color.active : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(app.showsPrivateHistory
                      ? "Private history: only the images kept here are shown, and new ones join them. Click to go back."
                      : "Show the private history. With it on, the images generated are kept there instead.")
                .accessibilityLabel(app.showsPrivateHistory ? "Private history shown" : "Show private history")
                Menu {
                    Picker("Order", selection: $app.historyOrder) {
                        ForEach(HistoryOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label(app.historyOrder.title, systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.leading, 6)
                .help("By date, the newest on the right, or in your own order: drag the images and clips where you want them")
                Spacer()
                Button {
                    withAnimation(.snappy) { isCollapsed.toggle() }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(isCollapsed ? "Show the history thumbnails" : "Hide the history thumbnails")
                .accessibilityLabel(isCollapsed ? "Show History" : "Hide History")
                Menu {
                    Button("Show Folder in Finder") {
                        NSWorkspace.shared.open(HistoryStore.directory)
                    }
                    Button("Clear Queue") { app.cancelAll() }
                        .disabled(!app.isBusy)
                    Divider()
                    Button("Clear History…", role: .destructive) { confirmsClear = true }
                        .disabled(app.visibleHistory.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            // The bar folds and resizes from its own surface, not from the buttons on it: the
            // drag layer sits behind them, and the title and count let clicks through to it.
            // The pointer is the prompt block's resize cursor only over the bar itself.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .pointerStyle(isCollapsed ? PointerStyle.default : .frameResize(position: .top))
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) { isCollapsed.toggle() }
                    }
                    .gesture(
                        // Global coordinates: the bar moves up as the strip grows, so a local
                        // drag would chase itself and make the thumbnails jump.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .updating($stretch) { value, state, _ in
                                guard !isCollapsed else { return }
                                state = value.translation.height
                            }
                            .onEnded { value in
                                guard !isCollapsed else { return }
                                thumbnailHeightValue = Double(thumbnailHeight(stretchedBy: value.translation.height))
                            }
                    )
                    .help("Double-click to fold or unfold the history; drag up or down to resize the thumbnails")
            }

            let isEmpty = app.visibleHistory.isEmpty && app.pendingJobs.isEmpty
            // The "+" outside the scroll view, so it is always there: back to the next generation
            // from anywhere in the history in one click, the strip staying where it was scrolled.
            HStack(alignment: .top, spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            ForEach(app.arrangedHistory) { item in
                                HistoryThumbnail(item: item, height: thumbnailHeight, isSelected: app.isSelected(item))
                                    .id(item.id)
                            }
                            // The running job next to the images it will join, then the queue.
                            ForEach(app.pendingJobs) { job in
                                JobThumbnail(job: job, height: thumbnailHeight, isSelected: app.isSelected(job))
                                    .id(job.id)
                            }
                            if isEmpty {
                                Text(app.showsPrivateHistory
                                     ? "Nothing private yet: turn the padlock on and generate, or move an image here from its menu."
                                     : "Generated images will appear here.")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                    .frame(height: thumbnailHeight)
                            }
                        }
                        .padding(.leading, 14)
                        .padding(.trailing, isEmpty ? 14 : 0)
                        .padding(.vertical, rowPadding)
                        // Only the vertical, which scrolling leaves alone.
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            let row = proxy.frame(in: .named("HistoryStrip"))
                            return row.minY + (row.height - thumbnailHeight) / 2 - rowPadding
                        } action: {
                            rowOffset = $0
                        }
                    }
                    .scrollIndicators(.automatic)
                    .scrollPosition($position)
                    .onChange(of: isCollapsed) { _, collapsed in
                        guard !collapsed else { return }
                        // A folded strip has no viewport, so the scroll view forgets where it
                        // was: bring the item on the stage — or the newest — back into view.
                        let target = app.displayedItem?.id ?? app.displayedJob?.id
                            ?? app.pendingJobs.last?.id ?? app.arrangedHistory.last?.id
                        guard let target else { return }
                        withAnimation(.snappy) { proxy.scrollTo(target, anchor: .trailing) }
                    }
                    .onChange(of: app.displayedItem?.id ?? app.displayedJob?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) }
                    }
                    // A new job: back to the end, where it is. Not after a deletion, which leaves the
                    // strip where it was.
                    .onChange(of: app.history.items.count + app.pendingJobs.count) { old, new in
                        guard new > old else { return }
                        withAnimation(.snappy) { position.scrollTo(edge: .trailing) }
                    }
                }
                if !isEmpty {
                    NewTile(height: thumbnailHeight)
                        .padding(.trailing, 14)
                        .padding(.vertical, rowPadding)
                        .offset(y: rowOffset)
                }
            }
            .coordinateSpace(.named("HistoryStrip"))
            // Folded, the row slides down out of the header's frame rather than fading: the
            // header stays, the stage takes the height back, and nothing is removed.
            .offset(y: isCollapsed ? thumbnailHeight + rowPadding * 2 : 0)
            .allowsHitTesting(!isCollapsed)
            .accessibilityHidden(isCollapsed)
        }
        .frame(height: isCollapsed ? headerHeight : thumbnailHeight + 48, alignment: .top)
        .clipped()
        .animation(.snappy, value: isCollapsed)
        .background(.background)
        .confirmationDialog(
            app.showsPrivateHistory ? "Clear the private history?" : "Clear the history?",
            isPresented: $confirmsClear
        ) {
            Button("Move \(app.visibleHistory.count) \(app.showsPrivateHistory ? "Private " : "")Images to the Trash",
                   role: .destructive) {
                app.clearHistory()
            }
        } message: {
            Text(app.showsPrivateHistory
                 ? "Only the images kept in the private history go to the Trash; the normal history stays."
                 : "The images go to the Trash, so you can still recover them from Finder.")
        }
    }
}

/// At the strip's right end: the next generation, set up with its settings on the left and its frame
/// on the right, for Generate to start.
private struct NewTile: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let height: CGFloat
    @State private var isHovered = false

    var body: some View {
        let isSelected = app.showsDraft
        Button { app.startDraft(undoManager: undoManager) } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered || isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.active, lineWidth: 3)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .overlay {
                    Image(systemName: "plus")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: height * 0.7, height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("New: the last one’s settings on the left, ready to change and generate")
        .accessibilityLabel("New")
    }
}

private func thumbnailWidth(for size: PixelSize, height: CGFloat) -> CGFloat {
    // A 3D object has no size: its still is square.
    guard size.width > 0, size.height > 0 else { return height }
    let ratio = CGFloat(size.width) / CGFloat(max(size.height, 1))
    return min(max(height * ratio, height * 0.56), height * 1.78)
}

/// "2×": an upscale's factor, as the thumbnail tag shows it.
private func upscaleTag(_ factor: Double) -> String {
    let value = factor.rounded() == factor
        ? "\(Int(factor))"
        : factor.formatted(.number.precision(.fractionLength(1)))
    return "\(value)×"
}

private struct HistoryThumbnail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let item: HistoryItem
    let height: CGFloat
    let isSelected: Bool

    var body: some View {
        let url = app.url(for: item)
        FileImage(url: app.posterURL(for: item), maxPixelSize: 320)
            .aspectRatio(contentMode: .fill)
            .frame(width: thumbnailWidth(for: item.size, height: height), height: height)
            .background {
                if item.request.transparentBackground { Checkerboard(squareSize: 6) }
            }
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video || item.kind == .audio {
                    Image(systemName: item.isSoundEffect ? "waveform" : item.kind == .audio ? "music.note" : "play.fill")
                        .font(.caption2)
                        .padding(4)
                        .background(.black.opacity(0.5), in: Circle())
                        .foregroundStyle(.white)
                        .padding(5)
                }
            }
            .overlay(alignment: .topTrailing) {
                // Which engine on the render Mac produced it (A9); local items are this Mac's
                // native engine and carry no tag.
                if let engine = item.engine {
                    Text(engine == "mflux" ? "mflux" : "native")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(5)
                        .help(engine == "mflux"
                              ? "Rendered by the render Mac's mflux engine"
                              : "Rendered by the render Mac's native engine")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // An upscale of another picture, as its factor ("2×"): the item's caption says
                // it in words once it is opened.
                if let factor = item.request.upscale {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text(upscaleTag(factor))
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(5)
                    .help("Upscaled \(upscaleTag(factor))")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.active : Color.primary.opacity(0.1), lineWidth: isSelected ? 3 : 1)
            }
            .contentShape(Rectangle())
            .onTapGesture { app.select(item, undoManager: undoManager) }
            .onHover { inside in
                // While the button is down the item under the pointer is the one being dragged:
                // leaving it, or passing over the others, must not change which one moves.
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                if inside {
                    app.pointedHistoryItem = item.id
                } else if app.pointedHistoryItem == item.id {
                    app.pointedHistoryItem = nil
                }
            }
            // The file, for Finder, other apps and the reference image; and the item itself, which
            // only this strip reads, to move it.
            .onDrag {
                app.pointedHistoryItem = item.id
                let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
                provider.registerDataRepresentation(for: .historyItem, visibility: .all) { completion in
                    completion(Data(item.id.uuidString.utf8), nil)
                    return nil
                }
                return provider
            }
            .onDrop(of: [.historyItem], delegate: HistoryMoveDelegate(target: item.id, app: app))
            .contextMenu { HistoryItemMenu(item: item) }
            .help(item.caption)
    }
}

/// Moves the dragged item into place as it passes over the others, so the strip shows where it
/// will land. While the drag lasts, its data cannot be read (`itemProviders` is only valid in
/// `performDrop`), and SwiftUI does not run `onDrag` again for a view dragged before: the item under
/// the pointer when the button went down names it (the tiles ignore hover while it is down: leaving
/// the dragged tile used to clear it, and the item stopped after a place or two). Should hover say
/// nothing, the drop moves the item, read from its `UTType.historyItem` data.
private struct HistoryMoveDelegate: DropDelegate {
    let target: HistoryItem.ID
    let app: AppModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.historyItem])
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = app.pointedHistoryItem else { return }
        move(dragged, to: target, app: app)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.historyItem]).first else { return false }
        let (target, app) = (target, app)
        _ = provider.loadDataRepresentation(for: .historyItem) { data, _ in
            guard let data, let dragged = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return }
            Task { @MainActor in
                // Already in place if it moved along the way.
                guard dragged != app.pointedHistoryItem else { return }
                move(dragged, to: target, app: app)
            }
        }
        return true
    }

    @MainActor
    private func move(_ dragged: HistoryItem.ID, to target: HistoryItem.ID, app: AppModel) {
        guard dragged != target else { return }
        withAnimation(.snappy) { app.moveHistoryItem(dragged, to: target) }
    }
}

/// A button, as the "+" is: a tap gesture would miss the click that brings the window forward.
private struct JobThumbnail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let job: GenerationJob
    let height: CGFloat
    let isSelected: Bool

    var body: some View {
        Button { app.select(job, undoManager: undoManager) } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.6))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Color.active, lineWidth: 3)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .overlay {
                    VStack(spacing: 6) {
                        if job.phase == .queued {
                            Image(systemName: "clock")
                                .foregroundStyle(.secondary)
                            Text("Queued").font(.caption2).foregroundStyle(.secondary)
                        } else if job.model.family.isUpscaler {
                            // One step: the ring follows the time instead, as the job's bar does.
                            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                                if let fraction = job.fraction(at: context.date) {
                                    ProgressView(value: fraction)
                                        .progressViewStyle(.circular)
                                        .controlSize(.small)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            Text("Upscale").font(.caption2).foregroundStyle(.secondary)
                        } else if let fraction = job.fraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                            Text("\(job.step)/\(job.totalSteps)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .frame(width: thumbnailWidth(for: job.request.size, height: height), height: height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(job.phase == .queued ? "Remove from Queue" : "Stop") { app.cancel(job) }
        }
        .help(job.request.caption)
        .accessibilityLabel(job.statusLabel)
    }
}
