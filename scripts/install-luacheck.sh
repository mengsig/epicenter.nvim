#!/usr/bin/env bash
# Installs a pinned, sha256-verified luacheck standalone binary into a bin
# dir. luarocks manifest mirrors are flaky (they periodically 404 the Lua
# 5.1 rockspec lookup luacheck needs), so the GitHub release binary is the
# primary path and `luarocks install luacheck` only runs as a fallback.
#
#   scripts/install-luacheck.sh [bin-dir]
#
# Prints the installed luacheck's path (or just "luacheck" when the fallback
# used luarocks, which puts it on PATH itself) to stdout on success.
set -euo pipefail

LUACHECK_VERSION="1.2.0"
LUACHECK_SHA256="d68da17fca0697d9e2fb04201f3884abd259fa558b3a449bccaed47f1390defc"
LUACHECK_URL="https://github.com/lunarmodules/luacheck/releases/download/v${LUACHECK_VERSION}/luacheck"

bin_dir="${1:-$HOME/.local/bin}"
dest="$bin_dir/luacheck"

verify_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    echo "$LUACHECK_SHA256  $file" | sha256sum --check --status
  elif command -v shasum >/dev/null 2>&1; then
    echo "$LUACHECK_SHA256  $file" | shasum -a 256 --check --status
  else
    echo "install-luacheck: no sha256sum/shasum available to verify the download" >&2
    return 1
  fi
}

try_binary_download() {
  # Upstream only publishes a Linux x86_64 binary; other platforms go
  # straight to the luarocks fallback.
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  if [ "$os" != "Linux" ] || [ "$arch" != "x86_64" ]; then
    echo "install-luacheck: no upstream binary for $os/$arch, skipping to fallback" >&2
    return 1
  fi
  command -v curl >/dev/null 2>&1 || { echo "install-luacheck: curl not available" >&2; return 1; }

  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL -o "$tmp" "$LUACHECK_URL"; then
    echo "install-luacheck: download of $LUACHECK_URL failed" >&2
    rm -f "$tmp"
    return 1
  fi
  if ! verify_sha256 "$tmp"; then
    echo "install-luacheck: sha256 mismatch for downloaded binary, discarding" >&2
    rm -f "$tmp"
    return 1
  fi
  mkdir -p "$bin_dir"
  chmod +x "$tmp"
  mv "$tmp" "$dest"
  return 0
}

if try_binary_download; then
  echo "$dest"
  exit 0
fi

echo "install-luacheck: falling back to luarocks install luacheck" >&2
command -v luarocks >/dev/null 2>&1 || {
  echo "install-luacheck: luarocks not available - cannot install luacheck" >&2
  exit 1
}
luarocks install luacheck
echo "luacheck"
