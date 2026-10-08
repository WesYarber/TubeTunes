import AVFoundation
import Observation

/// Plays the preview copy of a download, with fades applied as volume ramps.
@MainActor @Observable
final class PreviewPlayer {
    var currentTime: Double = 0
    var isPlaying = false

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var stopAt: Double?
    @ObservationIgnored private var audioTrack: AVAssetTrack?

    func load(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.tick(time.seconds) }
            }
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        if let stopAt, t >= stopAt {
            pause()
            self.stopAt = nil
        }
        isPlaying = player.rate > 0
    }

    func play(from start: Double? = nil, until end: Double? = nil) {
        if let start { seek(start) }
        stopAt = end
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func seek(_ t: Double) {
        let time = CMTime(seconds: max(0, t), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, t)
    }

    /// Mirrors each track's fade-in/out so previews sound like the export.
    func applyFades(_ segments: [Segment]) {
        guard let track = audioTrack, let item = player.currentItem else { return }
        let params = AVMutableAudioMixInputParameters(track: track)
        var cursor = -1.0
        for seg in segments.filter(\.included).sorted(by: { $0.start < $1.start }) {
            let fadeIn = min(seg.fadeIn, seg.duration / 2), fadeOut = min(seg.fadeOut, seg.duration / 2)
            if fadeIn > 0, seg.start >= cursor {
                params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: range(seg.start, fadeIn))
            }
            if fadeOut > 0 {
                params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: range(seg.end - fadeOut, fadeOut))
                params.setVolume(1, at: CMTime(seconds: seg.end + 0.01, preferredTimescale: 600))
            }
            cursor = seg.end + 0.01
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }

    private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600))
    }
}
