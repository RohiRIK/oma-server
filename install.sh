#!/usr/bin/env bash
# install.sh - Installer for oma-server on Omarchy systems
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TARGET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/server-mode"
BIN_DIR="$HOME/.local/bin"
HOOK_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/hooks/post-boot.d"

echo "==> Installing oma-server plugin to: $TARGET_DIR"
mkdir -p "$TARGET_DIR/bin" "$TARGET_DIR/lib" "$BIN_DIR" "$HOOK_DIR"

# Copy library and binary files
cp -r "$SCRIPT_DIR/lib/"* "$TARGET_DIR/lib/"
cp "$SCRIPT_DIR/bin/oma-server" "$TARGET_DIR/bin/omarchy-server-mode"
chmod +x "$TARGET_DIR/bin/omarchy-server-mode" "$TARGET_DIR/lib/"*.sh

# Install default config if not already present
if [[ ! -f "$TARGET_DIR/config.toml" ]]; then
    echo "==> Creating default configuration at: $TARGET_DIR/config.toml"
    cp "$SCRIPT_DIR/config/config.toml" "$TARGET_DIR/config.toml"
else
    echo "==> Existing config.toml preserved."
fi

# Install post-boot hook
echo "==> Installing boot recovery hook to: $HOOK_DIR"
cp "$SCRIPT_DIR/hooks/post-boot.d/99-server-profile-check.sh" "$HOOK_DIR/"
chmod +x "$HOOK_DIR/99-server-profile-check.sh"

# Symlinks in ~/.local/bin
echo "==> Linking binaries in $BIN_DIR"
ln -sf "$TARGET_DIR/bin/omarchy-server-mode" "$BIN_DIR/oma-server"
ln -sf "$TARGET_DIR/bin/omarchy-server-mode" "$BIN_DIR/omarchy-server-mode"

echo ""
echo "[OK] oma-server successfully installed!"
echo "Run 'oma-server status' or 'oma-server diff' to verify."
