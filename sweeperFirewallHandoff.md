# Handoff: Firewall Assessment & `myosSweeper` Port-Status Integration

> **Target**: `myosSweeper` chat session
> **Status**: Assessment + Handoff spec only (live `ufw` is currently `default deny incoming`, `41641/udp` Tailscale only; `postfix` disabled).

---

## 1. Commander's Intent

- **Firewall Policy**: Allow normal web browsing & upload/download, Steam, Discord (`vesktop`), Roblox Linux alt, Minecraft, and **ROS 2 development**, without exposing unnecessary incoming attack surfaces.
- **Sweeper Integration**: Show the **status of open ports** (and firewall posture) in `myosSweeper` alerts.

---

## 2. Firewall (`ufw`) Assessment by Workload

Because `ufw` is stateful (`default allow outgoing` + `established/related` return traffic permitted):

- **Web Browse & Upload/Download (HTTP/HTTPS/QUIC/DNS)**:
  - **0 incoming rules needed.** Handled 100% by `default allow outgoing`.
- **Discord (`vesktop`), Steam Client, Roblox Linux Alt**:
  - **0 incoming rules needed** for standard client play & voice (STUN/TURN/WebRTC).
  - *(Optional)* If using Steam Local Network Game Transfers / Remote Play on LAN: scope strictly to RFC1918 LAN (`27031:27036/udp`, `27036/tcp`).
- **Minecraft**:
  - Playing on remote servers: **0 incoming rules needed.**
  - Hosting a local/LAN server: allow `25565/tcp` (and `4445/udp` for LAN discovery) **scoped to LAN or `tailscale0` only** (`ufw allow in on tailscale0 to any port 25565 proto tcp`).
- **ROS 2 Development (DDS — FastDDS / CycloneDDS)**:
  - **Single-machine (`lo`)**: **0 incoming rules needed** (`ufw` permits loopback).
  - **Multi-machine (Robot / Desktop over LAN or Tailscale)**: `default deny incoming` **will block incoming DDS discovery (`239.255.0.1` multicast) and dynamic UDP ports (`7400–7500+`)**.
  - *Recommended fix when doing multi-host ROS 2*:
    - Over Tailscale (unicast peers): `sudo ufw allow in on tailscale0`
    - Over local Wi-Fi/LAN robot subnet: scope strictly to the robot subnet (e.g. `sudo ufw allow from 192.168.0.0/16 proto udp` + `igmp` if multicast is required), never `0.0.0.0/0`.

---

## 3. Handoff Tasks for `sweeper` Session

1. **Sync `ALLOWED_EXTERNAL_PORTS` in `sweeper/sweeper.conf`**:
   - Current default is `"22,5353,41641"`. Verify against actual `ufw` + `sshd` posture (e.g. if `22` is closed/blocked or Tailscale-only, update `ALLOWED_EXTERNAL_PORTS` accordingly, and account for ROS 2/MC ports if scoped rules are added).
2. **Include Open-Port Status in Sweeper Alerts (`collectDelta.py` / `escalateAndAlert.py`)**:
   - Currently `escalateAndAlert.py` prints `Ports: ...` only when `newExternalPorts` triggers.
   - Extend the alert/heartbeat payload to report:
     - Active listening sockets (`0.0.0.0` / `::` external listeners vs `127.0.0.1` local-only);
     - `ufw` state (`active` vs `inactive`) so any firewall drop triggers an immediate `swaync` alert.
   - Keep `collectDelta.py` unprivileged (read-only `ss -tuln` + `systemctl is-active ufw`).
