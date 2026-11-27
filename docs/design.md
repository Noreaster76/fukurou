# fukurō — system design

Status: **draft for discussion** (2026-11-25; revised 2026-11-26, stack decided 2026-11-27). Nothing in the cloud half is
built yet. Decisions already made are marked ✅; open ones are collected in
[Open questions](#open-questions).

## 1. What we're building

A self-hosted replacement for the Green Backyard app for one (or a few) nest-box
cameras:

- A **Raspberry Pi at home** ingests the camera, detects birds, and records
  activity. It is the only thing that talks to the camera.
- A **small cloud app** lets invited people watch clips and stills, see a
  live view, get alerts, and share clips — without anyone (including us) ever
  needing a way *into* the home network.

Each installation is a **separate copy** ✅: one home site, one cloud app, one
set of users. Another organization deploys its own Pi + its own cloud app from
this repo. No multi-tenancy.

### Goals

- Excellent security: no component becomes a path into the home network ✅.
- Cheap: **≤ $15/month** of cloud spend ✅.
- Works on phones and desktops in any modern browser.
- Simple enough to run unattended for months.

### Non-goals (for now)

- Telling owls from starlings or other animals (deferred ✅; the stock
  detector only knows "bird").
- SMS alerts (shelved ✅ — US carrier registration makes them costly to set up).
- Multi-tenant hosting of many organizations in one app ✅.
- Two-way audio, PTZ, or changing camera settings from the cloud.

## 2. Architecture

```
 HOME NETWORK — nothing here accepts connections from the internet
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  [camera] ── isolated: no internet access                           │
│      │  DVRIP (:34567), H.264                                       │
│      ▼                                                              │
│  Raspberry Pi 5                                                     │
│   ├─ Frigate        detect birds (CPU), record activity → USB drive │
│   └─ relay          watches Frigate, pushes media out ─────────────────┐
│                                                                     │  │ outbound HTTPS only
└─────────────────────────────────────────────────────────────────────┘  │
                                                                         ▼
 CLOUD                                                   ┌──────────────────────────┐
┌──────────────────────────────────────────────┐ presign │ Cloudflare R2 (private)  │
│ Heroku: web app + Postgres                   │────────▶│  clips/  stills/  live/  │
│  • portal: browse clips, live view, share    │         └──────────────────────────┘
│  • sign-in (invite-only), admin pages        │                      ▲
│  • alerts: web push + email                  │                      │ short-lived signed URLs
│  • device API for the relay                  │                      │
└──────────────────────────────────────────────┘                      │
        ▲                                                             │
        └──────────── viewers' browsers / phones ─────────────────────┘
```

The rule that makes this safe: **the Pi only ever makes outbound HTTPS
connections.** No port forwarding, no inbound tunnel. To let the cloud tell the
Pi something immediately (e.g. "someone opened Live"), the relay keeps **one
outbound WebSocket** open to the app; the app pushes commands down it. The
connection is still originated by the Pi, so nothing on the internet can open a
connection into the home — and the relay acts only on a short allowlist of
commands.

### Components

| Component | Runs on | Job |
|---|---|---|
| Camera | nest box | Streams H.264 video over DVRIP. Isolated from the internet. |
| Frigate | Pi (Docker) | Ingests the camera via go2rtc, detects `bird` on the sub stream, records the main stream on activity to the USB drive. LAN-only UI. |
| relay | Pi (Docker) | Small Rust service. Polls Frigate's API, groups activity into visits, uploads arrival/departure clips and stills to R2 via presigned URLs, reports them to the cloud app, serves live view on demand. |
| Web app | Heroku (1 Basic dyno) | Portal, auth, admin, device API + relay WebSocket, alert sending, retention job. Rust (Axum) + SvelteKit; see §2.1. |
| Database | Heroku Postgres Essential-0 | Users, cameras, visits, media, share links, alert state. |
| Object storage | Cloudflare R2 | Clips, stills, live-view segments. Private bucket; access only via signed URLs. |
| Email | free-tier transactional email service | Invites, sign-in codes, alert emails. |

### Why these choices

- **Rust (Axum) + SvelteKit** ✅ — see §2.1.
- **R2, not Heroku, for media** — Heroku's filesystem is wiped on every restart
  and requests time out at 30 s, so video never passes through the app. R2 has
  **no download (egress) fees**, which matters for video, and 10 GB of storage
  free each month.
- **Basic dyno, not Eco** — Eco sleeps after 30 minutes idle and takes ~10 s
  to wake, and a sleeping server can't even show a spinner. Basic ($7) never
  sleeps and fits the budget.
- **Polling Frigate's API, not MQTT** — no extra broker to run. Frigate's
  MQTT can replace polling later if latency matters.
- **Postgres, not SQLite** — Heroku's filesystem is wiped on every restart
  (at least daily), so a SQLite file would be lost. SQLite would be the
  natural choice on a host with persistent disks; on Heroku, Postgres
  Essential-0 ($5) is the simplest durable option.

### 2.1 Web stack ✅ Rust + SvelteKit

| Concern | Choice |
|---|---|
| HTTP server | **Axum** (tokio) |
| Sessions | **tower-sessions**, server-side sessions in Postgres; secure, HttpOnly, SameSite cookies |
| Login state & permissions | **axum-login** (login-required / role guards) |
| Google sign-in | **openidconnect** crate (OIDC with PKCE) |
| Email sign-in codes | small in-house module (random 6–8 digit code, 10-min expiry, rate-limited) |
| Passkeys / admin MFA | **webauthn-rs** |
| Database | **sqlx** + Postgres; queries checked against the schema at compile time; sqlx migrations |
| Front end | **SvelteKit** (TypeScript) built as a static app (`adapter-static`), served by Axum from the same origin as its JSON API — so auth is plain cookies, no tokens in the browser, no CORS |
| Admin pages | **hand-written** (user list sorted by `last_active_at`, invite, deactivate, device tokens, settings) as Svelte pages over admin-only API routes |
| relay (Pi) | Rust too: one small static binary in a container |

Why hand-write the admin pages: the Rust "Django-admin-like" crates
(`axum-admin` 0.1, `adminx`, `rustango`) are young, and we need only four or five
screens — less code to review than adopting a framework that can touch
everything. Loco (Rails-like, on Axum) was considered; its built-in auth is
token-based and it has no admin, so it buys little here.

Cost of Rust vs. Django, acknowledged: we write the sign-in glue and admin
screens ourselves (a few hundred lines each) instead of configuring them.

Heroku deploy: a container image (`heroku.yml`) or a community Rust
buildpack — to be settled in phase 1.

## 3. Security model

### Trust boundaries

| If this is compromised… | …the attacker can | …but cannot |
|---|---|---|
| **Cloud app** (Heroku, DB) | See footage, users' emails; start live view; send alerts | Reach the home network. The Pi accepts no inbound connections and only executes allowlisted commands. |
| **R2 credentials** | Read/delete stored media | Reach the home network. |
| **The Pi's device token** (stolen from the Pi) | Upload junk visits/media for that camera | Read other data, act as a user or admin. Token is revocable. |
| **The Pi itself** | Everything on the LAN the Pi can reach | — this is why the Pi is hardened and runs nothing that accepts input from the internet. |
| **The camera** (old XM firmware, known-weak class of device) | Attack other LAN devices | Phone home or be reached from the internet — it has no internet access. |
| **A viewer's account** | See footage, create share links | Admin functions (role-checked), anything on the Pi. |

### Controls

**Home side**
- Pi: SSH keys only, no root login, VNC/NFS off, unattended security upgrades,
  Tailscale for remote admin ✅ (done 2026-11-23). No ports forwarded on the
  router.
- Frigate: unauthenticated UI bound to `127.0.0.1`; the authenticated UI
  (`:8971`) is LAN/Tailscale only ✅.
- Camera: on an isolated network with no internet access (Deco IoT network,
  or a Pi-hosted camera-only Wi-Fi — to be decided on site). Fixed IP via DHCP
  reservation.
- Camera power watchdog: the camera sometimes hangs until power-cycled. A
  locally controllable smart plug (no vendor cloud), at the nest-box end of
  the extension cord and weather-protected like the camera's adapter, lets the
  Pi power-cycle it automatically after ~5 minutes unreachable. The plug sits
  on the isolated camera network too.
- relay: runs unprivileged in its own container, holds only its **device
  token** — a long random secret that identifies it to the app as "the
  uploader for camera X" (like an API key; stored only hashed in the cloud,
  revocable from admin) — and nothing else. Commands from the cloud arrive
  over the relay's own outbound WebSocket and are a fixed enum (`live_start`,
  `live_stop`; later `upload_range` for "Get the full video", §5.1), with
  parameters validated and bounded (e.g. live view auto-stops after 10 minutes
  without a renewed request; `upload_range` is limited to one camera, a past
  time range, and a maximum size).

