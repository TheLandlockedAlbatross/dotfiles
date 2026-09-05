# About

Scripts, configuration files and assets that I want pretty much everywhere. `$HOME` itself is the git repo, and the repo spans several machines: the current Omarchy (Arch + Hyprland) desktops plus an older Debian i3/XFCE setup.

Hopefully a never-ending work in progress.

## New machine setup

```
<install git, git-crypt, git-lfs>
cd $HOME
<move old $HOME content elsewhere if you want to preserve it>
git init
git branch -m main
git remote add origin https://github.com/TheLandlockedAlbatross/dotfiles/
git fetch origin
git checkout -b main origin/main
git crypt unlock <path to symmetric key from an existing machine>
```

The git-crypt key never lives in the repo; copy it over a secure channel from a machine that already has it.

## Security

To prevent accidentally tracking sensitive files, `.gitignore` ignores everything by default (`*`) and individual files and directories are allowlisted explicitly.

Files that are sensitive or useless to anybody but me are encrypted and prefixed `encrypted_MEO` (My Eyes Only). Small ones are encrypted transparently by git-crypt via `.gitattributes`; the large Firefox profile archives are encrypted with openssl before commit and stored through Git LFS. Firefox profiles are packed into archives so their internal paths stay private.

## Layout

### Hyprland (`.config/hypr/`)

Everything here adds to or overrides Omarchy defaults: tight gaps and borders, workspace toggle-back on re-pressing the shortcut for the workspace you are already on, fast key repeat, flat-accel touchpad tuning, idle/lock timers reworked around Omarchy's system lock, optional per-workspace wallpapers.

#### Keyboard layers

`input.conf` sets two stock xkb options: `caps:hyper` turns Caps Lock into a held Hyper/Mod3 modifier, and `compose:ralt` moves Compose to Right Alt. Neither key changes keycode; only the keysym and modifier attached to it change, so every application still agrees on which physical key was pressed.

That buys a second modifier and gives four workspace layers of ten, one decade per display:

| Layer | Workspaces |
|-------|------------|
| `Super` | 1-10 |
| `Caps` | 11-20 |
| `Super + Alt` | 21-30 |
| `Super + Caps` | 31-40 |

Adding `Shift` to any layer moves the focused window there instead of switching. Omarchy's digit-key defaults are relocated to keep the layers clear: `changegroupactive` to `Super + Ctrl`, `movetoworkspacesilent` to `Super + Ctrl + Shift`.

Two consequences of the remap worth knowing:

- Caps Lock no longer locks anything, anywhere, and its LED stays dark. The key is out of the Lock modifier map entirely.
- Right Alt is Compose now, not Alt. Alt bindings, including the `Super + Alt` workspace layer, need the left Alt key.

#### Displays and decades

Each panel owns one decade for good. The pairing is recorded by panel identity rather than by connector, in `~/.local/state/hypr/workspace-map-slots`, so moving a cable to another port takes the decade with it.

Unplug a display and only its own ten workspaces move, to the least loaded survivor, with ties going to the next panel clockwise. Nothing is renumbered and the other decades stay where they are, so `Caps + 3` is still workspace 13 with the same windows on it. Hyprland brings the workspaces home by itself when the panel comes back.

`Super+Ctrl+Alt` plus a digit lines every display up on that slot within its own decade, so `3` means 3, 13, 23 and 33 at once, with `0` the tenth as everywhere else. A display only borrowing a decade because its panel is unplugged is left where it is, since lining that up would put one screen in two places at once.

`Super+Alt+E` opens a picker for the same thing when the numbers are not in your head: type a slot and each display's row shows the workspace it is on and the one it would switch to, updating as you type. An empty box previews the slot already in use, which is what Enter then applies. The omarchy menu has these under Trigger, Workspaces, and `workspace-map.sh align N` does it from a shell.

Replace a panel and the one it replaced still owns that decade, so the newcomer starts with none and sits out the alignment. `workspace-map.sh claim`, or the same entry in the omarchy menu, hands it the decade it is already showing. It is not automatic on purpose: unplug a panel for an hour, plug a different one in, and doing it silently would mean the first one comes back to nothing.

