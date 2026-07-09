# Radmin VPN — netns edition (AppImage)

A self-contained AppImage that runs the **unmodified upstream Radmin VPN AppImage
inside an isolated network namespace**.

## Why

On some hosts Radmin VPN hangs at *"waiting for adapter / service never ready"*. The
cause is not Wine, the kernel or the driver — it's having **many network interfaces**
active on the host (docker / vmnet / tailscale / …). Given a clean network stack the
exact same build reaches `ready` and works. A throwaway network namespace with NAT'd
internet gives Radmin that clean stack without touching the host's real interfaces.

This wrapper packages that workaround as a double-clickable AppImage.

## Build

```sh
./build.sh                       # → ./RadminVPN-Linux-netns.AppImage
```

The script downloads the upstream `v0.3.4` AppImage and `appimagetool` (cached under
`.build-cache/`) and bundles them. To use local copies instead:

```sh
RADMIN_APPIMAGE=/path/to/RadminVPN-Linux-x86_64.AppImage \
APPIMAGETOOL=/path/to/appimagetool \
./build.sh /path/to/output.AppImage
```

Requirements to build: `curl` and FUSE (or an already-extracted `appimagetool`).

## Use

Double-click it (or run with `sudo`). It asks for the password twice — once for polkit
(root, to set up the namespace) and once for the app's own `sudo` (the TAP device and
routes) — then Radmin opens normally. Close the Radmin window and the namespace, NAT
rules and cached credential are all torn down automatically.

Requirements to run: `pkexec` (polkit), `zenity` **or** `kdialog`, and `ip`/`iptables`
(present on virtually any desktop distro). `xdotool` is optional (only used to raise the
window). Everything else (Wine, Radmin) is bundled.

## How it works

- **`AppRun`** — extracts the launcher + the bundled upstream AppImage to
  `~/.cache/radmin-vpn-netns`, shows a "preparing" notification, then escalates via
  `pkexec` (detached with `setsid`, so the auth dialog survives a file-manager launch).
- **`netns-orch.sh`** (root) — creates the `radminvpn` netns + a veth pair with NAT'd
  internet, launches the bundled AppImage **as the invoking user** inside it, shows a
  progress dialog until the GUI window is up, and tears everything down when Radmin
  exits. Also kills any leftover instance first so two launches don't race.
- **`radmin-askpass.sh`** — a caching askpass so the app's several `sudo` calls only
  prompt once (credential kept in a `0600` tmpfs file, removed on exit). No `sudoers`
  changes, no persisted privileges.
