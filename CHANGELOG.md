# Changelog

## 1.1.0 - 2026-07-10

- Added true simultaneous movement for the system cursor and blue pointer.
- Captured only the selected secondary HID device, leaving the primary pointer native to macOS.
- Added independent blue-pointer clicks, scrolling, and drag-and-drop.
- Kept the system cursor in place while blue actions are emitted.
- Simplified the menu to blue-device selection and capture status.
- Added the DoubleMouse app icon and reproducible universal DMG packaging.
- Removed cursor-cancellation experiments, event counters, obsolete modes, and unused click suppression.

## 1.0.3 - 2026-05-31

- Removed the release-delay setting.
- The system cursor is released on the next main run-loop cycle after secondary mouse movement.

## 1.0.2 - 2026-05-31

- Tested a fixed 10 ms release delay.
- Removed the manual delay editor after runtime changes caused cursor jitter.

## 1.0.1 - 2026-05-31

- Reduced the default release delay from 50 ms to 25 ms.

## 1.0.0 - 2026-05-31

- First working prototype.
- Independent system cursor and blue secondary pointer.
- Secondary pointer clicks.
- Menu bar device assignment.
