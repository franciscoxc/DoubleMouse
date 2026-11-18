# Changelog

## 1.3.0 - 2026-11-18

- The blue pointer reaches every display when "Displays have separate Spaces" is on, which is the macOS default. macOS was moving the single overlay window onto one display and the pointer was confined to it. Thanks to Harry Lau, who found the cause and sent the fix.
- The blue pointer can no longer wander into the empty corner an L-shaped display arrangement leaves, where it was drawn nowhere and clicked on nothing.
- Added Check for Updates to the menu. It asks GitHub for the latest release, shows its notes, downloads it, checks that it is signed by the same developer, and installs it. It is the only network request the app makes, and only when you choose it.
- Added Open at Login to the menu.
- Added Pause Blue Pointer: it hands the blue mouse back to macOS, so it moves the regular pointer, hover included, until you resume.
- The first time two pointing devices are connected, DoubleMouse asks which one moves the blue pointer: you click Use This Mouse with it. It used to guess, and the guess could just as well be the main mouse. Choose by Clicking, in the Blue Pointer submenu, replaces Set Blue Pointer From Next Movement, which caught the main mouse whenever the hand on it moved first.
- The blue pointer's clicks are counted, so a double click opens a file instead of selecting it twice.
- Shift, Control, Option, and Command held on the keyboard now apply to the blue pointer's clicks and scrolling.
- The middle button of the blue mouse works, and side buttons are passed along the same way.
- Holding the blue button down without moving now presses and holds, instead of waiting for the release to click.
- The blue pointer keeps working while the DoubleMouse menu or one of its dialogs is open. It used to freeze until it closed.
- The regular arrow stays in its place while the blue pointer drags or scrolls. It could travel to the blue pointer and stay there. A brief flicker remains.
- DoubleMouse never takes the last pointing device away from macOS. With only one connected, it is left alone, so you can't end up with no way to move the regular pointer.
- A blue mouse that macOS refuses to hand over no longer moves both pointers and clicks twice. The menu says so and opens the Input Monitoring settings.
- The menu is shorter: the blue mouse's name, the device list, and Choose by Clicking share one submenu, Acceleration moved in with Pointer Speed, and the version sits under Check for Updates. The Accessibility message no longer talks about running from Terminal. It also explains the case where DoubleMouse is listed and turned on but still not allowed, which happens after updating from 1.2.1 or earlier: macOS keeps the entry tied to the old signature until it is removed.
- Release builds require a version number and run the self-check on the signed app. Every push and pull request now builds and runs the self-check on GitHub Actions.

## 1.2.2 - 2026-07-29

- The published DMG is now signed with a Developer ID and notarized by Apple, so macOS no longer asks you to approve the first launch.
- Updating from an earlier version requires granting Accessibility, and Input Monitoring where it applies, one more time: the signature changed, so macOS treats this build as a different app and its old permissions do not carry over.
- Release builds now happen outside the working copy. iCloud Drive syncs Desktop and Documents, and its file provider was stamping attributes on the app bundle mid-build that made code signing fail at random.

## 1.2.1 - 2026-07-28

- Redrew the app icon: two translucent glass pointers overlapping on a light macOS tile, replacing the pair that faced away from each other.
- Added the vector sources for the icon, including a dark-appearance variant.

## 1.2.0 - 2026-07-28

- Added right-click and horizontal scrolling for the blue pointer.
- Added adjustable pointer speed and optional acceleration, so raw HID counts no longer map 1:1 to pixels.
- The selected blue device is now remembered between launches.
- Fixed the overlay not following display changes: connecting a monitor or changing resolution left the blue pointer unable to reach the new screen.
- Fixed the blue pointer being drawn at the wrong offset when a display sits left of or below the main one.
- Fixed reconnected devices inheriting the identity of an unplugged one, by keying devices on their IOService registry ID.
- Coalesced each HID report into a single movement, halving emitted drag events and redrawing only the area around the pointer instead of the whole desktop.
- Narrowed the Accessibility press path to button-like controls, so clicks on text fields, tables, and web content behave like real clicks.

## 1.1.1 - 2026-07-10

- Refreshed the app icon with inward-facing glass cursor arrows.
- Clarified the two-device requirement in the release materials.

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
