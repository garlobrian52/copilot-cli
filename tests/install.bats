#!/usr/bin/env bats
# tests/install.bats - Comprehensive tests for install.sh

SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/install.sh"

# =============================================================================
# Helpers
# =============================================================================

# Write a mock executable into $MOCK_BIN
create_mock() {
  local name="$1" body="$2"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$MOCK_BIN/$name"
  chmod +x "$MOCK_BIN/$name"
}

# Create a minimal valid tar.gz that contains a 'copilot' binary
create_test_tarball() {
  local target="$1" tmp
  tmp="$(command mktemp -d)"
  printf '#!/bin/sh\necho copilot\n' > "$tmp/copilot"
  command tar -czf "$target" -C "$tmp" copilot
  command rm -rf "$tmp"
}

# Default curl mock: copies the test tarball when downloading .tar.gz,
# fails for anything else (so checksum download is skipped by default).
default_curl_mock() {
  create_mock "curl" "
args=(\"\$@\")
output=\"\"
for i in \"\${!args[@]}\"; do
  if [[ \"\${args[\$i]}\" == \"-o\" ]]; then
    output=\"\${args[\$(( i + 1 ))]}\"
    break
  fi
done
if [[ \"\$output\" == *.tar.gz ]]; then
  cp \"$TEST_TARBALL\" \"\$output\"
  exit 0
fi
exit 1"
}

# Curl mock that also writes a (dummy) checksums file for the given tarball name
checksums_curl_mock() {
  local tarball_name="$1"
  create_mock "curl" "
args=(\"\$@\")
output=\"\"
for i in \"\${!args[@]}\"; do
  if [[ \"\${args[\$i]}\" == \"-o\" ]]; then
    output=\"\${args[\$(( i + 1 ))]}\"
    break
  fi
done
if [[ \"\$output\" == *.tar.gz ]]; then
  cp \"$TEST_TARBALL\" \"\$output\"
elif [[ \"\$output\" == *.txt ]]; then
  echo \"deadbeef  $tarball_name\" > \"\$output\"
fi
exit 0"
}

# Restrict PATH to only $MOCK_BIN, symlinking essential system tools so the
# script can still run - but tools not symlinked (e.g. sha256sum, curl) are
# invisible to 'command -v'.
#
# Tools included: tar and gzip (for tarball ops), file utilities (mktemp,
# mkdir, chmod, rm, cp), basename (for shell detection), and the runtime
# needed to launch the script itself (setsid, bash).
use_restricted_path() {
  for cmd in tar gzip mktemp mkdir chmod rm cp basename setsid bash; do
    local real_path
    real_path="$(PATH="$_ORIG_PATH" command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$real_path" ]]; then
      ln -sf "$real_path" "$MOCK_BIN/$cmd"
    fi
  done
  export PATH="$MOCK_BIN"
}

setup() {
  MOCK_BIN="$(command mktemp -d)"
  MOCK_HOME="$(command mktemp -d)"
  TARBALL_DIR="$(command mktemp -d)"
  TEST_TARBALL="$TARBALL_DIR/copilot.tar.gz"
  create_test_tarball "$TEST_TARBALL"

  # Build a safe original PATH with any copilot-containing dirs stripped out,
  # so a pre-installed system 'copilot' binary cannot interfere with tests.
  local _safe_path="" _dir
  while IFS= read -r _dir; do
    [[ -n "$_dir" && ! -x "$_dir/copilot" ]] && _safe_path+="${_safe_path:+:}$_dir"
  done < <(tr ':' '\n' <<< "$PATH")

  export _ORIG_PATH="$_safe_path"
  export PATH="$MOCK_BIN:$_safe_path"
  export HOME="$MOCK_HOME"

  # Default environment: Linux x86_64, non-root user, curl available
  create_mock "uname" '
case "$1" in
  -s) echo "Linux" ;;
  -m) echo "x86_64" ;;
esac'
  create_mock "id" 'echo 1000'
  default_curl_mock

  export PREFIX="$MOCK_HOME/install"
  export SHELL="/bin/bash"
  unset VERSION
  unset GITHUB_TOKEN
}

teardown() {
  command rm -rf "$MOCK_BIN" "$MOCK_HOME" "$TARBALL_DIR"
  export PATH="$_ORIG_PATH"
}

# =============================================================================
# General
# =============================================================================

@test "prints starting installation message" {
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installing GitHub Copilot CLI..."* ]]
}

@test "prints the download URL" {
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Downloading from:"* ]]
}

# =============================================================================
# Platform Detection
# =============================================================================

@test "detects Linux and uses linux in download URL" {
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"copilot-linux-"* ]]
}

@test "detects Darwin and uses darwin in download URL" {
  create_mock "uname" '
case "$1" in
  -s) echo "Darwin" ;;
  -m) echo "x86_64" ;;
esac'
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"copilot-darwin-"* ]]
}

@test "detects Windows and installs via winget" {
  create_mock "uname" 'case "$1" in -s) echo "MINGW64_NT" ;; esac'
  create_mock "winget" 'exit 0'
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Windows detected"* ]]
}

@test "fails on non-Linux/Darwin when winget is not available" {
  create_mock "uname" 'case "$1" in -s) echo "MINGW64_NT" ;; esac'
  run setsid bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"winget not found"* ]]
}

