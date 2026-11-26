# Changelog

## Unreleased

### Added

- Added Simplified Chinese menus and settings.
- Added a menu bar control for virtual trackpad mode and saved the selected mode across launches.
- Added single-finger tap-and-drag, two-finger secondary tap, and pinch and rotation gestures in virtual trackpad mode.

### Changed

- Generate continuous, two-axis pixel scrolling directly from Magic Mouse touch frames. Include the initial movement that triggered scroll recognition. Compatible apps can use the same input to pan a canvas.
- Filter small touch-coordinate fluctuations while accumulating slow intentional movement. Preserve an active scroll through a brief missing-finger report of up to 35 ms, and resume from a fresh position when the contact returns.
- Keep the cursor from moving when one finger remains after a two-finger gesture.
- Preserve scroll momentum and handle gesture cleanup when the utility quits, input monitoring stops, or Accessibility access is revoked.