**Cloud side**
- HTTPS everywhere (Heroku ACM), HSTS, secure/HttpOnly/SameSite cookies, CSRF,
  a strict Content-Security-Policy.
- R2 bucket private. Upload URLs valid 5 minutes and scoped to one object key;
  view URLs valid ≤ 1 hour.
- Device tokens stored hashed; one per camera; rotate/revoke from admin.
- Rate limits on sign-in, sign-in-code emails, share-link views, device API.
- Admins must enroll MFA (TOTP or passkey).
- Audit log of admin actions (invites, removals, role changes, token rotation,
  public-page toggles).
- Secrets only in Heroku config vars / the Pi's `.env`; never in git.
- Dependencies pinned; Dependabot (or equivalent) on the repo.

## 4. Accounts and access

- **Invite-only** ✅. An admin enters an email and role; the person gets an
  invite email. There is no public sign-up.
- **Sign-in**: "Sign in with Google", or a **one-time code by email** for people
  without Google accounts. (Sign in with Apple needs a paid Apple Developer
  account, $99/yr — out of budget for now.) Passkeys via `webauthn-rs`
  (required as admin MFA; optional for everyone else).
- **Roles**: `admin` (manage users, cameras, public page, device tokens) and
  `viewer`. All viewers see all cameras of the installation (one camera today);
  the data model leaves room for per-camera access.
