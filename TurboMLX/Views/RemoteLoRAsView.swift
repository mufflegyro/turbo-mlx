import SwiftUI

/// The render Mac's LoRA library: files another client used in a generation and the relay kept,
/// so a new Mac can import them instead of hunting for the download again.
struct RemoteLoRAsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("LoRAs on the Render Mac", systemImage: "externaldrive.connected.to.line.below")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    app.loadRemoteLoRAs(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(app.remoteLoRAsLoading)
                .help("Read the render Mac’s LoRAs again")
            }
            Text("A LoRA used in a generation is kept on the render Mac. Importing copies it to this Mac’s LoRA library; the file is transferred once, over the same connection as the models.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = app.remoteLoRAError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Group {
                if app.remoteLoRAsLoading, app.remoteLoRAs.isEmpty {
                    ProgressView("Reading the render Mac’s LoRAs…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if app.remoteLoRAs.isEmpty {
                    ContentUnavailableView(
                        "No LoRAs yet",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("LoRAs used in a generation on the render Mac appear here, ready to import.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(app.remoteLoRAs) { lora in
                                RemoteLoRARow(lora: lora)
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text("\(app.remoteLoRAs.count) LoRA\(app.remoteLoRAs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
        .task { app.loadRemoteLoRAs() }
    }
}

private struct RemoteLoRARow: View {
    @Environment(AppModel.self) private var app
    let lora: RemoteBackend.RemoteLoRA

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lora.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let family = lora.family {
                        Text(ModelFamily(rawValue: family)?.displayName ?? family)
                    }
                    Text(Format.bytes(lora.bytes))
                    if let date = lora.addedAt {
                        Text(date, format: .dateTime.year().month().day())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if app.importingRemoteLoRAs.contains(lora.id) {
                ProgressView()
                    .controlSize(.small)
                Text("Importing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isInLibrary {
                Label("In library", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Import") { app.importRemoteLoRA(lora) }
            }
        }
        .padding(.vertical, 7)
    }

    /// Imported in this session, or a file of that name is already in the library (an import
    /// earlier in another session).
    private var isInLibrary: Bool {
        app.importedRemoteLoRAs.contains(lora.id)
            || app.loraLibrary.entries.contains {
                $0.file.caseInsensitiveCompare(lora.name) == .orderedSame
            }
    }
}
