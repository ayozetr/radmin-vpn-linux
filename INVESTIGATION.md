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

## Static analysis of RvControlSvc.exe (experiment B, objdump)

32-bit PE, image base `0x400000` (so IDA addr = `0x400000 + RVA`, matching the
hook's offsets). Tools: only `objdump`/`strings` (no radare2/ghidra).

**Strings that map the state machine** (UTF-16 in `.rdata`, VA = off−0xfa200+0x4fb000):
- `Virtual network adapter opened / enabled` — `0x501b50` (enabled)
- `Registered as #%llu, %hs/%hs` — `0x501b90`
- **`Virtual network adapter ready` — `0x501bcc`** (the line we never get)
- `Failed to enable virtual adapter (err:0x%llx)` / `Failed to setup virtual adapter … may be not operable`
- Relay path: `InternetConnectW`, `TcpRelay`, `ROLClient_Connect/ContinueConnect`,
  `SHelper_RSession_*`. **→ the session/relay dials via WinINet, not raw winsock**
  (explains why the ws2_32 `connect` hook and the syscall trace saw no dial).
- RTTI message classes: `CSetupAdapter@task`, **`CDeviceReady@msg`**,
  `CConnectedToSlave`, **`CConnectToRosFailed`**, `CDisconnectedFromRos`,
  `CGuiConnected/Disconnected` → there's a **ROS (Radmin Online Server)** connect.

**The logger/dispatcher** (`~0x443260`–`0x44357e`): a jump-table switch on the
message type at `[esi+0x34]` (`dec ecx; cmp ecx,0x19; ja …; movzx ecx,[ecx+0x443598];
jmp [ecx*4+0x443584]`). Each case logs its state string via the log fn at `0x43b930`.
`"…ready"` (`0x44352c`/`push 0x501bcc`) is the **`CDeviceReady` case** — a separate
branch from `Registered` (which ends `ret 8` at `0x443529`). So "ready" is emitted
only when a device-ready message is *dispatched*, which never happens here.

**Conclusion of B (objdump):** confirmed the architecture — `ready` is gated on a
`CDeviceReady` message; the ROS/relay connect (WinINet) is never attempted.

## B continued (radare2 — xref tracing)

Analyzed with `r2 -A`. The ROS relay/session runs over **WinINet HTTP** (not
winsock — `WS2_32` only imports `socket`/`closesocket`, no `connect`, matching the
strace). The relay call chain, all never reached during the hang:

```
[CConnector thread] → 0x4bf60c → fcn.004c1ad0  (ROS comm layer)
                              → fcn.004c50e0  (builds the "POST" request)
                              → fcn.004c5260  (InternetOpenW → InternetConnectW
                                               → HttpOpenRequestW → HttpSendRequestW)
```

- Confirmed logger `fcn.00443220`: `push 0x501bcc` ("…ready") at `0x44352f` is the
  `CDeviceReady` case; `Registered` at `0x443502` is a separate case (ends `ret 8`).
- `InternetConnectW`/`InternetOpenW`/`HttpSendRequestW` are each called from exactly
  one function: `fcn.004c5260`.
- The connector is a **thread**: RTTI `.?AV?$TSimpleThread@VCConnector@ControlSvc@@`,
  with `IConnectorObject`/`CConnector`/`CConnectorLog` and C-exports
  `ROLClient_InitConnector` / `ROLClient_Connect` / `ROLClient_ShutdownConnector`.
  Connectors are kept in a per-`CRid` hash map (`TIterableHash<…CRid…CConnector>`).

**Where B lands:** the bug is upstream of the connector thread — the service never
drives the `CConnector`/`ROLClient_Connect` path that would HTTP-POST to ROS, so no
`CDeviceReady`, so no `ready`.

### Function map (RVA/IDA addr = base 0x400000), for the maintainer / future work

| Addr | What it is |
|---|---|
| `fcn.00443220` | **state logger/dispatcher** — jump-table switch on msg type `[esi+0x34]`; logs opened/enabled/`Registered`(0x443502)/`ready`(0x44352f) |
| `method ControlSvc::CControlSvc…virtual_4` @ `0x4407ce` | calls the setup-adapter task |
| `fcn.004435c0` | **CSetupAdapter task run** — calls setup `fcn.00461b60`; error strings `[req:%u] Failed`, `Failed to enable virtual adapter`, `Registration failed` (none logged in our runs); then a **boolean-gated post-setup sequence** (`fcn.00439870`, `fcn.0043bdc0`, `fcn.00446450/446530`, `fcn.00430cb0`, `fcn.0044f030`) |
| `fcn.00461b60` | adapter setup; error-code checks (23/37/6); logs `Failed to setup virtual adapter … may be not operable` (**not** hit here) |
| `fcn.00402f30` → `fcn.00402ea0` | **posts `CDeviceReady`** (inlined `CAbstractQueueableMessage` template + enqueue `fcn.00464ce0`); reached only downstream of a successful ROS connect. Caller chain climbs into unbounded template thunks (`(nofunc) 0x402e87…`). |
| `fcn.004c5260` | ROS relay: `InternetOpenW→InternetConnectW→HttpOpenRequestW→HttpSendRequestW` |
| `fcn.004c50e0` ← `fcn.004c1ad0` ← `(nofunc) 0x4bf60c` | HTTP-POST builder ← ROS comm ← `CConnector` thread (`TSimpleThread<CConnector>`) |
| `fcn.004c0940` @ `0x4c0b95`, `fcn.004d4629` @ `0x4d4672` | the two `CreateThread` sites |

### Concrete anomaly worth flagging (candidate gate)

`GetAdaptersAddresses` (via our hook) reports the adapter **`OperStatus=1` (UP)** but
with **no IPv4 unicast** — only the IPv6 link-local (`unicast=1(none)`). The Radmin
`26.x` address is never bound to the Linux TAP at the interface level. If the
post-setup path (or the connector) waits for the adapter to carry its assigned IPv4
before proceeding, that would explain the stall. Unconfirmed, but it's the one
environment-specific discrepancy we can see from outside the binary.

### Honest wall

Pinpointing the exact precondition means walking template-heavy, symbol-less C++
(`TSimpleThread`, `TIterableHash`, inlined queueable-message templates) where
radare2's auto-analysis leaves many `(nofunc)` gaps. This is the point where the
maintainer's existing Ghidra map (named functions) is decisive. **Handoff with the
map + syscall proof + the no-IPv4 anomaly above.**

## Upstream

Issue #16 (`ayozetr`): reported the never-ready + the rc4 `lib.sh` packaging bug +
the `lib.sh` outbound-grep bug + ufw/socket findings. Awaiting maintainer.
