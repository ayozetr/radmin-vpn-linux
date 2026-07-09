# Radmin VPN on Linux — "service never ready" investigation

Notes for the `fix/never-ready` branch.

## TL;DR (verified conclusion)

The "never ready" hang is **NOT** a Wine / kernel / driver / Radmin bug: the same
AppImage reaches `ready` and works fully (GUI online, network created, peer + chat)
inside an isolated **network namespace** on the same kernel and bundled Wine.

**Confirmed root cause: too many network interfaces on the host.** The Radmin service
stalls before `ready` when the machine presents several network interfaces/subnets.
Proven both ways:
- **Additive (inverse bisection):** starting from the clean netns where it works,
  adding dummy interfaces (docker0/vmnet1/vmnet8) reproduces the hang deterministically
  — 0–1 extra subnet interface → works, ≥2 → hangs.
- **Subtractive (native fix):** on the real host, stopping docker + tailscaled and
  removing the extra virtual interfaces makes Radmin reach `ready` **natively** (no
  netns), even with VMware's `vmnet1/vmnet8` still present.

This matches the project's own hook comment about a crash "when joining a server with
**many networks active**" — the same "many networks" condition, here as a hang.
The exact threshold / minimal interface set is fuzzy, but reducing the interface count
fixes it. Two working fixes: run in a netns (`contrib/run-in-netns.sh`), or remove the
extra host interfaces before launching.

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
- **On the host: hangs**, with the same kernel, Wine, AppImage. The differentiator is
  the host network stack — specifically the number of network interfaces (cause below).

## Confirmed cause: too many network interfaces

**Inverse bisection** (start from the working netns, add host traits one at a time):
- `rp_filter=1` + an IPv6 ULA together → still works. Not the cause.
- Add dummy interfaces (docker0/vmnet1/vmnet8/tailscale0) → **hangs**.
- Narrow: 1 extra interface (vmnet1 alone, *or* tailscale0 alone) → works;
  **2 extra subnet interfaces (vmnet1+vmnet8) → hangs**; 3 → hangs.

**Native confirmation:** on the real host, stopping docker + tailscaled and deleting the
extra virtual interfaces let Radmin reach `ready` **natively** (no netns) — even with
`vmnet1/vmnet8` still present. Dropping the interface count below the threshold fixes it.

This is the "many networks" condition the project's own `adapter_hook.c` comment warns
about (a crash "when joining a server with many networks active"); here it manifests as
the never-ready hang. The exact threshold / minimal set is fuzzy (a host that kept 2
vmnets worked, while the netns with 2 dummies hung — down interfaces and interface
identity may also weigh in), but **fewer interfaces = works**.

### Ruled out as the cause (verified — none of these is it; the interface count is)
- **DNS resolver** — forced `1.1.1.1`/`8.8.8.8` instead of `127.0.0.53`; still hangs.
- **ufw** — fully disabled; still hangs.
- **Prefix state** — fresh install on the host (new online RID); still hangs (not a
  stale/cached prefix).
- **Routing / Tailscale routing** — `ip route get` to the proxies is correct; Tailscale's
  fwmark rules don't touch Radmin's traffic; tailscale0 alone doesn't trigger it.
- **`rp_filter`** — `0` on all interfaces; still hangs.
- **IPv6** — no real IPv6 route out; the proxies are IPv4-only.

Note: earlier *subtractive* interface tests on the host looked like they "ruled out"
interfaces (removing docker/vmnet still hung), but they were incomplete/confounded
(`tailscale down` leaves `tailscale0`; some interfaces were only brought down, not
deleted). The controlled *additive* bisection in the netns is what actually pinned it.

## Fixes
- **Run in a netns** (`contrib/run-in-netns.sh`) — cleanest; docker/tailscale/VMware keep running.
- **Native** — stop docker + tailscaled and remove the extra interfaces before launching
  (they stay off while using Radmin).

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
5. Host subtractive tests (DNS, ufw, `rp_filter`, IPv6, fresh prefix, and *incomplete*
   interface removal) → still hang; routing verified correct. (These looked like they
   ruled interfaces out, but the removal was incomplete — see the note above.)
6. **Inverse bisection in the netns** → adding dummy interfaces reproduces the hang;
   pinned it to the interface count (≥2 extra subnet interfaces).
7. **Native fix confirmed** → stopping docker+tailscaled and removing the extra host
   interfaces makes Radmin reach `ready` natively.

## Upstream

Issue #16 (`ayozetr`): reported the never-ready hang, the rc4 `lib.sh` packaging bug,
and the `lib.sh` outbound-grep bug. **Update to send:** it is NOT a Radmin/Wine bug —
the same AppImage works in a clean netns on this kernel/Wine. Confirmed root cause:
**too many network interfaces** — reproduced by adding dummy interfaces to the netns,
and fixed natively by removing the host's extra interfaces. Likely the same "many
networks" condition the `adapter_hook.c` release-guard comment already documents.
