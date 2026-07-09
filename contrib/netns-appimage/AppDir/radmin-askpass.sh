#!/bin/bash
# Caching askpass for the Radmin VPN netns launcher.
#
# run.sh needs root for several `ip`/`sysctl`/route commands. Without a stable
# terminal, sudo would pop a password dialog for each one. This askpass prompts ONCE
# via a GUI dialog, caches the credential for this session in a 0600 file on tmpfs
# (only the invoking user can read it), and returns it for every later sudo call.
#
# A mkdir-based lock serializes concurrent invocations: if two sudo calls fire the
# askpass at the same moment, only the lock winner shows a dialog; the others wait for
# it to cache the credential and then reuse it. So you're asked exactly once.
# netns-orch deletes the cache file when Radmin closes (see its cleanup()).
uid="$(id -u)"
PWFILE="/run/user/$uid/.radmin-sudo"
[ -d "/run/user/$uid" ] || PWFILE="/tmp/.radmin-sudo-$uid"
LOCK="$PWFILE.lock"

# Fast path: already cached.
if [ -s "$PWFILE" ]; then cat "$PWFILE"; exit 0; fi

# Serialize: become the single prompter, or wait for whoever already is.
tries=0
while ! mkdir "$LOCK" 2>/dev/null; do
    [ -s "$PWFILE" ] && { cat "$PWFILE"; exit 0; }
    tries=$((tries + 1)); [ "$tries" -gt 900 ] && break   # ~3 min safety valve
    sleep 0.2
done
# Hold the lock (or the waited-out safety valve). Re-check before prompting.
if [ -s "$PWFILE" ]; then rmdir "$LOCK" 2>/dev/null; cat "$PWFILE"; exit 0; fi

prompt="${1:-[Radmin VPN] contraseña de administrador:}"
pw=""
# zenity first (GTK) to match the dialog the bundled AppRun would use, then fallbacks.
if command -v zenity >/dev/null 2>&1; then
    pw="$(zenity --password --title="Radmin VPN" 2>/dev/null)"
elif command -v kdialog >/dev/null 2>&1; then
    pw="$(kdialog --title "Radmin VPN" --password "$prompt" 2>/dev/null)"
elif command -v ksshaskpass >/dev/null 2>&1; then
    pw="$(ksshaskpass "$prompt" 2>/dev/null)"
fi

# Cache it (RAM-only, owner-read-only) so subsequent/concurrent calls don't re-prompt.
if [ -n "$pw" ]; then
    ( umask 077; printf '%s' "$pw" > "$PWFILE" )
fi
rmdir "$LOCK" 2>/dev/null
printf '%s' "$pw"
