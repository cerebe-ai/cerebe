#!/bin/sh
# Cerebe CLI installer — provenance-verified binaries onto PATH, then (when
# this is a laptop in a git repo) configure that repo. One line:
#
#   curl -fsSL https://cerebe.ai/install.sh | sh
#
# Run it from the repo you want adopted. CI (`CI` set) and CEREBE_SKIP_REPO=1
# stay binaries-only. No prompt — curl|sh has no stdin. No local critics.
#
# Before a binary is extracted, the release must prove its origin. There is
# no flag and no environment variable that skips this:
#   1. checksums.txt, its keyless bundle, and the SLSA provenance
#   2. cosign accepts the bundle for this exact workflow identity
#   3. slsa-verifier accepts each archive
#   4. each archive's sha256 matches the verified checksums.txt
# A release with no bundle or no provenance is refused.
#
# Env overrides:
#   CEREBE_VERSION=9.5.0     pin a version (default: latest stable). A release
#                            with no signature or provenance is refused.
#   CEREBE_INSTALL_DIR=DIR   install target AND binaries-only (CI / soak).
#                            Default /usr/local/bin or ~/.local/bin also
#                            configures this git repo.
#   CEREBE_SKIP_REPO=1       binaries only, even with the default install dir
#   CEREBE_RELEASE_JSON=FILE the release object for the CEREBE_VERSION pin,
#                            already fetched (GET .../releases/tags/v<pin>).
#                            The script then makes NO API call: for CI that
#                            fetched it authenticated, since anonymous calls
#                            share a 60/hour per-IP limit on hosted runners.
#                            Requires CEREBE_VERSION; every check below still
#                            runs on it.
#
# Releases resolve through the GitHub API by this repository's immutable
# numeric ID, and every download URL comes from that API response, so an
# owner or repo rename cannot break or redirect a release download. (The
# one-liner above still fetches this script itself by owner/repo.) That is
# one anonymous API call per run, pinned or not (GitHub allows 60/hour per IP),
# or none when the caller supplies CEREBE_RELEASE_JSON.
set -eu

REPO_ID=1181720228
API="https://api.github.com/repositories/${REPO_ID}/releases"
BINARIES="cerebe cyclone"

# The identity cli-release.yml's keyless certificate carries on main.
# Exact, not a pattern. ADR 0065 / cerebe-ai/dark-factory#706.
CERT_IDENTITY='https://github.com/cerebe-ai/dark-factory/.github/workflows/cli-release.yml@refs/heads/main'
CERT_ISSUER='https://token.actions.githubusercontent.com'
PROVENANCE_SOURCE='github.com/cerebe-ai/dark-factory'
PROVENANCE_BRANCH='main'
PROVENANCE_BUILDER='https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@refs/tags/v2.1.0'
BUNDLE_NAME='checksums.txt.sigstore.json'
PROVENANCE_NAME='cerebe-cyclone.intoto.jsonl'

# Bootstrap trust anchors, bumped deliberately. Official release binaries.
# cosign v3.0.6 from its published cosign_checksums.txt. slsa-verifier v2.7.1
# from the bytes at that tag. Used only when the tool is not already on PATH.
COSIGN_VERSION=v3.0.6
COSIGN_REPO=sigstore/cosign
SLSA_VERIFIER_VERSION=v2.7.1
SLSA_VERIFIER_REPO=slsa-framework/slsa-verifier
VERSION="${CEREBE_VERSION:-}"
VERSION="${VERSION#v}"
# Capture the caller's directory before we cd into the download temp.
# That is the repo the one-liner is supposed to configure.
ORIG_CWD=$(pwd)

