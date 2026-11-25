# fukurō — system design

Status: **draft for discussion** (2026-11-25). Nothing in the cloud half is
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
│ Heroku: web app (Django) + Postgres          │────────▶│  clips/  stills/  live/  │
│  • portal: browse clips, live view, share    │         └──────────────────────────┘
│  • sign-in (invite-only), admin pages        │                      ▲
│  • alerts: web push + email                  │                      │ short-lived signed URLs
│  • device API for the relay                  │                      │
└──────────────────────────────────────────────┘                      │
        ▲                                                             │
        └──────────── viewers' browsers / phones ─────────────────────┘
```

The rule that makes this safe: **the Pi only ever makes outbound HTTPS
requests.** No port forwarding, no inbound tunnel. If the cloud needs the Pi to
do something (start the live view, say), the Pi learns it by polling the cloud
and only acts on a short allowlist of commands.

### Components

| Component | Runs on | Job |
|---|---|---|
| Camera | nest box | Streams H.264 video over DVRIP. Isolated from the internet. |
| Frigate | Pi (Docker) | Ingests the camera via go2rtc, detects `bird` on the sub stream, records the main stream on activity to the USB drive. LAN-only UI. |
| relay | Pi (Docker) | Small Python service. Polls Frigate's API for finished activity, uploads clip + still to R2 via presigned URLs, reports the event to the cloud app, serves live view on demand. |
| Web app | Heroku (1 Basic dyno) | Django: portal, auth, admin, device API, alert sending, retention job. |
| Database | Heroku Postgres Essential-0 | Users, cameras, events, share links, alert state. |
| Object storage | Cloudflare R2 | Clips, stills, live-view segments. Private bucket; access only via signed URLs. |
| Email | free-tier transactional email service | Invites, sign-in codes, alert emails. |

### Why these choices

- **Django** — built-in admin pages (adding/removing users is nearly free), a
  mature auth/security track record, and `django-allauth` for Google sign-in,
  email sign-in codes, and MFA/passkeys. Python also matches Frigate and the
  relay.
- **R2, not Heroku, for media** — Heroku's filesystem is wiped on every restart
  and requests time out at 30 s, so video never passes through the app. R2 has
  **no download (egress) fees**, which matters for video, and 10 GB of storage
  free each month.
- **Basic dyno, not Eco** — Eco sleeps after 30 minutes idle and takes ~10 s
  to wake, and a sleeping server can't even show a spinner. Basic ($7) never
  sleeps and fits the budget.
- **Polling Frigate's API, not MQTT** — no extra broker to run. Frigate's
  MQTT can replace polling later if latency matters.

## 3. Security model

### Trust boundaries

| If this is compromised… | …the attacker can | …but cannot |
|---|---|---|
| **Cloud app** (Heroku, DB) | See footage, users' emails; start live view; send alerts | Reach the home network. The Pi accepts no inbound connections and only executes allowlisted commands. |
| **R2 credentials** | Read/delete stored media | Reach the home network. |
| **The Pi's device token** (stolen from the Pi) | Upload junk events/media for that camera | Read other data, act as a user or admin. Token is revocable. |
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
- relay: runs unprivileged in its own container, holds only the device token
  and nothing else; commands from the cloud are a fixed enum
  (`live_start`, `live_stop`), with parameters validated and bounded (e.g.
  live view auto-stops after 10 minutes without a renewed request).

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
  account, $99/yr — out of budget for now.) Passkeys can be added later via
  `django-allauth`.
- **Roles**: `admin` (manage users, cameras, public page, device tokens) and
  `viewer`. All viewers see all cameras of the installation (one camera today);
  the data model leaves room for per-camera access.
- **Admin portal** lives in the cloud app (Django admin + a few custom
  pages), not on the Pi ✅ — so the Pi has no admin surface at all.

## 5. Key flows

### 5.1 Activity → clip in the cloud

1. Frigate detects a `bird` in the sub stream and records the main stream for
   the activity (with a few seconds of pre/post-roll).
2. The relay polls Frigate's review API; when an activity item **ends**, it
   fetches the clip (MP4, H.264 — plays in every browser) and a snapshot.
3. The relay asks the app for presigned upload URLs, `PUT`s clip and still
   straight to R2, then calls `POST /api/device/events` with metadata (camera,
   start/end, label, score, sizes, object keys).
4. The app stores the event and triggers alerting (5.2).

The relay keeps a small on-disk queue so uploads survive network outages and
restarts; events are idempotent by Frigate's ID.

### 5.2 Alerts ✅

- Channels: **web push** (phone/desktop notifications from the site) and
  **email**, each on/off per user.
- **Rate limit: at most one alert per user per camera per rolling 24 hours**
  (default; admin-configurable later; per-user config is post-MVP).
- An alert reads e.g. *"Bird activity at Owl Box — 9:42 pm"* and links to
  that clip. Throttled events still appear in the portal; the next alert says
  *"…and 6 more since your last alert."* (So an owl after a starling is
  never lost, just not separately announced.)
- Links carry no access secrets; opening one requires signing in.
- iPhone note: web push works on iOS only after the person adds the site to
  their home screen. The portal shows a one-time prompt explaining this.

### 5.3 Viewing

- Portal home: newest activity first (still + time + duration), filter by
  date; tap for the clip. Clips and stills come from R2 via signed URLs.
- Every clip and still has a **Download** button.

### 5.4 Sharing ✅

- Any signed-in user can create a **share link** for one clip or still.
- Link = `https://<app>/s/<code>`, where `<code>` is 128 random bits in
  base62 (~22 characters). No third-party shortener (it would see every link,
  and short codes are guessable).
