# TubeTunes

A macOS app that downloads audio from YouTube videos and playlists, tags it, and adds it to Apple Music.

## Features
- **Best audio:** downloads the best audio stream YouTube offers (usually Opus) and converts it once to AAC 256 kbps (or 192/320, or Apple Lossless) in `.m4a`.
- **Metadata:** comes from YouTube Music credits, the video title, and the Apple Music catalog (iTunes Search API).
  - Studio tracks found in the catalog get their real album, track number, year, genre and official artwork.
  - Everything else goes into the album **"Youtube"** under that artist.
  - Covers ("Song - Original Artist (Performer)", "Cover by X", "X plays "Song"") and live performances are never filed under studio albums.
- **Playlists:** monitored playlists are checked every 30 minutes by default. Every video ID seen is remembered, so nothing downloads twice. Each playlist can auto-add to Music or hold new songs for review.
- **Single links:** a video link downloads just that song, even if it isn't on a playlist.
- **Splitting multi-song videos:**
  - Automatic, using YouTube chapters, or a "SET LIST" / "Tracklist" in the description (e.g. Tiny Desk).
  - "Detect Songs…" finds songs by silence, or by a known number of songs (quietest gaps, which works for live sets with applause).
  - Manual: split at the playhead, merge, delete, or drag the edges on the waveform.
- **Trim and fades:** per track, previewed live in the editor. Defaults are set separately for single songs and split tracks.
- **Waveform navigation:** pinch to zoom (centered under your fingers), swipe or scroll to pan, ⌥-scroll to zoom with a mouse, ⌘+ / ⌘− to step the zoom. The overview bar shows and drags the visible window. Space plays and pauses (except while typing). While playing, the view follows the playhead like Logic's Catch: scrolling away turns following off, and pressing play or the follow button turns it back on. ⌘B splits at the playhead.
- **Undo/redo (⌘Z / ⇧⌘Z):**
  - In the editor: every edit (splits, merges, deletes, detection, edge drags, trims, fades, tags, artwork, lookups).
  - In the main window: removing downloads, removing playlists, and the playlist toggles.
  - Editor changes reach Music only when you click **Update in Music**, so undo never loses a track.
- **Artwork:** use the YouTube thumbnail, any frame from the video (downloads up to 1080p), Apple Music catalog art, or a file, then crop it square.
- **History:** every track added to Music, with its YouTube thumbnail. **Edit…** re-exports a track and replaces it in Music.
- **Background sync:**
  - A per-user launchd agent (`~/Library/LaunchAgents/net.wesyarber.TubeTunes.sync.plist`) wakes every 5 minutes at background priority, even when the app is quit.
  - It exits within milliseconds unless a playlist is due for its check interval or downloads are queued. It skips work in Low Power Mode.
  - Only one process touches the library at a time: when the app is open, the agent leaves the work to it.
  - Log: `~/Library/Logs/TubeTunes-sync.log`. Turn it off in Settings › General.
- **Menu bar:** a menu bar extra keeps the app around after its window is closed. Optional "Open at login".
- **Links from other apps:** `tubetunes://add?url=<YouTube link>[&review=1][&playlist=1]` adds a link from Shortcuts or a bookmarklet.

## Requirements
`brew install yt-dlp ffmpeg` (yt-dlp pulls in deno, which YouTube now requires).
If downloads start failing, update yt-dlp: Settings › General › Update yt-dlp.

## Build
```
scripts/build-app.sh            # builds build/TubeTunes.app
scripts/build-app.sh --install  # also copies it to /Applications
```
The first time a track is added, macOS asks to let TubeTunes control Music. The app is ad-hoc signed, so a rebuild may ask again.

## Data
`~/Library/Application Support/TubeTunes/`:
- `library.json`: downloads, tracks, playlists, and every video ID already seen.
- `Items/<id>/`: the original audio, preview, thumbnail, artwork, and the optional video for picking frames.
- `Exports/`: temporary `.m4a` files. They're deleted once Music has copied them into its own library.
