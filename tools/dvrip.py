"""Minimal Xiongmai DVRIP (Sofia, :34567) client: log in and read or write config.

Usage (inside the Frigate container, which has the env vars):
  python3 - get <ConfigName> [<ConfigName> ...]  < dvrip.py
  python3 - set <ConfigName> '<json value>'       < dvrip.py
Reads FRIGATE_OWL_BOX_HOST / FRIGATE_OWL_BOX_PASSWORD (URL-encoded) from env.
"""
import hashlib, json, os, socket, struct, sys, urllib.parse

HOST = os.environ["FRIGATE_OWL_BOX_HOST"]
PASSWORD = urllib.parse.unquote(os.environ["FRIGATE_OWL_BOX_PASSWORD"])
LOGIN, CONFIG_SET, CONFIG_GET = 1000, 1040, 1042


def sofia_hash(pw):
    d = hashlib.md5(pw.encode()).digest()
    chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    return "".join(chars[(d[2 * i] + d[2 * i + 1]) % 62] for i in range(8))


class DVRIP:
    def __init__(self, host):
        self.s = socket.create_connection((host, 34567), timeout=10)
        self.session, self.seq = 0, 0

    def call(self, msg, body):
        data = json.dumps(body).encode() + b"\x0a\x00"
        hdr = struct.pack("<BB2xIIBBHI", 0xFF, 0, self.session, self.seq, 0, 0, msg, len(data))
        self.s.sendall(hdr + data)
        self.seq += 1
        head = self._recv(20)
        _, _, _, _, _, _, rmsg, length = struct.unpack("<BB2xIIBBHI", head)
        payload = self._recv(length).rstrip(b"\x00\x0a")
        return rmsg, json.loads(payload) if payload else {}

    def _recv(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.s.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("connection closed")
            buf += chunk
        return buf

    def login(self):
        _, r = self.call(LOGIN, {"EncryptType": "MD5", "LoginType": "DVRIP-Web",
                                 "PassWord": sofia_hash(PASSWORD), "UserName": "admin"})
        if r.get("Ret") not in (100, 515):
            raise SystemExit(f"login failed: Ret={r.get('Ret')}")
        self.session = int(r["SessionID"], 16)

    def sid(self):
        return "0x%08X" % self.session


def redact(obj):
    """Hide Wi-Fi keys/passwords in printed output."""
    if isinstance(obj, dict):
        return {k: ("***" if any(w in k.lower() for w in ("keys", "password", "passwd", "psk")) else redact(v))
                for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact(v) for v in obj]
    return obj


cam = DVRIP(HOST)
cam.login()
if sys.argv[1] == "get":
    for name in sys.argv[2:]:
        _, r = cam.call(CONFIG_GET, {"Name": name, "SessionID": cam.sid()})
        print(f"== {name} (Ret={r.get('Ret')})")
        print(json.dumps(redact(r.get(name, r)), indent=1))
elif sys.argv[1] == "set":
    name, value = sys.argv[2], json.loads(sys.argv[3])
    _, r = cam.call(CONFIG_SET, {"Name": name, name: value, "SessionID": cam.sid()})
    print(f"set {name}: Ret={r.get('Ret')}")
elif sys.argv[1] == "patch":
    # Read the config, deep-merge the given fields, write it back. Secrets in
    # the config (e.g. the Wi-Fi key) are carried over untouched, never printed.
    name, changes = sys.argv[2], json.loads(sys.argv[3])
    _, r = cam.call(CONFIG_GET, {"Name": name, "SessionID": cam.sid()})
    current = r[name]

    def merge(dst, src):
        for k, v in src.items():
            if k not in dst:
                raise SystemExit(f"refusing to add unknown field {k!r} to {name}")
            if isinstance(v, dict):
                merge(dst[k], v)
            else:
                dst[k] = v

    merge(current, changes)
    _, r = cam.call(CONFIG_SET, {"Name": name, name: current, "SessionID": cam.sid()})
    print(f"patch {name}: Ret={r.get('Ret')}")
