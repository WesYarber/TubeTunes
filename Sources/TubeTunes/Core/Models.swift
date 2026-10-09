import Foundation

struct Chapter: Codable, Hashable {
    var title: String
    var start: Double
    var end: Double
}

/// One song cut out of a downloaded video. A normal music video has a single
/// segment; concerts and full-album uploads have one per song.
struct Segment: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Double
    var end: Double
    var title: String
    var artist: String
    var album: String
    var albumArtist: String = ""
    var trackNumber: Int?
    var trackCount: Int?
    var year: String = ""
    var genre: String = ""
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    /// File name inside the item's folder.
    var artworkFile: String?
    var included: Bool = true
    var metadataSource: String = ""
    var musicPersistentID: String?
    var addedToMusicAt: Date?

    var duration: Double { max(0, end - start) }

    static let placeholder = Segment(start: 0, end: 0, title: "", artist: "", album: "")
}

enum ItemStatus: String, Codable {
    case queued, downloading, processing, needsReview, exporting, added, failed

    var label: String {
        switch self {
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .processing: "Processing"
        case .needsReview: "Ready for review"
        case .exporting: "Adding to Music"
        case .added: "In Music"
        case .failed: "Failed"
        }
    }

    var isBusy: Bool { [.queued, .downloading, .processing, .exporting].contains(self) }
}

/// A single YouTube video that was (or will be) downloaded.
struct DownloadItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var videoID: String
    var url: String
    var title: String = ""
    var channel: String = ""
    var duration: Double = 0
    var playlistID: UUID?
    var autoAdd: Bool = false
    var status: ItemStatus = .queued
    var errorMessage: String?
    var sourceFile: String?
    var previewFile: String?
    var thumbnailFile: String?
    var videoFile: String?
    var sourceCodec: String = ""
    var sourceBitrate: Double = 0
    var chapters: [Chapter] = []
    /// Song names found in the description ("SET LIST" / "Tracklist" blocks).
    var setlist: [String] = []
    var segments: [Segment] = []
    /// Music tracks this download has added and that should still exist (cleaned up on the next export).
    var musicTrackIDs: [String]?
    /// The tracks as they were last sent to Music, to tell whether later edits still need an update.
    var exportedSegments: [Segment]?
    var created = Date()
    var completed: Date?

    var remoteThumbnail: URL? { URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg") }
    var includedSegments: [Segment] { segments.filter(\.included) }
}

/// A playlist that is checked periodically for new videos.
struct Playlist: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: String
    var youtubeID: String
    var title: String
    var enabled = true
    var autoAddToMusic = true
    var lastChecked: Date?
    var lastError: String?
    /// Every video ID seen in this playlist, so nothing is downloaded twice.
    var knownVideoIDs: Set<String> = []
    var created = Date()
}

func formatTime(_ t: Double, precise: Bool = false) -> String {
    let total = max(0, t)
    let h = Int(total) / 3600
    let m = (Int(total) % 3600) / 60
    let s = total - Double(h * 3600 + m * 60)
    if precise {
        return h > 0 ? String(format: "%d:%02d:%04.1f", h, m, s) : String(format: "%d:%04.1f", m, s)
    }
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, Int(s)) : String(format: "%d:%02d", m, Int(s))
}

func parseTime(_ text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
    guard !parts.isEmpty, parts.count <= 3 else { return nil }
    var total = 0.0
    for part in parts {
        guard let v = Double(part) else { return nil }
        total = total * 60 + v
    }
    return total
}
