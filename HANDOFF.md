# Handoff — continuing this project in a new session

Paste the essentials of this file (or just point the new session at it) to pick
up the project on another machine. If you resumed the copied Claude Code session
you already have this context — this file is the standalone fallback.

**First actions for a fresh session:** read `README.md`, `config.yml`, and
`docker-compose.yml` in this directory, then help continue from "Where I left
off" below.

## Project

Replace the awful stock **"Green Backyard"** app for my backyard **owl nest-box
camera** with a self-hosted, open-source **Frigate** NVR.

## The camera (reverse-engineered on my home network)

- Rebranded **Xiongmai ("XM") Sofia firmware**; its RTSP server identifies as
  `H264DVR`. Sold under the brand "Green Backyard."
- Was at `<camera-ip>`. Its single NIC had also
  grabbed a second DHCP lease — same physical camera. **On a new
  network the IP will differ**: scan the LAN for a device with ports `554`
  (rtsp) + `34567` open, with RTSP reporting `H264DVR`, then update the IP in
  `config.yml`.
- Ports: RTSP `554`, ONVIF `8899`, XM "DVRIP" `34567`, HTTP `80`.
- Auth: RTSP digest, user `admin`, password set in the Green Backyard app.
- Main stream: 1920×1080 **HEVC/H.265**, 25 fps, PCM A-law audio.
  Sub stream: 800×448 HEVC.
- RTSP URL shape (password URL-encoded, e.g. `$`→`%24`, `!`→`%21`):

  ```
  rtsp://admin:<pw>@<ip>:554/user=admin&password=&channel=1&stream=0.sdp?real_stream
  ```

  `stream=0` = main, `stream=1` = sub.

## What's already built (in this repo, committed)

- Frigate via `docker compose`: go2rtc restream → Frigate recording. Object
  detection is wired to the sub stream but **disabled** for now.
- Camera password injected via the `FRIGATE_OWL_BOX_PASSWORD` env var (Frigate's
  `{FRIGATE_*}` substitution), kept out of git in `.env`.

## Recreate the secret first

`.env` is gitignored, so it did **not** travel with the code. Create a `.env`
next to `docker-compose.yml`:

```
FRIGATE_OWL_BOX_PASSWORD=<camera admin password, URL-encoded>
```

See `.env.example` for the format. (The value is in my password manager.)

## Two hard-won gotchas (already baked into `config.yml` — keep them)

1. **go2rtc sources need `#backchannel=0`.** Without it this XM firmware drops
   the RTSP session every few minutes (`error=EOF` → restream `404` → ffmpeg
   crash-loop). This took real debugging; don't remove it.
2. **Streams are H.265.** Recordings play smoothly in **Safari** on macOS but
   stutter in Chrome/Firefox; browser live view falls back to Frigate's low-res
   player. A future H.264 transcode (via go2rtc) would make playback universal.

## Where I left off / what's next

- Validated only as a **trial on a Mac laptop** (Docker Desktop). A laptop
  sleeps/moves, and macOS Docker has no GPU access, so it's not the permanent
  home.
- **Next goal:** design and build the **permanent deployment on a Raspberry
  Pi 5** (+ USB SSD for recordings, optional USB Coral TPU for detection). One
  camera is a light load — especially detecting on the sub stream and recording
  the main stream by copy.
- **Open design questions:** continuous vs. motion/event recording and
  retention length; whether to run bird/owl object detection (Coral vs. CPU);
  adding an H.264 transcode for universal browser playback; persisting Frigate's
  `/config` (the trial kept its DB ephemeral); a DHCP reservation so the camera
  keeps one fixed IP.

## To get running on the new machine

1. Install Docker.
2. Create `.env` (above).
3. Confirm/adjust the camera IP in `config.yml` (it may differ on this network).
4. `docker compose up -d`, then open <http://localhost:5000>.
5. Then let's design the Raspberry Pi deployment.
