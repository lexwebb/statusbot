#!/usr/bin/env bash
# install.sh — set statusbot up on this machine (macOS launchd or Linux systemd,
# with a cron fallback). Idempotent: safe to re-run after editing config.
#
#   ./install.sh              # validate, write path.env, install + start schedulers
#   ./install.sh --uninstall  # stop and remove the schedulers (leaves config/state)
#   ./install.sh --no-schedule# validate + path.env only, don't touch the scheduler
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$DIR/config.json"
OS="$(uname -s)"
LABEL="statusbot"

MODE="install"
case "${1:-}" in
  --uninstall)   MODE="uninstall" ;;
  --no-schedule) MODE="validate" ;;
  "" )           ;;
  * ) echo "unknown arg: $1" >&2; exit 2 ;;
esac

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*"; }
die()  { printf '  ✗ %s\n' "$*" >&2; exit 1; }

# The jobs: <name> <script> <macos-schedule-xml> <systemd-oncalendar> <cron-expr>
# Schedules self-gate to working hours inside the scripts, so firing all day is fine.
# The DAEMON sentinel marks a long-running KeepAlive process (not a timer); its
# schedule fields are all DAEMON. The `slacksocket` daemon is optional — it is
# only installed when config.json has an `appToken` (see install loop) — and the
# `slackwatch` 5-min poll always stays as its backstop.
jobs_meta() {
  cat <<'EOF'
digest|run.sh|<dict><key>Minute</key><integer>0</integer></dict><dict><key>Minute</key><integer>30</integer></dict>|*:0/30|*/30 * * * *
review|review.sh|<dict><key>Minute</key><integer>15</integer></dict><dict><key>Minute</key><integer>45</integer></dict>|*:15/30|15,45 * * * *
slackwatch|slack-watch.sh|INTERVAL300|*:0/5|*/5 * * * *
slacksocket|slack-socket.mjs|DAEMON|DAEMON|DAEMON
EOF
}

# ---------------------------------------------------------------- uninstall ---
if [ "$MODE" = "uninstall" ]; then
  echo "Removing statusbot schedulers…"
  if [ "$OS" = "Darwin" ]; then
    while IFS='|' read -r name _; do
      lbl="com.$(id -un).$LABEL.$name"
      launchctl unload "$HOME/Library/LaunchAgents/$lbl.plist" 2>/dev/null
      rm -f "$HOME/Library/LaunchAgents/$lbl.plist"
      ok "removed $lbl"
    done < <(jobs_meta)
  elif command -v systemctl >/dev/null 2>&1; then
    while IFS='|' read -r name _; do
      # Timed jobs are enabled via .timer, the daemon via .service — disable both.
      systemctl --user disable --now "$LABEL-$name.timer" 2>/dev/null
      systemctl --user disable --now "$LABEL-$name.service" 2>/dev/null
      rm -f "$HOME/.config/systemd/user/$LABEL-$name".{service,timer}
      ok "removed $LABEL-$name"
    done < <(jobs_meta)
    systemctl --user daemon-reload 2>/dev/null
  else
    warn "cron install isn't auto-removed — edit 'crontab -e' and delete the statusbot lines"
  fi
  echo "Done."; exit 0
fi

# ------------------------------------------------------------- prerequisites ---
echo "Checking prerequisites…"
missing=""
for t in bash jq perl git curl gh claude; do
  command -v "$t" >/dev/null 2>&1 && ok "$t" || { warn "$t MISSING"; missing="$missing $t"; }
done
command -v node >/dev/null 2>&1 && ok "node" || warn "node not found — the Claude CLI usually needs it on PATH"
[ -n "$missing" ] && die "install the missing tools and re-run:$missing"

# ------------------------------------------------------------------- config ---
echo "Checking config…"
if [ ! -f "$CONFIG" ]; then
  cp "$DIR/config.example.json" "$CONFIG"; chmod 600 "$CONFIG"
  die "created config.json from the template — fill it in (see README.md), then re-run"
fi
jq -e . "$CONFIG" >/dev/null 2>&1 || die "config.json is not valid JSON"
token=$(jq -r '.botToken // ""' "$CONFIG")
case "$token" in ""|xoxb-REPLACE*) die "set a real botToken in config.json";; esac
for k in githubOrg githubUser ownerName botUserId notifyChannel; do
  v=$(jq -r --arg k "$k" '.[$k] // ""' "$CONFIG")
  [ -n "$v" ] || die "config.json is missing required key: $k"
done
ok "config.json valid"
chmod 600 "$CONFIG" 2>/dev/null || true

