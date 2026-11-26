# Changelog

## Unreleased

### Changed

- Generate continuous, two-axis pixel scrolling directly from Magic Mouse touch frames. Include the initial movement that triggered scroll recognition. Compatible apps can use the same input to pan a canvas.
- Filter small touch-coordinate fluctuations while accumulating slow intentional movement. Preserve an active scroll through a brief missing-finger report of up to 35 ms, and resume from a fresh position when the contact returns.
- Keep the cursor from moving when one finger remains after a two-finger gesture.
- Generate a momentum tail from recent touch movement and cancel it when a new gesture starts.
- Close scroll events when the utility quits, touch monitoring stops, or Accessibility access is revoked.
