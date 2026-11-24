# Handoff — continuing this project in a new session

Paste the essentials of this file (or just point the new session at it) to pick
up the project on another machine. If you resumed the copied Claude Code session
you already have this context — this file is the standalone fallback.

**First actions for a fresh session:** read `README.md`, `config/config.yml`, and
`docker-compose.yml` in this directory, then help continue from "Where I left
off" below.

## Project

Replace the awful stock **"Green Backyard"** app for my backyard **owl nest-box
camera** with a self-hosted, open-source **Frigate** NVR.

## The camera (reverse-engineered on my home network)

- Rebranded **Xiongmai ("XM") Sofia firmware**; its RTSP server identifies as
  `H264DVR`. Sold under the brand "Green Backyard."
- Gets its IP from DHCP; its single NIC has been seen holding two leases at
  once (same physical camera). **On a new network the IP will differ**: scan
  the LAN for a device with ports `554` (rtsp) + `34567` open, with RTSP
  reporting `H264DVR`, then set `FRIGATE_OWL_BOX_HOST` in `.env`.
- Ports: RTSP `554`, ONVIF `8899`, XM "DVRIP" `34567`, HTTP `80`.
- Auth: RTSP digest, user `admin`, password set in the Green Backyard app.
- Main stream: 1920×1080 **H.264**, 8 fps, PCM A-law audio.
  Sub stream: 800×448 H.264, 20 fps. (Switched from H.265 via ONVIF on
  2026-11-23; one encoder setting covers both streams.)
- RTSP URL shape (password URL-encoded, e.g. `$`→`%24`, `!`→`%21`):

  ```
  rtsp://admin:<pw>@<ip>:554/user=admin&password=&channel=1&stream=0.sdp?real_stream
  ```

  `stream=0` = main, `stream=1` = sub.

## What's already built (in this repo, committed)

- Frigate via `docker compose`: go2rtc restream → Frigate recording. Object
  detection is wired to the sub stream but **disabled** for now.
- Camera IP and password injected via the `FRIGATE_OWL_BOX_HOST` and
  `FRIGATE_OWL_BOX_PASSWORD` env vars (Frigate's `{FRIGATE_*}` substitution),
  kept out of git in `.env`.

## Recreate the secret first

`.env` is gitignored, so it did **not** travel with the code. Create a `.env`
next to `docker-compose.yml`:

```
FRIGATE_OWL_BOX_HOST=<camera IP on this LAN>
FRIGATE_OWL_BOX_PASSWORD=<camera admin password, URL-encoded>
```

See `.env.example` for the format. (The value is in my password manager.)

## Hard-won gotchas

1. **go2rtc sources need `#backchannel=0`.** Without it this XM firmware drops
   the RTSP session every few minutes (`error=EOF` → restream `404` → ffmpeg
   crash-loop). This took real debugging; don't remove it.
2. **The camera shipped sending H.265** (Safari-only playback). It was switched
   to H.264 on the camera via ONVIF Media2 `SetVideoEncoderConfiguration`. A
   factory reset or the Green Backyard app could switch it back — re-check.
3. **The camera reboots itself** every few minutes to hours (all ports close,
   ping keeps answering, clock loses the downtime). Power is 120 V AC over a
   100–200 ft extension cord; Wi-Fi is via a repeater ~50–60 ft away. An
   overnight test with nothing connected to it is logging to
   `~/camwatch/camwatch.log` on the Pi.

## Where I left off / what's next

- Validated only as a **trial on a Mac laptop** (Docker Desktop). A laptop
  sleeps/moves, and macOS Docker has no GPU access, so it's not the permanent
  home.
- **Next goal:** design and build the **permanent deployment on a Raspberry
  Pi 5** (+ USB SSD for recordings, optional USB Coral TPU for detection). One
  camera is a light load — especially detecting on the sub stream and recording
  the main stream by copy.
- **Design decisions so far:**
  - **Recording:** motion/event-only, not continuous.
  - **Detection:** start on the Pi's CPU, detecting **birds** (not raw motion —
    the stock app's light-change false positives are the main annoyance). Add a
    Coral or other accelerator later and iterate. Telling owls from starlings
    (and other animals) is deferred.
  - **Retention:** a fixed storage budget (N GB), oldest-first eviction, with the
    ability to pin clips/stills so they are never deleted.
  - **Persist `/config`** (the trial keeps Frigate's DB ephemeral).
  - **DHCP reservation** for the camera.
  - **Browser playback:** solved at the source (camera now sends H.264).
  - **Pi:** Raspberry Pi 5, 16 GB RAM, Raspberry Pi OS (Debian 13). Hardened:
    SSH keys-only, VNC/rpcbind off, unattended security upgrades, OpenClaw
    removed, Tailscale installed (`fukurou-pi`). Next: wired Ethernet and a
    USB drive or NVMe SSD for recordings.

## To get running on the new machine

1. Install Docker.
2. Create `.env` (above).
3. Confirm/adjust the camera IP in `.env` (it may differ on this network).
4. `docker compose up -d`, then open <http://localhost:5000>.
5. Then let's design the Raspberry Pi deployment.
