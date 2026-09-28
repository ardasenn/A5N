#!/bin/zsh
# A5N setup. Creates the vault from the templates, then installs the scheduled
# jobs. Safe to run again: existing pages are never overwritten, and reruns are
# how you apply a schedule change or add a namespace for a new project.
set -u

SCRIPT_DIR="${0:A:h}"
REPO="${SCRIPT_DIR:h}"

say() { print -r -- "$@"; }
die() { print -r -- "error: $*" >&2; exit 1; }

# config.py owns the "where is the config" question, including the A5N_CONFIG
# override used for testing against a throwaway vault. Duplicating that check
# here would mean two answers to one question.
CONFIG_EXPORTS="$(python3 "$SCRIPT_DIR/config.py" --sh 2>&1)" || die "$CONFIG_EXPORTS"
eval "$CONFIG_EXPORTS"
python3 "$SCRIPT_DIR/config.py" --check || die "fix config.ini and run setup again"

VAULT="$A5N_VAULT"
say ""
say "vault: $VAULT"

# --- vault skeleton -------------------------------------------------------
mkdir -p "$VAULT"/{patterns,chess-moves,digests,.a5n-logs}
# Placeholders are created once and never touched again: touch refreshed an
# existing one's mtime on every run, and rclone copy --immutable reports a
# file whose mtime changed as modified (exit code 6 on a real vault).
for KEEP in "$VAULT/patterns/.gitkeep" "$VAULT/chess-moves/.gitkeep" "$VAULT/digests/.gitkeep"; do
  [ -e "$KEEP" ] || : > "$KEEP"
done

render() {
  # render <template> <destination>. Substitutes {{TOKENS}}. Never overwrites.
  local src="$1" dst="$2"
  [ -f "$dst" ] && return 0
  sed -e "s|{{VAULT_TITLE}}|$A5N_VAULT_TITLE|g" \
      -e "s|{{LANGUAGE}}|$A5N_LANGUAGE|g" \
      -e "s|{{TODAY}}|$(date +%F)|g" \
      "$src" > "$dst"
  say "  created $(basename "$dst")"
}

SCHEMA_SRC="$REPO/template/SCHEMA.en.md"
case "$A5N_LANGUAGE" in
  [Tt]urkish|[Tt]ürkçe|[Tt]urkce|tr|TR) SCHEMA_SRC="$REPO/template/SCHEMA.tr.md" ;;
esac

say "writing vault files"
render "$SCHEMA_SRC" "$VAULT/CLAUDE.md"
render "$REPO/template/index.md" "$VAULT/index.md"
render "$REPO/template/log.md" "$VAULT/log.md"
render "$REPO/template/GOALS.md" "$VAULT/GOALS.md"
render "$REPO/template/gitignore" "$VAULT/.gitignore"

# AGENTS.md lets Codex and other agents read the same schema as Claude Code.
if [ ! -f "$VAULT/AGENTS.md" ]; then
  print -r -- "@CLAUDE.md" > "$VAULT/AGENTS.md"
  say "  created AGENTS.md"
fi

# --- one namespace per configured project ---------------------------------
say "writing namespaces"
python3 "$SCRIPT_DIR/config.py" --projects | while IFS=$'\t' read -r NAME MATCH WATERMARK PROJECT_REPO; do
  NS="$VAULT/$NAME"
  for dir in raw/sessions raw/docs sources/sessions entities concepts decisions bugs syntheses archive; do
    mkdir -p "$NS/$dir"
    [ -e "$NS/$dir/.gitkeep" ] || : > "$NS/$dir/.gitkeep"
  done
  for file in index log; do
    [ -f "$NS/$file.md" ] && continue
    sed -e "s|{{PROJECT}}|$NAME|g" \
        -e "s|{{PROJECT_REPO}}|$PROJECT_REPO|g" \
        -e "s|{{WATERMARK}}|$WATERMARK|g" \
        -e "s|{{TODAY}}|$(date +%F)|g" \
        "$REPO/template/namespace/$file.md" > "$NS/$file.md"
  done
  say "  $NAME (match '$MATCH', since $WATERMARK)"
done

# --- git ------------------------------------------------------------------
# The vault is a git repository because the safety model depends on it: a
# failed run is undone with reset --hard, and a successful one is committed.
if [ ! -d "$VAULT/.git" ]; then
  git -C "$VAULT" init -q
  git -C "$VAULT" add -A
  git -C "$VAULT" commit -qm "chore: vault created by A5N setup"
  say "git repository initialised"
fi

