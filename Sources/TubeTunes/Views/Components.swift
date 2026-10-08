import SwiftUI

/// The video's YouTube thumbnail: the downloaded copy if present, otherwise the remote one.
struct VideoThumb: View {
    let item: DownloadItem
    @Environment(Library.self) private var lib

    var body: some View {
        Group {
            if let url = lib.file(item, item.thumbnailFile), let img = ImageCache.shared.image(url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                AsyncImage(url: item.remoteThumbnail) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ArtworkImage: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url, let img = ImageCache.shared.image(url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 8 : 4))
    }
}

/// Edits a time as m:ss.s text.
struct TimeField: View {
    let label: String
    @Binding var value: Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text)
            .monospacedDigit()
            .focused($focused)
            .onAppear { text = formatTime(value, precise: true) }
            .onChange(of: value) { _, v in if !focused { text = formatTime(v, precise: true) } }
            .onSubmit(commit)
            .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func commit() {
        if let t = parseTime(text) { value = t }
        text = formatTime(value, precise: true)
    }
}

struct StatusBadge: View {
    let status: ItemStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .failed: .red
        case .needsReview: .orange
        case .added: .green
        default: .blue
        }
    }
}
