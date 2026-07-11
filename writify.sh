#!/usr/bin/env bash
# Writify v1.0.0 — shell-native PoC & writeup capture tool
# Usage: writify <command> [args]

set -uo pipefail

WRITIFY_VERSION="1.0.0"
WRITIFY_DIR=".writify"
CONFIG_FILE="$WRITIFY_DIR/config"
SOLVE_LOG="$WRITIFY_DIR/solve_log"
ATTACH_LOG="$WRITIFY_DIR/attachments"
COUNTER_FILE="$WRITIFY_DIR/poc_counter"
DAEMON_PID_FILE="$WRITIFY_DIR/daemon.pid"
TRIGGER_FILE="$WRITIFY_DIR/capture.trigger"
LAST_BUILD_FILE="$WRITIFY_DIR/last_build"

NOTE_TYPES="observation finding command result dead_end"

# ---------- helpers ----------

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

err() { echo "✗ $*" >&2; }
ok()  { echo "✓ $*"; }
info(){ echo "→ $*"; }

require_workspace() {
  if [ ! -d "$WRITIFY_DIR" ]; then
    err "Not a writify workspace. Run 'writify start <name>' first."
    exit 1
  fi
}

read_config() {
  # shellcheck disable=SC1090
  [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

detect_screenshot_tool() {
  if command -v scrot >/dev/null 2>&1; then
    echo "scrot"
  elif command -v screencapture >/dev/null 2>&1; then
    echo "screencapture"
  elif command -v import >/dev/null 2>&1; then
    echo "import"
  else
    echo "none"
  fi
}

take_screenshot() {
  local outfile="$1"
  local tool
  tool=$(detect_screenshot_tool)
  case "$tool" in
    scrot)          scrot "$outfile" >/dev/null 2>&1 ;;
    screencapture)  screencapture -x "$outfile" >/dev/null 2>&1 ;;
    import)         import -window root "$outfile" >/dev/null 2>&1 ;;
    none)
      err "No screenshot tool found. Install scrot (Linux) or use macOS screencapture."
      return 1
      ;;
  esac
}

guess_lang() {
  case "$1" in
    *.py)  echo "python" ;;
    *.sh)  echo "bash" ;;
    *.js)  echo "javascript" ;;
    *.go)  echo "go" ;;
    *.rb)  echo "ruby" ;;
    *.c)   echo "c" ;;
    *.cpp) echo "cpp" ;;
    *.php) echo "php" ;;
    *.rs)  echo "rust" ;;
    *)     echo "" ;;
  esac
}

is_image() {
  case "$1" in
    *.png|*.jpg|*.jpeg|*.gif|*.bmp|*.webp) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------- init ----------

cmd_init() {
  echo "Writify v${WRITIFY_VERSION} — global setup"
  local install_dir="/usr/local/bin"
  local self_path
  self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

  if [ -w "$install_dir" ] 2>/dev/null; then
    cp "$self_path" "$install_dir/writify" && chmod +x "$install_dir/writify"
    ok "Installed to $install_dir/writify — 'writify' is now a global command."
  else
    info "No write access to $install_dir — trying sudo..."
    if sudo cp "$self_path" "$install_dir/writify" 2>/dev/null; then
      sudo chmod +x "$install_dir/writify"
      ok "Installed to $install_dir/writify — 'writify' is now a global command."
    else
      local user_bin="$HOME/.local/bin"
      mkdir -p "$user_bin"
      cp "$self_path" "$user_bin/writify" && chmod +x "$user_bin/writify"
      ok "Installed to $user_bin/writify"
      echo "  Add this to your shell profile if not already present:"
      echo '  export PATH="$HOME/.local/bin:$PATH"'
    fi
  fi

  read -rp "Default git author name (blank to skip): " gname
  read -rp "Default git author email (blank to skip): " gemail
  if [ -n "$gname" ]; then git config --global user.name "$gname"; fi
  if [ -n "$gemail" ]; then git config --global user.email "$gemail"; fi

  local tool
  tool=$(detect_screenshot_tool)
  if [ "$tool" = "none" ]; then
    echo "  ⚠ No screenshot tool detected. Install 'scrot' (Linux) for 'writify capture' to work."
  else
    ok "Screenshot tool detected: $tool"
  fi

  ok "Writify ready. Run: writify start <workspace-name>"
}

# ---------- start ----------

