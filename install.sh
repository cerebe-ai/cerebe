#!/bin/sh
# Cerebe CLI installer — checksum-verified binaries onto PATH, then (when
# this is a laptop in a git repo) configure that repo. One line:
#
#   curl -fsSL https://raw.githubusercontent.com/momentiq-ai/cerebe/main/install.sh | sh
#
# Run it from the repo you want adopted. CI (`CI` set) and CEREBE_SKIP_REPO=1
# stay binaries-only. No prompt — curl|sh has no stdin. No local critics.
#
# Env overrides:
#   CEREBE_VERSION=8.4.1     pin a version (default: latest stable release)
#   CEREBE_INSTALL_DIR=DIR   install target AND binaries-only (CI / soak).
#                            Default /usr/local/bin or ~/.local/bin also
#                            configures this git repo.
#   CEREBE_SKIP_REPO=1       binaries only, even with the default install dir
#
# Releases resolve through the GitHub API by this repository's immutable
# numeric ID, and every download URL comes from that API response, so an
# owner or repo rename cannot break or redirect an install. That is one
# anonymous API call per run, pinned or not (GitHub allows 60/hour per IP).
set -eu

REPO_ID=1181720228
API="https://api.github.com/repositories/${REPO_ID}/releases"
BINARIES="cerebe cyclone"
VERSION="${CEREBE_VERSION:-}"
VERSION="${VERSION#v}"
# Capture the caller's directory before we cd into the download temp.
# That is the repo the one-liner is supposed to configure.
ORIG_CWD=$(pwd)

log()  { printf '  %s\n' "$*"; }
err()  { printf 'cerebe-install: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "required tool not found: $1"; }

need curl
need tar
# One of sha256sum / shasum must exist for integrity verification.
if command -v sha256sum >/dev/null 2>&1; then SHACHK="sha256sum -c"; 
elif command -v shasum   >/dev/null 2>&1; then SHACHK="shasum -a 256 -c";
else err "need sha256sum or shasum for checksum verification"; fi

# --- detect os/arch → the GoReleaser asset suffix -------------------------
os=$(uname -s); arch=$(uname -m)
case "$os" in
  Linux)  OS=linux ;;
  Darwin) OS=darwin ;;
  *) err "unsupported OS: $os (Windows: download the .zip from the Releases page)";;
esac
case "$arch" in
  x86_64|amd64) ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) err "unsupported arch: $arch";;
esac
TARGET="${OS}_${ARCH}"

# --- resolve the release by repo ID (default: latest stable) --------------
# The temp dir is created here so the API response has somewhere to live;
# the cd into it stays where it was, below the install-dir block.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
REL="$tmp/release.json"
if [ -n "$VERSION" ]; then REL_URL="${API}/tags/v${VERSION}"; else REL_URL="${API}/latest"; fi
code=$(curl -sSL -H 'Accept: application/vnd.github+json' -o "$REL" -w '%{http_code}' "$REL_URL") \
  || err "could not reach the GitHub API: ${REL_URL}"
case "$code" in
  200) ;;
  404) err "release not found (HTTP 404): ${REL_URL}" ;;
  403|429) err "GitHub API refused ${REL_URL} (HTTP ${code}), usually the anonymous rate limit; retry later" ;;
  *) err "GitHub API error (HTTP ${code}): ${REL_URL}" ;;
esac

# json_str KEY — each string value of a "KEY": "..." member of the response,
# one per line. Commas and braces become line breaks and JSON whitespace a
# space, so each member sits on one line however the response is formatted.
# The match spans a whole member, and a value holding an escape never
# matches: a parse miss prints nothing, and every caller fails closed on it.
json_str() {
  # shellcheck disable=SC2020 # a char-for-char map: the repeats are intended
  tr '\n\r\t,{}' '   \n\n\n' < "$REL" | sed -n 's/^ *"'"$1"'" *: *"\([^"\\]*\)" *$/\1/p'
}
# asset_url NAME — the release's https://github.com/ download URL whose last
# path segment is exactly NAME; prints nothing unless exactly one matches.
asset_url() {
  json_str browser_download_url | awk -v want="/$1" '
    index($0, "https://github.com/") == 1 &&
    substr($0, length($0) - length(want) + 1) == want { n++; url = $0 }
    END { if (n == 1) print url }'
}

TAG=$(json_str tag_name | awk '{ n++; t = $0 } END { if (n == 1) print t }')
[ -n "$TAG" ] || err "could not read the release tag from ${REL_URL}"
if [ -n "$VERSION" ]; then
  [ "$TAG" = "v${VERSION}" ] || err "asked for v${VERSION} but GitHub returned ${TAG}"
