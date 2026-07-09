#!/bin/bash
# Caching askpass for the Radmin VPN netns launcher.
#
# run.sh needs root for several `ip`/`sysctl`/route commands. Without a stable
# terminal, sudo would pop a password dialog for each one. This askpass prompts once
# via a GUI dialog, VALIDATES the password, caches it for this session in a 0600 file
# on tmpfs (only the invoking user can read it), and returns it for every later sudo
# call — so you're asked once, not five times.
#
# It only caches a password that actually validates (`sudo -k -S -v`), so a typo is
# re-prompted instead of being cached and then failing sudo three times in a row.
# A mkdir-based lock serializes concurrent invocations. netns-orch deletes the cache
# file when Radmin closes (see its cleanup()).
uid="$(id -u)"
PWFILE="/run/user/$uid/.radmin-sudo"
[ -d "/run/user/$uid" ] || PWFILE="/tmp/.radmin-sudo-$uid"
LOCK="$PWFILE.lock"

ask() {
    if command -v zenity >/dev/null 2>&1; then
        zenity --password --title="Radmin VPN" 2>/dev/null
    elif command -v kdialog >/dev/null 2>&1; then
        kdialog --title "Radmin VPN" --password "$1" 2>/dev/null
    elif command -v ksshaskpass >/dev/null 2>&1; then
        ksshaskpass "$1" 2>/dev/null
    fi
}

# Fast path: already-validated cached credential.
if [ -s "$PWFILE" ]; then cat "$PWFILE"; exit 0; fi

# Serialize: become the single prompter, or wait for whoever already is.
tries=0
while ! mkdir "$LOCK" 2>/dev/null; do
    [ -s "$PWFILE" ] && { cat "$PWFILE"; exit 0; }
    tries=$((tries + 1)); [ "$tries" -gt 900 ] && break   # ~3 min safety valve
    sleep 0.2
done
if [ -s "$PWFILE" ]; then rmdir "$LOCK" 2>/dev/null; cat "$PWFILE"; exit 0; fi

# Prompt until the password validates (only cache a validated one).
prompt="${1:-[Radmin VPN] administrator password:}"
pw=""
n=0
while [ "$n" -lt 3 ]; do
    n=$((n + 1))
    pw="$(ask "$prompt")"
    [ -z "$pw" ] && break                                   # cancelled → give up
    if printf '%s\n' "$pw" | SUDO_ASKPASS= sudo -k -S -v 2>/dev/null; then
        ( umask 077; printf '%s' "$pw" > "$PWFILE" )        # valid → cache
        break
    fi
    pw=""                                                   # wrong → re-prompt
done
rmdir "$LOCK" 2>/dev/null
printf '%s' "$pw"
