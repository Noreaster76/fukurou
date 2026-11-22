# fukurō — nest-box camera → Frigate

*fukurō is Japanese for "owl."*

Self-hosted, open-source viewing and recording for a **"Green Backyard"**
nest-box camera (an owl box), replacing the stock Green Backyard app.

The camera is a rebranded **Xiongmai ("XM") Sofia-firmware** device. It exposes
standard local protocols, so [Frigate](https://docs.frigate.video/) can ingest
it directly — no cloud/app dependency.

## Camera facts

| | |
|---|---|
| IP | `<camera-ip>` (see DHCP note below) |
| Protocols | RTSP `:554`, ONVIF `:8899`, XM "DVRIP" `:34567`, HTTP `:80` |
| Auth | RTSP digest, user `admin`, password set via the Green Backyard app |
| Main stream | 1920×1080, **HEVC/H.265**, 25 fps, PCM A-law audio |
| Sub stream | 800×448, HEVC |

**RTSP URL shape** (password URL-encoded):

```
rtsp://admin:<pw>@<camera-ip>:554/user=admin&password=&channel=1&stream=0.sdp?real_stream
```

`stream=0` is the main feed, `stream=1` the sub feed.

### Two gotchas, both handled in config

- **Backchannel / EOF churn.** go2rtc's two-way-audio negotiation makes this
  firmware drop the RTSP session every few minutes. `#backchannel=0` on each
  go2rtc source fixes it. (Diagnosed from `error=EOF` → restream `404` →
  ffmpeg watchdog restarts.)
- **HEVC in the browser.** Recordings are H.265. On a Mac, **use Safari** for
  smooth recording playback; Chrome/Firefox can stutter. Live view falls back
  to Frigate's low-res player because browsers can't play H.265 live directly.
  A future H.264 transcode (via go2rtc) would make playback universal.

### DHCP note

The camera's single NIC currently holds **two** DHCP
leases. Add a **DHCP reservation** on the TP-Link Deco so it
stays on one fixed IP, then this config never needs an IP edit.

## Running (local trial on macOS + Docker Desktop)

> ⚠️ This is a **trial** deployment on a laptop. A laptop sleeps/moves, and on
> macOS Docker has no GPU access, so H.265 is decoded on CPU (fine for one
> camera on this M4, not the long-term home). Intended permanent host: a
> Raspberry Pi 5 — see below.

```sh
cp .env.example .env        # then put the real URL-encoded password in .env
docker compose up -d
```

- UI: <http://localhost:5000> (unauthenticated, local). Authenticated UI is on
  `:8971`.
- Stop: `docker compose down`
- Logs: `docker logs -f frigate-nest-box`

Recordings land in `./storage` (gitignored). Retention is **1 day** continuous
(~6 GB/day at 1080p); adjust `record` in `config.yml`.

## Configuration notes

- **Secret handling:** the password is injected from `FRIGATE_OWL_BOX_PASSWORD`
  (in gitignored `.env`) via Frigate's `{FRIGATE_*}` substitution. Nothing
  secret is committed.
- **Detection is off** (`detect.enabled: false`) — the trial proves live view +
  recording first. The detect role is already wired to the sub stream, so
  enabling object detection is a one-line change.
- Image is pinned to `frigate:0.18.3` (the version this was validated on).

## Planned permanent deployment (not built yet)

Target: **Raspberry Pi 5 + USB SSD + (optional) USB Coral TPU**. One camera is a
light load, especially detecting on the sub stream and recording the main stream
by copy. Open design questions to settle first:

- Continuous vs. motion/event-only recording, and retention length.
- Object detection (bird/owl) — worth a Coral, or skip detection?
- Add an H.264 transcode for universal browser playback?
- DHCP reservation for the camera.
- Persist `/config` (this trial keeps Frigate's DB ephemeral).

## Future work

- Pull **stored clips and stills** off the camera over the XM DVRIP protocol
  (`:34567`), outside the Green Backyard app — a separate effort.

## License

[MIT](LICENSE) © 2026 Gabe Heafitz