# =============================================================================
# Architecture Detection
# =============================================================================

@test "maps x86_64 to x64 in download URL" {
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"copilot-linux-x64"* ]]
}

@test "maps amd64 to x64 in download URL" {
  create_mock "uname" '
case "$1" in
  -s) echo "Linux" ;;
  -m) echo "amd64" ;;
esac'
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"copilot-linux-x64"* ]]
}

@test "maps aarch64 to arm64 in download URL" {
  create_mock "uname" '
case "$1" in
  -s) echo "Linux" ;;
  -m) echo "aarch64" ;;
esac'
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"copilot-linux-arm64"* ]]
}

@test "maps arm64 to arm64 in download URL" {
  create_mock "uname" '
case "$1" in
  -s) echo "Linux" ;;
  -m) echo "arm64" ;;
esac'
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"copilot-linux-arm64"* ]]
}

@test "fails on unsupported architecture" {
  create_mock "uname" '
case "$1" in
  -s) echo "Linux" ;;
  -m) echo "s390x" ;;
esac'
  run setsid bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unsupported architecture s390x"* ]]
}

# =============================================================================
# VERSION URL Construction
# =============================================================================

@test "empty VERSION downloads from latest release URL" {
  export VERSION=""
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"releases/latest/download"* ]]
}

@test "VERSION=latest downloads from latest release URL" {
  export VERSION="latest"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"releases/latest/download"* ]]
}

@test "VERSION=prerelease uses git ls-remote to find latest tag" {
  export VERSION="prerelease"
  create_mock "git" 'echo "abc123	refs/tags/v2.0.0-beta.1"'
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Latest prerelease version: v2.0.0-beta.1"* ]]
  [[ "$output" == *"releases/download/v2.0.0-beta.1"* ]]
}

@test "VERSION=prerelease fails when git is not available" {
  export VERSION="prerelease"
  use_restricted_path
  create_mock "uname" '
case "$1" in
  -s) echo "Linux" ;;
  -m) echo "x86_64" ;;
esac'
  create_mock "id" 'echo 1000'
  default_curl_mock
  export PREFIX="$MOCK_HOME/install"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"git is required"* ]]
}

@test "VERSION=prerelease fails when git ls-remote returns empty output" {
  export VERSION="prerelease"
  create_mock "git" 'echo ""'
  run setsid bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not determine prerelease version"* ]]
}

@test "specific VERSION with v prefix uses versioned download URL" {
  export VERSION="v3.1.0"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"releases/download/v3.1.0"* ]]
}

@test "specific VERSION without v prefix gets v prepended in URL" {
  export VERSION="3.1.0"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"releases/download/v3.1.0"* ]]
}

# =============================================================================
# GitHub Token Authentication
# =============================================================================