- **Admin portal** lives in the cloud app (a few admin pages), not on the Pi ✅ — so the Pi has no admin surface at all.

## 5. Key flows

### 5.1 Activity → a "visit" in the cloud ✅

Frigate detects activity on the sub stream and records the main stream for
it. The relay groups activity into **visits**: activity separated by gaps of
less than ~2 minutes is one visit (so a roosting owl that shifts occasionally
is one visit, not dozens).

For each visit the cloud receives:

| Media | What | Size (1080p) |
|---|---|---|
| **Arrival clip** | first minute of the visit, incl. **5 s pre-roll** | ≤ ~40 MB |
| **Departure clip** | last minute, incl. **10 s post-roll** (omitted if the visit is under a minute — the arrival clip already covers it) | ≤ ~40 MB |
| **Stills** | one at arrival, then one every 5 minutes | ~0.3 MB each |

Clips are **capped at 1 minute** ✅. Example — a 30-minute owl visit: 2
one-minute clips (~75 MB) + ~6 stills, shown in the portal as "Visit
9:42–10:12 pm". The Pi keeps the full recording locally (§5.6).

Later: a **"Get the full video"** button asks the Pi (via `upload_range` over
its WebSocket) to upload a bounded time range on demand.

Steps:
1. The relay polls Frigate's review API, tracking open visits.
2. At arrival + 1 min it uploads the arrival clip and first still (so alerts
   go out promptly); it adds stills while the visit lasts; when the visit
   ends it uploads the departure clip.
3. Each upload: the relay asks the app for a presigned URL, `PUT`s straight to
   R2, then reports the object to `POST /api/device/media`.
4. The app creates/updates the visit and triggers alerting (5.2) on arrival.

The relay keeps a small on-disk queue so uploads survive network outages and
restarts; uploads are idempotent (keyed by visit + media kind + timestamp).

### 5.2 Alerts ✅

- Channels: **web push** (phone/desktop notifications from the site) and
  **email**, each on/off per user.
- **Rate limit: at most one alert per user per camera per rolling 24 hours**
  (default; admin-configurable later; per-user config is post-MVP).
- One alert per **visit**, at most. It reads e.g. *"Activity at Owl Box —
  9:42 pm"* and links to that visit. Throttled visits still appear in the
  portal; the next alert says *"…and 6 more since your last alert."* (So an owl after a starling is
  never lost, just not separately announced.)
