# myOs Disaster Recovery Runbook (Offline / TTY-Safe)

Concise emergency recovery procedures for `myOs` (`Ubuntu Server 26.04 LTS Minimal`, `LVM /` + non-LVM `/boot`, JavaCard SmartPGP + password fallback). Written in plain ASCII for emergency TTY use.

---

## 1. LVM Root Snapshot Operations & Emergency Rollback

`myOs` reserves ~35 GiB free space in `ubuntu-vg` for LVM CoW snapshots of `/dev/ubuntu-vg/ubuntu-lv` (`/`).
- **`myos-pre-*`**: Created automatically by `myos-update` before `apt upgrade` (`8G`, auto-pruned to newest 2).
- **`myos-baseline-*`**: Manually pinned baseline snapshots (protected from `myos-update` auto-prune).

> **Important LVM CoW Warning**: Classic LVM snapshots grow as blocks on `/` change. Check `Data%` periodically with `sudo lvs ubuntu-vg`. If `Data%` reaches `100%`, the snapshot becomes **Invalid** (`I` in 5th attr char) and cannot be merged. Extend or refresh baselines before they fill.

### Everyday Snapshot Commands
```sh
# 1. Inspect all LVs, snapshots, CoW usage (Data%), and VG free space
sudo vgs ubuntu-vg
sudo lvs -o lv_name,lv_size,lv_attr,data_percent,origin,lv_time ubuntu-vg

# 2. Create a manual protected baseline snapshot (won't be pruned by myos-update)
sudo lvcreate --snapshot --name "myos-baseline-$(date +%Y%m%d)" --size 8G /dev/ubuntu-vg/ubuntu-lv

# 3. Extend a snapshot if Data% approaches 80%
sudo lvextend -L +4G /dev/ubuntu-vg/<snap-name>

# 4. Delete an old or invalid snapshot to reclaim VG space
sudo lvremove -f /dev/ubuntu-vg/<snap-name>
```

### Emergency Rollback (From Running System or Recovery TTY)
```sh
sudo lvs ubuntu-vg
sudo lvconvert --merge /dev/ubuntu-vg/<snap-name>
sudo reboot
```

- `lvconvert --merge` schedules the merge; it executes during root mount on the **next boot** (not in-place on a mounted `/`).
- **`/boot` is outside LVM (`nvme0n1p2`, ext4)**: merging `/` restores `/lib/modules` and packages, NOT `/boot`. Because `myos-update` skips `apt autoremove`, prior kernels remain in `/boot`. If a kernel/initramfs upgrade broke boot, hold `Shift` or tap `Esc` at boot -> **Advanced options for Ubuntu** -> select the **previous kernel**.
- Note: Merging **consumes** the snapshot. After confirming the system is healthy, create a new baseline snapshot if desired.

### Emergency Rollback (If System Cannot Boot — Live USB)
Boot any Ubuntu Live USB, open a terminal:
```sh
sudo vgchange -ay ubuntu-vg
sudo lvs ubuntu-vg
sudo lvconvert --merge /dev/ubuntu-vg/<snap-name>
sudo reboot
```

---

## 2. JavaCard Unavailable / Lost (Auth & Secrets Fallback)

### `sudo` Password Fallback
`/etc/pam.d/sudo` uses `auth sufficient pam_ssh_agent_auth.so` before `@include common-auth`.
- Unplugging the JavaCard falls back to the local Linux user password automatically.
- Force password fallback check without unplugging:
  ```sh
  SSH_AUTH_SOCK="" sudo -k true
  ```

### `.env.gpg` Offline Key Decryption
`envlock` encrypts `.env.gpg` to **two** recipients (`~/.config/myos/gpg-recipients`: JavaCard key + offline fallback key).
- Import your offline backup private key on a trusted machine or TTY (`gpg --import <offline-key.asc>`), then run `envview` / `envrun` normally.
- Never write decrypted `.env` to NVMe; if temporary plaintext is unavoidable, use `/dev/shm` and destroy with `shred -u`.

---

## 3. Sway / Waybar / Login Loop Recovery (TTY)

Switch to VT2 (`Ctrl+Alt+F2`), log in as `raybeak`:

```sh
# 1. Validate Sway config & Waybar JSON
sway -C -c ~/.config/sway/config
python3 -m json.tool ~/.config/waybar/config >/dev/null

# 2. Check POSIX /bin/sh syntax on login scripts (prevents tuigreet login loop)
sh -n ~/.profile

# 3. Temporarily remove myos-bin symlinks if a toolbox script misbehaves
stow -D -d ~/myOs/dotfiles -t ~ myos-bin

# 4. Inspect recent greetd / sway errors
journalctl -b -u greetd.service --no-pager | tail -n 40
```

---

## 4. Broken `sudoers.d` Recovery

If a broken `/etc/sudoers.d/*` file locks out `sudo`:

1. Reboot -> GRUB menu -> press `e` on the Ubuntu entry -> append `systemd.unit=rescue.target` (or `init=/bin/sh`) to the `linux` line -> `Ctrl+X`.
2. Remount `/` read-write if needed: `mount -o remount,rw /`.
3. Identify and remove the offending drop-in:
   ```sh
   visudo -c
   rm -f /etc/sudoers.d/<broken-file>
   visudo -c
   ```
4. Reboot normally.
