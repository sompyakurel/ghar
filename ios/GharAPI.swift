import Foundation

/// The app's content: the Nepal pack JSON, all audio, all images.
/// Since Phase 2 these ride INSIDE the app — no server needed.
/// A build-phase script (ios/BundleContent.sh) mirrors ../backend into the
/// bundle under Content/ at compile time, keeping the backend's URL layout
/// (/packs/…, /audio/…, /images/…). Every `baseURLString + path` call site
/// works unchanged — the base is just a file:// URL now.
///
/// Teaching notes:
/// - `baseURLString` points at the bundle's Content folder when it's there
///   (AVPlayer and AsyncImage read file:// URLs just fine). If the folder
///   is missing it falls back to his Mac backend, so dev never hard-breaks.
/// - `static let` with a closure: runs once, the first time anyone reads it.
/// - URLSession can read file:// URLs too — they just don't come back with
///   an HTTP response, hence the `if let http` check in fetchPack.
/// - `.convertFromSnakeCase`: backend sends `audio_url`, Swift style is
///   `audioUrl`. This one line handles every field — no manual mapping.
class GharAPI {
    static let shared = GharAPI()

    /// Bundle's Content folder first, Mac dev server as fallback.
    static let baseURLString: String = {
        if let content = Bundle.main.resourceURL?.appendingPathComponent("Content"),
           FileManager.default.fileExists(atPath: content.path) {
            return content.absoluteString
        }
        return "http://localhost:8000"
    }()

    private var baseURL: URL { URL(string: Self.baseURLString)! }

    func fetchPack(packId: String = "nepal-v1") async throws -> ContentPack {
        // One component at a time: appendingPathComponent percent-encodes a
        // "/" inside a single call ("packs%2Fnepal-v1"), which a file://
        // URL won't decode back. The old server forgave it; the bundle doesn't.
        let url = baseURL.appendingPathComponent("packs").appendingPathComponent(packId)

        let data: Data
        if url.isFileURL {
            // Bundled pack: read straight from disk. Data(contentsOf:) is
            // the right tool for a local file; URLSession is for the server.
            data = try Data(contentsOf: url)
        } else {
            let (netData, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse {
                guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
            }
            data = netData
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ContentPack.self, from: data)
    }
}