- Links carry no access secrets; opening one requires signing in.
- iPhone note: web push works on iOS only after the person adds the site to
  their home screen. The portal shows a one-time prompt explaining this.

### 5.3 Viewing

- Portal home: newest visit first (still + time span + duration), filter by
  date; tap for the visit's clips and stills. Media comes from R2 via signed
  URLs.
- Every clip and still has a **Download** button.

### 5.4 Sharing ✅

- Any signed-in user can create a **share link** for one clip or still.
- Link = `https://<app>/s/<code>`, where `<code>` is 128 random bits in
  base62 (~22 characters). No third-party shortener (it would see every link,
  and short codes are guessable).
- Expires after 7 days by default for clips and stills alike ✅ (choosable: 1 day – 30 days); revocable by its
  creator or an admin. Viewing a share link needs no account; the page shows
  the clip and a Download button, nothing else.
- On phones, a **Share** button uses the system share sheet (Web Share API),
  which can attach the actual video file to a text or email.
- An active share link counts as a pin (5.6) until it expires, so shared clips
  don't vanish from under the recipient.

### 5.5 Live view ✅ (5–10 s delay is fine)

- **On demand only.** When someone opens Live, their browser tells the app
  "I'm watching" every 30 s. The app immediately pushes `live_start` down the
  relay's WebSocket, and the relay starts cutting the go2rtc restream into 4-second HLS
  segments **by copy** (no transcoding — the camera already sends H.264),
  uploading each to R2 under `live/`. When no viewer has checked in for 2
  minutes, the relay stops.
- The app serves the HLS playlist itself, rewriting segment names into
  short-lived signed URLs; segments come straight from R2.
- Startup takes ~8–12 s (the first couple of segments must exist before
  playback). The page shows a spinner meanwhile. If the relay's WebSocket is
  down, the page says the camera is offline.
- Why on demand: streaming 24/7 would use ~650k R2 write operations a month
  (most of the 1M free) and keep the Pi and the camera's crash-prone firmware
  busy for nobody.

### 5.6 Storage budget and pinning ✅

- **Cloud**: a fixed budget (default **10 GB**, R2's free allowance; admin-
  configurable). A nightly job deletes the **oldest unpinned** clips/stills
  until usage is under budget. At ~19 MB per 30 s of 1080p, 10 GB holds roughly
  500 half-minute clips.
- **Pinning**: any signed-in user (viewer or admin) can pin a clip or still
  ✅; pinned items never get evicted. Pinned items count toward the budget;
  if pins alone exceed it, the app warns admins rather than deleting.