# --- sync -----------------------------------------------------------------
# Checked here, before any timer is installed: a scheduled job that cannot
# reach its remote would only fail later, unattended. The README section
# "Two machines, one vault" explains the settings.
if [ "$A5N_SYNC_ENABLED" = "yes" ]; then
  say "checking sync"
  git -C "$VAULT" remote get-url "$A5N_SYNC_REMOTE" >/dev/null 2>&1 \
    || die "sync is on but the vault has no git remote '$A5N_SYNC_REMOTE'. Add it: git -C \"$VAULT\" remote add $A5N_SYNC_REMOTE <url>"
  if [ -n "$A5N_SYNC_RAW_REMOTE" ]; then
    command -v rclone >/dev/null 2>&1 \
      || die "sync.raw_remote is set but rclone is not installed"
    case "$A5N_SYNC_RAW_REMOTE" in
      /*|:*) ;;  # a local path or an on the fly backend: nothing to look up
      *:*)
        RCLONE_NAME="${A5N_SYNC_RAW_REMOTE%%:*}:"
        rclone listremotes 2>/dev/null | grep -qxF -- "$RCLONE_NAME" \
          || die "rclone has no remote named '$RCLONE_NAME'. Create it with: rclone config" ;;
    esac
    FIRST_PROJECT="${${=A5N_PROJECT_NAMES}[1]}"
    if ! git -C "$VAULT" check-ignore -q "$FIRST_PROJECT/raw/sessions/x.jsonl"; then
      say "  warning: raw/ is tracked by git while sync.raw_remote is set, so raw files would travel twice. Add **/raw/ to the vault's .gitignore."
    fi
  fi
  # log.md files only ever grow, so when both machines added lines the right
  # merge keeps both. Machine local on purpose: the vault itself carries no
  # .gitattributes, and every machine that syncs runs this setup anyway.
  ATTR="$(git -C "$VAULT" rev-parse --git-path info/attributes)"
  [[ "$ATTR" = /* ]] || ATTR="$VAULT/$ATTR"
  mkdir -p "${ATTR:h}"
  grep -qxF '**/log.md merge=union' "$ATTR" 2>/dev/null \
    || print -r -- '**/log.md merge=union' >> "$ATTR"
  say "  pages via $A5N_SYNC_REMOTE/$A5N_SYNC_BRANCH, raw files via ${A5N_SYNC_RAW_REMOTE:-git}"
fi

# --- scheduled jobs -------------------------------------------------------
install_launchd() {
  local label="$1" script="$2" plist="$HOME/Library/LaunchAgents/$1.plist"
  local calendar="$3"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$script</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$REPO</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
$calendar
    </dict>
    <key>StandardOutPath</key>
    <string>$VAULT/.a5n-logs/$label.out</string>
    <key>StandardErrorPath</key>
    <string>$VAULT/.a5n-logs/$label.err</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
  if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; then
    say "  $label"
  else
    say "  warning: launchctl refused $label; inspect with: launchctl print gui/$(id -u)/$label"
  fi
}

# A job set to off in config.ini: not installed on this machine, and removed
# when an earlier setup installed it. A second machine sharing a vault turns
# lint and digest off, because both rewrite their output whole.
remove_launchd() {
  local label="$1"
  local plist="$HOME/Library/LaunchAgents/$1.plist"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
  if [ -f "$plist" ]; then
    rm -f "$plist"
    say "  $label removed (off in config)"
  else
    say "  $label off"
  fi
}

install_systemd() {
  local name="$1" script="$2" oncalendar="$3" description="$4"
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$dir"
  # A user manager starts services with a nearly empty PATH, so the runner
  # binary and git are resolved from an explicit list, the same way the
  # launchd plist above does it.
  cat > "$dir/$name.service" <<UNIT
[Unit]
Description=$description

[Service]
Type=oneshot
WorkingDirectory=$REPO
Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ExecStart=/bin/zsh $script
UNIT
  cat > "$dir/$name.timer" <<UNIT
[Unit]
Description=$description

[Timer]
OnCalendar=$oncalendar
# A machine that was off at the scheduled minute still runs the job once it
# comes back. Without this a desktop that sleeps through 09:07 silently
# ingests nothing that day, and the transcript deletion clock keeps running.
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl --user daemon-reload 2>/dev/null
  if systemctl --user enable --now "$name.timer" 2>/dev/null; then
    say "  $name.timer at $oncalendar"
  else
    say "  warning: systemctl refused $name.timer; inspect with: systemctl --user status $name.timer"
  fi
}

remove_systemd() {
  local name="$1"
  local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  if [ -f "$dir/$name.timer" ] || [ -f "$dir/$name.service" ]; then
    systemctl --user disable --now "$name.timer" 2>/dev/null
    rm -f "$dir/$name.timer" "$dir/$name.service"
    systemctl --user daemon-reload 2>/dev/null
    say "  $name.timer removed (off in config)"
  else
    say "  $name.timer off"
  fi
}

# "09:07", "sun 11:07" and "1 09:37" turn into launchd calendar keys. A
# leading token that is all digits is a day of the month (monthly job), a
# named token is a weekday (weekly job), no token means daily.
calendar_keys() {
  # One assignment per local: zsh expands every right hand side of a single
  # local statement BEFORE any of its assignments happen, so clock="$spec"
  # on the shared line read the (unset) outer spec and the daily schedule
  # silently produced empty Hour/Minute keys in the plist.
  local spec="$1"
  local when="" clock="$spec"
  case "$spec" in
    *" "*) when="${spec%% *}"; clock="${spec##* }" ;;
  esac
  local hour="${clock%%:*}"
  local minute="${clock##*:}"
  local out=""
  if [ -n "$when" ]; then
    case "$when" in
      <1-31>)
        out="        <key>Day</key>
        <integer>$when</integer>
" ;;
      *)
        local index
        case "$when" in
          sun) index=0 ;; mon) index=1 ;; tue) index=2 ;; wed) index=3 ;;
          thu) index=4 ;; fri) index=5 ;; sat) index=6 ;;
          *) die "unknown weekday or day of month in schedule: $when" ;;
        esac
        out="        <key>Weekday</key>
        <integer>$index</integer>