Left alone it does not behave that way. Hyprland dumps the workspaces of a departing display onto whichever monitor it connected first, which has no relation to the layout, and leaves the workspace rules pointing at a connector that is no longer there. `workspace-map.sh` re-resolves the whole mapping on every hotplug event, driven by the listener in `monitor-fallback.sh`. Its `slots` command prints the current table, `plan` shows the rules it would write without applying them, and `reset` re-seeds the table from the layout in front of you.

Nothing about it is specific to this machine: the layout order is computed from live geometry (rotated panels by their on-screen footprint, mirrors and disabled outputs skipped) and it works for any number of displays. The four decades come from the four digit-row layers `bindings.conf` binds, not from the hardware, so a machine with more displays than layers leaves the extras without a decade of their own and says so. Drop a `workspace-map.conf` next to the script setting `DECADES` to change that, and bind the matching layers.

#### Backgrounds

Per-workspace wallpapers (`Super+Shift+Ctrl+Alt+B`) hand each workspace one of the theme's backgrounds. On top of that, the layout editor (`Super+Shift+F9`) decides how an image sits on the screens: per monitor or spanned across any set of them, with pan, zoom and fit mode, saved per image.

Switching the feature on is also the way back to a clean theme. It throws away every saved layout and every image added by hand, and says how many of each before it does, so there is one obvious route out of an arrangement that went wrong. Presets survive, since they are recipes rather than an arrangement.

`o` in the editor adds images from anywhere on disk to the strip along the top. Nothing is copied into the theme; the list lives in `/tmp` and is gone after a reboot. An added image can be placed and spanned like any other, but the per-workspace map knows nothing about it and would paint over it on the next workspace switch, so applying one turns the per-workspace feature off and freezes what is on the screens. The editor says so and waits for a second Enter before doing it. Frozen is not unattended: displays coming and going are still followed, so slices are recut for the new geometry and a returning display gets its image back rather than a blank wall.

`scripts/` is the main toolbox. Each script documents itself in its header comment; by category:

| Area | Scripts | What they do |
|------|---------|--------------|
| Monitors | `monitor-picker.py`, `monitor-toggle.sh`, `monitor-configure.sh`, `monitor-rotate.sh`, `monitor-fallback.sh` | Whole-layout editor on `F8` (drag, multi-select, live workspace info), enable/disable and reposition displays, DRM-based fallback when all displays disconnect |
| VPN | `vpn-lib.sh`, `vpn-status.sh`, `vpn-cycle.sh`, `vpn-node-cycle.sh`, `vpn-disconnect.sh` | Provider-agnostic suite (currently Mullvad): distance-sorted relay cycling, per-city node cycling, status for waybar |
| Workspaces | `workspace-switch.sh`, `workspace-map.sh`, `workspace-backgrounds.sh` | Toggle-back tracking, 10 workspaces per monitor for any display count with hotplug-stable decade ownership (`Super+E` cycles back to a two-display odd/even split), per-workspace wallpapers |
| Utilities | `timer-menu.sh`, `screensaver.sh`, `free-keys.sh`, `keybinds-menu.sh`, `notify-focus-*.sh`, `swayosd-focused.sh`, `theme-bg-prev.sh`, `volume-osd-watch.sh`, `kb-color-cycle.sh`, `refresh-autoset.sh` | MPRIS timers, screensaver, keybinding viewers, notification-to-window focus jumping, OSD helpers, battery-aware refresh rate |

Keybindings live in `bindings.conf`, so they are not duplicated here. At runtime `Super+K` lists all of them and `Super+Alt+K` only the custom ones, with a dot on any not yet committed to this repo. Both go through `keybinds-menu.sh`, which wraps Omarchy's own menu and fills in the modifier names Omarchy leaves as raw modmask numbers (its renderer knows only Super, Shift, Ctrl and Alt, so the whole Caps layer came out as `32 + 1`).

### CLI tools (`.local/bin`)

General-purpose commands on `PATH`, usable from any terminal and not tied to the Hyprland session (some also have keybindings):

- `zfs-manager`: dual-pane ZFS TUI (`Super+Z`)
- `sleep-inhibit`: keep-awake with natural-language durations (`Super+Ctrl+K`)
- `bw-backup-menu`, `bw-backup-cli`, `bw-backup-gui`, `bw-backup-watcher`, `bw-vault-decrypt`: per-account Bitwarden vault backups with an offline decryption viewer (`Super+Shift+/`)

