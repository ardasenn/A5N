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
mkdir -p "$VAULT"/{patterns,chess-moves,.a5n-logs}
touch "$VAULT/patterns/.gitkeep" "$VAULT/chess-moves/.gitkeep"

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
    touch "$NS/$dir/.gitkeep"
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
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null
  say "  $label"
}

# "09:07" and "sun 11:07" turn into launchd calendar keys.
calendar_keys() {
  local spec="$1" weekday="" clock="$spec"
  case "$spec" in
    *" "*) weekday="${spec%% *}"; clock="${spec##* }" ;;
  esac
  local hour="${clock%%:*}" minute="${clock##*:}"
  local out=""
  if [ -n "$weekday" ]; then
    local index
    case "$weekday" in
      sun) index=0 ;; mon) index=1 ;; tue) index=2 ;; wed) index=3 ;;
      thu) index=4 ;; fri) index=5 ;; sat) index=6 ;;
      *) die "unknown weekday in schedule: $weekday" ;;
    esac
    out="        <key>Weekday</key>
        <integer>$index</integer>
"
  fi
  print -r -- "$out        <key>Hour</key>
        <integer>${hour#0}</integer>
        <key>Minute</key>
        <integer>${minute#0}</integer>"
}

if [ "$A5N_SCHEDULE_ENABLED" = "yes" ]; then
  if [ "$(uname)" = "Darwin" ]; then
    say "installing scheduled jobs"
    install_launchd "com.a5n.ingest" "$REPO/scripts/daily-ingest.sh" "$(calendar_keys "$A5N_SCHEDULE_INGEST")"
    install_launchd "com.a5n.lint" "$REPO/scripts/weekly-lint.sh" "$(calendar_keys "$A5N_SCHEDULE_LINT")"
  else
    say "scheduling is macOS only for now. Add these to crontab yourself:"
    say "  ingest at $A5N_SCHEDULE_INGEST -> $REPO/scripts/daily-ingest.sh"
    say "  lint at $A5N_SCHEDULE_LINT     -> $REPO/scripts/weekly-lint.sh"
  fi
else
  say "scheduling disabled in config, run the scripts by hand when you want them"
fi

say ""
say "done. Open $VAULT in Obsidian, or any editor, and start working."
say "Run one ingest now to see it work:"
say "  zsh $REPO/scripts/daily-ingest.sh"
