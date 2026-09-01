#!/usr/bin/env bash
#
# Installs the "global sudo timestamp + PreToolUse hook" workaround for
# running sudo from Claude Code over SSH/tmux, where SUDO_ASKPASS GUI
# helpers can't work (no X display) and the Bash tool has no PTY.
#
# What it does:
#   1. Installs /etc/sudoers.d/claude-global-timestamp (timestamp_type=global,
#      timestamp_timeout=20) — validated with `visudo -c` before AND after
#      it touches the live sudoers config. Requires an interactive sudo
#      password prompt (that's expected — this is the one-time bootstrap).
#   2. Installs ~/.claude/hooks/sudo-pty-check.sh — a PreToolUse hook that
#      probes `sudo -n true` before any Bash tool call containing `sudo`,
#      and asks you to authenticate in a real tty if the cache is cold.
#   3. Registers that hook under hooks.PreToolUse (matcher "Bash") in
#      ~/.claude/settings.json, merging with whatever is already there.
#
# Usage:
#   ./install.sh              install (safe to re-run; idempotent)
#   ./install.sh --uninstall  remove the sudoers drop-in, the hook file,
#                             and the settings.json entry
#
# Trust model: while the sudo cache is warm (up to 20 min after the last
# `sudo -v`), ANY process running as your user can sudo without a prompt —
# not just Claude. Same practical boundary as the interactive shell you're
# typing in. Fine for a single-user workstation under your own supervision;
# do not install this on a shared or multi-user machine, or for an
# unattended/autonomous agent.
set -euo pipefail

SUDOERS_DEST="/etc/sudoers.d/claude-global-timestamp"
HOOK_DIR="$HOME/.claude/hooks"
HOOK_FILE="$HOOK_DIR/sudo-pty-check.sh"
SETTINGS="$HOME/.claude/settings.json"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}

find_visudo() {
    command -v visudo 2>/dev/null && return 0
    for p in /usr/sbin/visudo /sbin/visudo; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    die "visudo not found (looked on PATH, /usr/sbin, /sbin)"
}

write_hook_script() {
    mkdir -p "$HOOK_DIR"
    cat > "$HOOK_FILE" <<'HOOK_EOF'
#!/bin/bash
# PreToolUse hook (Bash matcher) — sudo-over-SSH-without-a-PTY workaround.
# Requires /etc/sudoers.d/claude-global-timestamp (timestamp_type=global),
# installed by install.sh in this directory's parent workaround package.
set -o pipefail

input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -z "$command" ] && exit 0

# Only care about commands that actually invoke sudo as a command word.
printf '%s' "$command" | grep -Eq '(^|[^a-zA-Z0-9_/.-])sudo([[:space:]]|$)' || exit 0

# Cache-management / explicit non-interactive invocations never need to
# prompt: sudo -v (refresh), sudo -k / -K (drop cache), sudo -n (already
# non-interactive; it will just fail on its own if the cache is cold).
if printf '%s' "$command" | grep -Eq '(^|[^a-zA-Z0-9_/.-])sudo[[:space:]]+-[vkKn]([[:space:]]|$)'; then
    jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"sudo cache-management or non-interactive invocation"}}'
    exit 0
fi

if sudo -n true 2>/dev/null; then
    jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"sudo cache warm"}}'
    exit 0
fi

msg='Sudo cache is cold (no PTY available to this Bash tool call). Press Ctrl-Z, run `sudo -v`, then `fg` — or authenticate sudo in a sibling tmux pane / second SSH session — then tell me to retry. Cache lasts 20 minutes; `sudo -k` anywhere ends it early.'
jq -n --arg msg "$msg" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":$msg}}'
HOOK_EOF
    chmod +x "$HOOK_FILE"
    log "hook script installed at $HOOK_FILE"
}

