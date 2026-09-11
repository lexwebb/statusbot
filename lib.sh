#!/usr/bin/env bash
# lib.sh — shared setup + cross-platform shims, sourced by every statusbot script.
# Handles the differences between macOS/BSD and Linux/GNU coreutils, and sets a
# usable PATH for schedulers (launchd/systemd/cron) that start with a bare env.
#
# Callers set DIR before sourcing:  DIR=…; . "$DIR/lib.sh"

DIR="${DIR:-${HOME}/.claude/statusbot}"
CONFIG="${CONFIG:-$DIR/config.json}"

# Schedulers start with a minimal PATH, so node/claude/gh/jq/git aren't found.
# install.sh writes path.env with the real tool dirs; fall back to common ones.
if [ -f "$DIR/path.env" ]; then
  . "$DIR/path.env"
else
  export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
fi

# GNU coreutils accept --version; BSD (macOS) do not. Detect once.
if date --version >/dev/null 2>&1; then _GNU_DATE=1; else _GNU_DATE=0; fi
if stat --version >/dev/null 2>&1; then _GNU_STAT=1; else _GNU_STAT=0; fi

# epoch seconds → ISO-8601 UTC.
iso_utc() {
  if [ "$_GNU_DATE" = 1 ]; then date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
  else date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; fi
}

# N → epoch seconds of local midnight N days ago.
epoch_days_ago_midnight() {
  if [ "$_GNU_DATE" = 1 ]; then date -d "$1 days ago 00:00:00" +%s
  else date -v-"$1"d -v0H -v0M -v0S +%s; fi
}

# file → epoch mtime (empty on missing file, so callers can guard).
file_mtime() {
  if [ "$_GNU_STAT" = 1 ]; then stat -c %Y "$1" 2>/dev/null
  else stat -f %m "$1" 2>/dev/null; fi
}
