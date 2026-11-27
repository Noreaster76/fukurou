# tools

- `dvrip.py` — minimal client for the camera's native Xiongmai DVRIP protocol
  (`:34567`): log in, read (`get`) and update (`patch`) firmware config such
  as `NetWork.Wifi`, `NetWork.NetDNS`, `NetWork.NetNTP`, `NetWork.Nat`.
  Secrets in configs are redacted on output and carried over untouched by
  `patch`. Run it inside the Frigate container, which has the camera's IP and
  password in its environment:

  ```sh
  docker exec -i frigate-nest-box python3 - get NetWork.Wifi < tools/dvrip.py
  docker exec -i frigate-nest-box python3 - patch NetWork.Nat '{"NatEnable":false}' < tools/dvrip.py
  ```

  IP fields are little-endian hex, e.g. `192.0.2.20` → `0x140200C0`.
  A `Ret=603` reply means "saved; restart needed".
