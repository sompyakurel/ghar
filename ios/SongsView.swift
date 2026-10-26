import SwiftUI
import AVFoundation

// Songs deck: infrastructure + placeholders. Som picks the real songs —
// adding one later = one JSON entry in backend/app/data/songs-v1.json
// + one .m4a in backend/app/static/audio/songs-v1/ (filename goes in the
// entry's "audio" field, has_audio flipped true). No code changes, no
// app update beyond the content rebuild. Never invent lyrics or audio.
struct Song: Codable, Identifiable {
    let id: String
    let titleNe: String
    let titleEn: String
    let lyricsNe: [String]
    let lyricsEn: [String]
    let audio: String?       // filename in audio/songs-v1/, nil when none yet
    let hasAudio: Bool
    let image: String?       // e.g. "/images/nepal-v1/rhyme_khaibiralo.jpg", nil when none
}

struct SongsPack: Codable {
        let id: String
        let version: String
        let songs: [Song]
    }
    
    enum SongsAPI {
        /// Same loading pattern as GharAPI.fetchPack: bundled file first,
        /// Mac dev server as fallback.
        static func fetchSongs() async throws -> SongsPack {
            let base = GharAPI.baseURLString
            guard let root = URL(string: base) else { throw URLError(.badURL) }
            let url = root.appendingPathComponent("packs").appendingPathComponent("songs-v1")
            let data: Data
            if url.isFileURL {
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
            return try decoder.decode(SongsPack.self, from: data)
        }
    }
    
    struct SongsView: View {
        @State private var songs: [Song] = []
        @State private var errorMessage: String?
        
        var body: some View {
            Group {
                if let errorMessage {
                    VStack(spacing: 12) {
                        Text("Couldn't load songs")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if songs.isEmpty {
                    ProgressView()
                } else {
                    List(songs) { song in
                        NavigationLink {
                            SongDetailView(song: song)
                        } label: {
                            HStack(spacing: 12) {
                                Text("🎵").font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(song.titleNe).font(.headline)
                                    Text(song.titleEn).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if song.hasAudio, song.audio != nil {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.blue)
                                } else {
                                    Text("Audio coming soon")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Songs")
            .task { await load() }
        }
        
        private func load() async {
            do {
                songs = try await SongsAPI.fetchSongs().songs
            } catch {
                errorMessage = "Check your connection and try again."
            }
        }
    }
    
    struct SongDetailView: View {
        let song: Song
        @State private var player: AVPlayer?
        @State private var isPlaying = false
        
        var body: some View {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 6) {
                        Text(song.titleNe)
                            .font(.largeTitle)
                        Text(song.titleEn)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    
                    if song.hasAudio, let file = song.audio {
                        Button {
                            togglePlay(file: file)
                        } label: {
                            Label(isPlaying ? "Pause" : "Play",
                                  systemImage: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Text("Audio coming soon — Som is picking the songs!")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    if song.lyricsNe.isEmpty {
                        Text("Lyrics coming soon.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 14) {
                            ForEach(Array(song.lyricsNe.enumerated()), id: \.offset) { i, line in
                                VStack(spacing: 2) {
                                    Text(line)
                                        .font(.title2)
                                        .multilineTextAlignment(.center)
                                    if i < song.lyricsEn.count {
                                        Text(song.lyricsEn[i])
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(song.titleEn)
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                player?.pause()
                isPlaying = false
            }
        }
        
        private func togglePlay(file: String) {
            if isPlaying {
                player?.pause()
                isPlaying = false
                return
            }
            // Missing file = stay silent. No crash, no TTS fallback weirdness.
            guard let url = URL(string: GharAPI.baseURLString + "/audio/songs-v1/" + file) else { return }
            if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { return }
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
            isPlaying = true
        }
    }
    
    // MARK: - Rhymes
    // Traditional folk rhymes for young kids, recorded in Som's voice.
    // Same data shape as Songs (rhymes-v1.json), audio in audio/rhymes-v1/.
    
    struct RhymesPack: Codable {
        let id: String
        let version: String
        let songs: [Song]
    }
    
    enum RhymesAPI {
        static func fetchRhymes() async throws -> RhymesPack {
            let base = GharAPI.baseURLString
            guard let root = URL(string: base) else { throw URLError(.badURL) }
            let url = root.appendingPathComponent("packs").appendingPathComponent("rhymes-v1")
            let data: Data
            if url.isFileURL {
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
            return try decoder.decode(RhymesPack.self, from: data)
        }
    }
    
    struct RhymesView: View {
        @State private var rhymes: [Song] = []
        @State private var errorMessage: String?
        
        var body: some View {
            Group {
                if let errorMessage {
                    VStack(spacing: 12) {
                        Text("Couldn't load rhymes")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if rhymes.isEmpty {
                    ProgressView()
                } else {
                    List(rhymes) { rhyme in
                        NavigationLink {
                            RhymeDetailView(rhyme: rhyme)
                        } label: {
                            HStack(spacing: 12) {
                                Text("🎶").font(.title2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rhyme.titleNe).font(.headline)
                                    Text(rhyme.titleEn).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if rhyme.hasAudio, rhyme.audio != nil {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.blue)
                                } else {
                                    Text("Audio coming soon")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Rhymes")
            .task { await load() }
        }
        
        private func load() async {
            do {
                rhymes = try await RhymesAPI.fetchRhymes().songs
            } catch {
                errorMessage = "Check your connection and try again."
            }
        }
    }
    
    struct RhymeDetailView: View {
        let rhyme: Song
        @State private var player: AVPlayer?
        @State private var isPlaying = false
        
        var body: some View {
            ScrollView {
                VStack(spacing: 24) {
                    if let img = rhyme.image,
                       let url = URL(string: GharAPI.baseURLString + img) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 280)
                                    .clipShape(RoundedRectangle(cornerRadius: 18))
                            } else {
                                Text("\u{1F3B5}").font(.system(size: 72))
                            }
                        }
                    }
                    
                    VStack(spacing: 6) {
                        Text(rhyme.titleNe)
                            .font(.largeTitle)
                        Text(rhyme.titleEn)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    
                    if rhyme.hasAudio, let file = rhyme.audio {
                        Button {
                            togglePlay(file: file)
                        } label: {
                            Label(isPlaying ? "Pause" : "Play",
                                  systemImage: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Text("Audio coming soon")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    if rhyme.lyricsNe.isEmpty {
                        Text("Lyrics coming soon.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 14) {
                            ForEach(Array(rhyme.lyricsNe.enumerated()), id: \.offset) { i, line in
                                VStack(spacing: 2) {
                                    Text(line)
                                        .font(.title2)
                                        .multilineTextAlignment(.center)
                                    if i < rhyme.lyricsEn.count {
                                        Text(rhyme.lyricsEn[i])
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(rhyme.titleEn)
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                player?.pause()
                isPlaying = false
            }
        }
        
        private func togglePlay(file: String) {
            if isPlaying {
                player?.pause()
                isPlaying = false
                return
            }
            guard let url = URL(string: GharAPI.baseURLString + "/audio/rhymes-v1/" + file) else { return }
            if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { return }
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
            isPlaying = true
        }
    }
