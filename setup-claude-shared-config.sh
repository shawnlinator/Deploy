#!/usr/bin/env bash
# Install Claude Code for root and a chosen less-privileged user, then share
# session/config history between them via a symlink + auto-chown hooks.
#
# Must be run as root. Re-running is safe (idempotent).

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "error: this script must be run as root." >&2
  exit 1
fi

read -rp "Username of the less-privileged user to sync Claude Code config with: " TARGET_USER

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "error: user '$TARGET_USER' does not exist." >&2
  exit 1
fi

TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
  echo "error: could not resolve a home directory for '$TARGET_USER'." >&2
  exit 1
fi

echo "==> Installing Claude Code natively for root..."
curl -fsSL https://claude.ai/install.sh | bash

echo "==> Installing Claude Code natively for $TARGET_USER..."
# Each account gets its own real binary in its own $HOME — the installer
# refuses `sudo <script>` from a non-root user and always installs under
# $HOME, so there is no supported "one shared system binary" mode.
su - "$TARGET_USER" -c 'curl -fsSL https://claude.ai/install.sh | bash'

echo "==> Ensuring jq is available (needed to merge hooks into settings.json)..."
if ! command -v jq >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y jq
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y jq
  elif command -v yum >/dev/null 2>&1; then
    yum install -y jq
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache jq
  elif command -v brew >/dev/null 2>&1; then
    brew install jq
  else
    echo "error: jq is required but not installed, and no supported package manager was found. Install jq manually and re-run." >&2
    exit 1
  fi
fi

USER_CLAUDE_DIR="$TARGET_HOME/.claude"
ROOT_CLAUDE_DIR="/root/.claude"

echo "==> Ensuring $USER_CLAUDE_DIR exists and is owned by $TARGET_USER..."
mkdir -p "$USER_CLAUDE_DIR"
chown -R "$TARGET_USER:$TARGET_USER" "$USER_CLAUDE_DIR"

echo "==> Pointing $ROOT_CLAUDE_DIR at $USER_CLAUDE_DIR..."
if [ -L "$ROOT_CLAUDE_DIR" ]; then
  if [ "$(readlink -f "$ROOT_CLAUDE_DIR")" = "$(readlink -f "$USER_CLAUDE_DIR")" ]; then
    echo "    already symlinked correctly, skipping."
  else
    rm "$ROOT_CLAUDE_DIR"
    ln -s "$USER_CLAUDE_DIR" "$ROOT_CLAUDE_DIR"
  fi
elif [ -e "$ROOT_CLAUDE_DIR" ]; then
  BACKUP="${ROOT_CLAUDE_DIR}.bak.$(date +%Y%m%d%H%M%S)"
  echo "    $ROOT_CLAUDE_DIR already exists as a real directory; backing it up to $BACKUP"
  mv "$ROOT_CLAUDE_DIR" "$BACKUP"
  ln -s "$USER_CLAUDE_DIR" "$ROOT_CLAUDE_DIR"
else
  ln -s "$USER_CLAUDE_DIR" "$ROOT_CLAUDE_DIR"
fi

echo "==> Installing chown-sync hooks into the shared settings.json..."
SETTINGS_FILE="$USER_CLAUDE_DIR/settings.json"
[ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"

# Only fires when the invoking uid is 0, so it's a harmless no-op when
# TARGET_USER runs claude (this settings.json is shared via the symlink above).
CHOWN_CMD="[ \"\$(id -u)\" = \"0\" ] && chown -R ${TARGET_USER}:${TARGET_USER} ${USER_CLAUDE_DIR} 2>/dev/null; true"

TMP_FILE=$(mktemp)
jq --arg cmd "$CHOWN_CMD" '
  .hooks //= {} |
  .hooks.SessionStart //= [] |
  .hooks.SessionEnd //= [] |
  .hooks.SessionStart = (
    if ([.hooks.SessionStart[].hooks[]?.command] | index($cmd)) then .hooks.SessionStart
    else .hooks.SessionStart + [{"hooks": [{"type": "command", "command": $cmd}]}]
    end
  ) |
  .hooks.SessionEnd = (
    if ([.hooks.SessionEnd[].hooks[]?.command] | index($cmd)) then .hooks.SessionEnd
    else .hooks.SessionEnd + [{"hooks": [{"type": "command", "command": $cmd}]}]
    end
  )
' "$SETTINGS_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$SETTINGS_FILE"

chown "$TARGET_USER:$TARGET_USER" "$SETTINGS_FILE"

echo "==> Done."
echo "    root:  $(su - root -c 'command -v claude' 2>/dev/null || echo '~/.local/bin/claude')"
echo "    $TARGET_USER: $(su - "$TARGET_USER" -c 'command -v claude' 2>/dev/null || echo "$TARGET_HOME/.local/bin/claude")"
echo "    $ROOT_CLAUDE_DIR -> $USER_CLAUDE_DIR (shared session/config history)"
echo "    SessionStart/SessionEnd hooks will re-chown $USER_CLAUDE_DIR to $TARGET_USER after any root session."
exit 0