# ----------------------------------------------------------------- path.env ---
# Schedulers start with a bare PATH; capture the dirs of the tools we need so the
# scripts (which source path.env) can find them.
echo "Writing path.env…"
tooldirs=""
for t in node claude gh jq git perl bash; do
  p=$(command -v "$t" 2>/dev/null) || continue
  d=$(dirname "$p")
  case ":$tooldirs:" in *":$d:"*) ;; *) tooldirs="${tooldirs:+$tooldirs:}$d" ;; esac
done
printf 'export PATH="%s:$PATH"\n' "$tooldirs" > "$DIR/path.env"
ok "path.env → $tooldirs"

# -------------------------------------------------------------- slack sanity ---
echo "Checking Slack…"
auth=$(curl -sS "https://slack.com/api/auth.test" -H "Authorization: Bearer $token")
if [ "$(printf '%s' "$auth" | jq -r '.ok')" != "true" ]; then
  die "Slack auth.test failed: $(printf '%s' "$auth" | jq -r '.error // .')"
fi
ok "token valid — bot @$(printf '%s' "$auth" | jq -r '.user') in $(printf '%s' "$auth" | jq -r '.team')"
real_bot=$(printf '%s' "$auth" | jq -r '.user_id')
cfg_bot=$(jq -r '.botUserId' "$CONFIG")
[ "$real_bot" = "$cfg_bot" ] || warn "config botUserId ($cfg_bot) != token's user ($real_bot) — the bot won't skip its own messages"
# Watch-channel membership (the bot must be a member to read a channel).
while IFS=$'\t' read -r cid cname; do
  [ -n "$cid" ] || continue
  err=$(curl -sS "https://slack.com/api/conversations.history?channel=$cid&limit=1" \
        -H "Authorization: Bearer $token" | jq -r 'if .ok then "" else .error end')
  [ -z "$err" ] && ok "watch #$cname readable" || warn "watch #$cname: $err — /invite the bot to it"
done < <(jq -r '.watch[]? | [.id, .name] | @tsv' "$CONFIG")

# ------------------------------------------ optional Socket Mode daemon --------
# The slacksocket daemon (slack-socket.mjs) is only installed when config.json
# carries an appToken (xapp-…). Without one we run poll-only: the slackwatch
# 5-min job already covers everything, just less instantly. Validate the app
# token and install node deps here so --no-schedule surfaces problems too.
apptoken=$(jq -r '.appToken // ""' "$CONFIG")
WANT_DAEMON=0
case "$apptoken" in
  xapp-*)
    WANT_DAEMON=1
    conn=$(curl -sS -X POST "https://slack.com/api/apps.connections.open" -H "Authorization: Bearer $apptoken")
    if [ "$(printf '%s' "$conn" | jq -r '.ok')" = "true" ]; then
      ok "app token valid — Socket Mode daemon will be installed"
    else
      warn "appToken set but apps.connections.open failed: $(printf '%s' "$conn" | jq -r '.error // .') — check Socket Mode is enabled and the token has connections:write. Skipping the daemon; poll-only."
      WANT_DAEMON=0
    fi ;;
  ""|xapp-REPLACE*) : ;;   # no daemon requested
  *) warn "appToken is set but isn't an xapp- token — ignoring; poll-only." ;;
esac
if [ "$WANT_DAEMON" = "1" ]; then
  command -v node >/dev/null 2>&1 || die "appToken set but 'node' not found — the daemon needs Node.js"
  echo "Installing Node deps for the Socket Mode daemon…"
  ( cd "$DIR" && npm install --omit=dev >/dev/null 2>&1 ) && ok "npm deps installed" || die "npm install failed in $DIR"
fi

[ "$MODE" = "validate" ] && { echo "Validation done (--no-schedule)."; exit 0; }

# ------------------------------------------------------------- scheduler -------
emit_plist() { # label script schedule-xml
  local lbl="$1" script="$2" sched="$3" body runatload="false" interp="/bin/bash"
  # A .mjs script is a Node daemon; anything else is a bash script.
  case "$script" in *.mjs) interp="$(command -v node)" ;; esac
  if [ "$sched" = "DAEMON" ]; then
    # Long-running: restart on crash, start at load, no timer. ThrottleInterval
    # guards against a tight crash-restart loop.
    body="<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict><key>ThrottleInterval</key><integer>10</integer>"
    runatload="true"
  elif [ "$sched" = "INTERVAL300" ]; then
    body="<key>StartInterval</key><integer>300</integer>"
  else
    body="<key>StartCalendarInterval</key><array>$sched</array>"
  fi
  cat > "$HOME/Library/LaunchAgents/$lbl.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$lbl</string>
  <key>ProgramArguments</key><array><string>$interp</string><string>$DIR/$script</string></array>
  $body
  <key>RunAtLoad</key><$runatload/>
  <key>StandardOutPath</key><string>$DIR/state/$lbl.out</string>
  <key>StandardErrorPath</key><string>$DIR/state/$lbl.err</string>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
}

