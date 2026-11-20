# myOs CLI Toolbox (`myos-*`) Guide

Operational reference for the modular desktop/system utilities stowed from `dotfiles/myos-bin/.local/bin/` into `~/.local/bin/` (via `stow --no-folding` in `bootstrap.sh`).

All utilities adhere to `myOs` invariants: no new packages beyond `packagesV2.txt` (reuses `wofi`, `foot`, `grim`, `slurp`, `wl-copy`, `wlsunset`, `swayidle`, `brave-browser`), plain ASCII text-only UI, and explicit input/safety validation.

### Environment Overrides

- `MYOS_SCREENSHOT_DIR`: Override screenshot output dir (default: `~/photo/screenshots`).
- `MYOS_NIGHTLIGHT_TEMP`: Color temperature in Kelvin, integer `1000..9999` (default: `3750`).
- `MYOS_WEBAPP_BROWSER`: Browser executable name/path validated against `^[A-Za-z0-9._/-]+$` (default: `brave-browser`).
- `MYOS_VG_NAME` / `MYOS_ROOT_LV`: LVM VG and root LV names (default: `ubuntu-vg` / `ubuntu-lv`).
- `MYOS_BACKLIGHT_DEV` / `MYOS_BACKLIGHT_MIN_PCT`: Backlight sysfs device (default: `intel_backlight`) and minimum brightness floor percent `1..50` (default: `2`).

### Uninstall / Rollback of Toolbox

- Remove symlinks cleanly: `stow -D -d ~/myOs/dotfiles -t ~ myos-bin`
- Reclaim LVM snapshots after verifying an upgrade: `myos-update --prune` (or `sudo lvremove -f /dev/ubuntu-vg/myos-pre-<ts>`).

---

## 1. `myos-menu` — Unified Action Center

- **Path**: `dotfiles/myos-bin/.local/bin/myos-menu`
- **Keybinding**: `$mod+Alt+space` (in `dotfiles/sway/.config/sway/config`)
- **Usage**:
  - `myos-menu` — Opens the main `wofi --dmenu` action center showing live `Idle Lock [ON|OFF]` and `Nightlight [ON|OFF]` status, screenshot actions, TUI Apps submenu, Web Apps submenu, Security & System submenu (`myos-update`, `myosSweeper status`, `usbguard list-devices`, `swaymsg reload`), Keybindings cheatsheet, and Power submenu (`~/.config/sway/scripts/power.sh`).
  - `myos-menu --keybindings` — Directly opens a searchable list of all `bindsym` entries parsed from `~/.config/sway/config`.
- **Dependencies**: `wofi`, `awk`, sibling `myos-*` scripts.
- **Verification**: `bash -n ~/.local/bin/myos-menu && sway -C`

---

## 2. `myos-screenshot` — Screenshot + Clipboard Pipeline

- **Path**: `dotfiles/myos-bin/.local/bin/myos-screenshot`
- **Keybindings**:
  - `Print` -> `myos-screenshot region`
  - `Shift+Print` -> `myos-screenshot full`
- **Usage**: `myos-screenshot [region|full]`
- **Behavior**:
  - Creates `~/photo/screenshots/` automatically (overridable via `MYOS_SCREENSHOT_DIR`).
  - Captures PNG atomically via `mktemp` + `grim` (and `slurp` for `region`), saves `shot-YYYYMMDD-HHMMSS-mmm.png` (with PID fallback on collision), copies image data to the Wayland clipboard via `wl-copy --type image/png`, and sends a desktop notification via `notify-send`.
  - Cancelling `slurp` (Esc / right-click) exits `0` cleanly without writing an empty file.
- **Dependencies**: `grim`, `slurp`, `wl-copy`, `notify-send` (optional).
- **Verification**: `myos-screenshot region` -> verify new file in `~/photo/screenshots/` and `wl-paste --list-types | grep image/png`.

---

## 3. `myos-toggle-idle` — Auto-Lock / DPMS Caffeine Toggle

- **Path**: `dotfiles/myos-bin/.local/bin/myos-toggle-idle`
- **Usage**: `myos-toggle-idle [toggle|on|off|status]`
- **Behavior**:
  - `off`: Stops `swayidle` and creates runtime marker `${XDG_RUNTIME_DIR:-/run/user/$UID}/myos-idle-off` (caffeine mode).
  - `on`: Removes marker and restarts `swayidle` with the standard `myOs` lock/DPMS timeouts (300s lock, 600s output power off, lock before sleep).
  - `status`: Prints `ON` or `OFF`.
- **Safety Note**: Manual screen lock (`$mod+Shift+x`) remains active independently of `swayidle`. Because the marker lives in `XDG_RUNTIME_DIR` (`tmpfs`), caffeine state resets automatically on logout/reboot. `start_idle()` clean-restarts `swayidle` (`pkill` before `nohup`) to avoid duplicate instances. `myos-menu` surfaces `[OFF]` so caffeine state is visible.
- **Verification**: `myos-toggle-idle status`