cmd_start() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    err "Usage: writify start <name>"
    exit 1
  fi
  if [ -d "$name" ]; then
    err "Directory '$name' already exists."
    exit 1
  fi

  mkdir -p "$name"/{screenshots,artifacts,scripts,.github/workflows,"$WRITIFY_DIR"}
  cd "$name" || exit 1

  git init -q

  read -rp "Short description of this workspace: " description
  read -rp "Author name [$(git config user.name 2>/dev/null)]: " author
  author="${author:-$(git config user.name 2>/dev/null)}"
  read -rp "Git remote URL (blank to skip for now): " remote

  cat > "$CONFIG_FILE" <<EOF
NAME="$name"
DESCRIPTION="$description"
AUTHOR="$author"
REMOTE="$remote"
CREATED="$(ts)"
EOF

  : > "$SOLVE_LOG"
  : > "$ATTACH_LOG"
  echo "0" > "$COUNTER_FILE"

  cat > .gitignore <<'EOF'
.writify/
*.pyc
__pycache__/
.DS_Store
EOF

  cat > scripts/validate.sh <<'EOF'
#!/usr/bin/env bash
# Writify local/CI validation — shared by `writify` local checks and GitHub Actions
set -uo pipefail
fail=0

if [ ! -f README.md ] || [ ! -s README.md ]; then
  echo "✗ README.md missing or empty"
  fail=1
else
  echo "✓ README.md present"
fi

# Check every image reference in README resolves to an existing file
if [ -f README.md ]; then
  while IFS= read -r ref; do
    path=$(echo "$ref" | sed -E 's/.*\(([^)]+)\).*/\1/')
    if [ -n "$path" ] && [ ! -f "$path" ]; then
      echo "✗ Broken image reference: $path"
      fail=1
    fi
  done < <(grep -oE '!\[[^]]*\]\([^)]+\)' README.md || true)
  echo "✓ Image references checked"
fi

if [ $fail -ne 0 ]; then
  echo "VALIDATION FAILED"
  exit 1
fi
echo "VALIDATION PASSED"
EOF
  chmod +x scripts/validate.sh

  cat > .github/workflows/validate.yml <<'EOF'
name: Writify Validate
on: [push, pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run validation
        run: bash scripts/validate.sh
EOF

  echo "# $name" > README.md
  echo "" >> README.md
  echo "_Writeup not yet built — run \`writify build\`._" >> README.md

  git add -A
  git commit -q -m "writify: initialize workspace ($name)"

  if [ -n "$remote" ]; then
    git remote add origin "$remote"
    ok "Remote 'origin' set to $remote"
  fi

  ok "Workspace '$name' created."
  start_daemon
  echo ""
  echo "cd $name  # then use: writify note / writify capture / writify attach / writify build / writify push"
}

# ---------- daemon ----------

start_daemon() {
  require_workspace 2>/dev/null || true
  if [ -f "$DAEMON_PID_FILE" ] && kill -0 "$(cat "$DAEMON_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    info "Capture daemon already running (PID $(cat "$DAEMON_PID_FILE"))."
    return
  fi
  : > "$TRIGGER_FILE"
  (
    while true; do
      if [ -s "$TRIGGER_FILE" ]; then
        : > "$TRIGGER_FILE"
        n=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" > "$COUNTER_FILE"
        outfile="screenshots/poc-$n.png"
        take_screenshot "$outfile" 2>/dev/null
        if [ -f "$outfile" ]; then
          echo "$(ts)|screenshot|$outfile" >> "$SOLVE_LOG"
        fi
      fi
      sleep 1
    done
  ) &
  disown
  echo $! > "$DAEMON_PID_FILE"
  ok "Background capture daemon started (PID $!)."
}

cmd_stop() {
  require_workspace
  if [ -f "$DAEMON_PID_FILE" ]; then
    kill "$(cat "$DAEMON_PID_FILE")" 2>/dev/null
    rm -f "$DAEMON_PID_FILE"
    ok "Capture daemon stopped."
  else
    info "No daemon running."
  fi
}

cmd_capture() {
  require_workspace
  if [ -f "$DAEMON_PID_FILE" ] && kill -0 "$(cat "$DAEMON_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    echo "1" > "$TRIGGER_FILE"
    sleep 1.2
    n=$(cat "$COUNTER_FILE")
    ok "Captured screenshots/poc-$n.png"
  else
    n=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$COUNTER_FILE"
    outfile="screenshots/poc-$n.png"
    if take_screenshot "$outfile"; then
      echo "$(ts)|screenshot|$outfile" >> "$SOLVE_LOG"
      ok "Captured $outfile (daemon not running, captured directly)"
    fi
  fi
}

