# DoubleMouse

Ever wondered how to be faster on your Mac? What if, instead of one little arrow, you had two?

Meet **DoubleMouse**: a macOS menu bar app that lets you control your computer with two mice. One mouse keeps the normal macOS cursor; the second mouse gets its own blue pointer and can click independently.

It is also useful in teaching and support settings, where a teacher and a student can each have their own cursor on the same Mac. Less "move over, let me show you" and more "look, we both have arrows now."

## Features

- Use a second physical mouse as an independent blue pointer.
- Keep the normal macOS cursor and the blue pointer independent in everyday use.
- Click with the blue pointer.
- Choose which physical device is the system mouse and which one drives the blue pointer.
- Lives quietly in the macOS menu bar.
- Open source Swift/AppKit implementation.

## Behavior

macOS exposes one real system cursor. DoubleMouse works around that by drawing a virtual blue pointer for the secondary device, then briefly using the real cursor as an internal click executor. For blue-pointer clicks, it suppresses the secondary mouse's physical click and emits a synthetic click at the blue pointer instead.

This is not a kernel driver and not a native multi-cursor implementation. It does not promise true simultaneous pointer movement. It is a practical user-space approach for fast alternating control, teaching, demonstrations, and support sessions.

## Current Limitations

- The blue pointer supports clicks, but not drag-and-drop yet.
- True simultaneous movement of both pointers is not supported.
- Some custom apps, games, canvases, or graphics tools may not respond to accessibility/synthetic clicks exactly like standard macOS controls.

## Technical Notes

- Input is read per device with `IOHIDManager`.
- The blue pointer is drawn in a transparent always-on-top AppKit overlay.
- AppKit and CoreGraphics use different coordinate systems; click execution converts AppKit points to Quartz points before warping or posting events.
- Physical secondary clicks are suppressed with a short `CGEventTap` window.
- Synthetic DoubleMouse clicks are marked so the suppressor does not block its own events.

## Usability Notes

- Quit any old DoubleMouse instance before testing a new build.
- If the wrong device controls the blue pointer, use `Set Blue Pointer From Next Movement`.
- If the blue pointer moves vertically in the wrong direction, toggle `Invert Blue Pointer Y Axis`.
- True simultaneous two-pointer movement is a future research area and likely requires a lower-level event-remapping approach.

## Requirements

- macOS 13 or later.
- Xcode or Xcode Command Line Tools.
- Accessibility permission for blue-pointer clicks.

## Run From Source

```sh
swift run DoubleMouse
```

While running from Terminal with `swift run`, macOS grants Accessibility permission to Terminal. A packaged app will request permission as DoubleMouse.

## Try it with two pointing devices

1. Run `swift run DoubleMouse`.
2. Look for `DoubleMouse` in the macOS menu bar.
3. Choose the normal device under `System Mouse`.
4. Choose the device that should drive the blue overlay under `Blue Pointer Mouse`.
5. If needed, use `Set Blue Pointer From Next Movement` and then move the secondary mouse.
6. Move both devices to confirm the system cursor and blue pointer remain independent during normal alternating use.

The built-in MacBook trackpad may appear as a touchpad device on some Macs and macOS versions. If it does not appear, use the two external mouse setup first; trackpad support will need model-specific testing.

## Project Status

DoubleMouse is an early working prototype. It is usable enough to demonstrate the idea, but still needs packaging, preference persistence, broader device testing, and UI polish.

## Roadmap

- Package as a signed `.app`.
- Persist selected devices and pointer preferences.
- Improve the blue cursor artwork.
- Test more devices, including MacBook trackpad plus external mouse.
- Add releases with downloadable builds.
- Research true simultaneous movement through lower-level event remapping.
- Add drag-and-drop support for the blue pointer.

## Contributing

Issues and pull requests are welcome. Please include your macOS version, device models, and whether you are testing with USB, Bluetooth, or built-in pointing devices.

## License

MIT. See [LICENSE](LICENSE).

This is an early prototype. The core movement separation is implemented with observed cursor cancellation, which is more stable than event suppression or cursor hiding on current macOS.
