import Foundation
import Observation

/// A prompt kept in the library: the prompt's blocks (their names and text) and its negative
/// prompt. Nothing else — the model, size, steps, seed, transparency and LoRAs are not saved, so
/// using a prompt never changes how the next image is made.
nonisolated struct SavedPrompt: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var blocks: [PromptBlock]
    var negativePrompt: String
    var createdAt = Date()

    /// The prompt as one line, for a row's second line.
    var preview: String {
        blocks.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The prompts the user saved, newest first, in a JSON file in Application Support.
@Observable
final class PromptLibrary {
    static let directory = BackendController.supportDirectory
        .appending(path: "Prompt Library", directoryHint: .isDirectory)

    private var fileURL: URL { Self.directory.appending(path: "prompts.json") }

    private(set) var prompts: [SavedPrompt] = []
    /// Why the file could not be read or written, for the window to show.
    private(set) var problem: String?

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load() {
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            let stored = try Self.decoder.decode([SavedPrompt].self, from: Data(contentsOf: fileURL))
            prompts = stored.sorted { $0.createdAt > $1.createdAt }
            problem = nil
        } catch {
            problem = "The saved prompts could not be read: \(error.localizedDescription)"
        }
    }

    /// Saves the prompt (its blocks and negative prompt) under `name`; returns it.
    @discardableResult
    func save(name: String, blocks: [PromptBlock], negativePrompt: String) -> SavedPrompt {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedPrompt(name: trimmed.isEmpty ? "Untitled Prompt" : trimmed,
                                blocks: blocks, negativePrompt: negativePrompt)
        prompts.insert(saved, at: 0)
        write()
        return saved
    }

    func delete(_ id: SavedPrompt.ID) {
        prompts.removeAll { $0.id == id }
        write()
    }

    func rename(_ id: SavedPrompt.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        prompts[index].name = trimmed
        write()
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try Self.encoder.encode(prompts).write(to: fileURL, options: .atomic)
            problem = nil
        } catch {
            problem = "The prompt could not be saved: \(error.localizedDescription)"
        }
    }
}
