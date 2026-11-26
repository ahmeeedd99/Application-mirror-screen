# ipad-main-display

Plug your iPad into the Mac with USB-C and it becomes the **main display**, automatically.
Uses only Apple's built-in Sidecar and code in this repo. No third-party apps.

## One-time setup (do this while you can still see the Mac, e.g. over HDMI)

1. Make sure both devices use the **same Apple ID** (two-factor on), and that the iPad has been
   used with Sidecar once: System Settings ▸ Displays ▸ Add Display ▸ your iPad.
2. In Terminal:
   ```
   xcode-select --install        # only if you've never installed Apple's developer tools
   git clone <this repo> && cd Application-mirror-screen
   git checkout claude/festive-bohr-h7o7vw
   ./install.sh                  # or: ./install.sh "Part of my iPad's name"
   ```
3. Plug in the iPad, unlock it, tap **Trust** once. Within a few seconds the iPad becomes the main display.
   Check: `tail -f ~/Library/Logs/ipad-main-display.log`

## Daily use

Log in to the Mac, plug in the iPad, unlock the iPad. That's it. Unplug and re-plug: it reconnects by itself.

## Using it blind, in public

- **After a reboot** the Mac sits at the login window, which Sidecar cannot show. Type your password
  blind, or turn on auto-login (needs FileVault off; weigh the security trade-off).
- **After sleep/lock** the iPad keeps showing the lock screen: type your password on the iPad, or use Touch ID.
- If an app's window seems missing, it is on the broken panel. Click the app, then Window ▸ Move to ▸ iPad.

## Troubleshooting

- `~/.local/share/ipad-main-display/ipad-main-display doctor` prints what Sidecar and the displays look like.
- Log says *"Sidecar does not list it yet"*: unlock the iPad, tap Trust, check the Apple ID.
- Log says a selector is missing: a macOS update changed Apple's private API. Run `doctor` and share the output.
- Remove everything with `./uninstall.sh`.

## How it works

`launchd` keeps `ipad-main-display` running. Every 2 s it checks whether an iPad is on the USB bus
(IOKit), asks Sidecar to connect (private `SidecarCore` framework via the Objective-C runtime,
every call guarded), then uses CoreGraphics to put the iPad at the origin so it is the main display.
Failures retry with backoff (3 s up to 30 s).

## Status

Written without access to a Mac, so it has **not been compiled or run yet**. The install script
lints the plist; the first real run on your Mac is the test. If anything fails, send me the
`doctor` output and the log.