# ---------- note ----------

cmd_note() {
  require_workspace
  local type="${1:-}"
  shift || true
  local text="$*"

  if [ -z "$type" ] || [ -z "$text" ]; then
    err "Usage: writify note <type> <text>"
    echo "Types: $NOTE_TYPES"
    exit 1
  fi

  local valid=0
  for t in $NOTE_TYPES; do
    [ "$t" = "$type" ] && valid=1
  done
  if [ "$valid" -ne 1 ]; then
    err "Invalid note type '$type'. Must be one of: $NOTE_TYPES"
    exit 1
  fi

  echo "$(ts)|note|$type|$text" >> "$SOLVE_LOG"
  ok "Note added [$type]"
}

# ---------- attach ----------

cmd_attach() {
  require_workspace
  local file="${1:-}"
  shift || true
  local caption="$*"

  if [ -z "$file" ] || [ ! -f "$file" ]; then
    err "Usage: writify attach <file> [caption]  (file must exist)"
    exit 1
  fi

  local basefile dest kind
  basefile=$(basename "$file")

  if is_image "$file"; then
    kind="image"
    dest="screenshots/$basefile"
  else
    kind="code"
    dest="artifacts/$basefile"
  fi

  cp "$file" "$dest"
  echo "$dest|$kind|$caption" >> "$ATTACH_LOG"
  ok "Attached $dest [$kind]"
}

# ---------- build ----------

cmd_build() {
  require_workspace
  read_config

  local out="README.md"
  {
    echo "# ${NAME:-Untitled}"
    echo ""
    echo "**Author:** ${AUTHOR:-unknown}  "
    echo "**Date:** $(date -u +%Y-%m-%d)  "
    echo ""
    if [ -n "${DESCRIPTION:-}" ]; then
      echo "## Overview"
      echo ""
      echo "$DESCRIPTION"
      echo ""
    fi

    for section in observation finding command dead_end result; do
      local heading
      case "$section" in
        observation) heading="Observations" ;;
        finding)     heading="Findings" ;;
        command)     heading="Commands" ;;
        dead_end)    heading="Dead Ends" ;;
        result)      heading="Results" ;;
      esac

      local lines
      lines=$(awk -F'|' -v t="$section" '$2=="note" && $3==t {print $0}' "$SOLVE_LOG")
      if [ -n "$lines" ]; then
        echo "## $heading"
        echo ""
        while IFS='|' read -r tstamp _ _ text; do
          if [ "$section" = "command" ]; then
            echo '```bash'
            echo "$text"
            echo '```'
          elif [ "$section" = "dead_end" ]; then
            echo "- ~~$text~~ _($tstamp)_"
          else
            echo "- $text _($tstamp)_"
          fi
        done <<< "$lines"
        echo ""
      fi
    done

    local shots
    shots=$(awk -F'|' '$2=="screenshot" {print $0}' "$SOLVE_LOG")
    if [ -n "$shots" ]; then
      echo "## Screenshots"
      echo ""
      while IFS='|' read -r tstamp _ path; do
        echo "![screenshot]($path)"
        echo ""
      done <<< "$shots"
    fi

    if [ -s "$ATTACH_LOG" ]; then
      echo "## Attachments"
      echo ""
      while IFS='|' read -r path kind caption; do
        if [ "$kind" = "image" ]; then
          echo "![${caption:-attachment}]($path)"
        else
          local lang
          lang=$(guess_lang "$path")
          echo "**${caption:-$path}**"
          echo ""
          echo '```'"$lang"
          cat "$path" 2>/dev/null
          echo '```'
        fi
        echo ""
      done < "$ATTACH_LOG"
    fi

    echo "---"
    echo "_Generated by Writify v${WRITIFY_VERSION} — $(ts)_"
  } > "$out"

  ts > "$LAST_BUILD_FILE"
  ok "README.md built."
}

# ---------- push ----------

