# sudo-toggle

A one-click / one-keystroke switch that arms or disarms passwordless `sudo`
for your account, with a matching desktop widget and menu-bar indicator.

- **Locked** (default): `sudo` behaves normally and asks for your password.
- **Armed**: an `/etc/sudoers.d/sudo-nopasswd` rule is in place, so `sudo` runs
  without a password until you toggle it back off.

Arming requires you to authenticate once, in a terminal window.

> **Security warning.** While armed, any process running as your user can run
> any command as root without a password. This is a convenience switch, not a
> security boundary. Only arm it when you want that, and lock it when done.
> Installing this puts a `NOPASSWD: ALL` rule on your machine whenever armed.

## How it works

- `bin/sudo-toggle` (installed to `/usr/local/sbin`, root-owned) creates or
  removes `/etc/sudoers.d/sudo-nopasswd`. It validates the rule with `visudo`
  before installing it, so a bad write can't lock you out of `sudo`.
- `app/Sudo Toggle.app` is a tiny launcher. It opens a WezTerm window that runs
  `sudo /usr/local/sbin/sudo-toggle`, so the password prompt appears in a
  terminal your window manager will focus. This is deliberate: macOS's own
  authorization dialog does not reliably take keyboard focus under a tiling WM.
  Find it in Spotlight as "Sudo Toggle".
- `ubersicht/sudo-toggle.jsx` and `sketchybar/sudo.sh` are read-only indicators
  that poll the sudoers file every 2s and, on click, open the launcher app.

## Requirements

- macOS, with an admin account (so `sudo` works with your password).
- [WezTerm](https://wezterm.org) at `/Applications/WezTerm.app`, the terminal
  the launcher opens. The window auto-closes on exit via WezTerm's default
  `exit_behavior`; if you set it to `Hold`, the window will stay open.
- Optional: [Übersicht](https://tracesof.net/uebersicht/) for the desktop
  widget; [SketchyBar](https://felixkratz.github.io/SketchyBar/) for the pill.

## Install

```sh
./install.sh
```

Run it *without* `sudo`; it copies the user files itself and prompts once for
your password for the root-owned script.

For the SketchyBar pill, add the item in `sketchybar/sketchybarrc.snippet` to
your `sketchybarrc`.

## Uninstall

```sh
./uninstall.sh
```
