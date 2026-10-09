import SwiftUI
import UniformTypeIdentifiers

/// Designs a track's artwork: pick an image (thumbnail, any video frame, a file), position or pad it,
/// and optionally style it with a background, border, filter and text. Styles are generated from the
/// image's colors. The design is saved next to the JPEG so it can be edited again later.
struct ArtworkEditor: View {
    let item: DownloadItem
    let segment: Segment
    let trackCount: Int
    /// Called with the saved artwork file name and whether it applies to every track.
    var onSave: (String, Bool) -> Void

    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss

    @State private var design = ArtworkDesign(sourceFile: "")
    @State private var image: NSImage?
    @State private var palette = Palette.neutral
    @State private var panel: Panel = .styles
    @State private var applyToAll = true
    @State private var dragStart: CGSize?
    @State private var pinchStart: Double?

    @State private var frames: [Frame] = []
    @State private var videoURL: URL?
    @State private var videoProgress: Double?
    @State private var scrub: Double = 0
    @State private var busy = false
    @State private var error: String?

    enum Panel: String, CaseIterable { case styles = "Styles", image = "Image", background = "Background", text = "Text" }

    struct Frame: Identifiable {
        let time: Double
        let image: NSImage
        var id: Double { time }
    }

    private var dir: URL { lib.folder(for: item.id) }
    private var aspect: Double { image.map { $0.size.width / max(1, $0.size.height) } ?? 1 }
    private var range: ClosedRange<Double> {
        segment.duration > 1 ? segment.start...segment.end : 0...max(1, item.duration)
    }

