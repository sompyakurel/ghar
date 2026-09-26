import Foundation

/// The app's only connection to our Python backend.
/// One job: download the content pack as JSON and decode it.
///
/// Teaching notes:
/// - `async throws`: the network call suspends without freezing the UI.
///   The `await` in ContentView is where the magic happens.
/// - `.convertFromSnakeCase`: backend sends `audio_url`, Swift style is
///   `audioUrl`. This one line handles every field — no manual mapping.
/// - Simulator shares your Mac's network, so `localhost:8000` just works.
///   On a real iPhone later, swap this for your Mac's local IP address.
class GharAPI {
    static let shared = GharAPI()

    /// One place for the server address, so every call (JSON + audio) uses it.
    static let baseURLString = "http://localhost:8000"

    private var baseURL: URL { URL(string: Self.baseURLString)! }

    func fetchPack(packId: String = "nepal-v1") async throws -> ContentPack {
        let url = baseURL.appendingPathComponent("packs/\(packId)")
        let (data, response) = try await URLSession.shared.data(from: url)

        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ContentPack.self, from: data)
    }
}