emit_systemd() { # name script oncalendar
  local name="$1" script="$2" cal="$3" u="$HOME/.config/systemd/user" interp="bash"
  case "$script" in *.mjs) interp="node" ;; esac
  mkdir -p "$u"
  if [ "$cal" = "DAEMON" ]; then
    # Long-running service, restart on exit; enabled directly (no timer).
    cat > "$u/$LABEL-$name.service" <<UNIT
[Unit]
Description=statusbot $name (daemon)
[Service]
Type=simple
ExecStart=/usr/bin/env $interp $DIR/$script
Restart=always
RestartSec=10
[Install]
WantedBy=default.target
UNIT
    rm -f "$u/$LABEL-$name.timer"   # in case a prior install left a timer
    return
  fi
  cat > "$u/$LABEL-$name.service" <<UNIT
[Unit]
Description=statusbot $name
[Service]
Type=oneshot
ExecStart=/usr/bin/env $interp $DIR/$script
UNIT
  cat > "$u/$LABEL-$name.timer" <<UNIT
[Unit]
Description=statusbot $name timer
[Timer]
OnCalendar=$cal
Persistent=false
[Install]
WantedBy=timers.target
UNIT
}

mkdir -p "$DIR/state"
# Skip the daemon row unless a valid app token asked for it. Any job whose
# schedule is DAEMON is the daemon; everything else installs unconditionally.
want_job() { # name schedule → 0 if it should be installed
  [ "$2" = "DAEMON" ] && [ "$WANT_DAEMON" != "1" ] && return 1
  return 0
}

if [ "$OS" = "Darwin" ]; then
  echo "Installing launchd agents…"
  while IFS='|' read -r name script macos _ _; do
    lbl="com.$(id -un).$LABEL.$name"
    launchctl unload "$HOME/Library/LaunchAgents/$lbl.plist" 2>/dev/null
    if ! want_job "$name" "$macos"; then rm -f "$HOME/Library/LaunchAgents/$lbl.plist"; continue; fi
    emit_plist "$lbl" "$script" "$macos"
    launchctl load "$HOME/Library/LaunchAgents/$lbl.plist" && ok "loaded $lbl"
  done < <(jobs_meta)
  # A legacy hand-installed set would double-post; flag it.
  ls "$HOME/Library/LaunchAgents"/me.*.claude-*.plist >/dev/null 2>&1 && \
    warn "legacy me.*.claude-* agents present — 'launchctl unload' them to avoid double-posting"
elif command -v systemctl >/dev/null 2>&1; then
  echo "Installing systemd user units…"
  while IFS='|' read -r name script _ cal _; do
    want_job "$name" "$cal" || { systemctl --user disable --now "$LABEL-$name.service" 2>/dev/null; continue; }
    emit_systemd "$name" "$script" "$cal"
  done < <(jobs_meta)
  systemctl --user daemon-reload
  while IFS='|' read -r name _ _ cal _; do
    want_job "$name" "$cal" || continue
    # A DAEMON job is a plain service; a timed job is enabled via its .timer.
    if [ "$cal" = "DAEMON" ]; then unit="$LABEL-$name.service"; else unit="$LABEL-$name.timer"; fi
    systemctl --user enable --now "$unit" && ok "enabled $unit"
  done < <(jobs_meta)
  warn "for units to run while logged out: 'sudo loginctl enable-linger $(id -un)'"
else
  echo "No launchd or systemd — installing crontab entries…"
  tmp=$(mktemp); crontab -l 2>/dev/null | grep -v "# statusbot" > "$tmp" || true
  while IFS='|' read -r name script _ _ cron; do
    # cron has no daemon story; the daemon can't run here. The 5-min poll covers it.
    [ "$cron" = "DAEMON" ] && { warn "cron can't run the Socket Mode daemon — poll-only on this host"; continue; }
    printf '%s /usr/bin/env bash %s/%s  # statusbot %s\n' "$cron" "$DIR" "$script" "$name" >> "$tmp"
  done < <(jobs_meta)
  crontab "$tmp" && ok "crontab updated"; rm -f "$tmp"
fi

echo
echo "Done. Smoke-test any job with e.g.:  $DIR/run.sh --dry-run"