Only these files are tracked; the rest of `.local/bin` stays local-only.

### Waybar (`.config/waybar/`)

Replaces several default modules with custom widgets: clock with day-of-year and weeks remaining, network with live bandwidth and VPN overlay plus incognito toggle, power draw with color scaling, battery, weather, screen temperature and brightness with fine-grained scroll steps (brightness can dim below the hardware minimum via gamma), and a configurable poll-rate menu.

### Omarchy extensions (`.config/omarchy/`)

Menu overrides (monitor tools, VPN picker, extended setup), theme hooks, and the `ethereal-extended` theme: blue/purple space theme with a colored active-workspace number and extra backgrounds.

### Shell (`.zshrc`, `.zsh/`, `.bashrc`, `.bash/`, `.config/shell/`)

- **zsh**: znap-managed plugins (auto-cloned on first run), a prompt chooser (none/p10k/starship) that persists its choice, and modular per-topic files in `.zsh/custom/` (fzf, history, editor, package managers, and so on) with an `x11/` split for X11-only bits.
- **bash**: ports of the fzf and history customizations in `.bash/custom/`, sourced after Omarchy's defaults.
- **`.config/shell/hist-merge`**: read-only merged history view across zsh, bash and fish, time-ordered and tagged by shell. The `h` command in both shells uses it; `HISTORY_MODE` and `HISTORY_SCOPE` env vars (with per-shell overrides) switch between merged/per-shell views and global/per-directory history files. It never writes to any history file.
- **`h` subcommands** (`h help` lists them): `h swap [file]` switches to a directory's history file read-only (nothing is written to any history file until `h back`; `hh` remains the switch-for-real variant), `h remove <n> ...` deletes entries by the numbers `h` shows (reaching zsh/bash/fish files in the merged view), and `h file` lists each shell's current history file with swap status (also shown at the end of `h help`); every subcommand also has a single-letter alias (`h r`, `h s`, `h b`, `h f`, `h h`).

### mpv (`.config/mpv/`)

uosc + thumbfast and other plugins, modular includes under `conf/` (including an isolated 4090 GPU profile), and extensive custom keybinds. `Ctrl+K` inside the player shows the key help.

### Firefox (`.mozilla/`)

Encrypted profile archives (see Security above), repacked as settings and userscripts change.

### Older machines

- `.config/i3/` and sxhkd: the previous Debian i3 setup, including fuzzy launcher helpers and default-program scripts.
- `.config/xfce4/`: panel and xfconf state from the same machine.
- `bin/`: bootstrap and utility scripts (`setup`, per-OS `setup-home`, nvim/tmux setup, LUKS drive setup, ZFS mirroring).
- `system/`: files that belong outside `$HOME`, currently fonts and sounds for `/usr/share`.

### macOS (malvolio)

The Mac runs AeroSpace + SketchyBar in place of a Linux WM. Files are tracked at their real `$HOME` paths, same as everywhere else; the packaged tools live under `macos/` because they install outside the repo (a root-owned helper, `~/Applications` app bundles).

- `.aerospace.toml`: tiling config. Focus is on `cmd-alt-hjkl`; plain `alt-hjkl` is deliberately left unbound so nvim keeps its move-line maps.
- `.config/sketchybar/`: transparent bar overlaying the empty center of the native menu bar (which stays visible), with AeroSpace workspace bubbles and a sudo/date/weather pill.
- `.local/bin/aerospace-cheatsheet` + `-collect`, `.config/alacritty/cheatsheet.toml`: `alt-shift-slash` fuzzy cheatsheet over every layer that can claim a key, flagging bindings shadowed by a global grabber. Opens in an always-on-top floating Alacritty popup; Alacritty is installed for this alone.
- `macos/sudo-toggle/`: password-gated switch that arms or disarms a NOPASSWD sudoers rule, with menu-bar state and a Spotlight launcher.
- `macos/restic-backup/`: home-directory backups to the restic repo on puck; the app wrapper exists so the backup inherits a terminal's Full Disk Access.

### Misc configs

`ghostty`, `btop`, `flameshot`, `autostart`, `.Xmodmap` and friends: tracked as-is, no story to tell.