- **Pi**: keeps its own local history on the USB drive, capped **by size, not
  days** ✅: a **100 GB ext4 partition** on the Seagate drive (≈ 45 hours of
  1080p activity at ~37 MB/min). Frigate itself retains by days, but deletes
  the oldest recordings when its disk runs low, so a dedicated partition sized
  to the cap gives oldest-first eviction. The drive's existing Mac (HFS+)
  partition — 297 GB used of 466 GB — is kept: it gets shrunk to ~366 GB on a
  Mac (Linux can't resize HFS+), then the Pi formats the freed space.
- Live segments in R2 are deleted after 1 hour (R2 lifecycle rule).

### 5.7 Public live page (later)

- Per-camera switch, **off by default**, admin-only, audit-logged.
- `https://<app>/live/<camera-slug>`: live view only — no clips, no history,
  no sharing. Same on-demand HLS pipeline; viewer check-ins rate-limited per IP.
- Cost risk: a popular page means many R2 reads (10M/month free ≈ 11,000
  viewer-hours at 4 s segments) and keeps the stream running continuously.
  The page can be capped (e.g. max concurrent viewers) if needed.

## 6. Data model (sketch)

Conventions: foreign keys are `<table>_id`; state is a nullable timestamp
rather than a boolean where "when" is useful (`deactivated_at` instead of
`is_active`, `revoked_at`, `pinned_at`, `*_enabled_at`). The admin user list
sorts by `last_active_at`.

```
user(id, email, name, role[admin|viewer], created_at, last_active_at, deactivated_at)
alert_pref(user_id, camera_id, push_enabled_at, email_enabled_at, last_alert_at, pending_count)
push_subscription(id, user_id, endpoint, keys, created_at)
camera(id, name, slug, public_live_enabled_at, timezone)
device_token(id, camera_id, token_hash, created_at, revoked_at, last_seen_at)
visit(id, camera_id, started_at, ended_at, label, alerted_at)
media(id, visit_id, kind[arrival_clip|departure_clip|still], object_key, bytes,
      captured_at, pinned_by_user_id, pinned_at)
share_link(code UNIQUE, media_id, created_by_user_id,
           created_at, expires_at, revoked_at, view_count)
live_session(camera_id, requested_until, started_at)  -- drives live_start/stop
audit_log(id, actor_user_id, action, target, details, created_at)
setting(key, value)                                    -- storage budget, alert window
```

## 7. Cost (monthly)

| Item | Cost |
|---|---|
| Heroku Basic dyno | $7.00 |
| Heroku Postgres Essential-0 | $5.00 |
| Cloudflare R2 — ≤ 10 GB stored, under free operation limits | $0.00 |
| (each GB over 10) | +$0.015 |
| Transactional email, free tier | $0.00 |
| Custom domain | none for now ✅ (`*.herokuapp.com` has HTTPS) |
| **Total** | **≈ $12** (budget $15 ✅) |

Prices as published by Heroku and Cloudflare in Nov 2026; re-check before
launch.

## 8. Repository layout (proposed)

```
pi/          docker-compose.yml, config/ (Frigate), relay/ (Rust crate)
cloud/       Rust (Axum) crate, web/ (SvelteKit app), app.json (Heroku "Deploy" button)
docs/        design.md (this), setup-pi.md, setup-cloud.md, security.md
```

The current top-level Frigate files move into `pi/`. `app.json` lets another
organization deploy its own copy of the cloud app with one click; `setup-*.md`
walks them through the Pi.

## 9. Phases

0. **Home setup** (needs site access). Done: camera streams over DVRIP;
   Pi on Ethernet with a 5 A supply (fan already fitted). To do: shrink the
   Seagate's Mac partition and add the 100 GB recordings partition; Frigate →
   activity-only recording with motion tuned for lighting changes; DHCP
   reservations; isolate the camera from the internet; smart-plug power
   watchdog.
1. **Cloud skeleton**: web app on Heroku, Postgres, invite-only sign-in
   (Google + email code), admin MFA, security headers. No video yet.
2. **Clips**: relay + device API + R2; portal lists clips and stills;
   downloads; storage budget + pinning.
3. **Alerts**: web push + email, 24 h rolling cap, per-user on/off.
4. **Sharing**: share links, expiry/revocation, Web Share API.
5. **Live view**: on-demand HLS.
6. **Public live page** and packaging for other organizations (`app.json`,
   setup guides).

Phases 1 and (most of) 2 can be built and tested with no access to the home
hardware: the relay can be developed against recorded sample clips.
Rust work adds to phase 1 (sign-in glue) and phase 2 (admin screens).

## Open questions

1. **Detection**: how well a COCO-trained `bird` detector sees an owl from
   directly above, in IR at night, is unknown — likely poorly. Plan: start
   with tuned motion-based recording (the box interior is static, so most
   motion is an animal), collect real footage, then decide on detection or a
   custom-trained model.
2. **Smart plug model** for the power watchdog: must be weather-protectable
   at the nest-box end and controllable locally without a vendor cloud.
3. **Heroku deploy method** for the Rust app: container vs. buildpack.

### Decided

- 2026-11-26: no custom domain; any user may pin; 5 s pre-roll / 10 s
  post-roll; 1-minute clip cap; Pi storage capped by size; stills share links
  default 7 days; `*_id` foreign keys and timestamps-over-booleans in the
  schema; Pi-initiated WebSocket for cloud→Pi commands; Postgres.
- 2026-11-27: Rust (Axum, axum-login, openidconnect, webauthn-rs, sqlx) +
  SvelteKit static front end; hand-written admin screens; visits with arrival
  and departure clips plus periodic stills; 100 GB recordings partition on the
  Seagate drive alongside its existing Mac partition; smart-plug power
  watchdog.