@test "GITHUB_TOKEN is passed as Authorization header in curl calls" {
  export GITHUB_TOKEN="test-token-abc"
  create_mock "curl" "
args=(\"\$@\")
output=\"\"
for i in \"\${!args[@]}\"; do
  if [[ \"\${args[\$i]}\" == \"-H\" ]] && [[ \"\${args[\$(( i + 1 ))]}\" == \"Authorization: token test-token-abc\" ]]; then
    echo AUTH_HEADER_PRESENT
  fi
  if [[ \"\${args[\$i]}\" == \"-o\" ]]; then
    output=\"\${args[\$(( i + 1 ))]}\"
  fi
done
if [[ \"\$output\" == *.tar.gz ]]; then
  cp \"$TEST_TARBALL\" \"\$output\"
  exit 0
fi
exit 1"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTH_HEADER_PRESENT"* ]]
}

@test "no Authorization header when GITHUB_TOKEN is unset" {
  unset GITHUB_TOKEN
  create_mock "curl" "
args=(\"\$@\")
output=\"\"
for i in \"\${!args[@]}\"; do
  if [[ \"\${args[\$i]}\" == \"-H\" ]] && [[ \"\${args[\$(( i + 1 ))]}\" == Authorization* ]]; then
    echo UNEXPECTED_AUTH_HEADER
  fi
  if [[ \"\${args[\$i]}\" == \"-o\" ]]; then
    output=\"\${args[\$(( i + 1 ))]}\"
  fi
done
if [[ \"\$output\" == *.tar.gz ]]; then
  cp \"$TEST_TARBALL\" \"\$output\"
  exit 0
fi
exit 1"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"UNEXPECTED_AUTH_HEADER"* ]]
}

# =============================================================================
# Download Tool Selection
# =============================================================================

@test "uses curl for download when curl is available" {
  create_mock "curl" "
args=(\"\$@\")
output=\"\"
for i in \"\${!args[@]}\"; do
  if [[ \"\${args[\$i]}\" == \"-o\" ]]; then
    output=\"\${args[\$(( i + 1 ))]}\"
  fi
done
echo CURL_CALLED
if [[ \"\$output\" == *.tar.gz ]]; then
  cp \"$TEST_TARBALL\" \"\$output\"
  exit 0
fi
exit 1"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CURL_CALLED"* ]]
}

@test "falls back to wget when curl is not available" {
  rm -f "$MOCK_BIN/curl"
  use_restricted_path
  create_mock "uname" '
case "$1" in
  -s) echo "Linux" ;;
  -m) echo "x86_64" ;;
esac'
  create_mock "id" 'echo 1000'
  create_mock "wget" "
args=(\"\$@\")
output=\"\"
for i in \"\${!args[@]}\"; do
  if [[ \"\${args[\$i]}\" == \"-qO\" ]]; then
    output=\"\${args[\$(( i + 1 ))]}\"
    break
  fi
done
if [[ \"\$output\" == *.tar.gz ]]; then
  cp \"$TEST_TARBALL\" \"\$output\"
  exit 0
fi
exit 1"
  export PREFIX="$MOCK_HOME/install"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"installed"* ]]
}

@test "fails with error when neither curl nor wget is available" {
  rm -f "$MOCK_BIN/curl"
  use_restricted_path
  create_mock "uname" '
case "$1" in
  -s) echo "Linux" ;;
  -m) echo "x86_64" ;;
esac'
  create_mock "id" 'echo 1000'
  run setsid bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Neither curl nor wget found"* ]]
}

# =============================================================================
# Checksum Validation
# =============================================================================

@test "validates checksum successfully using sha256sum" {
  checksums_curl_mock "copilot-linux-x64.tar.gz"
  create_mock "sha256sum" 'exit 0'
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ Checksum validated"* ]]
}

@test "fails installation when sha256sum reports a mismatch" {
  checksums_curl_mock "copilot-linux-x64.tar.gz"
  create_mock "sha256sum" 'exit 1'
  run setsid bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Checksum validation failed"* ]]
}

@test "validates checksum using shasum when sha256sum is unavailable" {
  use_restricted_path
  create_mock "uname" '
case "$1" in
  -s) echo "Linux" ;;
  -m) echo "x86_64" ;;
esac'
  create_mock "id" 'echo 1000'
  checksums_curl_mock "copilot-linux-x64.tar.gz"
  create_mock "shasum" 'exit 0'
  export PREFIX="$MOCK_HOME/install"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"✓ Checksum validated"* ]]
}

@test "fails installation when shasum reports a mismatch" {
  use_restricted_path
  create_mock "uname" '
case "$1" in
  -s) echo "Linux" ;;
  -m) echo "x86_64" ;;
esac'
  create_mock "id" 'echo 1000'
  checksums_curl_mock "copilot-linux-x64.tar.gz"
  create_mock "shasum" 'exit 1'
  export PREFIX="$MOCK_HOME/install"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Checksum validation failed"* ]]
}

@test "warns and continues when checksums file is available but no checksum tool exists" {
  use_restricted_path
  create_mock "uname" '
case "$1" in
  -s) echo "Linux" ;;
  -m) echo "x86_64" ;;
esac'
  create_mock "id" 'echo 1000'
  checksums_curl_mock "copilot-linux-x64.tar.gz"
  # No sha256sum or shasum added to MOCK_BIN
  export PREFIX="$MOCK_HOME/install"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: No sha256sum or shasum found"* ]]
}

@test "skips checksum validation silently when checksums file is not downloadable" {
  # Default curl mock returns non-zero for non-.tar.gz URLs (checksums unavailable)
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Checksum validated"* ]]
  [[ "$output" != *"Checksum validation failed"* ]]
  [[ "$output" != *"No sha256sum"* ]]
}

# =============================================================================
# Tarball Validation
# =============================================================================

@test "fails when the downloaded file is not a valid tarball" {
  create_mock "curl" "
args=(\"\$@\")
output=\"\"
for i in \"\${!args[@]}\"; do
  if [[ \"\${args[\$i]}\" == \"-o\" ]]; then
    output=\"\${args[\$(( i + 1 ))]}\"
    break
  fi
done
if [[ \"\$output\" == *.tar.gz ]]; then
  echo 'this is not a valid tarball' > \"\$output\"
  exit 0
fi
exit 1"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a valid tarball"* ]]
}

# =============================================================================
# Installation Directory
# =============================================================================

@test "installs to HOME/.local/bin for non-root user when PREFIX is unset" {
  unset PREFIX
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.local/bin/copilot"* ]]
}

@test "installs to /usr/local/bin for root user when PREFIX is unset" {
  unset PREFIX
  create_mock "id" 'echo 0'
  # We may not have write permission to /usr/local/bin in this environment, so
  # we don't assert a specific exit code - we only verify the path appears in
  # the output, confirming the root-user PREFIX logic is exercised.
  run setsid bash "$SCRIPT"
  [[ "$output" == *"/usr/local"* ]]
}

@test "installs to custom PREFIX/bin when PREFIX is set" {
  export PREFIX="$MOCK_HOME/myprefix"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$MOCK_HOME/myprefix/bin/copilot"* ]]
}

@test "fails when the install directory cannot be created" {
  export PREFIX="/proc/nonexistent/readonly"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not create directory"* ]]
}

# =============================================================================
# Existing Binary Replacement Notice
# =============================================================================

@test "shows replacement notice when a copilot binary already exists" {
  mkdir -p "$PREFIX/bin"
  touch "$PREFIX/bin/copilot"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Notice: Replacing copilot binary"* ]]
}

@test "does not show replacement notice when no previous binary exists" {
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Notice: Replacing copilot binary"* ]]
}

# =============================================================================
# Success Message and PATH Check
# =============================================================================

@test "shows copilot-help success message when install dir is already in PATH" {
  export PREFIX="$MOCK_HOME/install"
  export PATH="$MOCK_BIN:$PREFIX/bin:$_ORIG_PATH"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run 'copilot help'"* ]]
}

@test "shows PATH warning when install dir is not in PATH" {
  # Default setup: $PREFIX/bin not in PATH
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not in your PATH"* ]]
}

# =============================================================================
# Shell Profile Detection
# =============================================================================

@test "suggests .zprofile for zsh shell" {
  export SHELL="/bin/zsh"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *".zprofile"* ]]
}

@test "suggests .bash_profile for bash when .bash_profile exists" {
  export SHELL="/bin/bash"
  touch "$MOCK_HOME/.bash_profile"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *".bash_profile"* ]]
}

@test "suggests .bash_login when .bash_profile is absent but .bash_login exists" {
  export SHELL="/bin/bash"
  touch "$MOCK_HOME/.bash_login"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *".bash_login"* ]]
}

@test "suggests .profile for bash when neither .bash_profile nor .bash_login exists" {
  export SHELL="/bin/bash"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *".profile"* ]]
}

@test "suggests .profile for an unrecognized shell" {
  export SHELL="/usr/local/bin/fish"
  run setsid bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *".profile"* ]]
}