" ;;
    esac
  fi
  print -r -- "$out        <key>Hour</key>
        <integer>${hour#0}</integer>
        <key>Minute</key>
        <integer>${minute#0}</integer>"
}

# The same three shapes calendar_keys() reads, rendered as a systemd
# OnCalendar expression instead of launchd calendar keys.
systemd_calendar() {
  # One assignment per local, for the zsh expansion order reason
  # calendar_keys() documents above.
  local spec="$1"
  local when="" clock="$spec"
  case "$spec" in
    *" "*) when="${spec%% *}"; clock="${spec##* }" ;;
  esac
  local hour="${clock%%:*}"
  local minute="${clock##*:}"
  # 10# forces base ten: "09" is a legal schedule and a leading zero would
  # otherwise be read as octal and rejected.
  local stamp
  stamp="$(printf '%02d:%02d:00' "$((10#$hour))" "$((10#$minute))")"
  if [ -z "$when" ]; then
    print -r -- "*-*-* $stamp"
    return
  fi
  case "$when" in
    <1-31>) printf -- '*-*-%02d %s\n' "$((10#$when))" "$stamp" ;;
    sun|mon|tue|wed|thu|fri|sat) print -r -- "${(C)when} *-*-* $stamp" ;;
    *) die "unknown weekday or day of month in schedule: $when" ;;
  esac
}

# job, script, schedule and description, one row per scheduled job
JOB_ROWS=(
  ingest daily-ingest.sh "$A5N_SCHEDULE_INGEST" "A5N daily ingest"
  lint weekly-lint.sh "$A5N_SCHEDULE_LINT" "A5N weekly lint"
  digest digest.sh "$A5N_SCHEDULE_DIGEST" "A5N monthly digest"
)

if [ "$A5N_SCHEDULE_ENABLED" = "yes" ]; then
  typeset -A CAL
  if [ "$(uname)" = "Darwin" ]; then
    say "installing scheduled jobs"
    # Every calendar is computed and CHECKED before any plist is written: a
    # die() inside $(...) only kills the subshell, and an empty calendar
    # dict means "fire every minute" to launchd. config.py validates the
    # schedule strings too; this is the second seatbelt.
    for JOB SCRIPT SPEC DESC in "${JOB_ROWS[@]}"; do
      [ "$SPEC" = off ] && continue
      CAL[$JOB]="$(calendar_keys "$SPEC")" || die "invalid $JOB schedule: $SPEC"
    done
    for JOB SCRIPT SPEC DESC in "${JOB_ROWS[@]}"; do
      if [ "$SPEC" = off ]; then
        remove_launchd "com.a5n.$JOB"
      else
        install_launchd "com.a5n.$JOB" "$REPO/scripts/$SCRIPT" "${CAL[$JOB]}"
      fi
    done
  elif command -v systemctl >/dev/null 2>&1; then
    say "installing scheduled jobs"
    # Captured and CHECKED before any unit is written, for the same reason
    # the launchd branch above does it: a die() inside $(...) only kills the
    # subshell, and an empty OnCalendar makes systemd refuse the timer.
    for JOB SCRIPT SPEC DESC in "${JOB_ROWS[@]}"; do
      [ "$SPEC" = off ] && continue
      CAL[$JOB]="$(systemd_calendar "$SPEC")" || die "invalid $JOB schedule: $SPEC"
    done
    for JOB SCRIPT SPEC DESC in "${JOB_ROWS[@]}"; do
      if [ "$SPEC" = off ]; then
        remove_systemd "a5n-$JOB"
      else
        install_systemd "a5n-$JOB" "$REPO/scripts/$SCRIPT" "${CAL[$JOB]}" "$DESC"
      fi
    done
    # User timers are torn down at logout unless lingering is on, which
    # turns a working install into one that only fires while you happen to
    # be logged in.
    if [ "$(loginctl show-user "$USER" --property=Linger 2>/dev/null)" != "Linger=yes" ]; then
      say "  note: user lingering is off, so these timers stop when you log out"
      say "  turn it on with: loginctl enable-linger $USER"
    fi
  else
    say "no launchd and no systemd here. Add these to crontab yourself:"
    for JOB SCRIPT SPEC DESC in "${JOB_ROWS[@]}"; do
      [ "$SPEC" = off ] && continue
      say "  $JOB at $SPEC -> $REPO/scripts/$SCRIPT"
    done
  fi
