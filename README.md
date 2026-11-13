# LockLyrics 🎵📱

A high-performance iOS tweak for iOS 16+ that automatically looks up the currently playing song on [LRCLIB](https://lrclib.net), parses synchronized `.lrc` timestamps, and displays real-time animated lyrics right on your Lock Screen.

## Features

- 🎧 **Automatic Track Detection**: Listens to system-wide MediaRemote playback state changes (Spotify, Apple Music, YouTube Music, SoundCloud, etc.) with minimal CPU/battery overhead.
- ⚡ **LRCLIB Integration**:
  - Direct exact matching via `/api/get?track_name=...&artist_name=...&duration=...`.
  - Fallback fuzzy search via `/api/search?q=...` if exact metadata differs.
  - Automatic LRC synchronized timestamp parsing `[mm:ss.xx]`.
  - Plain lyrics fallback support.
  - In-memory LRU caching to eliminate duplicate network requests.
- 📍 **Freely Repositionable on Lock Screen**:
  - **Live Dragging**: Press and drag the lyrics directly on your lockscreen anytime to reposition!
  - **Auto-save**: Dropping the lyrics widget saves its exact coordinates across reboots.
  - **Lock Position Toggle**: Prevent accidental dragging when scrolling notifications.
  - **Position Presets**: Below Clock, Screen Center, Above Media Controls, or Custom.
- ✨ **Fluid Aesthetics**:
  - Native iOS dark/ultra-thin blur effect (`UIVisualEffectView`) with continuous rounded corners.
  - Smooth line transitions and active-line highlighting.
  - Configurable line counts (1, 3, or 5 lines).
  - Configurable font sizes.
- ⚙️ **Full Settings Integration**:
  - Dedicated preference bundle in Settings app with instant Darwin notification updates (no respring needed).
- 🔓 **Jailbreak Compatibility**:
  - Supports modern rootless jailbreaks (Dopamine, Palera1n) as well as rootful setups.
  - Built with Logos following modern Theos best practices.

## Project Structure

```
locklyrics/
├── Makefile                # Root build definition (tweak + preferences)
├── control                 # Debian control file
├── LockLyrics.plist        # Filter plist (XML format for SpringBoard)
├── Headers/
│   ├── CoverSheet.h        # Private CoverSheet interfaces
│   ├── MediaRemote.h       # MediaRemote private framework functions
│   └── SpringBoard.h       # SBMediaController declarations
├── Source/
│   ├── Tweak.x             # Logos hooks for CSCoverSheetViewController & SpringBoard
│   ├── Tweak.h             # Common tweak imports and declarations
│   ├── LRLyricsModel.h/m   # LRC parser and data models
│   ├── LRLyricsManager.h/m # LRCLIB client, playback sync, and cache
│   ├── LRLyricsView.h/m    # Custom Lock Screen UI & pan gesture handler
│   └── LRPreferences.h/m   # Preference management & Darwin notifications
└── Preferences/
    ├── Makefile            # Preference bundle build definition
    ├── LRPRootListController.h/m # Settings view controller
    └── Resources/
        ├── Root.plist      # Preference specifiers (sliders, switches, presets)
        └── Info.plist      # Bundle metadata
```

## How It Works

1. **Media Detection**: Hooking `CSCoverSheetViewController` and MediaRemote notification centers in SpringBoard, `LRLyricsManager` tracks track changes, playback state (`isPlaying`), duration, elapsed time, and rate.
2. **Lyric Fetching**: When a song starts, a query is sent to LRCLIB:
   ```
   GET https://lrclib.net/api/get?track_name=...&artist_name=...
   ```
3. **Synchronized Playback**: A lightweight timer compares estimated playback progress against parsed timestamps:
   $$\text{Current Time} = \text{Elapsed Time} + (\text{Current Date} - \text{Timestamp}) \times \text{Playback Rate}$$
4. **Positioning & Gestures**: A `UIPanGestureRecognizer` attached to `LRLyricsView` handles live dragging with haptic feedback, automatically saving the coordinates to `com.locklyrics.preferences`.

## Building & Installation

Requirements:
- [Theos](https://theos.dev) (or [Roothide Theos fork](https://github.com/roothide/theos)) installed and configured with modern iOS SDK (iOS 16+).

### Roothide (Default)
```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```
*(Package will be built into `./packages/` for `iphoneos-arm64e`)*

### Rootless (Dopamine / Palera1n)
```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

### Rootful
```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootful
```

### Deploy directly to Device via SSH
```bash
make do THEOS_DEVICE_IP=192.168.1.xxx
```

