# Bloomin8 Mac

![Bloomin8 Mac showing what's on the frame, what's coming up, recent activity and the battery](docs/screenshot.png)

Two macOS apps for the [BLOOMIN8](https://bloomin8.com/) e-ink photo frame, sharing one underlying engine:

- **Bloomin8 Widget** — a menu bar app for quick actions: see what's on your frame, push a random photo, wake it up, all from a popover without a Dock icon.
- **Bloomin8 Mac** — a full windowed app with a sidebar and a real image grid, for actually browsing — a folder of thousands of local photos, a device gallery, or pulling a screenshot from a local video.

Use the widget for quick, everyday actions; use the windowed app when you want to properly look through a folder or gallery.

> 🤖 **This entire project — every line of code, this README included — was built by [Claude Code](https://claude.com/claude-code), Anthropic's AI coding assistant, working from plain-English requests in a chat conversation.** No hand-written Swift went into it.

## Features

Shared by both apps:

- **Live preview** of what's currently on the frame, and one-click **Random Photo** from selected galleries.
- **Gallery tabs** — group galleries into named tabs, optionally locked behind a password (a UI-level deterrent, not real security — see [Security notes](#security-notes)).
- **Randomize by photo or by gallery** — pool every photo across selected galleries, or give every gallery equal odds regardless of size.
- **Bluetooth wake** — sends a BLE pulse to bring the frame's Wi-Fi radio back up when it's asleep, and retries automatically once it's reachable.
- **Local Folder** — pick from photos (and videos, in the app) on your Mac instead of a gallery already on the frame.
- **Favorites** — mark local photos for quick, repeated access without re-browsing.
- **Museum cards** — every photo you send gets a little museum-style label (title, place, date, camera) built from its EXIF, ready for a companion e-paper display beside the frame. See [Museum cards and the CrowPanel display](#museum-cards-and-the-crowpanel-display).
- **Crop or letterbox landscape photos** — a landscape photo on the frame's portrait screen can either show in full with black bars, or crop and center to fill the screen (your choice, per-user setting).

Widget-only:

- **Battery indicator** and **right-click quick menu** (Random Photo, Wake Frame, Quit) without opening the popover.

App-only (the windowed app), for cases the popover was never going to handle well:

- **Full image grid** with adjustable thumbnail size and filename search, for folders and galleries with thousands of images.
- **Multi-select** — Cmd-click to toggle, Shift-click for a range, right-click for bulk send/delete/favorite.
- **Delete images from a device gallery** directly, with confirmation.
- **Drag-and-drop upload** onto the grid while browsing a gallery.
- **Video screenshots** — Local Folder also scans local movies (mp4/mov/m4v); pick a video to pull a handful of frames spread across it, "Next" for a different set, and confirm before sending.
- **Museum card editor and preview** — edit the card for what's on the frame in the On the Frame pane, and see the card a photo will get under Send to Frame before you send it.
- **Live "on the frame" badge** on whichever grid cell matches what's currently displayed.
- Cached gallery listings and thumbnails, so revisiting a folder or gallery you've already opened is instant rather than re-fetching everything.

## How it works

The BLOOMIN8 frame exposes an undocumented local HTTP API on your Wi-Fi network (no cloud, no auth) — both apps talk to it directly:

- `GET /deviceInfo` — current photo, active gallery, battery level, device name
- `GET /gallery/list`, `GET /gallery` — list galleries and their images (with cursor-based pagination for galleries over 51 photos)
- `POST /show` — display a specific image on the frame
- `POST /upload`, `POST /image/delete` — add or remove images from a gallery

Since the frame's Wi-Fi radio sleeps to save battery, waking it requires Bluetooth Low Energy: the app scans for the frame by its advertised BLE name, connects, and writes a short pulse to one of its known GATT characteristics, which brings Wi-Fi back up.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (for the Swift toolchain — `xcode-select --install` if you don't already have it)

No Xcode project is needed; this is a plain Swift Package Manager workspace.

## Installing a release

Download `Bloomin8-<version>.dmg` from the [Releases](https://github.com/philipholtom/Bloomin8-Mac-Widget/releases) page, open it, and drag both apps onto Applications. The apps aren't notarized by Apple, so macOS blocks the first launch. Run this once in Terminal (works on every macOS version):

```bash
xattr -dr com.apple.quarantine "/Applications/Bloomin8 Mac.app" "/Applications/Bloomin8 Widget.app"
```

Or try to open each app, then go to System Settings → Privacy & Security and click **Open Anyway**. (On macOS 14 and earlier, right-click → Open also works.) Requires macOS 13 or later, Apple Silicon or Intel.

Maintainers: `./build_app.sh all && ./package_release.sh` produces the disk image in `dist/`.

## Building & running

```sh
git clone https://github.com/philipholtom/Bloomin8-Mac-Widget.git
cd Bloomin8-Mac-Widget
./build_app.sh
```

`build_app.sh` builds both apps, packages, codesigns, installs them to `/Applications` (replacing any previous copies), and launches them. Pass `widget` or `app` to build just one:

```sh
./build_app.sh widget   # just Bloomin8 Widget.app
./build_app.sh app      # just Bloomin8 Mac.app
./build_app.sh          # both (same as "all")
```

Re-run any time after pulling changes.

On first launch of either app, open Settings (gear icon) to enter:

- **Frame IP address** — your frame's local network IP (find it via the BLOOMIN8 phone app or your router's device list)
- **Bluetooth device name** — the frame's advertised BLE name, used to wake it when asleep

Settings are shared between both apps (one `UserDefaults` suite) — configure either one and the other picks it up.

To launch the widget automatically at login, add `/Applications/Bloomin8 Widget.app` in System Settings → General → Login Items.

## Museum cards and the CrowPanel display

A small companion e-paper screen (an [Elecrow CrowPanel 2.13"](https://www.elecrow.com/wiki/CrowPanel_ESP32_E-Paper_HMI_2.13-inch_Display.html), ESP32-S3) sits next to the frame and shows a label for whatever photo is on it, like the cards beside paintings in a museum. Its buttons double as a remote: random photo, pick a gallery, wake the frame.

- **Where cards come from** — when a photo is sent, the app reads its EXIF/IPTC (title or caption, date taken, GPS, camera and lens) and reverse-geocodes the location with Apple's geocoder: "Landmark, City, Country" when there's a known point of interest, otherwise "City, Country". Anything you type in the card editor wins from then on.
- **Where they live** — `~/Library/Application Support/Blooming8/museum_cards.json`, keyed by the photo's path on the frame (e.g. `/gallerys/Apple/IMG_1234-ab12cd34_P.jpg`), since that path is the one identifier the frame, the Mac and the display all share.
- **How the display gets them** — whichever of the two apps is running serves them on port 8738 (also advertised over Bonjour as `_b8cards._tcp`):
  - `GET /version` — a number that changes whenever the cards (or the locked galleries) change, plus the image, gallery and battery level this Mac last saw on the frame
  - `GET /cards` — every card, plus `hiddenGalleries`: the galleries in password-locked tabs, which the display never offers
- **Pull, not push** — the display asks the Mac every 30 seconds, re-downloads the cards only when the version changes, and keeps its own copy so it can still label photos while the Mac is off.
- **Knowing what's on the frame** — the frame's Wi-Fi sleeps most of the time, but the Mac checks it every minute and knows straight away when it sends a photo, so `/version` tells the display what's showing. The display also asks the frame directly every few minutes, for when the Mac is off.
- **Power** — the display normally runs on mains power and stays awake (and takes firmware updates over Wi-Fi). Its firmware also has a battery mode that deep-sleeps, waking every 15 minutes or on a button press.
- **Networking** — the display has to be able to reach the Mac. If the frame lives on a separate network that can't route back to the Mac's, join the Mac's Wi-Fi to the frame's network too and give it a fixed address there.

The display's firmware isn't part of this repo.

## Security notes

- The frame's HTTP API has no authentication of its own — anyone on your local network can talk to it directly. Neither app adds any security to the frame itself.
- Gallery tab passwords and the Local Folder password are convenience features only: they gate each app's own UI (a locked tab's galleries won't show, randomize, or browse until unlocked) but don't touch the frame's actual access control. Don't rely on them for genuinely sensitive photos.
- The museum card server (port 8738) has no authentication either: anyone on your local network can read the card text and the names of locked galleries. It's read-only.
- Unlocking a tab is per-app-process and in-memory only — unlocking it in the widget doesn't unlock it in the windowed app, or vice versa, and it re-locks on relaunch.

## Project structure

```
Sources/Bloomin8Core/       shared engine — device client, controller, settings, BLE wake, content sources
  BloominClient.swift          the frame's local HTTP API client
  PhotoController.swift        app state and business logic
  AppSettings.swift            persisted settings (shared UserDefaults suite)
  GalleryTab.swift             gallery tab / password model
  MuseumCard.swift             museum cards: store, EXIF reading, place names
  MuseumCardServer.swift       serves cards to the CrowPanel display (port 8738)
  BLEWaker.swift                CoreBluetooth wake pulse
  ImageFolder.swift             local image scanning + thumbnail caching
  VideoFrames.swift             local video scanning + frame extraction
  ContentRendering.swift        image compositing (letterbox/crop-fill, generated content)
  *Source.swift                 generated content sources (weather, moon phase, fortune, ...)

Sources/Bloomin8Widget/     the menu bar app
  main.swift, AppDelegate.swift  entry point, status item, popover
  ContentView.swift               the popover UI

Sources/Bloomin8App/        the windowed app
  Bloomin8AppMain.swift          entry point, window/scene setup
  RootView.swift, Sidebar.swift   sidebar navigation
  LibraryModel.swift, LibraryGrid.swift, InspectorPane.swift   the image grid + detail pane
  VideoFramePickerSheet.swift     video screenshot picker
  MuseumCardEditor.swift, MuseumCardPreview.swift   edit / preview museum cards
  SettingsSheet.swift, LockedGalleryPrompt.swift

Resources/AppIcon.icns       shared app icon
build_app.sh                  build, package, codesign, install, and relaunch
```
