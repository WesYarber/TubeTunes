import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AudioSettings().tabItem { Label("Audio", systemImage: "waveform") }
            MetadataSettings().tabItem { Label("Metadata", systemImage: "tag") }
        }
        .frame(width: 560)
        .padding(.vertical, 8)
    }
}

private struct GeneralSettings: View {
    @AppStorage(PrefKey.checkInterval) private var interval = 30.0
    @AppStorage(PrefKey.reviewManual) private var reviewManual = true
    @AppStorage(PrefKey.cookiesBrowser) private var cookiesBrowser = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var ytVersion: String?
    @State private var updating = false
    @State private var updateMessage: String?

    var body: some View {
        Form {
            Section("Playlists") {
                Picker("Check monitored playlists every", selection: $interval) {
                    ForEach([5.0, 15, 30, 60, 180, 360, 720], id: \.self) { m in
                        Text(m < 60 ? "\(Int(m)) minutes" : "\(Int(m / 60)) hour\(m == 60 ? "" : "s")").tag(m)
                    }
                }
                Toggle("Open at login (keeps playlists syncing)", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            updateMessage = "Login item: \(error.localizedDescription)"
                        }
                    }
            }
            Section("Single links") {
                Toggle("Review before adding to Music by default", isOn: $reviewManual)
            }
            Section {
                Picker("Use cookies from", selection: $cookiesBrowser) {
                    Text("None").tag("")
                    ForEach(["safari", "chrome", "firefox", "brave", "edge", "arc"], id: \.self) {
                        Text($0.capitalized).tag($0)
                    }
                }
                LabeledContent("yt-dlp", value: ytVersion ?? (Tools.path("yt-dlp") == nil ? "not installed" : "…"))
                LabeledContent("ffmpeg", value: Tools.path("ffmpeg") ?? "not installed")
                HStack {
                    Button("Update yt-dlp") { update() }.disabled(updating || Tools.path("brew") == nil)
                    if updating { ProgressView().controlSize(.small) }
                }
                if let updateMessage { Text(updateMessage).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Downloader")
            } footer: {
                Text("Cookies let yt-dlp see age-restricted videos and, with YouTube Premium, higher-bitrate audio. YouTube changes often, so update yt-dlp if downloads start failing.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .task { ytVersion = await YTDLP.version() }
    }

    private func update() {
        updating = true
        Task {
            do {
                try await Tools.run("brew", ["upgrade", "yt-dlp"])
                updateMessage = "yt-dlp is up to date."
            } catch {
                updateMessage = error.localizedDescription
            }
            ytVersion = await YTDLP.version()
            updating = false
        }
    }
}

private struct AudioSettings: View {
    @AppStorage(PrefKey.audioFormat) private var format = "aac"
    @AppStorage(PrefKey.aacBitrate) private var bitrate = 256
    @AppStorage(PrefKey.fadeInSingle) private var fadeInSingle = 0.0
    @AppStorage(PrefKey.fadeOutSingle) private var fadeOutSingle = 0.0
    @AppStorage(PrefKey.fadeInSplit) private var fadeInSplit = 0.5
    @AppStorage(PrefKey.fadeOutSplit) private var fadeOutSplit = 2.0
    @AppStorage(PrefKey.fadeCurve) private var curve = "tri"
    @AppStorage(PrefKey.autoSplitChapters) private var autoSplit = true
    @AppStorage(PrefKey.minChapters) private var minChapters = 3
    @AppStorage(PrefKey.silenceThreshold) private var threshold = -40.0
    @AppStorage(PrefKey.minSilence) private var minSilence = 1.5
    @AppStorage(PrefKey.minSong) private var minSong = 60.0

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $format) {
                    Text("AAC (.m4a)").tag("aac")
                    Text("Apple Lossless (.m4a)").tag("alac")
                }
                if format == "aac" {
                    Picker("Bitrate", selection: $bitrate) {
                        ForEach([192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                }
            } header: {
                Text("Output")
            } footer: {
                Text("TubeTunes always downloads the best audio stream YouTube offers (usually Opus). Music can't play Opus, so it's converted once. 256 kbps AAC sounds the same as the source; Apple Lossless keeps it bit-for-bit but makes much larger files.")
                    .font(.caption)
            }

            Section("Default fades") {
                fade("Single song — fade in", $fadeInSingle)
                fade("Single song — fade out", $fadeOutSingle)
                fade("Split tracks — fade in", $fadeInSplit)
                fade("Split tracks — fade out", $fadeOutSplit)
                Picker("Fade shape", selection: $curve) {
                    Text("Linear").tag("tri")
                    Text("Smooth (quarter sine)").tag("qsin")
                    Text("Exponential").tag("exp")
                    Text("Logarithmic").tag("log")
                    Text("S-curve").tag("esin")
                }
            }

            Section {
                Toggle("Split automatically using chapters or a description set list", isOn: $autoSplit)
                Stepper("Only when there are at least \(minChapters) chapters", value: $minChapters, in: 2...10)
                    .disabled(!autoSplit)
                LabeledContent("“Detect Songs” silence level") {
                    Slider(value: $threshold, in: -70 ... -15, step: 1)
                    Text("\(Int(threshold)) dB").monospacedDigit().frame(width: 55)
                }
                LabeledContent("Minimum silence") {
                    Slider(value: $minSilence, in: 0.3...6, step: 0.1)
                    Text(String(format: "%.1f s", minSilence)).monospacedDigit().frame(width: 55)
                }
                LabeledContent("Shortest song") {
                    Slider(value: $minSong, in: 20...300, step: 5)
                    Text(formatTime(minSong)).monospacedDigit().frame(width: 55)
                }
            } header: { Text("Splitting multi-song videos") }
        }
        .formStyle(.grouped)
    }

    private func fade(_ label: String, _ value: Binding<Double>) -> some View {
        LabeledContent(label) {
            Slider(value: value, in: 0...10, step: 0.1)
            Text(String(format: "%.1f s", value.wrappedValue)).monospacedDigit().frame(width: 50)
        }
    }
}

private struct MetadataSettings: View {
    @AppStorage(PrefKey.catalogLookup) private var lookup = true
    @AppStorage(PrefKey.catalogCountry) private var country = "US"
    @AppStorage(PrefKey.singlesAsAlbums) private var singles = true
    @AppStorage(PrefKey.fallbackAlbum) private var fallback = "Youtube"

    var body: some View {
        Form {
            Section {
                Toggle("Look up songs in the Apple Music catalog", isOn: $lookup)
                TextField("Store country code", text: $country)
                Toggle("Treat singles and EPs as albums", isOn: $singles)
            } footer: {
                Text("When a video is a studio recording found in the catalog, it's filed under its real album with the official artwork, track number, year and genre. Covers and live performances are never matched to studio albums.")
                    .font(.caption)
            }
            Section {
                TextField("Album name for everything else", text: $fallback)
            } footer: {
                Text("Songs that aren't on an album go into this album under each artist.").font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}