---

## 4. `myos-toggle-nightlight` — Color Temperature Toggle

- **Path**: `dotfiles/myos-bin/.local/bin/myos-toggle-nightlight`
- **Keybinding**: `Fn+F9` (`XF86Launch5`, keycode `192`) -> `myos-toggle-nightlight toggle`
- **Usage**: `myos-toggle-nightlight [toggle|on|off|status]`
- **Behavior**:
  - Starts or stops `wlsunset` immediately at `MYOS_NIGHTLIGHT_TEMP` (default `3750`K, using `-t 3750 -T 3751` so no geolocation is required).
  - `status`: Prints `ON` or `OFF`.
- **Dependencies**: `wlsunset`.
- **Verification**: `myos-toggle-nightlight status`

---

## 5. `myos-launch-tui` — Standardized Floating TUI Wrapper

- **Path**: `dotfiles/myos-bin/.local/bin/myos-launch-tui`
- **Usage**: `myos-launch-tui [--hold] <command> [args...]`
- **Behavior**:
  - Launches `<command>` inside `foot --app-id=myos-tui --title="TUI: <cmd>"`.
  - Matched by `for_window [app_id="myos-tui"] floating enable, resize set 960 640, move position center` in `dotfiles/sway/.config/sway/config`.
  - `--hold` keeps the window open after command exit (`[exit N - press Enter to close]`), used for one-shot commands like `myosSweeper status`, `usbguard list-devices`, and `myos-update`.
  - Exits `127` with a notification if `<command>` is missing from `$PATH`.
- **Verification**: `myos-launch-tui btop`

---

## 6. `myos-webapp` — Frameless Brave Web App Manager

- **Path**: `dotfiles/myos-bin/.local/bin/myos-webapp`
- **Usage**:
  - `myos-webapp add <name> <url>` — Creates `~/.local/share/applications/myos-webapp-<name>.desktop` launching `brave-browser --app=<url>` (reuses Brave process pool; zero Electron RAM overhead).
  - `myos-webapp remove <name>` — Removes the `.desktop` entry.
  - `myos-webapp list` — Prints `<name>\t<url>` for registered web apps.
  - `myos-webapp launch <name|url>` — Launches a registered web app or direct URL immediately.
- **Security Controls**:
  - `<name>` restricted to `^[A-Za-z0-9_-]{1,40}$`.
  - `<url>` restricted to `^https?://[]A-Za-z0-9._~:/?#@!()+%=&[-]+$` (escapes `%` -> `%%` per Desktop Entry `Exec=` specification when writing `.desktop` files).
- **Verification**: `myos-webapp add test https://example.com && myos-webapp list && myos-webapp remove test`

---

## 7. `myos-update` — LVM Pre-Upgrade Snapshot Guard

- **Path**: `dotfiles/myos-bin/.local/bin/myos-update`
- **Usage**: `myos-update [--dry-run] [--list] [--prune] [--size 8G] [--keep 2]`
- **Behavior**:
  1. Acquires an exclusive `flock` lock (`$XDG_RUNTIME_DIR/myos-update.lock`, refusing symlinks; read-only `--list` is intentionally unlocked) to serialize mutating runs.
  2. Validates `--size` (`G`/`M`) and verifies `ubuntu-vg` free space (in `MiB` via `vgs --units m`) is $\ge \text{size} + 2\text{ GiB}$ **before** mutating or pruning any snapshots.
  3. Creates an `8G` LVM CoW snapshot of `/dev/ubuntu-vg/ubuntu-lv` named `myos-pre-YYYYMMDD-HHMMSS` and installs an `ERR` trap so failed upgrades still print the rollback command.
  4. Prunes oldest `myos-pre-*` snapshots (sorted by `lv_time`, explicitly protecting the newly created snapshot) beyond `--keep` (default `2`) **only after** the new snapshot succeeds.
  5. Runs `sudo apt-get update && sudo apt-get upgrade -y` (**without** `apt autoremove`).
  6. Verifies post-upgrade snapshot health (`lv_attr` Invalid check and numeric `snap_percent`/`data_percent` $< 100\%$) before printing rollback instructions.
- **Rollback Procedure (Partial Rollback — `/` Only)**:
  1. `sudo lvconvert --merge /dev/ubuntu-vg/myos-pre-<timestamp>` (schedules merge; does **not** apply in-place on a mounted `/`).
  2. `sudo reboot` (merge executes on next boot during root mount).
  3. **Limitation (`/boot` outside LVM)**: `/boot` resides on `nvme0n1p2` (non-LVM ext4) and is not rolled back by LVM merge. Because `myos-update` skips `apt autoremove`, prior kernel images remain in `/boot`; select the previous kernel in GRUB if a kernel/initramfs upgrade occurred.