else
  say "scheduling disabled in config, run the scripts by hand when you want them"
fi

# --- first ingest, backfill ------------------------------------------------
# The first value moment should not wait for tomorrow's schedule. Count the
# pending work deterministically (dry run capture plus the queue with the
# unit cap lifted) and offer to process it right now. A5N_BACKFILL=yes|no
# answers without a terminal, for automation and tests.
PENDING_NEW="$(A5N_MAX_UNITS=1000000 python3 "$SCRIPT_DIR/ingest-discover.py" capture --dry-run 2>/dev/null \
  | sed -n 's/.*summary: copied=\([0-9]*\).*/\1/p')"
PENDING_QUEUED="$(A5N_MAX_UNITS=1000000 python3 "$SCRIPT_DIR/ingest-discover.py" queue 2>/dev/null | grep -c .)"
PENDING=$(( ${PENDING_NEW:-0} + ${PENDING_QUEUED:-0} ))

if [ "$PENDING" -gt 0 ]; then
  say ""
  say "$PENDING sessions are waiting to be processed. The watermark in"
  say "config.ini controls how far back history reaches; move it earlier and"
  say "rerun setup to pull in more."
  ANSWER="${A5N_BACKFILL:-}"
  if [ -z "$ANSWER" ] && [ -t 0 ]; then
    if read -q "REPLY?Process them now? One model run per session. [y/N] "; then
      ANSWER=yes
    else
      ANSWER=no
    fi
    say ""
  fi
  if [ "$ANSWER" = "yes" ]; then
    say "running the first ingest with the unit cap lifted, this can take a while..."
    A5N_MAX_UNITS=1000000 zsh "$REPO/scripts/daily-ingest.sh"
    say "first ingest finished. The vault log has the details:"
    say "  $VAULT/.a5n-logs/$(date +%F).log"
  else
    say "skipped. The scheduled run picks them up, or run it yourself:"
    say "  zsh $REPO/scripts/daily-ingest.sh"
  fi
fi

# --- the read path ---------------------------------------------------------
say ""
say "give your coding agents read access to the vault (run once per machine):"
say ""
say "  claude mcp add --scope user a5n -- python3 $REPO/scripts/a5n-mcp.py"
say ""
say "  # Codex, add to ~/.codex/config.toml:"
say "  [mcp_servers.a5n]"
say "  command = \"python3\""
say "  args = [\"$REPO/scripts/a5n-mcp.py\"]"

# Registration alone does not make agents look things up: without a standing
# instruction in the project's own agent file, history questions get answered
# from guesswork instead of the archive. Same block as the README.
say ""
say "then tell each project's agents to use it. Add this block to the"
say "project's CLAUDE.md or AGENTS.md:"
say ""
say "  ## Knowledge vault (A5N)"
say ""
say "  This project has a permanent knowledge archive: decisions, bug root"
say "  causes and architecture notes distilled from earlier agent sessions."
say ""
say "  - When you need history, an old bug or the reason behind a decision,"
say "    ask the a5n MCP server first: vault_overview for the catalogue,"
say "    vault_search for anything specific."
say "  - For methods and lessons that span projects, search the pattern pages."
say "  - The vault is read only from here. Writing is done by the vault's own"
say "    automation, never from this repository."

say ""
say "done. Open $VAULT in Obsidian, or any editor, and start working."
