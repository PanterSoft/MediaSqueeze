# MediaSqueeze

An iOS app that frees up storage in your Photos library:

- **Video compression.** Re-encodes videos in your library into much smaller files, with settings that control how much quality you trade for space.
- **Duplicate and similar media cleanup.** Finds exact duplicates and near-identical shots (bursts, retakes, re-saved copies), suggests the best copy to keep, and deletes the rest.

Everything runs on-device. Nothing is uploaded.

<img src="MediaSqueeze/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="96" alt="App icon">

## Features

### Compress videos

- Lists every video with its size and the estimated size after compression. You can sort by size, estimated savings, date or length.
- Quick selections: all videos, videos over 100 MB or 500 MB, or videos older than a year.
- Compresses the selected videos one after another, with per-video progress and a running total of space saved. It downloads videos from iCloud when needed.
- Each compressed copy keeps the original's **creation date, location, favorite and hidden state, album membership** and QuickTime metadata.
- The originals can be deleted automatically. All of them go in one batch, so iOS asks for confirmation once, and they sit in *Recently Deleted* for 30 days.
- If the result would shrink the video by less than a minimum percentage you set, the app skips it and keeps the original.
- Videos the app has already compressed are marked and can be hidden from the list.

### Compression settings

| Preset | Resolution | Frame rate | Quality | Typical savings |
|---|---|---|---|---|
| Maximum Quality | original | original | maximum | 30–50% (H.264 sources) |
| Balanced *(default)* | original | original | balanced | 50–70% |
| Space Saver | ≤ 1080p | ≤ 30 fps | compact | 70–85% |
| Extreme | ≤ 720p | ≤ 30 fps | minimum | 85–95% |
| Custom | any | any | any | depends |

In **Custom** you can set each of these yourself:

- **Codec:** HEVC (H.265) or H.264 (for compatibility).
- **Max resolution:** original, 4K, 1440p, 1080p, 720p or 540p. The limit applies to the short side, so portrait videos are handled correctly. Videos are never upscaled.
- **Frame rate cap:** original, 60, 30 or 24 fps.
- **Quality:** five levels. Each one shows a plain-language description of how it affects the picture.
- **Audio:** AAC at 192, 128 or 64 kbps.

The *What to expect* section shows live estimates for typical iPhone recordings with the current settings.

**HDR** videos (iPhone HLG/Dolby Vision) are always encoded as 10-bit HEVC so they keep their HDR look.

### Find duplicates and similar media

- **Duplicates** mode finds identical copies, including resized or re-encoded ones such as copies saved from messaging apps.
- **Similar** mode finds near-identical shots. It has a sensitivity slider and an option to compare only shots taken within 10 minutes of each other.
- Works on photos, videos or both. A video only matches another video of nearly the same length.
- Picks the best copy in each group to keep (★): favorites first, then the highest resolution, then the largest file, then the oldest. Every other copy starts out selected for deletion. Tap an item to change that, or use the context menu to preview it.
- Warns when every item in a group is selected.
- Caches hashes between scans, so scanning again is fast.

## How it works

| Part | Implementation |
|---|---|
| Transcoding | `AVAssetReader` → `AVAssetWriter` (`VideoCompressor.swift`). This gives full control of bitrate, resolution, frame rate, codec profile and bit depth, which `AVAssetExportSession` presets don't offer. The writer does the scaling. Frame rates are reduced by dropping frames on a fixed time grid. |
| Bitrate | Bits per pixel × pixels × fps, scaled by codec efficiency (HEVC ≈ 0.65 × H.264). It is capped below the source bitrate so a re-encode never makes a file bigger (`CompressionPlanner.swift`). |
| Similarity | 64-bit difference hash (dHash) of a small grayscale thumbnail (`PerceptualHash.swift`). Matches are hashes within *n* bits (Hamming distance) whose aspect ratios agree. |
| Grouping | Union-find over the matched pairs. Without a time window, candidate pairs come from a pigeonhole index: the hash is split into *n + 1* blocks, and two hashes can only be within *n* bits if at least one block is identical. That avoids comparing every pair, which would be O(n²). With a time window, a sliding window runs over the items sorted by date (`SimilarityGrouper.swift`). |
| Library access | PhotoKit (`PHAssetCreationRequest`, `PHAssetChangeRequest.deleteAssets`). Library changes are observed so the lists update themselves. |

### Project layout

```
MediaSqueeze/                 iOS app (SwiftUI, iOS 17+)
  App/                        entry point, tab navigation
  Services/                   PhotoKit, transcoder, queue, duplicate scanner, settings
  Views/                      screens
  Resources/                  asset catalog (icon, accent color)
Packages/SqueezeCore/         platform-independent logic + unit tests
  CompressionSettings.swift   presets and options
  CompressionPlanner.swift    output resolution / bitrate / size estimation
  PerceptualHash.swift        dHash + downsampling
  SimilarityGrouper.swift     grouping + keeper selection
project.yml                   XcodeGen project definition
```

## Building

Requirements: Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
./scripts/bootstrap.sh        # installs XcodeGen via Homebrew if needed, generates and opens the project
```

In Xcode, select your development team under *Signing & Capabilities* and run on a device. The simulator works, but its photo library is small and its hardware encoder is slow.

Or use the Makefile:

```bash
make open     # generate the Xcode project and open it
make test     # run the core unit tests without Xcode
make build    # build the app for the iOS Simulator
```

CI (GitHub Actions) runs the core tests and builds the app for the iOS Simulator on every push and pull request.

## Notes and limitations

- Deleted items go to *Recently Deleted*. Photos only frees their space once it is emptied, either after 30 days or manually.
- Keep the app in the foreground while it compresses. The screen stays awake during a batch, and iOS allows only a short grace period in the background.
- Slow-motion and edited videos are compressed as they currently play, with edits baked in.
- Compressed copies are new assets. They don't keep the originals' Live Photo pairing or shared-album membership.
- File sizes come from `PHAssetResource`'s `fileSize` key. It is read through KVC, and many App Store apps rely on it.
