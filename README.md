# Magic Mouse Trackpad

[简体中文](README.zh-CN.md) · [v1.19 Downloads](https://github.com/gc66656/magic-mouse-trackpad/releases/tag/v1.19)

Use an Apple Magic Mouse as a small trackpad. Leave the mouse on your desk and use its touch surface to move the pointer, scroll, zoom, rotate, and drag.

## What sets Magic Mouse Trackpad apart

The upstream project already provides a virtual trackpad mode with pointer movement and two-finger scrolling. Magic Mouse Trackpad adds tap-to-drag and reworks how touch input feels on the mouse surface. [Magic Mouse Toolkit by mori0818](https://github.com/mori0818/magic-mouse-toolkit)

- **Two-finger scrolling and canvas panning.** Swipe to produce continuous horizontal and vertical scrolling with inertia, without pressing the mouse or pausing first. Compatible design apps can use the same input to pan the canvas.
- **One-finger tap-to-drag.** Tap once, touch down again, then slide to drag. Lift your finger to release. You can select text or drag an object while the mouse stays on the desk.
- **Touch input tuned for the mouse surface.** Pointer movement adapts to how fast you slide. Scrolling filters small jitters, accumulates slow movement, and can continue if one finger briefly drops out of the touch reports.

## Install

1. Download `Magic-Mouse-Trackpad-1.19-macOS.zip` from [Release v1.19](https://github.com/gc66656/magic-mouse-trackpad/releases/tag/v1.19) and extract it.
2. Move **Magic Mouse Trackpad.app** to Applications and open it. This community build is ad-hoc signed and is not Apple-notarized. If macOS blocks it, review the download and use **System Settings → Privacy & Security → Open Anyway**, or build it from source.
3. Enable the app in **System Settings → Privacy & Security → Accessibility**. Trackpad Mode starts automatically after permission is available and can be toggled from the menu bar.

Requires macOS 26 or later and an Apple Magic Mouse. The download is a universal app for Apple silicon and Intel Macs. Settings follow the app language, with English and Simplified Chinese available.

## Gestures

| Gesture | Action |
| --- | --- |
| Slide or tap with one finger | Move the pointer or left-click |
| Tap twice, lifting both times | Double-click |
| Tap, touch again, and hold | Hold left click. Slide your finger or move the mouse body to drag. Lift to release. |
| Tap with two fingers | Right-click |
| Slide two fingers together | Continuous horizontal and vertical scrolling with inertia |
| Pinch, spread, or turn two fingers | Zoom or rotate in supported apps |

During a touch-driven drag, the app detaches the hardware pointer from the cursor until touch movement stops or the drag is released. This prevents the mouse body from interrupting finger-based positioning. Two-finger gestures lock to one action for the duration of the gesture. Zoom and rotation use private macOS gesture fields, so support can vary by app or macOS version.

## Build from source

Use Xcode or the Command Line Tools with a macOS 26 SDK or newer.

```sh
./build.sh
open "build/Magic Mouse Toolkit.app"
```

For Command Line Tools that default to a macOS 27 SDK without the SwiftUI macro plugin, select an installed 26.5 SDK with `SDKROOT="$(xcrun --sdk macosx26.5 --show-sdk-path)" ./build.sh`. Use `SIGN_ID` to specify a signing identity for your own builds.

## License and credits

GPL-3.0-only. This project builds on [Magic Mouse Toolkit](https://github.com/mori0818/magic-mouse-toolkit) by mori0818. See the [license](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md).
