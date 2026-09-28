# Pawshot

A native macOS screenshot and screen recording tool. One hotkey, draw on it, ⌘C — done.

![Pawshot: capture, annotate, record, cut, export — at 2× speed](docs/demo.gif)

## Why

Apple has had years to ship a decent screenshot tool and still hasn't: nothing where one hotkey
drops you straight into editing and ⌘C / ⌘V just work. The alternatives are either half-baked or
want a subscription for drawing an arrow. Five, ten, twenty bucks — for *this*? Nope.

So I built my own. Native, free, a few megabytes, no account, no nagging. Grab it. Let's go.

- **⇧⌘2** a region, **⇧⌘1** the whole screen, **Space** a single window.
- Annotate with one key per tool — line or (double) arrow, box, pen, text, blur, step counter — all
  undoable objects, on any keyboard layout. Four colours plus one of your own with an eyedropper,
  fills of any opacity, labels in any installed font with every weight it has, and **⌘L / ⌘R** to turn the
  selection — or the whole shot with everything on it.
- **⌘C** copies the image, **⌘S** saves a PNG, **⌘D** copies the *text* read off the shot.
- Missed by a few pixels? Drag the editor window's edge — the shot grows into the screen around it.
- **⇧⌘3** records a region, **⇧⌘4** the whole screen — with mic, system sound, click rings, shortcut
  captions, zooms and a pen that draws into the video.
- Stop, keep the pieces you want, get HEVC, 1080p or a GIF straight onto the clipboard.

## Install

Pawshot needs macOS 26 (Tahoe). There is one way in:

1. Download `Pawshot-<version>.dmg` from the
   [latest release](https://github.com/CaramelHeaven/Pawshot/releases/latest).
2. Open it and drag Pawshot onto Applications.
3. Open Pawshot. The build isn't notarised, so macOS stops the first launch: go to System Settings →
   Privacy & Security, press **Open Anyway** and enter your password. This happens once — updates
   never ask again.
4. The welcome window lists everything Pawshot can use, each with its own button: **Screen
   Recording** is the one it needs; the microphone, Input Monitoring (shortcut captions in videos),
   freeing ⇧⌘3 / ⇧⌘4 from macOS and launch at login can wait. Press **Get Started**.

The paw in the menu bar means it is running. **⌘S** asks for the Desktop the first time it saves.

## Updates

Pawshot updates itself through [Sparkle](https://sparkle-project.org): it checks the releases here
once a day, or right away from the paw → **Check for Updates…**, and **Install and Relaunch** swaps
the app in place. No DMG, no Open Anyway, no password, and the permissions you gave it stay.

## Development

Building from source is for working on Pawshot, not for installing it. You need Xcode 26 and
[mise](https://mise.jdx.dev), which pulls the pinned Tuist and SwiftFormat on its own.

```sh
git clone https://github.com/CaramelHeaven/Pawshot.git && cd Pawshot
make run    # build a Debug copy and launch it
make test   # the unit tests
make        # every other target
```

<details>
<summary>A stable signature, so Screen Recording survives rebuilds</summary>

Out of the box the build is signed ad hoc, and macOS asks for Screen Recording again after every
rebuild. A self-signed identity fixes that and needs no Apple account:

```sh
T=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$T/k.pem" -out "$T/c.pem" \
  -subj "/CN=Pawshot Self-Signed" -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -inkey "$T/k.pem" -in "$T/c.pem" -name "Pawshot Self-Signed" -out "$T/p.p12" -passout pass:pawshot
security import "$T/p.p12" -k ~/Library/Keychains/login.keychain-db -P pawshot -A \
  -T /usr/bin/codesign
rm -rf "$T"
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
```

The three `-keypbe/-certpbe/-macalg` flags matter with OpenSSL 3 (Homebrew's): its default `.p12`
is one macOS's `security import` rejects as "MAC verification failed". An Apple Development
certificate works too — see `Config/Signing.local.xcconfig.example`.

</details>

Releases are the owner's: raise the version in `Project.swift`, commit, push, then
`make release publish` — it builds the DMG, signs the update with the key in the owner's Keychain
and puts both on GitHub, where every installed copy finds them.

## For AI agents

Read [`AGENTS.md`](AGENTS.md) first — the architecture, the hard rules and every trap already
stepped on, with measurements. `CLAUDE.md` only imports it. The short version:

- Tuist generates the project: `Project.swift` is the source of truth; after adding a file run
  `make generate`. Build and test through `make`, never a global `tuist`.
- SwiftFormat is mandatory — `make lint` must be clean.
- Coordinate math lives only in `SelectionGeometry`, covered by tests.
- Hotkeys, the overlay and anything you'd need eyes for can't be verified from a shell. Say so
  instead of writing "checked, works".
- Don't commit or push — leave the work in the tree for the owner to review.
