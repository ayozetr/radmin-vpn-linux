# Radmin VPN on Linux — "service never ready" investigation

Notes for the `fix/never-ready` branch.

## TL;DR (verified conclusion)

Radmin VPN **works on this machine** — proven by running the same AppImage inside an
isolated **network namespace** (same kernel 7.1.3, same bundled Wine, NAT'd internet):
it reaches `ready`, the GUI shows "En línea", a network was created and a peer joined
with a working chat. The "never ready" hang is therefore **NOT** a Wine / kernel /
driver / Radmin bug — it is a **conflict with the host's network environment**. The
exact host-side cause is not yet pinned (see "Ruled out" and "Not yet tested").

## Environment

- Host: CachyOS, kernel `7.1.3-1-cachyos` x86_64, KDE/Wayland.
- Wrapper `baptisterajaut/radmin-vpn-linux`, reproduced on `v0.3.4` and `v1.0.0-rc3/rc4`.
- Radmin VPN `2.0.4899.9`; bundled Wine 11.11 (v0.3.4) / 11.12 (rc4), Staging.
- `ufw` active (default `allow (outgoing)`, `deny (routed)`); public IP is routable (not CGNAT).

## Symptom

Service logs `opened → enabled → Registered as #… 26.x`, then polls the driver
(`IOCTL STATUS/FILTER`) and never logs `Virtual network adapter ready`; `run.sh`
times out after ~33–63 s. Identical on v0.3.4 and rc3/rc4.

## ★ Root finding: it's the host network environment

- **In an isolated netns (with NAT'd internet): WORKS fully.** A clean pcap (no host
  noise) shows the service resolve `proxy.radminte.com` / `fail.radminte.com` and
  connect over TCP **:17301** to OVH IPs (57.128.187.188 / 148.113.190.78 /
  198.244.203.247), exchanging data → `ready` → online → network created, peer joined.
- **On the host: hangs**, with the same kernel, Wine, AppImage, and (after tests) even
  the same minimal interface set. So the differentiator is the host network stack.

## Ruled OUT on the host (each tested; host still hangs)

- **Extra interfaces** — brought down and then *deleted* (docker0, br-*, vmnet1/8,
  tailscale0), reducing the host to `enp10s0 + radminvpn0` like the netns.
- **DNS resolver** — forced `1.1.1.1`/`8.8.8.8` instead of systemd-resolved `127.0.0.53`.
- **ufw** — fully disabled.
- **Prefix state** — fresh install on the host (fresh online registration, new RID
  each time). Removes the confound that netns runs always used a fresh prefix:
  fresh+host still fails, fresh+netns works ⇒ it's the environment, not the prefix.
- **Routing** — `ip route get` to the proxy IPs is correct (via `enp10s0`, right source).
- **Tailscale routing** — its policy rules only match Tailscale's own fwmark'd traffic;
  the proxy IPs aren't in `100.64/10`.

## NOT yet tested (top remaining suspect)

- **`net.ipv4.conf.*.rp_filter`** — the host is `1` (strict); a fresh netns defaults to
  `0`. With the `26.0.0.0/8` on-link route plus several interfaces, strict RPF is a
  plausible cause. Test script: `radmin-rpfilter-test.sh`.
- Other candidates: residual netfilter chains left by docker/libvirt/tailscale that
  `ufw disable` doesn't flush; or a CachyOS net sysctl (the netns gets kernel defaults).

## Working solution today

Run Radmin inside the netns: `radmin-netns-test.sh` (in the debug folder). Fully functional.

## How Radmin's connection works (radare2 static analysis, corroborated by the netns pcap)

`RvControlSvc.exe` is a 32-bit PE, image base `0x400000`.

- `Virtual network adapter ready` (`.rdata` VA `0x501bcc`) is logged by the message
  dispatcher `fcn.00443220` — a jump-table switch on the message type at `[esi+0x34]`.
  It is the **`CDeviceReady`** case (a branch separate from `Registered`, which ends
  `ret 8` at `0x443529`). So `ready` is emitted only when a `CDeviceReady` message is
  dispatched.
- `CDeviceReady` is posted by `fcn.00402f30` (inlined `CAbstractQueueableMessage`
  template + enqueue), reached downstream of a successful ROS connection.
- The session/relay uses **WinINet HTTP** (not raw winsock — `WS2_32` only imports
  `socket`/`closesocket`): `fcn.004c5260` (`InternetOpenW → InternetConnectW →
  HttpOpenRequestW → HttpSendRequestW`) ← `fcn.004c50e0` (builds the POST) ←
  `fcn.004c1ad0` ← a **`CConnector` thread** (`TSimpleThread<CConnector>`,
  `ROLClient_Connect`). This matches the netns pcap (WinINet to `:17301`).
- In the netns this chain completes and posts `CDeviceReady` → `ready`; on the host it
  does not complete → no `ready`. i.e. the host network cause stops the connector's ROS
  session from completing.

### Function map (IDA addr = base 0x400000)

| Addr | What it is |
|---|---|
| `fcn.00443220` | state logger/dispatcher — switch on msg type `[esi+0x34]`; logs opened/enabled/`Registered`(0x443502)/`ready`(0x44352f) |
| `CControlSvc…virtual_4` @ `0x4407ce` | calls the setup-adapter task |
| `fcn.004435c0` | CSetupAdapter task run — calls setup `fcn.00461b60`; then a boolean-gated post-setup sequence |
| `fcn.00461b60` | adapter setup; its `Failed to setup virtual adapter …` path is **not** hit (setup succeeds) |
| `fcn.00402f30` | posts `CDeviceReady` (inlined queueable-message template) |
| `fcn.004c5260` | ROS relay: `InternetOpenW→InternetConnectW→HttpOpenRequestW→HttpSendRequestW` |
| `fcn.004c50e0` ← `fcn.004c1ad0` ← `(nofunc) 0x4bf60c` | POST builder ← ROS comm ← `CConnector` thread |

## rc4 packaging bugs found (reported in #16)

- **Missing `lib.sh`**: the rc4 AppImage's `run.sh` does `source "$DIR/lib.sh"` under
  `set -euo pipefail`, but `lib.sh` isn't bundled in `usr/bin/` → it dies immediately.
  (`lib.sh` *is* in the repo at the `v1.0.0-rc4` tag — a `build-appimage.sh` packaging
  miss.) Worked around by `--appimage-extract` + dropping in the repo's `lib.sh`.
- **`lib.sh` "Outbound connections" grep**: `ss -tanp | grep -iE 'wine|radmin'` won't
  match the service process name `RvControlSvc.exe`, so that diagnostics section is
  always empty.

## Instrumentation notes & corrected assumptions

- Built from source (mingw-w64 16.1; full `make`, incl. the `rvpnnetmp.sys` driver).
  Added ws2_32 `connect`/`WSAConnect` IAT tracing + adapter `OperStatus` logging to
  `adapter_hook.c` (commit on branch).
- **CORRECTION — do not trust these earlier readings:**
  - An early `strace -f -e trace=network` on the launcher showed "no external I/O", but
    that was an **artifact**: the launcher hands off to a `wineserver`-parented service,
    so `strace -f` never followed `RvControlSvc.exe` (0 followed PIDs). The netns pcap
    proves the app *does* perform the full WinINet/`:17301` flow when it works.
  - Host-side `/proc`, `ss` and filtered pcaps did not catch a proxy connection **on the
    host** during the hang, but those were noisy/gap-prone. The reliable signal is the
    host-vs-netns comparison, not "no sockets seen".
  - "Registration is cached / no network" was **wrong**: fresh prefixes get new
    server-assigned RIDs, so registration reaches Famatech online.
- The adapter shows `OperStatus=UP` with no IPv4 on the Linux TAP during the hang —
  this is **not** the cause: `run.sh` only assigns the `26.x` IP to the TAP *after*
  `ready` (line ~392), and the netns works under the same timing.
- Early eliminations (all still valid, but moot given the root cause is the host env):
  not the NDIS-poisoning bug #12 (clean prefix + `drvinst` stub + `RvNetMP60` scrub);
  not the rc fork's bridge (v0.3.4 fails the same); `--no-broadcast-routes` no change;
  the `GetINetwork` stub is an anti-crash guard, not a connectivity check.

## Build / iterate (this branch)

- Rebuild just the hook:
  ```
  i686-w64-mingw32-gcc -Wall -O2 -shared -o build/adapter_hook.dll \
      src/adapter_hook.c -liphlpapi -lws2_32 -lole32 -Wl,--enable-stdcall-fixup
  ```
- Test loop (no AppImage rebuild): copy the binary into the extracted AppImage at
  `scratchpad/squashfs-root/usr/lib/radmin-vpn/` — `run.sh` copies it into the prefix
  on every launch (line ~214) — then run `squashfs-root/AppRun`.
- Logs: `~/.local/share/radmin-vpn-linux/run.log`, and in the prefix
  `drive_c/radmin_{driver,hook_debug,crash}.log`,
  `drive_c/ProgramData/Famatech/Radmin VPN/service.log` (UTF-16LE).

## Timeline (verified outcomes)

1. rc3/v0.3.4/rc4 on the host → all hang at "never ready" (~33–63 s).
2. rc4 AppImage was broken (missing `lib.sh`); patched by injecting it.
3. Built from source + instrumented the hook; mapped the state machine with radare2.
4. **netns run → WORKS** (ready, online, network + peer + chat). ← key result.
5. Back on the host, ruled out interfaces, DNS, ufw, and fresh-vs-cached prefix — all
   still hang. Routing verified correct.
6. Remaining untested host suspect: `rp_filter` (and residual netfilter / sysctls).

## Upstream

Issue #16 (`ayozetr`): reported the never-ready hang, the rc4 `lib.sh` packaging bug,
and the `lib.sh` outbound-grep bug. **Update to send:** it is NOT a Radmin/Wine bug —
the same AppImage works in a clean netns on this kernel/Wine; the hang is a host
network-stack conflict (details above).
