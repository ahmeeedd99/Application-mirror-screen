# ipad-main-display

Plug your iPad into the Mac with USB-C and it becomes the **main display**, automatically.
Built on Apple's own Sidecar plus ~300 lines of code in this repo. No third-party apps, no downloads.

## Setup (once, while you can still see the Mac, e.g. over HDMI)

1. Both devices must use the **same Apple ID** (two-factor on). Connect the iPad once the normal way
   (System Settings ▸ Displays ▸ Add Display) so the Mac and iPad trust each other. Do this with internet.
2. Unzip this folder. In Terminal:
   ```
   cd ~/Downloads/ipad-main-display      # wherever you unzipped it
   xcode-select --install                # only if you've never installed Apple's developer tools
   bash install.sh                       # or: bash install.sh "My iPad's exact name"
   ```
   `bash install.sh` (not double-clicking) avoids macOS's "unidentified developer" prompt.
3. Plug in the iPad, unlock it, tap **Trust** once. Within seconds it becomes the main display.

Then: log in, plug in, unlock the iPad. Unplug and re-plug any time; it reconnects by itself.
No internet needed after setup.

## What it does when the iPad connects

- Makes the iPad the main display (menu bar and Dock).
- Parks the broken panel at the iPad's far corner, so the mouse can't slide onto an invisible screen.
- Keeps it that way if macOS shuffles displays (at most every 30 s). To get your normal setup back, run `bash uninstall.sh`.

## Using it blind, in public

- **After a reboot** the Mac shows its login window, which Sidecar can't display. Type your password blind,
  or enable auto-login (needs FileVault off, which weakens security).
- **After sleep/lock** the iPad keeps showing the lock screen: type your password there, or use Touch ID.
- A window opened *before* the iPad connected can be stuck on the broken panel: click its app, then Window ▸ Move to ▸ iPad.

## Security

| Concern | What the code does |
|---|---|
| Privileges | Runs as your user as a LaunchAgent. No sudo, no root (it refuses to run as root), no system files changed. |
| Network | Zero. No sockets, no downloads, no telemetry. Setup can be done fully offline once cloned. |
| Supply chain | Built on your Mac from the source you can read. No prebuilt binary, no `curl | bash`. |
| Wrong device | Pins one iPad by name. If several Sidecar devices exist and none is pinned, it refuses to connect instead of guessing. |
| Public places | Acts only while an Apple "iPad" is on the **USB** bus, so a nearby device can never be pulled in wirelessly. Sidecar itself only lists devices on your own Apple ID. |
| Private API | Apple's `SidecarCore` is loaded from its absolute system path; every call is checked first, so an OS change logs an error instead of crashing. |
| Files | Only `~/.local/share/ipad-main-display` (0700), one launch file, one log (0600, auto-trimmed at 512 KB). `uninstall.sh` removes all of it. |
| Injection | The iPad name is validated and XML-escaped before it goes into the launch file (tested with `&`, `<`, quotes). |
| Display changes | Session-only (undone by logout/reboot); never permanent, never disables a display. |

Residual risk: Sidecar's API is private and unsupported, so a macOS update could break it. You'd lose the
automation, not security: the display just stays as it was.

## Troubleshooting

- `tail -f ~/Library/Logs/ipad-main-display.log` shows what it is waiting for.
- `~/.local/share/ipad-main-display/ipad-main-display doctor` prints Sidecar, USB and display state.
- *"cannot pick a Sidecar device"*: unlock the iPad, tap Trust, check the Apple ID; or re-run `install.sh "<name>"`.
- *"selector is missing"*: a macOS update changed Apple's private API. Send the `doctor` output.

## How it works

`launchd` keeps `ipad-main-display` alive. Each 2 s it checks IOKit for an iPad on USB, asks Sidecar to
connect (retrying 3 s → 30 s backoff), then uses CoreGraphics to place the iPad at the origin.

## Status: read this

Written without access to a Mac. The code compiles clean (`-Wall -Wextra`, zero warnings) against stand-in
headers, and the installer, launch-file XML and name-escaping are tested. It has **not been run against
real Sidecar**; that happens on your first plug-in. If anything misbehaves, send the log and `doctor` output.
