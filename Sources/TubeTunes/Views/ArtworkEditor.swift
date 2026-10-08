import SwiftUI
import UniformTypeIdentifiers

/// Picks artwork from a video frame, the thumbnail or a file, then crops it square.
struct ArtworkEditor: View {
    let itemID: UUID
    let segmentID: UUID
    /// Called with the saved artwork file name and whether it applies to every track.
    var onSave: (String, Bool) -> Void
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss

    @State private var image: CGImage?
    @State private var crop: CGRect = .zero
    @State private var frames: [Frame] = []
    @State private var videoURL: URL?
    @State private var videoProgress: Double?
    @State private var scrub: Double = 0
    @State private var busy = false
    @State private var applyToAll = false
    @State private var error: String?

    struct Frame: Identifiable {
        let time: Double
        let image: NSImage
        var id: Double { time }
    }

    private var item: DownloadItem? { lib.item(itemID) }
    private var segment: Segment? { item?.segments.first { $0.id == segmentID } }
    private var dir: URL { lib.folder(for: itemID) }
    private var range: ClosedRange<Double> {
        guard let s = segment, s.duration > 1 else { return 0...max(1, item?.duration ?? 1) }
        return s.start...s.end
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                cropPane.frame(minWidth: 460, maxWidth: .infinity)
                sidebar.frame(width: 340)
            }
            .padding(16)
            Divider()
            HStack {
                if let error { Text(error).foregroundStyle(.red).font(.callout).lineLimit(2) }
                Spacer()
                if (item?.segments.count ?? 0) > 1 {
                    Toggle("Use for all tracks from this video", isOn: $applyToAll)
                }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Artwork") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(image == nil)
            }
            .padding(12)
        }
        .frame(width: 900, height: 640)
        .onAppear(perform: loadInitial)
    }

    // MARK: - Crop

    private var cropPane: some View {
        VStack(spacing: 10) {
            if let image {
                CropView(image: image, crop: $crop)
                HStack {
                    Image(systemName: "crop").foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(crop.width) },
                        set: { resize(to: $0, image: image) }),
                           in: 64...Double(min(image.width, image.height)))
                    Button("Fit") { crop = ImageTools.centeredSquare(for: image) }
                }
                Text("Drag the square to move it; drag its corner or use the slider to resize. \(Int(crop.width))×\(Int(crop.height)) px")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("No image", systemImage: "photo")
            }
        }
    }

    private func resize(to side: Double, image: CGImage) {
        let s = CGFloat(side)
        let cx = crop.midX, cy = crop.midY
        var r = CGRect(x: cx - s / 2, y: cy - s / 2, width: s, height: s)
        r.origin.x = min(max(0, r.origin.x), CGFloat(image.width) - s)
        r.origin.y = min(max(0, r.origin.y), CGFloat(image.height) - s)
        crop = r
    }

    // MARK: - Sources

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source").font(.headline)
            HStack {
                Button("YouTube Thumbnail") {
                    if let item, let url = lib.file(item, item.thumbnailFile) { setImage(ImageTools.load(url)) }
                }
                .disabled(item?.thumbnailFile == nil)
                Button("Choose File…", action: chooseFile)
            }

            Divider()
            Text("Frame from the video").font(.headline)
            if videoURL == nil {
                if let p = videoProgress {
                    ProgressView(value: p) { Text("Downloading video…").font(.caption) }
                } else {
                    Button("Load Video Frames", systemImage: "film", action: loadVideo)
                        .disabled(busy)
                    Text("Downloads the video (up to 1080p) once so you can pick any moment.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                        ForEach(frames) { frame in
                            Button {
                                scrub = frame.time
                                grabFrame(at: frame.time)
                            } label: {
                                Image(nsImage: frame.image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                                    .frame(height: 58).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4)
                                        .stroke(abs(frame.time - scrub) < 0.01 ? Color.accentColor : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .help(formatTime(frame.time))
                            .accessibilityLabel("Frame at \(formatTime(frame.time))")
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                if busy && frames.isEmpty { ProgressView().controlSize(.small) }
                Text("Fine-tune: \(formatTime(scrub, precise: true))").font(.caption).monospacedDigit()
                HStack {
                    Button { step(-1 / 24) } label: { Image(systemName: "chevron.left") }
                    Slider(value: $scrub, in: 0...max(1, item?.duration ?? 1)) { editing in
                        if !editing { grabFrame(at: scrub) }
                    }
                    Button { step(1 / 24) } label: { Image(systemName: "chevron.right") }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func step(_ dt: Double) {
        scrub = max(0, min(item?.duration ?? 0, scrub + dt))
        grabFrame(at: scrub)
    }

    // MARK: - Actions

    private func loadInitial() {
        guard let item, let seg = segment else { return }
        scrub = seg.start + seg.duration / 3
        if let url = lib.file(item, seg.artworkFile), let img = ImageTools.load(url) {
            image = img
            crop = ImageTools.centeredSquare(for: img)
        } else if let url = lib.file(item, item.thumbnailFile) {
            setImage(ImageTools.load(url))
        }
        if let existing = lib.file(item, item.videoFile), FileManager.default.fileExists(atPath: existing.path) {
            videoURL = existing
            makeFrames()
        }
    }

    private func setImage(_ img: CGImage?) {
        guard let img else { return }
        image = img
        crop = ImageTools.centeredSquare(for: img)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { setImage(ImageTools.load(url)) }
    }

    private func loadVideo() {
        guard let item else { return }
        videoProgress = 0
        busy = true
        error = nil
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
        let dest = dir.appendingPathComponent("frames/full-\(Int(time * 1000)).jpg")
        Task {
            do {
                if !FileManager.default.fileExists(atPath: dest.path) {
                    try await AudioTools.extractFrame(video: video, at: time, dest: dest)
                }
                // Keep the crop square where it was if the size still fits.
                if let img = ImageTools.load(dest) {
                    let keep = image.map { $0.width == img.width && $0.height == img.height } ?? false
                    image = img
                    if !keep { crop = ImageTools.centeredSquare(for: img) }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let image, let out = ImageTools.render(image, crop: crop) else { return }
        let name = "art-\(UUID().uuidString.prefix(8)).jpg"
        do {
            try ImageTools.writeJPEG(out, to: dir.appendingPathComponent(name))
        } catch {
            self.error = error.localizedDescription
            return
        }
        onSave(name, applyToAll)
        dismiss()
    }
}

/// Shows an image with a draggable, resizable square crop region (pixel coordinates, top-left origin).
struct CropView: View {
    let image: CGImage
    @Binding var crop: CGRect
    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geo in
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            let scale = min(geo.size.width / iw, geo.size.height / ih)
            let dw = iw * scale, dh = ih * scale
            let ox = (geo.size.width - dw) / 2, oy = (geo.size.height - dh) / 2
            let r = CGRect(x: ox + crop.minX * scale, y: oy + crop.minY * scale,
                           width: crop.width * scale, height: crop.height * scale)

            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: dw, height: dh)
                    .offset(x: ox, y: oy)

                Path { p in
                    p.addRect(CGRect(x: ox, y: oy, width: dw, height: dh))
                    p.addRect(r)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                Rectangle()
                    .stroke(Color.white, lineWidth: 2)
                    .overlay {
                        // rule-of-thirds guides
                        Path { p in
                            for f in [1.0 / 3, 2.0 / 3] {
                                p.move(to: CGPoint(x: r.width * f, y: 0)); p.addLine(to: CGPoint(x: r.width * f, y: r.height))
                                p.move(to: CGPoint(x: 0, y: r.height * f)); p.addLine(to: CGPoint(x: r.width, y: r.height * f))
                            }
                        }
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    }
                    .frame(width: r.width, height: r.height)
                    .contentShape(Rectangle())
                    .offset(x: r.minX, y: r.minY)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                let start = dragStart ?? crop
                                dragStart = start
                                var n = start
                                n.origin.x = min(max(0, start.minX + v.translation.width / scale), iw - start.width)
                                n.origin.y = min(max(0, start.minY + v.translation.height / scale), ih - start.height)
                                crop = n
                            }
                            .onEnded { _ in dragStart = nil }
                    )

                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.4)))
                    .frame(width: 16, height: 16)
                    .offset(x: r.maxX - 8, y: r.maxY - 8)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                let start = dragStart ?? crop
                                dragStart = start
                                let delta = max(v.translation.width, v.translation.height) / scale
                                let limit = min(iw - start.minX, ih - start.minY)
                                let side = min(max(64, start.width + delta), limit)
                                crop = CGRect(x: start.minX, y: start.minY, width: side, height: side)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
                    .onHover { inside in
                        if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                    }
            }
        }
    }
}
