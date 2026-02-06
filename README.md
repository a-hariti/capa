# Capa

Capa is a native macOS screen recorder CLI that produces high-quality, QuickTime-like recordings with advanced features for creators and developers.

## Features

- **High Quality**: Captures at native display resolution and refresh rate using **ScreenCaptureKit**.
- **Interactive Wizard**: A user-friendly TUI to configure your recording (display, audio, camera, etc.).
- **Camera Sidecar**: Record your camera and screen simultaneously into **separate** files.
- **Timecode Sync**: Automatically embeds synchronized timecode tracks across all recorded files for easy editing in NLEs (FCP, Premiere, Resolve).
- **Audio Routing**: Capture system audio, microphone, or both with real-time level meters and a safe master limiter.
- **CFR Post-processing**: Automatically converts variable frame rate captures to rock-solid Constant Frame Rate (default 60fps) for better editor compatibility.

## Installation

### Homebrew
```bash
brew tap a-hariti/homebrew-capa
brew install capa
```

Upgrade later with:
```bash
brew update
brew upgrade capa
```

## Usage

Simply run `capa` to start the interactive wizard:
```bash
capa
```

### Output Locations

- **Production (release builds)**: recordings are written to `~/Desktop/capa/<project>/...`
  - Applies to `swift run -c release capa` and release binaries (for example `.build/release/capa`).
- **Development (debug builds)**: recordings are written to `./recs/<project>/...`
  - Applies to `swift run capa` and other debug builds.

### Command Line Options

For automated workflows, you can pass arguments directly:

```text
OPTIONS:
  -p, --project-name <name>  Project folder name (default: capa-<timestamp>)
  --display <display>        Select display by index (from --list-displays) or displayID
  --cursor <cursor>          Show cursor: on|off
  --menubar <menubar>        Show menu bar: on|off
  --audio <audio>            Audio sources: (none, mic, system, mic+system)
  --mic <mic>                Select microphone by index (from --list-mics) or AVCaptureDevice.uniqueID
  --camera <camera>          Record camera by index (from --list-cameras) or AVCaptureDevice.uniqueID
  --fps <fps>                Screen timing mode: integer CFR fps or 'vfr' (default: 60)
  --codec <codec>            Video codec (h264|hevc)
  --safe-mix <safe-mix>      Safe master limiter: on|off (default: on)
  --duration <duration>      Auto-stop after N seconds (non-interactive friendly)
  --list-displays            List available displays and exit
  --list-mics                List available microphones and exit
  --list-cameras             List available cameras and exit
  --no-open                  Do not open file when done
  --non-interactive          Error instead of prompting for missing options
  -v, --verbose              Show detailed capture settings/debug output
  -h, --help                 Show help information.
```

### Examples

**Record with microphone and system audio (non-interactive):**
```bash
capa --non-interactive --audio mic+system --duration 60
```

**Record screen and camera with a specific project name:**
```bash
capa --project-name "Tutorial-01" --camera 0 --audio mic
```

## Architecture

- **Capture**: Uses **ScreenCaptureKit** `SCStream` with an `SCContentFilter`.
- **Resolution**: Computes true pixel dimensions from `contentRect` and `pointPixelScale` for sharp Retina recording.
- **Frame Pacing**: Captures at native refresh, then post-processes to 60 fps Constant Frame Rate (CFR) by default for better NLE compatibility.
- **Encoding**: **AVFoundation** `AVAssetWriter` with real-time, high-quality settings.
- **Multi-source**: Records camera sidecar files with synchronized timecode tracks.

## Development

### Prerequisites
- macOS 15.0 or later.
- Apple Silicon (recommended).
- Swift 6.0+ toolchain.

### Build from Source

```bash
git clone https://github.com/a-hariti/capa.git
cd capa
swift build -c release
cp .build/release/capa /usr/local/bin/capa
```

### Project Structure
- `Sources/`:
  - `ScreencapWizard.swift`: TUI wizard and CLI entry point.
  - `ScreenRecorder.swift`: Core recording engine.
  - `VideoCFR.swift`: Constant Frame Rate rewriter.
  - `TimecodeSync.swift`: Timecode generation logic.
  - `LiveMeters.swift`: Real-time audio levels.
- `Tests/`: Comprehensive unit test suite.

### Commands
- **Build (debug)**: `swift build -c debug`
- **Build (release)**: `swift build -c release`
- **Test**: `swift test`
- **Run (debug)**: `swift run capa`
- **Run (release)**: `swift run -c release capa`

## License
MIT