install_sudoers_dropin() {
    local visudo tmp
    visudo=$(find_visudo)
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' RETURN
    cat > "$tmp" <<'SUDOERS_EOF'
Defaults timestamp_type=global
Defaults timestamp_timeout=20
SUDOERS_EOF

    log "validating sudoers syntax before touching /etc/sudoers.d ..."
    "$visudo" -c -f "$tmp" || die "sudoers syntax check failed on the generated drop-in — aborting, nothing was installed"

    log "installing $SUDOERS_DEST (requires sudo password)"
    sudo install -m 0440 -o root -g root "$tmp" "$SUDOERS_DEST"

    log "re-validating full sudoers config after install ..."
    if ! sudo "$visudo" -c; then
        warn "post-install sudoers check FAILED — removing $SUDOERS_DEST to avoid leaving sudo broken"
        sudo rm -f "$SUDOERS_DEST"
        die "aborted: sudoers config would not have parsed; nothing left installed"
    fi
    log "sudoers drop-in installed and validated"
}

register_hook_in_settings() {
    mkdir -p "$(dirname "$SETTINGS")"
    if [ ! -f "$SETTINGS" ]; then
        echo '{}' > "$SETTINGS"
    fi
    jq -e . "$SETTINGS" >/dev/null || die "$SETTINGS is not valid JSON — fix it manually before re-running"

    local backup
    backup="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$SETTINGS" "$backup"
    log "backed up existing settings to $backup"

    local tmp
    tmp=$(mktemp)
    jq --arg cmd "$HOOK_FILE" '
      .hooks = (.hooks // {}) |
      .hooks.PreToolUse = (.hooks.PreToolUse // []) |
      (.hooks.PreToolUse | any(.matcher == "Bash" and ((.hooks // []) | any(.command == $cmd)))) as $already_present |
      if $already_present then .
      else .hooks.PreToolUse += [{"matcher": "Bash", "hooks": [{"type": "command", "command": $cmd}]}]
      end
    ' "$SETTINGS" > "$tmp"

    jq -e . "$tmp" >/dev/null || die "merge produced invalid JSON — see $tmp, original untouched"
    mv "$tmp" "$SETTINGS"

    jq -e --arg cmd "$HOOK_FILE" '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == $cmd)' "$SETTINGS" >/dev/null \
        || die "hook entry missing from $SETTINGS after merge — restore from $backup"
    log "hook registered in $SETTINGS (PreToolUse / Bash)"
}

uninstall() {
    log "removing sudoers drop-in (requires sudo password)"
    sudo rm -f "$SUDOERS_DEST"

    if [ -f "$SETTINGS" ]; then
        local backup tmp
        backup="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
        cp -p "$SETTINGS" "$backup"
        tmp=$(mktemp)
        jq --arg cmd "$HOOK_FILE" '
          if .hooks.PreToolUse then
            .hooks.PreToolUse = [
              .hooks.PreToolUse[]
              | if .matcher == "Bash" then .hooks = [.hooks[] | select(.command != $cmd)] else . end
            ] | .hooks.PreToolUse = [.hooks.PreToolUse[] | select((.hooks | length) > 0)]
          else . end
        ' "$SETTINGS" > "$tmp"
        jq -e . "$tmp" >/dev/null && mv "$tmp" "$SETTINGS" || die "uninstall merge produced invalid JSON — see $tmp, original backed up at $backup"
        log "removed hook entry from $SETTINGS (backup at $backup)"
    fi

    rm -f "$HOOK_FILE"
    log "removed $HOOK_FILE"
    log "uninstall complete"
}

main() {
    require_cmd jq
    require_cmd sudo

    if [ "${1:-}" = "--uninstall" ]; then
        uninstall
        exit 0
    fi

    log "this will modify /etc/sudoers.d and ~/.claude/settings.json — see the header comment for the trust model"
    install_sudoers_dropin
    write_hook_script
    register_hook_in_settings

    cat <<EOF

Done. To use it:
  1. In Claude Code, open /hooks once (or restart the session) so the new
     hook is picked up.
  2. When Claude runs a Bash tool call containing 'sudo' and the cache is
     cold, it will ask you to Ctrl-Z, run 'sudo -v', then 'fg' — do that in
     the real terminal (not Claude's '!' prefix, which has no PTY either),
     then tell Claude to retry.
  3. To remove everything: $0 --uninstall
EOF
}

main "$@"
