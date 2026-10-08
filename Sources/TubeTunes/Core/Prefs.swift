import Foundation

/// UserDefaults keys shared by the settings UI (@AppStorage) and the engine.
enum PrefKey {
    static let checkInterval = "checkIntervalMinutes"
    static let reviewManual = "reviewManualDownloads"
    static let cookiesBrowser = "cookiesBrowser"
    static let audioFormat = "audioFormat"
    static let aacBitrate = "aacBitrate"
    static let fadeInSingle = "fadeInSingle"
    static let fadeOutSingle = "fadeOutSingle"
    static let fadeInSplit = "fadeInSplit"
    static let fadeOutSplit = "fadeOutSplit"
    static let fadeCurve = "fadeCurve"
    static let autoSplitChapters = "autoSplitChapters"
    static let minChapters = "minChaptersToSplit"
    static let silenceThreshold = "silenceThresholdDB"
    static let minSilence = "minSilenceSeconds"
    static let minSong = "minSongSeconds"
    static let catalogLookup = "catalogLookup"
    static let catalogCountry = "catalogCountry"
    static let singlesAsAlbums = "singlesAsAlbums"
    static let fallbackAlbum = "fallbackAlbum"
}

enum Prefs {
    private static var d: UserDefaults { .standard }

    static func register() {
        d.register(defaults: [
            PrefKey.checkInterval: 30.0,
            PrefKey.reviewManual: true,
            PrefKey.cookiesBrowser: "",
            PrefKey.audioFormat: "aac",
            PrefKey.aacBitrate: 256,
            PrefKey.fadeInSingle: 0.0,
            PrefKey.fadeOutSingle: 0.0,
            PrefKey.fadeInSplit: 0.5,
            PrefKey.fadeOutSplit: 2.0,
            PrefKey.fadeCurve: "tri",
            PrefKey.autoSplitChapters: true,
            PrefKey.minChapters: 3,
            PrefKey.silenceThreshold: -40.0,
            PrefKey.minSilence: 1.5,
            PrefKey.minSong: 60.0,
            PrefKey.catalogLookup: true,
            PrefKey.catalogCountry: "US",
            PrefKey.singlesAsAlbums: true,
            PrefKey.fallbackAlbum: "Youtube",
        ])
    }

    static var checkIntervalMinutes: Double { d.double(forKey: PrefKey.checkInterval) }
    static var reviewManualDownloads: Bool { d.bool(forKey: PrefKey.reviewManual) }
    static var cookiesBrowser: String { d.string(forKey: PrefKey.cookiesBrowser) ?? "" }
    static var audioFormat: String { d.string(forKey: PrefKey.audioFormat) ?? "aac" }
    static var aacBitrate: Int { d.integer(forKey: PrefKey.aacBitrate) }
    static var fadeInSingle: Double { d.double(forKey: PrefKey.fadeInSingle) }
    static var fadeOutSingle: Double { d.double(forKey: PrefKey.fadeOutSingle) }
    static var fadeInSplit: Double { d.double(forKey: PrefKey.fadeInSplit) }
    static var fadeOutSplit: Double { d.double(forKey: PrefKey.fadeOutSplit) }
    static var fadeCurve: String { d.string(forKey: PrefKey.fadeCurve) ?? "tri" }
    static var autoSplitChapters: Bool { d.bool(forKey: PrefKey.autoSplitChapters) }
    static var minChaptersToSplit: Int { d.integer(forKey: PrefKey.minChapters) }
    static var silenceThreshold: Double { d.double(forKey: PrefKey.silenceThreshold) }
    static var minSilence: Double { d.double(forKey: PrefKey.minSilence) }
    static var minSong: Double { d.double(forKey: PrefKey.minSong) }
    static var catalogLookup: Bool { d.bool(forKey: PrefKey.catalogLookup) }
    static var catalogCountry: String { d.string(forKey: PrefKey.catalogCountry) ?? "US" }
    static var singlesAsAlbums: Bool { d.bool(forKey: PrefKey.singlesAsAlbums) }
    static var fallbackAlbum: String {
        let s = d.string(forKey: PrefKey.fallbackAlbum) ?? ""
        return s.isEmpty ? "Youtube" : s
    }
}