log()  { printf '  %s\n' "$*"; }
err()  { printf 'cerebe-install: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "required tool not found: $1"; }

# Delegate before requiring POSIX archive/checksum tools. Native PowerShell
# inherits this directory; prevent MSYS from rewriting caller overrides.
os=$(uname -s)
case "$os" in
  MINGW*|MSYS*|CYGWIN*)
    need powershell.exe
    # Translate only path-valued POSIX inputs at the native-process boundary.
    # Destination defaults and user PATH still belong entirely to install.ps1.
    case "${CEREBE_INSTALL_DIR:-}" in
      //[!/]*) ;; # Native UNC, including its forward-slash spelling.
      /*)
        need cygpath
        CEREBE_INSTALL_DIR=$(cygpath -w "$CEREBE_INSTALL_DIR") || err "could not translate CEREBE_INSTALL_DIR"
        export CEREBE_INSTALL_DIR
        ;;
    esac
    case "${CEREBE_RELEASE_JSON:-}" in
      //[!/]*) ;;
      /*)
        need cygpath
        CEREBE_RELEASE_JSON=$(cygpath -w "$CEREBE_RELEASE_JSON") || err "could not translate CEREBE_RELEASE_JSON"
        export CEREBE_RELEASE_JSON
        ;;
    esac
    if [ "${MSYS2_ENV_CONV_EXCL:-}" != '*' ]; then
      export MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL:+${MSYS2_ENV_CONV_EXCL};}CI=;CEREBE_"
    fi
    exec powershell.exe -NoProfile -ExecutionPolicy ByPass -Command 'irm https://cerebe.ai/install.ps1 | iex'
    ;;
esac

need curl
need tar
# One of sha256sum / shasum must exist for integrity verification.
if command -v sha256sum >/dev/null 2>&1; then SHACHK="sha256sum -c"; 
elif command -v shasum   >/dev/null 2>&1; then SHACHK="shasum -a 256 -c";
else err "need sha256sum or shasum for checksum verification"; fi

# --- detect os/arch → the GoReleaser asset suffix -------------------------
arch=$(uname -m)
case "$os" in
  Linux)  OS=linux ;;
  Darwin) OS=darwin ;;
  *) err "unsupported OS: $os";;
esac
case "$arch" in
  x86_64|amd64) ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) err "unsupported arch: $arch";;
esac
TARGET="${OS}_${ARCH}"

# tool_sha NAME — the embedded sha256 for NAME on this OS/arch.
tool_sha() {
  case "$1:$TARGET" in
    cosign:darwin_amd64) printf '%s\n' '4c3e7af8372d3ca3296e62fa56f23fcbb5721cc6ac1827900d398f110d7cd280' ;;
    cosign:darwin_arm64) printf '%s\n' '5fadd012ae6381a6a29ff86a7d39aa873878852f1073fc90b15995961ecfb084' ;;
    cosign:linux_amd64) printf '%s\n' 'c956e5dfcac53d52bcf058360d579472f0c1d2d9b69f55209e256fe7783f4c74' ;;
    cosign:linux_arm64) printf '%s\n' 'bedac92e8c3729864e13d4a17048007cfafa79d5deca993a43a90ffe018ef2b8' ;;
    slsa-verifier:darwin_amd64) printf '%s\n' '4baf25415727821f847a38bccedc86c3e5b17cbfc2eb534cd554feb6c856d6f1' ;;
    slsa-verifier:darwin_arm64) printf '%s\n' '39abfcf5f1d690c3e889ce3d2d6a8b87711424d83368511868d414e8f8bcb05c' ;;
    slsa-verifier:linux_amd64) printf '%s\n' '946dbec729094195e88ef78e1734324a27869f03e2c6bd2f61cbc06bd5350339' ;;
    slsa-verifier:linux_arm64) printf '%s\n' '5d3b2349ede7bfec19e7a21569f18b9f7410145ad12e9584b175370669e14061' ;;
    *) return 1 ;;
  esac
}

# install_pinned NAME VERSION REPO — the official binary, checked against the
# embedded sha256, at $tmp/tools/NAME. Returns 1 if the download fails. A
# checksum mismatch refuses: that file is not the pinned tool. A tool already
# on PATH is not used here.
install_pinned() {
  name=$1
  version=$2
  repo=$3
  mkdir -p "$tmp/tools"
  dest="$tmp/tools/$name"
  if [ -x "$dest" ]; then
    return 0
  fi
  sum=$(tool_sha "$name") || err "no embedded sha256 for $name on $TARGET — refusing to verify with an untrusted $name"
  url="https://github.com/${repo}/releases/download/${version}/${name}-${OS}-${ARCH}"
  log "downloading ${name} ${version}"
  curl -fsSL -o "$dest" "$url" || return 1
  # A file, not a pipe: macOS /sbin/sha256sum -c does not read stdin.
  printf '%s  %s\n' "$sum" "$(basename "$dest")" > "$tmp/tools/$name.sha256"
  (cd "$tmp/tools" && $SHACHK "$name.sha256") >/dev/null \
    || err "${name} ${version} checksum mismatch — refusing to verify with an untrusted ${name}"
  chmod 0755 "$dest"
}

# A verifier on PATH is tried first. Cosign v2 rejects the v0.3 bundle, so a
# rejection is not the answer: the pinned binary verifies again. The install
# is refused only when that pinned binary also rejects. Nothing skips the check.
cosign_accepts() {
  "$1" verify-blob \
    --bundle "$BUNDLE_NAME" \
    --certificate-identity "$CERT_IDENTITY" \
    --certificate-oidc-issuer "$CERT_ISSUER" \
    checksums.txt >/dev/null
}
slsa_accepts() {
  tool=$1
  shift
  "$tool" verify-artifact \
    --provenance-path "$PROVENANCE_NAME" \
    --source-uri "$PROVENANCE_SOURCE" \
    --source-branch "$PROVENANCE_BRANCH" \
    --builder-id "$PROVENANCE_BUILDER" \
    "$@" >/dev/null
}

# verify_bundle_asset — download the bundle and require cosign to accept it
# for CERT_IDENTITY. Missing and tampered checksums both stop here.
verify_bundle_asset() {
  url=$(asset_url "$BUNDLE_NAME")
  [ -n "$url" ] || err "release v${VERSION} has no ${BUNDLE_NAME} — refusing to install an unsigned release"
  curl -fsSL -o "$BUNDLE_NAME" "$url" \
    || err "release v${VERSION} has no ${BUNDLE_NAME} — refusing to install an unsigned release"
  [ -s "$BUNDLE_NAME" ] || err "release v${VERSION} has no ${BUNDLE_NAME} — refusing to install an unsigned release"
  if command -v cosign >/dev/null 2>&1 && cosign_accepts cosign; then
    return 0
  fi
  install_pinned cosign "$COSIGN_VERSION" "$COSIGN_REPO" \
    || err "could not download cosign ${COSIGN_VERSION} — refusing to install"
  cosign_accepts "$tmp/tools/cosign" \
    || err "checksum signature rejected for ${CERT_IDENTITY}"
}

# verify_provenance_asset ARCHIVE... — download the provenance and require
# slsa-verifier to accept every archive before any of them is extracted.
verify_provenance_asset() {
  url=$(asset_url "$PROVENANCE_NAME")
  [ -n "$url" ] || err "release v${VERSION} has no ${PROVENANCE_NAME} — refusing to install a release with no provenance"
  curl -fsSL -o "$PROVENANCE_NAME" "$url" \
    || err "release v${VERSION} has no ${PROVENANCE_NAME} — refusing to install a release with no provenance"
  [ -s "$PROVENANCE_NAME" ] || err "release v${VERSION} has no ${PROVENANCE_NAME} — refusing to install a release with no provenance"
  [ $# -ge 1 ] || err "no archives to verify"
  if command -v slsa-verifier >/dev/null 2>&1 && slsa_accepts slsa-verifier "$@"; then
    return 0
  fi
  install_pinned slsa-verifier "$SLSA_VERIFIER_VERSION" "$SLSA_VERIFIER_REPO" \
    || err "could not download slsa-verifier ${SLSA_VERIFIER_VERSION} — refusing to install"
  slsa_accepts "$tmp/tools/slsa-verifier" "$@" \
    || err "provenance rejected for v${VERSION} — refusing to install"
}

# --- resolve the release by repo ID (default: latest stable) --------------
# The temp dir is created here so the API response has somewhere to live;
# the cd into it stays where it was, below the install-dir block.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
REL="$tmp/release.json"
# A version goes into a URL and into file names below: plain versions only.
# Any non-empty CEREBE_VERSION is a pin, so a bare "v" fails, not "latest".
valid_version() { case "$1" in ''|*[!0-9A-Za-z.+_-]*) return 1 ;; esac; }
if [ -n "${CEREBE_VERSION:-}" ]; then
  valid_version "$VERSION" || err "CEREBE_VERSION is not a release version: ${CEREBE_VERSION}"
  REL_URL="${API}/tags/v${VERSION}"
else
  REL_URL="${API}/latest"
fi
if [ -n "${CEREBE_RELEASE_JSON:-}" ]; then
  # A supplied release object stands in for the API response. It must be for
  # the pinned version (checked against its tag_name below, like any response).
  [ -n "${CEREBE_VERSION:-}" ] || err "CEREBE_RELEASE_JSON needs a CEREBE_VERSION pin (the release it describes)"
  if [ ! -f "$CEREBE_RELEASE_JSON" ] || [ ! -r "$CEREBE_RELEASE_JSON" ]; then
    err "CEREBE_RELEASE_JSON is not a readable file: ${CEREBE_RELEASE_JSON}"
  fi
  cp "$CEREBE_RELEASE_JSON" "$REL"
  REL_URL="CEREBE_RELEASE_JSON (${CEREBE_RELEASE_JSON})"
  log "Using the release object from CEREBE_RELEASE_JSON (no GitHub API call)"
  code=200
else
  code=$(curl -sSL -o "$REL" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$REL_URL") || err "could not reach the GitHub API: ${REL_URL}"
fi
case "$code" in
  200) ;;
  404) err "release not found (HTTP 404): ${REL_URL}" ;;
  403|429) err "GitHub API refused ${REL_URL} (HTTP ${code}), usually the anonymous rate limit; retry later, or pass CEREBE_RELEASE_JSON" ;;
  *) err "GitHub API error (HTTP ${code}): ${REL_URL}" ;;
esac

# json_str KEY — each string value of a "KEY": "..." member of the response,
# one per line. Commas and braces become line breaks and JSON whitespace a
# space, so each member sits on one line however the response is formatted.
# The match spans a whole member, and a value holding an escape never
# matches: a parse miss prints nothing, and every caller fails closed on it.
json_str() {
  # A char-for-char map: the repeated characters are intended.
  # shellcheck disable=SC2020
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
  valid_version "$VERSION" || err "unexpected release version: ${VERSION}"
fi
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
# The bundle is checked before any archive is extracted. Deleting this call
# is what the missing-bundle and tampered-checksum refusals pin.
verify_bundle_asset # cerebe:check bundle

set --
for bin in $BINARIES; do
  asset="${bin}_${VERSION}_${TARGET}.tar.gz"
  log "→ ${asset}"
  url=$(asset_url "$asset")
  [ -n "$url" ] || err "no ${asset} in release v${VERSION}"
  curl -fsSL -o "$asset" "$url" || err "download failed: ${asset}"
  set -- "$@" "$asset"
done
# Provenance before the checksum lines, and before extract. Deleting this
# call is what the missing-provenance refusal pins.
verify_provenance_asset "$@" # cerebe:check provenance

for asset in "$@"; do
  # Materialize THIS asset's checksum line; fail hard if absent (an empty grep
  # piped to the checker can exit 0), then verify. Extract only after every
  # archive has passed.
  grep " ${asset}\$" checksums.txt > "${asset}.sha256" \
    || err "no checksum entry for ${asset} — refusing to install unverified"
  [ -s "${asset}.sha256" ] || err "empty checksum entry for ${asset}"
  $SHACHK "${asset}.sha256" >/dev/null || err "checksum mismatch for ${asset} — refusing to install"
done
for bin in $BINARIES; do
  asset="${bin}_${VERSION}_${TARGET}.tar.gz"
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
