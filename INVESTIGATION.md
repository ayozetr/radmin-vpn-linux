# Radmin VPN on Linux — "service never ready" investigation

Working notes for the `fix/never-ready` branch. Goal: figure out why the Radmin
VPN service (via the Wine wrapper) registers but never reaches `ready`, so the
GUI hangs on *"Waiting for adapter response"* and `run.sh` times out.

## Environment

- Host: CachyOS, kernel `7.1.3-1-cachyos` x86_64, KDE/Wayland.
- Wrapper: `baptisterajaut/radmin-vpn-linux`. Reproduced on `v0.3.4` (stable) and
  `v1.0.0-rc3`/`rc4` (Linux-stability fork). All fail identically.
- Radmin VPN service: `2.0.4899.9`. Wine: 11.11/11.12 Staging (bundled).
- Firewall: `ufw` active, default `allow (outgoing)`, `deny (routed)`.
- Public IP is a normal routable address (not CGNAT).

## Symptom

`opened → enabled → Registered as #… 26.x` all succeed, then the service polls
the driver (`IOCTL STATUS`/`FILTER`) forever and never logs
`Virtual network adapter ready`. `run.sh` times out (~33–63s).

## What we've ruled out / confirmed

| Finding | Evidence |
|---|---|
| Not the NDIS-poisoning bug (#12) | clean prefix; both builds carry the `drvinst` stub + `RvNetMP60` scrub |
| Not the fork's new bridge | `v0.3.4` (simple bridge) fails the same as `rc3/rc4` (dual-thread) |
| Not RX-ring flooding | `--no-broadcast-routes` makes no difference |
| Local firewall not blocking outbound | `ufw` default is `allow (outgoing)`; host reaches external `:443` fine |
| **Service opens NO network socket during the hang** | verified 2 ways: `/proc/<pid>/fd ∩ /proc/net/{tcp,udp}*` (RvControlSvc: 3 sockets, 0 TCP/UDP) AND raw `ss` dumps every 2s |
| Adapter looks healthy to the service | hook `GAA`: `OperStatus=1 (UP)`, `IfType=6 (eth)` — but `unicast=1`, **no IPv4 (only IPv6 link-local)** on the interface |
| Service doesn't dial via direct `ws2_32` `connect` | instrumented `connect`/`WSAConnect` IAT hooks never fired → uses WinHTTP or dynamic resolution |
| `GetINetwork` stub is anti-crash, not a connectivity check | source comment: guards a dangling Wine `netprofm` `INetwork` COM object |

### Dead hypotheses
- "GetINetwork stub makes the service think there's no internet" — **no**, it's a
  crash guard for a stale COM pointer; `v0.3.4` lacks it and still fails.
- "Blocked outbound (firewall/NAT)" — **no**, `ufw` allows outbound and the host
  reaches the servers; and the service isn't even opening a socket.
- "SYN-SENT to AWS:443 was Radmin" — **no**, that was CurseForge (false positive).

## Current working theory

The service never reaches the outbound session/relay dial step during the polling
window (kernel confirms no socket). The maintainer says `ready` is gated on that
outbound connection completing. So it's stalling *before* the dial, for a reason
still internal to the closed `RvControlSvc.exe`.

## strace result (definitive — experiment A)

Patched `run.sh` (in the extracted AppImage only) to launch the service under
`strace -f --seccomp-bpf -e trace=network -o /tmp/radmin_strace.log`. Over the
full 32s window (54795 syscall lines captured):

- `socket()`: **16× AF_UNIX** (Wine IPC), **1× AF_INET**, **1× AF_INET6** (both TCP).
- `connect()`: **18 total, ZERO to an external address.** Only non-UNIX connects
  are to `127.0.0.1:631` / `::1:631` (CUPS — noise).
- `sendto`/`sendmsg` to a non-local address: **ZERO** (no outbound UDP either).

**Conclusion:** at the syscall level, API-agnostic, the service performs **no
external network I/O at all** during the hang. It does not attempt the
session/relay connection — it's not blocked, it never dials. `Registered as
#… 26.x` is replayed from the cached registration (same RID every run; no network
this run). Corroborates the `/proc` finding (RvControlSvc: 0 TCP/UDP). Caveat:
`strace -f` may not follow every Wine subprocess, but the `/proc` probe already
confirmed `RvControlSvc.exe` specifically had 0 TCP/UDP sockets.

**Open question (now RE-territory):** *why* does the service never reach the dial
step? That needs static analysis of `RvControlSvc.exe` (the maintainer's domain).
Candidate: a state/precondition check between "registered" and "dial session"
that silently fails under Wine on this setup.

## Build / iterate (this branch)

- Toolchain: `mingw-w64-gcc` 16.1 (AUR). Full `make` builds everything incl. the
  `rvpnnetmp.sys` driver (DDK headers present). `upx` missing but non-fatal.
- Rebuild just the hook:
  ```
  i686-w64-mingw32-gcc -Wall -O2 -shared -o build/adapter_hook.dll \
      src/adapter_hook.c -liphlpapi -lws2_32 -lole32 -Wl,--enable-stdcall-fixup
  ```
- Test loop (no AppImage rebuild): copy the built binary into the extracted
  AppImage at `scratchpad/squashfs-root/usr/lib/radmin-vpn/` — `run.sh` copies it
  into the prefix on every launch (line 214) — then run `squashfs-root/AppRun`.
- Logs: `~/.local/share/radmin-vpn-linux/run.log`, and in the prefix
  `drive_c/radmin_{driver,hook_debug,crash}.log`,
  `drive_c/ProgramData/Famatech/Radmin VPN/service.log` (UTF-16LE).

## Instrumentation added (commit on branch)

`src/adapter_hook.c`: ws2_32 `connect`/`WSAConnect` IAT tracing (by name + ordinal)
and adapter `OperStatus`/`IfType`/`unicast` logging in the `GetAdaptersAddresses`
hook. Result: GAA logged once (OperStatus=up, no IPv4); connect hooks never fired.

## Timeline / experiments

1. rc3 clean prefix → enabled+registered, GUI "waiting", driver→TAP=0. FAIL.
2. v0.3.4 → full DIAGNOSTICS, timeout 63s. FAIL.
3. v0.3.4 `--no-broadcast-routes` → timeout 62s. FAIL.
4. rc4 → broken AppImage (missing `lib.sh`); patched by injecting repo's `lib.sh`.
5. rc4 patched → timeout 33s; captured sockets: no service socket during hang.
6. `/proc` probe → RvControlSvc 3 sockets, 0 TCP/UDP (2-method confirmation).
7. Instrumented hook → OperStatus=up/no-IPv4; service doesn't import ws2_32 connect.
8. strace `-f -e trace=network` on the wine chain → **zero external network I/O**
   during the hang (see "strace result"). Service never dials the relay.
9. **Next: needs RE of `RvControlSvc.exe` to find why it skips the dial** — hand
   the syscall proof to the maintainer, or static-analyse the binary ourselves.

## Upstream

Issue #16 (`ayozetr`): reported the never-ready + the rc4 `lib.sh` packaging bug +
the `lib.sh` outbound-grep bug + ufw/socket findings. Awaiting maintainer.
