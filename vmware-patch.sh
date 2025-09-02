#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

# Globals
DRY_RUN=false
TIMESTAMP() { date +%s; }
BACKUP_DIR="/tmp/backup/vmware"
TERMINAL_CMD="${TERMINAL_CMD:-ghostty}"

usage() {
  cat <<EOF
Usage: ${0##*/} [--dry-run] [--help]

Options:
  --dry-run   Show changes that would be made, do not modify files
  --help      Show this help
EOF
}

run_or_echo() {
  if [ "$DRY_RUN" = true ]; then
    echo "+ $*"
  else
    eval "$*"
  fi
}

# Apply a transform to a file idempotently.
# Arguments: <file> <transform-cmd-that-writes-to-stdout>
apply_transform() {
  local file="$1" transform_cmd="$2" tmp
  if [ ! -f "$file" ]; then
    echo "$file not found, skipping."
    return 0
  fi
  tmp=$(mktemp) || { echo "mktemp failed" >&2; return 1; }
  # shellcheck disable=SC2086
  eval "$transform_cmd" > "$tmp"
  if cmp -s -- "$file" "$tmp"; then
    echo "No changes needed for $file"
    rm -f -- "$tmp"
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "Changes for $file:"
    diff -u -- "$file" "$tmp" || true
    rm -f -- "$tmp"
    return 0
  fi
  mkdir -p -- "$BACKUP_DIR"
  local bak="$BACKUP_DIR/$(basename "$file").$(TIMESTAMP).bak"
  cp -- "$file" "$bak"
  mv -- "$tmp" "$file"
  echo "Patched $file (backup: $bak)"
}

# verify_changes: check GSK_RENDERER appears exactly once and omarchy-menu perms are 755
verify_changes() {
  local env_file="$HOME/.config/uwsm/env"
  local menu_file="$HOME/.local/share/omarchy/bin/omarchy-menu"

  # Check GSK_RENDERER line exists exactly once
  if [ -f "$env_file" ]; then
    local count
    count=$(grep -c '^export GSK_RENDERER=' "$env_file" || true)
    if [ "$count" -ne 1 ]; then
      echo "verify_changes: expected exactly one GSK_RENDERER line in $env_file, found: $count"
      return 1
    fi
  else
    echo "verify_changes: $env_file not found"
    return 1
  fi

  # Check omarchy-menu permission
  if [ -f "$menu_file" ]; then
    mode=$(stat -c '%a' "$menu_file")
    if [ "$mode" != "755" ]; then
      echo "verify_changes: expected $menu_file mode 755, found: $mode"
      return 1
    fi
  else
    echo "verify_changes: $menu_file not found"
    return 1
  fi

  echo "verify_changes: OK"
  return 0
}

# Prerequisite: install the configured terminal (TERMINAL_CMD)
install_terminal() {
  if command -v "$TERMINAL_CMD" &> /dev/null; then
    return 0
  fi
  echo "$TERMINAL_CMD not found"
  if command -v yay &> /dev/null; then
    echo "Installing $TERMINAL_CMD with yay..."
    if ! yay -S --noconfirm "$TERMINAL_CMD"; then
      echo "Failed to install $TERMINAL_CMD via yay"
      exit 1
    fi
  else
    echo "Package manager 'yay' not found. Please install $TERMINAL_CMD manually."
    exit 1
  fi
  # Final check
  if ! command -v "$TERMINAL_CMD" &> /dev/null; then
    echo "$TERMINAL_CMD still not available after attempted install"
    exit 1
  fi
}
patch_hypr_bindings() {
  BINDINGS_FILE="$HOME/.config/hypr/bindings.conf"
  if [ -f "$BINDINGS_FILE" ]; then
  # transform command: sed writes to stdout
    transform="sed 's|\\\$terminal = uwsm app -- alacritty|\\\$terminal = uwsm app -- ${TERMINAL_CMD}|g' '$BINDINGS_FILE'"
  apply_transform "$BINDINGS_FILE" "$transform"
  else
    echo "$BINDINGS_FILE not found, skipping patch."
  fi
}

patch_omarchy_menu() {
  MENU_FILE="$HOME/.local/share/omarchy/bin/omarchy-menu"
  if [ -f "$MENU_FILE" ]; then
  # Only operate on lines containing 'alacritty'. Replace alacritty -> ghostty,
    # Only operate on lines containing 'alacritty'. Replace alacritty -> the
    # configured terminal, remove --class forms (space or =) including quoted
    # values, and collapse internal duplicate spacing while preserving leading indentation.
  transform="sed -E '/alacritty/ { s/\\balacritty\\b/${TERMINAL_CMD}/g; s/--class(=| )[[:space:]]*[^[:space:]]+//g; s/([^[:space:]])[[:space:]]{2,}/\\1 /g }' '$MENU_FILE'"
  apply_transform "$MENU_FILE" "$transform"
  else
    echo "$MENU_FILE not found, skipping patch."
  fi
}

patch_env() {
  ENV_FILE="$HOME/.config/uwsm/env"
  if [ ! -f "$ENV_FILE" ]; then
    echo "$ENV_FILE not found, skipping env patch."
    return 0
  fi
  transform="(printf '%s\n' 'export GSK_RENDERER=cairo'; awk '{ if (\$0 == \"export TERMINAL=alacritty\") { print \"export TERMINAL=ghostty\" } else { print \$0 } }' '$ENV_FILE')"
    transform="(printf '%s\n' 'export GSK_RENDERER=cairo'; awk '{ if (\$0 == \"export TERMINAL=alacritty\") { print \"export TERMINAL=${TERMINAL_CMD}\" } else { print \$0 } }' '$ENV_FILE')"
  apply_transform "$ENV_FILE" "$transform"
}

# Main execution
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 2 ;;
  esac
done

install_terminal
patch_env
patch_hypr_bindings
patch_omarchy_menu

verify_changes || true
