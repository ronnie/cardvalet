# Building CardValet

Developer notes. These are not part of the in-app Help.

## Safety

A wrong PIN counts against the card, and the card locks after a few failures. Keep these rules.

- Do not type a PIN, and do not press OK, unless `cardSafe()` has just returned ok. Locked, final try, low retry count, no card, a tool failure, and the 5 second timeout all mean type nothing. The one exception is a missing OpenSC install: the check is skipped and the PIN is typed.
- `judge` reads every token in the `pkcs11-tool -L` output. A healthy token listed first does not clear a locked card listed after it.
- The PIN lives only in the login Keychain (service `cardvalet`, account `pin`). Log the character count. Never log, print, or write the PIN.
- Do not set `AXValue` on the secure field. The field looks filled, the signature still fails, and the card can lock.
- Do not post keystrokes to the HID event tap. They go to whichever app is frontmost. Post each character to the `coreautha` process with `postToPid`.
- Before pressing OK, the secure field count must match the PIN length (a reported 0 is allowed, because a secure field may not report its contents) and the OK button must be enabled. If either check fails, pause and submit nothing.
- If the PIN prompt returns within 3 to 8 seconds of a submit, pause. That usually means the PIN was wrong. Do not submit again.

## Requirements

- macOS 13 or later, Xcode command line tools.
- OpenSC (`pkcs11-tool`) for the card status check. Optional. Without it the check is skipped and the PIN is typed. Official package or `brew install opensc`.

## Build

```
./build.sh
open build/CardValet.app
```

`build.sh` runs `swift build -c release`, wraps the binary in `build/CardValet.app`, copies `CardValet.icns`, generates `help.html` from `README.md` with `md2html.py`, copies `docs/screenshots` into the bundle, and ad-hoc signs the app. The bundle id and the signature identifier are both `com.ronniemoore.cardvalet`.

## After every rebuild

The app is ad-hoc signed, so macOS treats each rebuild as a new app:

- Accessibility: remove CardValet in System Settings, Privacy & Security, Accessibility, add it again and relaunch.
- Keychain: click Always Allow at the launch prompt.

## Versions

A release is created only when you push a version tag. Commits on `main` do not build a release. There is no nightly build.

The first public version is 0.1.0. Later numbers are whatever tag you push. There is no VERSION file.

```
git tag v0.2.0
git push origin v0.2.0
```

The tag must be `v` plus three numbers, such as `v0.1.1`. The workflow builds that version and publishes it as the latest release.

- Patch (0.1.0 to 0.1.1): a fix. Same setup, same behavior aside from the bug.
- Minor (0.1.0 to 0.2.0): something new that existing setups can ignore.
- Major (0.1.0 to 1.0.0): the version you are willing to call stable, or a change a current user has to adapt to.

The downloaded zip is ad-hoc signed and not notarized. macOS may block it the first time. Right-click CardValet.app, choose Open, then Open. Remove CardValet from Accessibility if it is already listed, add it again, and switch it on. OpenSC must be installed.

## Other files

- `make-icon.swift`: regenerates `CardValet.icns` (`swift make-icon.swift && iconutil -c icns CardValet.iconset -o CardValet.icns`).
- `md2html.py`: tiny Markdown to HTML converter for the Help page.
- `docs/screenshots/`: images used by the guide.

## Dev checks

```
.build/release/CardValet --selftest
.build/release/CardValet --check-card
.build/release/CardValet --preview-locked
.build/release/CardValet --preview-nocard
.build/release/CardValet --preview-nopin
.build/release/CardValet --preview-accessibility
```
