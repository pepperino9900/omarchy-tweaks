#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

# Globals
DRY_RUN=false
TIMESTAMP() { date +%s; }

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
  local bak="${file}.$(TIMESTAMP).bak"
  cp -- "$file" "$bak"
  mv -- "$tmp" "$file"
  echo "Patched $file (backup: $bak)"
}

# Prerequisite: install ghostty
install_ghostty() {
  if command -v ghostty &> /dev/null; then
    return 0
  fi
  echo "ghostty not found"
  if command -v yay &> /dev/null; then
    echo "Installing ghostty with yay..."
    yay -S --noconfirm ghostty
  else
    echo "Package manager 'yay' not found. Please install ghostty manually."
    return 1
  fi
}
patch_hypr_bindings() {
  BINDINGS_FILE="$HOME/.config/hypr/bindings.conf"
  if [ -f "$BINDINGS_FILE" ]; then
  # transform command: sed writes to stdout
  transform="sed 's|\\\$terminal = uwsm app -- alacritty|\\\$terminal = uwsm app -- ghostty|g' '$BINDINGS_FILE'"
  apply_transform "$BINDINGS_FILE" "$transform"
  else
    echo "$BINDINGS_FILE not found, skipping patch."
  fi
}

patch_omarchy_menu() {
  MENU_FILE="$HOME/.local/share/omarchy/bin/omarchy-menu"
  if [ -f "$MENU_FILE" ]; then
  # Only operate on lines containing 'alacritty'. Replace alacritty -> ghostty,
  # remove --class forms (space or =) including quoted values, and collapse
  # internal duplicate spacing while preserving leading indentation.
    transform="sed -E '/alacritty/ { s/\\balacritty\\b/ghostty/g; s/--class(=| )[[:space:]]*[^[:space:]]+//g; s/([^[:space:]])[[:space:]]{2,}/\\1 /g }' '$MENU_FILE'"
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

install_ghostty || true
patch_env
patch_hypr_bindings
patch_omarchy_menu
