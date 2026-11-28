#!/usr/bin/env bash
# fukurou camera watchdog. Run every minute by fukurou-camera-watchdog.timer.
#
# The camera's firmware sometimes hangs until its power is cut. If the camera
# hasn't answered on its DVRIP port for DOWN_AFTER seconds, power-cycle it via
# its Shelly smart plug: "off, then back on after 10 s". The "back on" timer
# runs on the plug itself (toggle_after), so the camera gets power back even if
# this Pi loses contact mid-cycle. After a cycle, the next one waits longer
# (15, 30, 60 ... up to 240 min) until the camera answers again.
set -euo pipefail

# shellcheck source=/dev/null
. /etc/fukurou/watchdog.env   # CAMERA_IP, PLUG_IP, PLUG_PASSWORD
STATE_DIR=/var/lib/fukurou
STATE="$STATE_DIR/watchdog.state"
DOWN_AFTER=${DOWN_AFTER:-300}
BASE_BACKOFF=${BASE_BACKOFF:-900}
MAX_BACKOFF=${MAX_BACKOFF:-14400}

mkdir -p "$STATE_DIR"
now=$(date +%s)
last_ok=$now; last_cycle=0; cycles=0
# shellcheck source=/dev/null
[ -r "$STATE" ] && . "$STATE"

save() { printf 'last_ok=%s\nlast_cycle=%s\ncycles=%s\n' "$last_ok" "$last_cycle" "$cycles" > "$STATE"; }

if timeout 3 bash -c "</dev/tcp/$CAMERA_IP/34567" 2>/dev/null; then
  if [ "$cycles" -gt 0 ]; then
    echo "camera answering again after $cycles power cycle(s)"
  fi
  last_ok=$now; cycles=0; save; exit 0
fi

down_for=$(( now - last_ok ))
backoff=$(( BASE_BACKOFF << (cycles > 4 ? 4 : cycles) ))
[ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
since_cycle=$(( now - last_cycle ))

if [ "$down_for" -lt "$DOWN_AFTER" ] || { [ "$cycles" -gt 0 ] && [ "$since_cycle" -lt "$backoff" ]; }; then
  save; exit 0
fi

if out=$(curl -s -m 10 --digest -u "admin:$PLUG_PASSWORD" \
      "http://$PLUG_IP/rpc/Switch.Set?id=0&on=false&toggle_after=10"); then
  cycles=$(( cycles + 1 )); last_cycle=$now; save
  echo "camera unreachable for ${down_for}s: power-cycled via plug (cycle #$cycles; reply: $out)"
else
  save
  echo "camera unreachable for ${down_for}s, but the plug at $PLUG_IP didn't answer" >&2
  exit 1
fi