- **Verification**: `myos-update --dry-run` (and `myos-update --list` to inspect snapshots).

---

## 8. `myos-brightness` — Logind Seat-Scoped Backlight Control

- **Path**: `dotfiles/myos-bin/.local/bin/myos-brightness`
- **Keybindings**: `XF86MonBrightnessUp` (`Fn+F3`) -> `myos-brightness up 5`; `XF86MonBrightnessDown` (`Fn+F2`) -> `myos-brightness down 5`
- **Usage**: `myos-brightness [up [pct]|down [pct]|set <pct>|get]`
- **Behavior**:
  - Reads current/max brightness from `/sys/class/backlight/${MYOS_BACKLIGHT_DEV}` and writes via `busctl call org.freedesktop.login1 /org/freedesktop/login1/session/auto org.freedesktop.login1.Session SetBrightness` (falling back to the user's active seated `loginctl` session).
  - Avoids adding the user to the `video` group (keeps `/dev/video*` unexposed) while working around Ubuntu's `brightnessctl` lacking `libsystemd` support.
  - Enforces a configurable minimum brightness floor (`MYOS_BACKLIGHT_MIN_PCT`, default `2%`) to prevent accidental `0%` screen blackout.
- **Verification**: `myos-brightness get && myos-brightness down 5 && myos-brightness up 5`

---

## 9. `myos-toggle-touchpad` — Touchpad Toggle + LED Sync

- **Path**: `dotfiles/myos-bin/.local/bin/myos-toggle-touchpad`
- **Keybinding**: `Fn+F5` (`XF86TouchpadToggle`, keycode `199`) -> `myos-toggle-touchpad toggle`
- **Usage**: `myos-toggle-touchpad [toggle|on|off|status]`
- **Behavior**:
  - `toggle` / `on` / `off`: Toggles (or explicitly enables/disables) touchpad input events via Sway.
  - Keeps the hardware touchpad LED in sync with the input state via the `logind` `tpad_led` LED subsystem (zero-root D-Bus path, same model as `myos-brightness`; no `sudo`, no `input` group membership).
  - `status`: Prints `ON` or `OFF`.
- **Verification**: `myos-toggle-touchpad status` (and press `Fn+F5` to confirm input state and `tpad_led` LED flip together)

---

## 10. `myos-display` — Sway-Native Output Switcher

- **Path**: `dotfiles/myos-bin/.local/bin/myos-display`
- **Keybinding**: `Fn+F7` (hardware emits `Super_L`+`p`, bound as `$mod+p`) -> `myos-display`
- **Usage**: `myos-display`
- **Behavior**:
  - Enumerates connected outputs via Sway-native `get_outputs` (`swaymsg -t get_outputs`; no external display-management dependency).
  - Presents the output switcher menu via `wofi --dmenu` and applies the selected output action.
  - Zero extra dependencies: reuses the existing toolbox stack (`swaymsg`, `wofi`); no new packages beyond `packagesV2.txt`.
- **Verification**: `myos-display` with an external monitor connected -> confirm the `wofi` menu lists outputs and the selected action applies

---

## 11. `myos-toggle-charge` — Battery Care (80%) / Full Charge (100%) Toggle

- **Path**: `dotfiles/myos-bin/.local/bin/myos-toggle-charge`
- **Keybinding**: `Fn+F1` (`XF86Launch6`, keycode `193`) -> `myos-toggle-charge toggle`
- **Usage**: `myos-toggle-charge [toggle|full|care|status]`
- **Behavior**:
  - Toggles between Battery Care at 80% and Full Charge at 100%; `care`, `full`, and `status` select or query each mode directly.
  - LG gram 16ZD90P (`lg_laptop` + TLP 1.8.0) EC accepts only `80` or `100` at `/sys/class/power_supply/CMB0/charge_control_end_threshold`; `85` is rejected with `-EINVAL`.
  - Baseline `/etc/tlp.d/90-gram.conf` sets `STOP_CHARGE_THRESH_BAT0="80"`. `tlp setcharge 0 100` is a temporary override (works on both AC and battery) and auto-reverts to 80% on reboot.
- **Security model**:
  - Root-owned `/usr/local/sbin/myos-battery-ctl` (installed `0755 root:root`) accepts only `care` (`tlp setcharge`) or `full` (`tlp setcharge 0 100`) or `status`.
  - `etc/sudoers.d/myos-battery` (`0440 root:root`) uses a strict sudoers allowlist for only `care` and `full`, with no wildcards.
- **Verification**: `visudo -cf /etc/sudoers.d/myos-battery`; run `myos-toggle-charge status`, then `myos-toggle-charge care` / `full` and confirm the hardware threshold is `80` / `100` respectively.
