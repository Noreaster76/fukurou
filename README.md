# 🦉 fukurō — nest-box camera → Frigate

*fukurō is Japanese for "owl."*

Self-hosted, open-source viewing and recording for a **"Green Backyard"**
nest-box camera (an owl box), replacing the stock Green Backyard app.

The camera is a rebranded **Xiongmai ("XM") Sofia-firmware** device. It exposes
standard local protocols, so [Frigate](https://docs.frigate.video/) can ingest
it directly — no cloud/app dependency.

## Camera facts

| | |
|---|---|
| IP | Assigned by DHCP; set `FRIGATE_OWL_BOX_HOST` in `.env` (see DHCP note below) |
| Protocols | RTSP `:554`, ONVIF `:8899`, XM "DVRIP" `:34567`, HTTP `:80` |
| Auth | RTSP digest, user `admin`, password set via the Green Backyard app |
| Main stream | 1920×1080, **H.264**, 8 fps, PCM A-law audio |
| Sub stream | 800×448, H.264, 20 fps |
| Hardware | Goke GK7205V200 SoC, firmware `V5.00.R02.263739N7.10010.140d17` |

**RTSP URL shape** (password URL-encoded):

```
rtsp://admin:<pw>@<camera-ip>:554/user=admin&password=&channel=1&stream=0.sdp?real_stream
```

`stream=0` is the main feed, `stream=1` the sub feed.

### Gotchas

- **Use DVRIP, not RTSP.** The camera's RTSP server crashes its main process
  under load: with both streams over RTSP it went down every 4–10 minutes.
  Over the native XM DVRIP protocol (`dvrip://…:34567`, which go2rtc speaks
  natively) it ran for hours between crashes in testing. Each crash costs
  ~2 minutes (ports close, ping keeps answering) and Frigate reconnects on its
  own. If RTSP is ever needed again, keep `#backchannel=0` on the go2rtc
  source — without it this firmware drops the RTSP session every few minutes.
- **Codec: switched to H.264 on the camera itself.** It shipped sending H.265,
  which only Safari plays smoothly. The camera's ONVIF Media2 service offers
  H.264 too, so on 2026-11-23 the encoder was switched via
  `SetVideoEncoderConfiguration` (one setting applies to both streams) — no
  transcoding needed, and recordings play in any browser. If the camera is ever
  factory-reset or reconfigured by the Green Backyard app, re-check this.
- **The camera may not rejoin Wi-Fi on its own** after its access point
  restarts (seen once: offline until power-cycled).

### DHCP note

The camera's single NIC has been seen holding **two** DHCP leases at once. Add
a **DHCP reservation** on the TP-Link Deco so it stays on one fixed IP, then
`.env` never needs an IP edit.

## Keeping the camera off the internet

The camera is cheap Xiongmai firmware that phones home (XMeye cloud,
`secu100.net`), so it is cut off from the internet without any router
features:

- **On the camera** (set over DVRIP with `tools/dvrip.py`): default gateway,
  DNS and NTP all point at the Pi, and the XMeye cloud connection
  (`NetWork.Nat`) is disabled.
- **On the Pi** (`sudo host/install.sh`): nftables drops everything the camera
  sends off the LAN, logging a sample (`journalctl -k | grep
  fukurou-camera-egress`); ICMP redirects are off so the camera is never told
  to bypass the Pi; chrony serves time to the camera only.
- **The ping trick:** when the camera's "am I online?" pings (to
  114.114.114.114, 8.8.8.8, 180.76.76.76) fail, the firmware stops answering
  on the LAN until power-cycled. The Pi therefore answers those pings itself.

Consequence: the Green Backyard app can no longer reach the camera from
outside the home. To undo, point the camera's gateway back at the router and
re-enable `NetWork.Nat` with `tools/dvrip.py patch`.

## Running (local trial on macOS + Docker Desktop)

> ⚠️ This is a **trial** deployment on a laptop. A laptop sleeps/moves, and on
> macOS Docker has no GPU access, so video is decoded on CPU (fine for one
> camera on this M4, not the long-term home). Intended permanent host: a
> Raspberry Pi 5 — see below.

```sh
cp .env.example .env        # then set the camera IP and URL-encoded password
docker compose up -d
```

- UI: <http://localhost:5000> — unauthenticated, bound to localhost only.
  From other devices use the authenticated UI on `https://<host>:8971`; the
  first-start admin password is printed in `docker logs frigate-nest-box`.
- Stop: `docker compose down`
- Logs: `docker logs -f frigate-nest-box`

Recordings land in `./storage` (gitignored) unless `FRIGATE_MEDIA_DIR` says
otherwise. Frigate records **only on motion/objects**, and retention is
limited by disk size rather than days: on the Pi, recordings get a dedicated
100 GB partition and Frigate deletes the oldest when it runs low.

## Configuration notes

- **Secret handling:** the camera IP and password are injected from
  `FRIGATE_OWL_BOX_HOST` and `FRIGATE_OWL_BOX_PASSWORD` (in gitignored `.env`)
  via Frigate's `{FRIGATE_*}` substitution. Neither is committed.
- **Detection is off** (`detect.enabled: false`) — the trial proves live view +
  recording first. The detect role is already wired to the sub stream, so
  enabling object detection is a one-line change.
- Image is pinned to `frigate:0.18.3` (the version this was validated on).

## Planned permanent deployment (not built yet)

Target: **Raspberry Pi 5 + USB SSD + (optional) USB Coral TPU**. One camera is a
light load, especially detecting on the sub stream and recording the main stream
by copy. Decisions so far:

- **Recording:** motion/event-only, not continuous.
- **Detection:** start on the Pi's CPU, detecting **birds** (not raw motion —
  the stock app's light-change false positives are the main annoyance). Add a
  Coral or other accelerator later and iterate. Telling owls from starlings
  (and other animals) is deferred.
- **Retention:** a fixed storage budget (N GB), oldest-first eviction, with the
  ability to pin clips/stills so they are never deleted.
- **Persist `/config`:** done — `./config` is mounted writable.
- **DHCP reservation** for the camera.
- **Browser playback:** solved at the source (camera now sends H.264).
- **Pi:** Raspberry Pi 5, 16 GB RAM, Raspberry Pi OS (Debian 13); recordings
  on a USB drive or NVMe SSD rather than the SD card; wired Ethernet.

## Future work

- Pull **stored clips and stills** off the camera over the XM DVRIP protocol
  (`:34567`), outside the Green Backyard app — a separate effort.

## License

[MIT](LICENSE) © 2026 Gabe Heafitz
