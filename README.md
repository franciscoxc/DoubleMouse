# DoubleMouse

Ever wondered how to be faster on your Mac? What if, instead of one little arrow, you had two?

Meet **DoubleMouse**: a macOS menu bar app that lets you control your computer with two mice. One pointer stays as the normal system cursor; the second mouse gets its own blue pointer and can click independently.

It is also useful in teaching and support settings, where a teacher and a student can each have their own cursor on the same Mac. Less "move over, let me show you" and more "look, we both have arrows now."

## Features

- Use a second physical mouse as an independent blue pointer.
- Keep the normal macOS cursor and the blue pointer independent.
- Click with the blue pointer.
- Choose which physical device is the system mouse and which one drives the blue pointer.
- Lives quietly in the macOS menu bar.
- Open source Swift/AppKit implementation.

## Behavior

macOS exposes one real system cursor. DoubleMouse works around that by drawing a virtual blue pointer for the second device, then freezing/restoring the system cursor while the secondary mouse moves. For clicks, it suppresses the secondary mouse's physical click and emits a click at the blue pointer instead.

This is not a kernel driver and not a native multi-cursor implementation. It is a practical user-space approach that works well for the current prototype.

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
3. Choose the normal device under `Mouse del sistema`.
4. Choose the device that should drive the blue overlay under `Mouse flecha azul`.
5. If needed, use `Elegir flecha azul con el proximo movimiento` and then move the secondary mouse.
6. Move both devices to confirm the system cursor and blue pointer remain independent.

The built-in MacBook trackpad may appear as a touchpad device on some Macs and macOS versions. If it does not appear, use the two external mouse setup first; trackpad support will need model-specific testing.

## Project Status

DoubleMouse is an early working prototype. It is usable enough to demonstrate the idea, but still needs packaging, preference persistence, broader device testing, and UI polish.

## Roadmap

- Package as a signed `.app`.
- Persist selected devices and pointer preferences.
- Improve the blue cursor artwork.
- Test more devices, including MacBook trackpad plus external mouse.
- Add releases with downloadable builds.

## Contributing

Issues and pull requests are welcome. Please include your macOS version, device models, and whether you are testing with USB, Bluetooth, or built-in pointing devices.

## License

MIT. See [LICENSE](LICENSE).

This is an early prototype. The core movement separation is implemented with observed cursor cancellation, which is more stable than event suppression or cursor hiding on current macOS.