else
  VERSION="${TAG#v}"
fi
# VERSION becomes part of file names below: accept only a plain version.
case "$VERSION" in ''|*[!0-9A-Za-z.+_-]*) err "unexpected release version: ${VERSION}" ;; esac
CHECKSUMS_URL=$(asset_url checksums.txt)
[ -n "$CHECKSUMS_URL" ] || err "no checksums.txt in release v${VERSION}; refusing to install unverified"
log "Installing Cerebe CLI v${VERSION} (${TARGET}) from ${CHECKSUMS_URL%/*}"

# --- install dir (writable, on PATH) --------------------------------------
# An explicit CEREBE_INSTALL_DIR is honored (created if needed). Only the DEFAULT
# (/usr/local/bin) falls back to ~/.local/bin when it is not writable.
if [ -n "${CEREBE_INSTALL_DIR:-}" ]; then
  DIR="$CEREBE_INSTALL_DIR"; mkdir -p "$DIR" || err "cannot create CEREBE_INSTALL_DIR=$DIR"
  [ -w "$DIR" ] || err "CEREBE_INSTALL_DIR=$DIR is not writable"
else
  DIR="/usr/local/bin"
  if [ ! -d "$DIR" ] || [ ! -w "$DIR" ]; then
    DIR="$HOME/.local/bin"; mkdir -p "$DIR"
    log "Note: /usr/local/bin not writable → installing to $DIR (ensure it is on PATH)"
  fi
fi

# --- download + verify + extract each binary ------------------------------
cd "$tmp"
curl -fsSL -o checksums.txt "$CHECKSUMS_URL" || err "could not download checksums.txt for v${VERSION}"
for bin in $BINARIES; do
  asset="${bin}_${VERSION}_${TARGET}.tar.gz"
  log "→ ${asset}"
  url=$(asset_url "$asset")
  [ -n "$url" ] || err "no ${asset} in release v${VERSION}"
  curl -fsSL -o "$asset" "$url" || err "download failed: ${asset}"
  # Materialize THIS asset's checksum line; fail hard if absent (an empty grep
  # piped to the checker can exit 0), then verify, then extract.
  grep " ${asset}\$" checksums.txt > "${asset}.sha256" \
    || err "no checksum entry for ${asset} — refusing to install unverified"
  [ -s "${asset}.sha256" ] || err "empty checksum entry for ${asset}"
  $SHACHK "${asset}.sha256" >/dev/null || err "checksum mismatch for ${asset} — refusing to install"
  tar -xzf "$asset" "$bin"
  chmod 0755 "$bin"
  mv -f "$bin" "$DIR/$bin"
done

printf '\nInstalled: %s → %s\n' "$BINARIES" "$DIR"
"$DIR/cerebe" --version || err "just-installed cerebe did not run"
case ":$PATH:" in *":$DIR:"*) : ;; *) printf 'PATH:      add %s to your PATH\n' "$DIR";; esac

# --- this repo (laptop only) ----------------------------------------------
# Reusable workflows run this script under env -i with CEREBE_INSTALL_DIR
# set to $RUNNER_TEMP. That isolated dir is the CI signal — not $CI.
# A prompt cannot work on curl|sh.
if [ -n "${CEREBE_INSTALL_DIR:-}" ] || [ -n "${CI:-}" ] || [ -n "${CEREBE_SKIP_REPO:-}" ]; then
  log "Skipping repo setup (isolated install dir or CI)."
  exit 0
fi
if ! command -v git >/dev/null 2>&1 \
   || ! git -C "$ORIG_CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf '\nNot a git repository — binaries only.\n'
  printf 'Re-run the same curl from the repo you want adopted.\n'
  exit 0
fi
GIT_ROOT=$(git -C "$ORIG_CWD" rev-parse --show-toplevel) || err "could not resolve git root"
# Hooks resolve CEREBE_BIN before PATH. Export the just-installed binary so
# the next commit works even if $DIR is not on this shell's PATH yet.
export CEREBE_BIN="$DIR/cerebe"
export PATH="$DIR:$PATH"
if [ -f "$GIT_ROOT/cerebe/config.json" ]; then
  log "Configuring this repo (cerebe init — already adopted)."
  (cd "$GIT_ROOT" && "$DIR/cerebe" init)
else
  log "Configuring this repo (cerebe install — empty fleet, no local critics)."
  (cd "$GIT_ROOT" && "$DIR/cerebe" install)
fi
# doctor is the proof the one-liner finished; a blocking row fails the install.
(cd "$GIT_ROOT" && "$DIR/cerebe" doctor)