cmd_push() {
  require_workspace
  read_config

  # rebuild if solve_log/attach_log newer than last build
  local need_build=0
  if [ ! -f "$LAST_BUILD_FILE" ]; then
    need_build=1
  elif [ "$SOLVE_LOG" -nt "$LAST_BUILD_FILE" ] || [ "$ATTACH_LOG" -nt "$LAST_BUILD_FILE" ]; then
    need_build=1
  fi
  if [ "$need_build" -eq 1 ]; then
    info "Changes detected since last build — rebuilding..."
    cmd_build
  fi

  while true; do
    echo ""
    echo "───────── README.md preview ─────────"
    head -n 40 README.md
    echo "───────────────────────────────────────"
    echo ""
    read -rp "Does this writeup need any revision before pushing? [y/N] " ans
    case "$ans" in
      y|Y)
        read -rp "What should be changed? " revision_note
        echo "$(ts)|revision_request|$revision_note" >> "$SOLVE_LOG"
        echo "Did you edit the README directly, or the underlying data (solve_log/config)? [readme/data]"
        read -rp "> " edit_target

        local editor="${EDITOR:-}"
        if [ -z "$editor" ]; then
          echo "No \$EDITOR set. Edit the files manually now, then press Enter to continue."
          if [ "$edit_target" = "data" ]; then
            echo "Edit: $SOLVE_LOG or $CONFIG_FILE"
          else
            echo "Edit: README.md"
          fi
          read -rp "Press Enter when done..." _
        else
          if [ "$edit_target" = "data" ]; then
            "$editor" "$SOLVE_LOG" "$CONFIG_FILE"
          else
            "$editor" README.md
          fi
        fi

        if [ "$edit_target" = "data" ]; then
          info "Rebuilding from updated data..."
          cmd_build
        else
          info "Keeping direct README edits as-is."
        fi
        continue
        ;;
      *)
        break
        ;;
    esac
  done

  git add -A
  git commit -q -m "solve: ${NAME:-workspace} $(date -u +%Y-%m-%d)" || info "Nothing new to commit."

  read_config
  if [ -z "${REMOTE:-}" ] && ! git remote get-url origin >/dev/null 2>&1; then
    read -rp "No remote configured. Git remote URL to push to: " remote
    if [ -n "$remote" ]; then
      git remote add origin "$remote"
      sed -i.bak "s#^REMOTE=.*#REMOTE=\"$remote\"#" "$CONFIG_FILE" 2>/dev/null || true
      rm -f "$CONFIG_FILE.bak"
    else
      err "No remote provided — cannot push. Commit is saved locally."
      exit 1
    fi
  fi

  local branch
  branch=$(git branch --show-current)
  [ -z "$branch" ] && branch="main" && git branch -M main

  if git push -u origin "$branch"; then
    ok "Pushed to origin/$branch."
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null)
    echo "CI validation will run automatically. Check: ${remote_url%.git}/actions"
  else
    err "Push failed. Check remote/credentials and try 'writify push' again."
    exit 1
  fi
}

# ---------- misc git wrappers ----------

cmd_pull()   { require_workspace; git pull; }
cmd_status() { require_workspace; git status; }
cmd_log()    { require_workspace; cat "$SOLVE_LOG" 2>/dev/null; }

# ---------- dispatch ----------

cmd="${1:-}"
shift || true

case "$cmd" in
  init)     cmd_init "$@" ;;
  start)    cmd_start "$@" ;;
  capture)  cmd_capture "$@" ;;
  note)     cmd_note "$@" ;;
  attach)   cmd_attach "$@" ;;
  build)    cmd_build "$@" ;;
  push)     cmd_push "$@" ;;
  pull)     cmd_pull "$@" ;;
  status)   cmd_status "$@" ;;
  log)      cmd_log "$@" ;;
  stop)     cmd_stop "$@" ;;
  ""|help|-h|--help)
    cat <<EOF
Writify v${WRITIFY_VERSION}

Usage: writify <command> [args]

Commands:
  init                       Global setup, installs 'writify' command
  start <name>               Create workspace, git init, start capture daemon
  capture                    Take a screenshot -> screenshots/poc-N.png
  note <type> <text>         Add note. Types: $NOTE_TYPES
  attach <file> [caption]    Attach code/image file to workspace
  build                      Generate README.md from notes + attachments
  push                       Revision checkpoint -> commit -> push -> CI
  pull                       git pull
  status                     git status
  log                        Print raw solve log
  stop                       Stop background capture daemon
EOF
    ;;
  *)
    err "Unknown command: $cmd"
    echo "Run 'writify help' for usage."
    exit 1
    ;;
esac