    @State private var previewSide: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                GeometryReader { geo in
                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .onAppear { previewSide = side(for: geo.size) }
                        .onChange(of: geo.size) { _, size in previewSide = side(for: size) }
                }
                VStack(spacing: 10) {
                    Picker("", selection: $panel) {
                        ForEach(Panel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    ScrollView {
                        Group {
                            switch panel {
                            case .styles: stylesPanel
                            case .image: imagePanel
                            case .background: backgroundPanel
                            case .text: textPanel
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 6)
                    }
                }
                .frame(width: 380)
            }
            .padding(16)
            Divider()
            HStack {
                if let error { Text(error).foregroundStyle(.red).font(.callout).lineLimit(2) }
                Spacer()
                if trackCount > 1 {
                    Toggle("Use for all \(trackCount) tracks from this video", isOn: $applyToAll)
                        .onChange(of: applyToAll) { old, new in swapDefaultText(from: old, to: new) }
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Artwork") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(image == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 880, idealWidth: 1000, maxWidth: 1300, minHeight: 560, idealHeight: 680, maxHeight: 1000)
        .onAppear(perform: loadInitial)
    }

    private func side(for size: CGSize) -> CGFloat {
        max(240, min(size.width, size.height - 28))
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(spacing: 8) {
            if let image {
                ArtworkCanvas(image: image, design: design, side: previewSide)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(radius: 8, y: 3)
                    .overlay {
                        Color.clear
                            .frame(width: previewSide, height: previewSide)
                            .contentShape(Rectangle())
                            .accessibilityLabel("Artwork preview")
                            .gesture(
                                DragGesture()
                                    .onChanged { v in
                                        let start = dragStart ?? CGSize(width: design.offsetX, height: design.offsetY)
                                        dragStart = start
                                        design.offsetX = start.width + v.translation.width / previewSide
                                        design.offsetY = start.height + v.translation.height / previewSide
                                    }
                                    .onEnded { _ in dragStart = nil }
                            )
                            .simultaneousGesture(
                                MagnifyGesture()
                                    .onChanged { v in
                                        let start = pinchStart ?? design.scale
                                        pinchStart = start
                                        design.scale = min(4, max(0.2, start * v.magnification))
                                    }
                                    .onEnded { _ in pinchStart = nil }
                            )
                    }
                Text("Drag to move the image · pinch or use Image › Size to resize")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: previewSide, height: previewSide)
                    .overlay(ProgressView())
            }
        }
    }

    // MARK: - Panels

    private var stylesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Styles made from this image's colors. Pick one, then fine-tune it in the other tabs.")
                .font(.caption).foregroundStyle(.secondary)
            if let image {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 12) {
                    ForEach(ArtworkStyles.all(palette: palette, aspect: aspect)) { style in
                        let styled = styledDesign(style)
                        Button { design = styled } label: {
                            VStack(spacing: 4) {
                                ArtworkCanvas(image: image, design: styled, side: 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(style.name).font(.caption).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(style.name) style")
                    }
                }
            }
        }
    }

    private func styledDesign(_ style: ArtworkStyle) -> ArtworkDesign {
        var d = design
        style.apply(&d)
        return d
    }

    private var imagePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Size & position") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Fill Square") { design.scale = 1; design.offsetX = 0; design.offsetY = 0 }
                            .help("Crop the image to fill the square")
                        Button("Fit Whole Image") {
                            design.scale = ArtworkStyles.containScale(aspect: aspect)
                            design.offsetX = 0; design.offsetY = 0
                        }
                        .help("Show the entire image, padded above and below")
                        Button("Center") { design.offsetX = 0; design.offsetY = 0 }
                    }
                    LabeledContent("Size") {
                        Slider(value: $design.scale, in: 0.2...3)
                    }
                    LabeledContent("Vertical") {
                        Slider(value: $design.offsetY, in: -0.6...0.6)
                    }
                    LabeledContent("Horizontal") {
                        Slider(value: $design.offsetX, in: -1...1)
                    }
                }
                .padding(4)
            }

            GroupBox("Filter") {
                VStack(alignment: .leading) {
                    Picker("Filter", selection: $design.filter) {
                        ForEach(ArtFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if design.filter == .duotone {
                        colorRow("Tint", $design.tint)
                    }
                }
                .padding(4)
            }

            GroupBox("Source") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("YouTube Thumbnail") { setSource(item.thumbnailFile) }
                            .disabled(item.thumbnailFile == nil)
                        Button("Choose File…", action: chooseFile)
                    }
                    framesSection
                }
                .padding(4)
            }
        }
    }

    @ViewBuilder private var framesSection: some View {
        if videoURL == nil {
            if let p = videoProgress {
                ProgressView(value: p) { Text("Downloading video…").font(.caption) }
            } else {
                Button("Pick a Frame from the Video…", systemImage: "film", action: loadVideo).disabled(busy)
                Text("Downloads the video (up to 1080p) once.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                ForEach(frames) { frame in
                    Button {
                        scrub = frame.time
                        grabFrame(at: frame.time)
                    } label: {
                        Image(nsImage: frame.image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                            .frame(height: 56).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(abs(frame.time - scrub) < 0.01 ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help(formatTime(frame.time))
                }
            }
            if busy && frames.isEmpty { ProgressView().controlSize(.small) }
            Text("Fine-tune: \(formatTime(scrub, precise: true))").font(.caption).monospacedDigit()
            HStack {
                Button { step(-1 / 24) } label: { Image(systemName: "chevron.left") }
                Slider(value: $scrub, in: 0...max(1, item.duration)) { editing in
                    if !editing { grabFrame(at: scrub) }
                }
                Button { step(1 / 24) } label: { Image(systemName: "chevron.right") }
            }
        }
    }

    private var backgroundPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Background") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Fill", selection: $design.background) {
                        ForEach(ArtBackground.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if design.background != .blur { colorRow(design.background == .gradient ? "Top" : "Color", $design.bg1) }
                    if design.background == .gradient { colorRow("Bottom", $design.bg2) }
                    Text("Shows wherever the image doesn't cover the square (use Image › Fit Whole Image).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }
            GroupBox("Border") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Style", selection: $design.border) {
                        ForEach(ArtBorder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if design.border != .none {
                        LabeledContent("Width") { Slider(value: $design.borderWidth, in: 0.004...0.08) }
                        colorRow("Color", $design.borderColor)
                    }
                }
                .padding(4)
            }
        }
    }

    private var textPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show text on the artwork", isOn: $design.showText)
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Title", text: $design.title)
                    TextField("Subtitle", text: $design.subtitle)
                    Picker("Font", selection: $design.font) {
                        ForEach(ArtFont.allCases, id: \.self) { f in
                            Text(f.rawValue).font(f.font(size: 13)).tag(f)
                        }
                    }
                    LabeledContent("Size") { Slider(value: $design.textSize, in: 0.03...0.16) }
                    colorRow("Color", $design.textColor)
                    Picker("Position", selection: $design.placement) {
                        ForEach(TextPlacement.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Alignment", selection: $design.centered) {
                        Text("Centered").tag(true)
                        Text("Left").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Toggle("All caps", isOn: $design.uppercase)
                    Picker("Behind text", selection: $design.band) {
                        ForEach(TextBand.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if design.band != .none { colorRow("Band color", $design.bandColor) }
                }
                .padding(4)
                .disabled(!design.showText)
            }
        }
    }

    /// A color picker plus one-click swatches from the image's palette.
    private func colorRow(_ label: String, _ value: Binding<RGBA>) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 74, alignment: .leading)
            ColorPicker("", selection: Binding(get: { value.wrappedValue.color },
                                               set: { value.wrappedValue = RGBA($0) }),
                        supportsOpacity: false)
                .labelsHidden()
            ForEach(Array(palette.swatches.enumerated()), id: \.offset) { _, swatch in
                Button { value.wrappedValue = swatch } label: {
                    Circle().fill(swatch.color).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.separator))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Loading

    private func defaultText(allTracks: Bool) -> (String, String) {
        if trackCount > 1 && allTracks {
            let subtitle = segment.album != Prefs.fallbackAlbum
                ? segment.album
                : MetadataResolver.parseTitle(item.title, channel: item.channel).title
            return (segment.albumArtist.isEmpty ? segment.artist : segment.albumArtist, subtitle)
        }
        return (segment.title, segment.artist)
    }

    private func swapDefaultText(from old: Bool, to new: Bool) {
        let before = defaultText(allTracks: old), after = defaultText(allTracks: new)
        if design.title == before.0 { design.title = after.0 }
        if design.subtitle == before.1 { design.subtitle = after.1 }
    }

    private func loadInitial() {
        scrub = segment.start + segment.duration / 3
        let (title, subtitle) = defaultText(allTracks: applyToAll)
        if let art = segment.artworkFile,
           let data = try? Data(contentsOf: designURL(for: art)),
           let saved = try? JSONDecoder().decode(ArtworkDesign.self, from: data) {
            design = saved
        } else if let art = segment.artworkFile, art != "art-thumb.jpg",
                  FileManager.default.fileExists(atPath: dir.appendingPathComponent(art).path) {
            design = ArtworkDesign(sourceFile: art, title: title, subtitle: subtitle)
        } else {
            design = ArtworkDesign(sourceFile: item.thumbnailFile ?? "", title: title, subtitle: subtitle)
        }
        loadImage(design.sourceFile)
        if let existing = lib.file(item, item.videoFile), FileManager.default.fileExists(atPath: existing.path) {
            videoURL = existing
            makeFrames()
        }
    }

    private func designURL(for artwork: String) -> URL {
        dir.appendingPathComponent((artwork as NSString).deletingPathExtension + ".json")
    }

    private func loadImage(_ file: String) {
        guard !file.isEmpty, let img = NSImage(contentsOf: dir.appendingPathComponent(file)) else { return }
        image = img
        if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { palette = Palette(image: cg) }
    }

    /// Switches the picture but keeps the layout and styling.
    private func setSource(_ file: String?) {
        guard let file else { return }
        design.sourceFile = file
        loadImage(file)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = "src-\(UUID().uuidString.prefix(8)).\(url.pathExtension.isEmpty ? "jpg" : url.pathExtension)"
        do {
            try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
            setSource(name)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Video frames

    private func step(_ dt: Double) {
        scrub = max(0, min(item.duration, scrub + dt))
        grabFrame(at: scrub)
    }

    private func loadVideo() {
        videoProgress = 0
        busy = true
        error = nil
        let itemID = item.id
        Task {
            defer { busy = false; videoProgress = nil }
            do {
                let url = try await YTDLP.downloadVideo(item.url, into: dir) { p in
                    Task { @MainActor in videoProgress = p }
                }
                lib.update(itemID) { $0.videoFile = url.lastPathComponent }
                videoURL = url
                makeFrames()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func makeFrames() {
        guard let video = videoURL else { return }
        let r = range
        let count = 18
        let times = (0..<count).map { r.lowerBound + (r.upperBound - r.lowerBound) * (Double($0) + 0.5) / Double(count) }
        let framesDir = dir.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        busy = true
        Task {
            defer { busy = false }
            var result: [Frame] = []
            await withTaskGroup(of: Frame?.self) { group in
                for t in times {
                    group.addTask {
                        let dest = framesDir.appendingPathComponent("thumb-\(Int(t * 1000)).jpg")
                        if !FileManager.default.fileExists(atPath: dest.path) {
                            try? await AudioTools.extractFrame(video: video, at: t, dest: dest, width: 320)
                        }
                        return NSImage(contentsOf: dest).map { Frame(time: t, image: $0) }
                    }
                }
                for await frame in group { if let frame { result.append(frame) } }
            }
            frames = result.sorted { $0.time < $1.time }
        }
    }

    private func grabFrame(at time: Double) {
        guard let video = videoURL else { return }
        let name = "frames/full-\(Int(time * 1000)).jpg"
        let dest = dir.appendingPathComponent(name)
        Task {
            do {
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try await AudioTools.extractFrame(video: video, at: time, dest: dest)
                }
                setSource(name)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Save

    private func save() {
        guard let image, let out = ArtworkCanvas.render(image, design) else {
            error = "Couldn't render the artwork."
            return
        }
        let name = "art-\(UUID().uuidString.prefix(8)).jpg"
        do {
            try ImageTools.writeJPEG(out, to: dir.appendingPathComponent(name))
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(design).write(to: designURL(for: name))
        } catch {
            self.error = error.localizedDescription
            return
        }
        onSave(name, applyToAll && trackCount > 1)
        dismiss()
    }
}
