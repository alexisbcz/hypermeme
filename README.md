<p align="center">
  <img src="docs/icon.png" width="128" alt="Hypermeme app icon">
</p>

# Hypermeme

A native macOS app for finding, captioning and pasting memes from your menu bar. Imgflip as a Mac app, made with SwiftUI.

![Hypermeme editing a Two Buttons meme](docs/screenshot.png)

## What it does

- **Lives in the menu bar.** Press ⌃⌥M anywhere, or click the grin at the top right of the screen. The panel opens over whatever you're doing without taking focus from it. The shortcut can be changed in Settings.
- **Finds any template.** Search covers imgflip's whole catalog, by name or by the other names people use, like "drakeposting". Popular templates scroll on for as long as you keep going.
- **Puts the text in the right place.** Each template opens with imgflip's own layout: text boxes in position, rotated where needed, with the right font and colors.
- **Inserts it where you were typing.** Type a caption and press Return. The meme is pasted into the app you were using, as an image. Without Accessibility access, Insert copies it and you press ⌘V yourself.
- **Keeps what you make.** My Memes holds every finished meme as a PNG. Search them by caption, insert one again, drag it into another app, or edit it again.
- **Edits properly when you want to.** The main window has draggable, resizable and rotatable text, six fonts, text and outline colors, alignment, a soft shadow, and a white caption strip above the image.
- **Captions your own images.** Drop one on the window, or press ⇧⌘V to use the clipboard.
- **Runs on your Mac.** Text is drawn locally with no watermark, no account and no imgflip login. An internet connection is needed only for searching and for templates you haven't opened before.

<p align="center">
  <img src="docs/panel.png" width="430" alt="The Hypermeme panel, captioning Distracted Boyfriend">
</p>

## Keyboard

In the panel:

| Key | Action |
| --- | --- |
| Type | Search |
| Arrow keys | Move through the grid |
| ⇥ | Next section |
| ↩ | Open a template, or insert a finished meme |
| ↩ in a caption | Insert |
| ⇧⌘C | Copy without pasting |
| ⎋ | Go back, then close |

Right-click the menu bar icon for the main window, Settings, updates and Quit.

## Links

`hypermeme://` links work from scripts, launchers and Shortcuts:

```sh
open 'hypermeme://panel?q=drake'
open 'hypermeme://search?q=boat cat'
open 'hypermeme://edit?template=two%20buttons&text=ship%20it&text=write%20tests&panel=1'
```

## Installation

### Download

Get `Hypermeme-<version>.dmg` from the [latest release](https://github.com/alexisbcz/hypermeme/releases/latest), open it, and drag Hypermeme into Applications. It needs macOS 26 or later.

The app isn't notarized, so macOS blocks the first launch. Allow it under **System Settings › Privacy & Security › Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Hypermeme.app
```

To paste directly, allow Hypermeme under **System Settings › Privacy & Security › Accessibility**. It uses that access only to press ⌘V after you choose Insert. The build is ad-hoc signed, so macOS may ask again after an update.

### Build from source

```sh
curl -fsSL https://raw.githubusercontent.com/alexisbcz/hypermeme/main/install.sh | bash
```

This builds Hypermeme with Xcode and installs it in Applications. For development, `make run` builds and starts it, and `make test` runs the tests.

## Releasing

1. Set `MARKETING_VERSION` in `project.yml` to the new version, so builds from source know which release they match.
2. Tag it and push the tag:

   ```sh
   git tag v0.2.0 && git push origin v0.2.0
   ```

The Release workflow builds the DMG, signs it for Sparkle, and publishes it with an `appcast.xml`, which installed copies read from the latest release. Signing needs the `SPARKLE_PRIVATE_KEY` repository secret, the private half of the `SUPublicEDKey` in `Hypermeme/Info.plist`. Sparkle's `generate_keys --account hypermeme` (in `build/SourcePackages/artifacts/sparkle/Sparkle/bin` after a build) keeps it in your keychain; `generate_keys --account hypermeme -x key.txt` exports it. Keep a backup: without it, installed copies can't take updates.

`make dmg` builds the same DMG locally.

Meme templates belong to their owners and come from [imgflip](https://imgflip.com). Hypermeme isn't affiliated with imgflip.

[MIT License](LICENSE)