- Expires after 7 days by default (choosable: 1 day – 30 days); revocable by its
  creator or an admin. Viewing a share link needs no account; the page shows
  the clip and a Download button, nothing else.
- On phones, a **Share** button uses the system share sheet (Web Share API),
  which can attach the actual video file to a text or email.
- An active share link counts as a pin (5.6) until it expires, so shared clips
  don't vanish from under the recipient.

### 5.5 Live view ✅ (5–10 s delay is fine)

- **On demand only.** When someone opens Live, their browser tells the app
  "I'm watching" every 30 s. The relay sees a pending `live_start` on its next
  poll (≤ 5 s), and starts cutting the go2rtc restream into 4-second HLS
  segments **by copy** (no transcoding — the camera already sends H.264),
  uploading each to R2 under `live/`. When no viewer has checked in for 2
  minutes, the relay stops.
- The app serves the HLS playlist itself, rewriting segment names into
  short-lived signed URLs; segments come straight from R2.
- Startup takes ~10–15 s (poll + first segments). Acceptable per the 5–10 s
  delay tolerance; the page shows a spinner meanwhile.
- Why on demand: streaming 24/7 would use ~650k R2 write operations a month
  (most of the 1M free) and keep the Pi and the camera's crash-prone firmware
  busy for nobody.

### 5.6 Storage budget and pinning ✅

- **Cloud**: a fixed budget (default **10 GB**, R2's free allowance; admin-
  configurable). A nightly job deletes the **oldest unpinned** clips/stills
  until usage is under budget. At ~19 MB per 30 s of 1080p, 10 GB holds roughly
  500 half-minute clips.
- **Pinning**: any admin (viewers too? — see open questions) can pin a clip or
  still; pinned items never get evicted. Pinned items count toward the budget;
  if pins alone exceed it, the app warns admins rather than deleting.
- **Pi**: keeps its own longer local history on the USB drive (Frigate's
  time-based retention, e.g. 30 days of activity recordings), independent of the
  cloud. Live segments in R2 are deleted after 1 hour (R2 lifecycle rule).

### 5.7 Public live page (later)

- Per-camera switch, **off by default**, admin-only, audit-logged.
- `https://<app>/live/<camera-slug>`: live view only — no clips, no history,
  no sharing. Same on-demand HLS pipeline; viewer check-ins rate-limited per IP.
- Cost risk: a popular page means many R2 reads (10M/month free ≈ 11,000
  viewer-hours at 4 s segments) and keeps the stream running continuously.
  The page can be capped (e.g. max concurrent viewers) if needed.

## 6. Data model (sketch)

```
User(id, email, name, role[admin|viewer], is_active, created_at)
  └─ AlertPrefs(user, camera, push_enabled, email_enabled, last_alert_at, pending_count)
  └─ PushSubscription(user, endpoint, keys, created_at)
Camera(id, name, slug, public_live_enabled, timezone)
  └─ DeviceToken(camera, token_hash, created_at, revoked_at, last_seen_at)
Event(id, camera, frigate_id UNIQUE, label, score, started_at, ended_at,
      clip_key, still_key, clip_bytes, still_bytes, pinned_by, pinned_at)
ShareLink(code UNIQUE, event, kind[clip|still], created_by, expires_at, revoked_at, view_count)
LiveSession(camera, requested_until, started_at)   -- drives live_start/stop
AuditLog(actor, action, target, details, at)
Setting(key, value)                                 -- storage budget, alert window
```

## 7. Cost (monthly)

| Item | Cost |
|---|---|
| Heroku Basic dyno | $7.00 |
| Heroku Postgres Essential-0 | $5.00 |
| Cloudflare R2 — ≤ 10 GB stored, under free operation limits | $0.00 |
| (each GB over 10) | +$0.015 |
| Transactional email, free tier | $0.00 |
| Custom domain (optional; `*.herokuapp.com` works with HTTPS) | ~$1 |
| **Total** | **≈ $12–13** (budget $15 ✅) |

Prices as published by Heroku and Cloudflare in Nov 2026; re-check before
launch.

## 8. Repository layout (proposed)

```
pi/          docker-compose.yml, config/ (Frigate), relay/ (Python service)
cloud/       Django project, Procfile, app.json (Heroku "Deploy" button)
docs/        design.md (this), setup-pi.md, setup-cloud.md, security.md
```

The current top-level Frigate files move into `pi/`. `app.json` lets another
organization deploy its own copy of the cloud app with one click; `setup-*.md`
walks them through the Pi.

## 9. Phases

0. **Home setup** (needs site access): 27 W power supply, Ethernet, USB drive,
   active cooler; Frigate → activity-only recording + CPU bird detection; DHCP
   reservations; isolate the camera from the internet. *(Camera now streams
   over DVRIP — done.)*
1. **Cloud skeleton**: Django app on Heroku, Postgres, invite-only sign-in
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

## Open questions

1. **Domain**: use `<name>.herokuapp.com`, or buy a domain (~$12/yr)? A real
   domain makes share links nicer and email deliverability better.
2. **Who may pin?** Admins only, or any viewer?
3. **Clip shape**: how much pre/post-roll (e.g. 5 s before, 10 s after)? Cap
   clip length (e.g. 2 minutes) so one long visit doesn't eat the budget?
4. **Pi local retention**: how many days of activity recordings to keep on
   the USB drive?
5. **Share links for stills**: same 7-day default as clips?
6. **Stack**: OK with Django/Python for the cloud app? (Recommended; see §2.)
