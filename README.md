# DoubleMouse

<p align="center">
  <img src="Assets/DoubleMouse.png" alt="DoubleMouse icon" width="180">
</p>

Ever wondered how to be faster on your Mac? What if, instead of one little arrow, you had two?

**DoubleMouse** is an open-source macOS menu bar app that gives a second physical mouse its own blue pointer. Both pointers move simultaneously, and each can click, scroll, and drag. It is also handy in classrooms and support sessions, where teacher and student can each keep a hand on the computer without negotiating custody of the cursor.

## Download

- [Download DoubleMouse 1.1.0 for macOS from GitHub](https://github.com/franciscoxc/DoubleMouse/releases/download/v1.1.0/DoubleMouse-1.1.0.dmg)
- [Download mirror and project page](https://apps.franxc.com/doublemouse/)

The downloadable build supports Apple Silicon and Intel Macs running macOS 13 or later.

## Install

1. Open the DMG and drag DoubleMouse to Applications.
2. Launch DoubleMouse and grant Accessibility permission when macOS asks.
3. If the blue pointer does not react, also enable DoubleMouse under System Settings > Privacy & Security > Input Monitoring.
4. Use `Set Blue Pointer From Next Movement` from the menu bar when you need to assign a different device.

Version 1.1.0 is ad-hoc signed but not notarized. macOS may require you to approve the first launch under System Settings > Privacy & Security.

## Features

- Truly simultaneous movement of the normal macOS cursor and the blue pointer.
- Independent clicks for both physical devices.
- Scroll-wheel support at the blue pointer location.
- Drag-and-drop with either pointer.
- External USB and Bluetooth mouse support.
- MacBook trackpad plus external mouse support when macOS exposes both HID devices.
- Compact menu bar device selection.
- No analytics, accounts, network access, or kernel extension.

## How It Works

DoubleMouse opens HID devices independently and takes exclusive user-space ownership of the selected blue-pointer device. macOS continues to own the normal cursor, while DoubleMouse draws the blue pointer and emits its actions at the correct screen coordinates.

The implementation uses public AppKit, IOKit, Accessibility, and CoreGraphics APIs. It does not install a driver or system extension.

## Limitations

- macOS still has one global mouse-button state, so two simultaneous drag operations are not supported.
- Some games, remote desktops, canvases, or custom controls may reject synthetic pointer events.
- The selected blue device is not persisted between launches yet.
- The public DMG is not notarized until a Developer ID certificate is available.

## Run From Source

```sh
swift run DoubleMouse
```

When running from Terminal, macOS assigns the relevant privacy permissions to Terminal. The packaged app requests them as DoubleMouse.

## Build The DMG

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/package-release.sh 1.1.0
```

The script uses only native macOS tools and writes the DMG plus SHA-256 checksum to `dist/`.

## Contributing

Issues and pull requests are welcome. Include your macOS version, Mac model, pointing-device models, connection types, and whether the problem affects movement, clicks, scroll, or dragging.

## License

MIT. See [LICENSE](LICENSE).
