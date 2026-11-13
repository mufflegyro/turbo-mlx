import Foundation

/// One reusable style prompt from the MOSS-Image Character & Style Catalog. Only the prompt text
/// is bundled; the catalog's generated sample images stay out of the app.
nonisolated struct StylePreset: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let category: String
    let categoryName: String
    let prompt: String
    let tags: String
}

nonisolated struct StyleCategory: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// The bundled style catalog, read once from `styles.json`.
nonisolated struct StyleCatalog: Codable, Sendable {
    let source: String
    let sourceURL: String
    let license: String
    let categories: [StyleCategory]
    let styles: [StylePreset]

    static let shared: StyleCatalog = load()

    private static func load() -> StyleCatalog {
        let candidates = [
            Bundle.main.url(forResource: "styles", withExtension: "json"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("TurboMLX/Resources/styles.json"),
        ].compactMap { $0 }
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let catalog = try? JSONDecoder().decode(StyleCatalog.self, from: data) {
                return catalog
            }
        }
        return StyleCatalog(source: "", sourceURL: "", license: "", categories: [], styles: [])
    }
}
