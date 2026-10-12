#!/bin/sh
# Offline regression tests for install.sh. The real script runs against a
# stub curl that serves a fixture GitHub API response and locally built
# release assets: no network, no jq, nothing installed outside a temp dir.
#
#   sh tests/install/run.sh
#   TEST_SH="bash --posix" sh tests/install/run.sh    # pick the shell under test
#
# release-v8.17.1.json is a real GET /repositories/<id>/releases/tags/v8.17.1
# response with the owner and user identities replaced by placeholders and a
# synthetic body full of decoys. An install case asserts the API endpoint
# queried and the installed versions; a refusal case asserts the error AND
# that the binary never landed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
INSTALLER=${INSTALLER:-"$HERE/../../install.sh"}
FIXTURE="$HERE/release-v8.17.1.json"
TEST_SH=${TEST_SH:-sh}
API="https://api.github.com/repositories/1181720228/releases"
V=8.17.1

case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) echo "unsupported OS"; exit 1 ;; esac
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) echo "unsupported arch"; exit 1 ;; esac
A="cerebe_${V}_${os}_${arch}.tar.gz"
Y="cyclone_${V}_${os}_${arch}.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then sha256() { sha256sum "$@"; }; else sha256() { shasum -a 256 "$@"; }; fi

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"

# Stub curl. The API answers with $STUB_API_BODY and $STUB_API_CODE; release
# downloads are served from $STUB_ASSETS by file name; any other URL is
# unreachable. Every requested URL is appended to $STUB_LOG.
cat > "$W/bin/curl" <<'STUB'
#!/bin/sh
out=; fmt=; url=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) fmt=$2; shift 2 ;;
    -H) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\n' "$url" >> "$STUB_LOG"
case "$url" in
  https://api.github.com/*)
    [ -z "${STUB_API_DOWN:-}" ] || { echo "curl: (7) Failed to connect" >&2; exit 7; }
    cp "$STUB_API_BODY" "$out"
    [ -z "$fmt" ] || printf '%s' "${STUB_API_CODE:-200}"
    exit 0 ;;
  https://github.com/*/releases/download/*)
    f="$STUB_ASSETS/${url##*/}"
    [ -f "$f" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
    cp "$f" "$out"; exit 0 ;;
esac
echo "curl: (6) Could not resolve host: $url" >&2
exit 6
STUB
chmod 0755 "$W/bin/curl"

# The identity the installer must pass through. Read from the script so a
# drifted constant fails here instead of being restated.
EXPECT_IDENTITY=$(sed -n "s/^CERT_IDENTITY='\\(.*\\)'\$/\\1/p" "$INSTALLER")
EXPECT_ISSUER=$(sed -n "s/^CERT_ISSUER='\\(.*\\)'\$/\\1/p" "$INSTALLER")
EXPECT_SOURCE=$(sed -n "s/^PROVENANCE_SOURCE='\\(.*\\)'\$/\\1/p" "$INSTALLER")
EXPECT_BUILDER=$(sed -n "s/^PROVENANCE_BUILDER='\\(.*\\)'\$/\\1/p" "$INSTALLER")
if [ -z "$EXPECT_IDENTITY" ] || [ -z "$EXPECT_ISSUER" ] || [ -z "$EXPECT_SOURCE" ] || [ -z "$EXPECT_BUILDER" ]; then
  echo "installer is missing the pinned identity"
  exit 1
fi

# Stub cosign. A missing --certificate-identity accepts, so a refusal that
# only happens because the flag is absent is not this stub. A present identity
# must be the pinned one. A bundle whose first line is not the checksums
# file's sha256 is a signature mismatch.
cat > "$W/bin/cosign" << 'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_COSIGN_LOG"
[ "$1" = "verify-blob" ] || { echo "cosign: unexpected $1" >&2; exit 1; }
shift
bundle=""; identity=""; issuer=""; blob=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) bundle=$2; shift 2 ;;
    --certificate-identity) identity=$2; shift 2 ;;
    --certificate-oidc-issuer) issuer=$2; shift 2 ;;
    --*) shift ;;
    *) blob=$1; shift ;;
  esac
done
if [ -n "$blob" ] && [ -n "$bundle" ] && [ -f "$bundle" ]; then
  want=$(awk 'NR==1 { print; exit }' "$bundle")
  if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$blob" | awk '{print $1}')
  else got=$(shasum -a 256 "$blob" | awk '{print $1}'); fi
  if [ "$want" != "$got" ]; then echo "cosign: signature mismatch" >&2; exit 1; fi
fi
if [ -z "$identity" ]; then exit 0; fi
if [ "$identity" != "$EXPECT_IDENTITY" ] || [ "$issuer" != "$EXPECT_ISSUER" ]; then
  echo "cosign: identity rejected" >&2
  exit 1
fi
exit 0
STUB
chmod 0755 "$W/bin/cosign"

# Stub slsa-verifier. Missing source flags accept, so removing the flags is
# not itself a refusal. Present flags must be the pinned source and builder,
# and each archive's sha256 line must be in the provenance file.
cat > "$W/bin/slsa-verifier" << 'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_SLSA_LOG"
[ "$1" = "verify-artifact" ] || { echo "slsa: unexpected $1" >&2; exit 1; }
shift
prov=""; source=""; branch=""; builder=""
while [ $# -gt 0 ]; do
  case "$1" in
    --provenance-path) prov=$2; shift 2 ;;
    --source-uri) source=$2; shift 2 ;;
    --source-branch) branch=$2; shift 2 ;;
    --builder-id) builder=$2; shift 2 ;;
    --*) shift ;;
    *) break ;;
  esac
done
if [ -z "$source" ] && [ -z "$builder" ]; then exit 0; fi
if [ "$source" != "$EXPECT_SOURCE" ] || [ "$branch" != "main" ] || [ "$builder" != "$EXPECT_BUILDER" ]; then
  echo "slsa: source rejected" >&2
  exit 1
fi
[ -s "$prov" ] || { echo "slsa: no provenance" >&2; exit 1; }
for f in "$@"; do
  if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$f")
  else got=$(shasum -a 256 "$f"); fi
  grep -qxF "$got" "$prov" || { echo "slsa: $f not in provenance" >&2; exit 1; }
done
exit 0
STUB
chmod 0755 "$W/bin/slsa-verifier"

# build_assets VERSION DIR — both binaries for every target, plus checksums,
# a bundle the stub cosign accepts, and a provenance the stub verifier accepts.
write_proof() {
  sha256 checksums.txt | awk '{print $1}' > checksums.txt.sigstore.json
  : > cerebe-cyclone.intoto.jsonl
  for f in *.tar.gz; do
    sha256 "$f" >> cerebe-cyclone.intoto.jsonl
  done
}
build_assets() {
  mkdir -p "$2" "$W/src-$1"
  for b in cerebe cyclone; do
    printf '#!/bin/sh\necho "%s v%s"\n' "$b" "$1" > "$W/src-$1/$b"; chmod 0755 "$W/src-$1/$b"
    for t in darwin_amd64 darwin_arm64 linux_amd64 linux_arm64; do
      tar -czf "$2/${b}_$1_${t}.tar.gz" -C "$W/src-$1" "$b"
    done
  done
  (cd "$2" && sha256 ./*.tar.gz | sed 's#  \./#  #' > checksums.txt)
  (cd "$2" && write_proof)
}
build_assets "$V" "$W/assets"

# The captured release predates the bundle and the provenance. Add their
# download URLs beside checksums.txt so every case sees them. The installer's
# parser reads each browser_download_url, so the extra lines do not need to
# be a separate asset object.
# The checksums URL is the last field of its object, so it has no comma.
# The installer's parser turns newlines into spaces and commas into
# newlines: extra URL lines with no comma would glue onto checksums.txt
# and hide it. Each URL gets a comma.
awk '
  {
    if (!done && $0 ~ /\/checksums\.txt"$/) {
      done = 1
      print $0 ","
      line = $0 ","
      sub(/checksums\.txt"/, "checksums.txt.sigstore.json\"", line)
      print line
      sub(/checksums\.txt\.sigstore\.json"/, "cerebe-cyclone.intoto.jsonl\"", line)
      print line
      next
    }
    print
  }
' "$FIXTURE" > "$W/fixture.json"
FIXTURE="$W/fixture.json"

# Fixture and asset variants. Each prints the path of what it wrote.
variant() { sed "$2" "$FIXTURE" > "$W/$1.json"; printf '%s' "$W/$1.json"; }
compact() { sed 's/^[[:space:]]*//' "$FIXTURE" | tr -d '\n' > "$W/compact.json"; printf '%s' "$W/compact.json"; }
crlf() { awk '{ printf "%s\r\n", $0 }' "$FIXTURE" > "$W/crlf.json"; printf '%s' "$W/crlf.json"; }
garbage() { printf '{"message": "Bad credentials"}' > "$W/garbage.json"; printf '%s' "$W/garbage.json"; }
assets_with() { # assets_with NAME CMD... — a copy of the assets, edited by CMD inside it
  d="$W/assets-$1"; shift; cp -R "$W/assets" "$d"; (cd "$d" && "$@") || exit 1; printf '%s' "$d"
}
flip_checksums() { awk '{ c = substr($1, 1, 1); r = (c == "0") ? "1" : "0"; print r substr($0, 2) }' checksums.txt > s && mv s checksums.txt; write_proof; }
append_byte() { printf X >> "$1"; }
append_sums() { printf 'X\n' >> checksums.txt; }
drop_line() { grep -v " $1\$" checksums.txt > s; mv s checksums.txt; write_proof; }

n=0; failed=0
run() { # run ENV=VAL... — the installer under $TEST_SH, from a clean non-git cwd
  n=$((n+1)); c="$W/case$n"; mkdir -p "$c/cwd"; : > "$c/urls"
  # TEST_SH may carry flags, e.g. "bash --posix", so it stays unquoted.
  # shellcheck disable=SC2086
  (cd "$c/cwd" && env PATH="$W/bin:$PATH" STUB_LOG="$c/urls" STUB_ASSETS="$W/assets" \
    STUB_API_BODY="$FIXTURE" STUB_COSIGN_LOG="$c/cosign" STUB_SLSA_LOG="$c/slsa" \
    EXPECT_IDENTITY="$EXPECT_IDENTITY" EXPECT_ISSUER="$EXPECT_ISSUER" \
    EXPECT_SOURCE="$EXPECT_SOURCE" EXPECT_BUILDER="$EXPECT_BUILDER" \
    CEREBE_INSTALL_DIR="$c/bin" "$@" $TEST_SH "$INSTALLER") > "$c/out" 2>&1
  rc=$?
}
report() { # report yes|no NAME
  if [ "$1" = yes ]; then printf 'ok %d - %s\n' "$n" "$2"; return; fi
  printf 'not ok %d - %s (rc=%s)\n' "$n" "$2" "$rc"
  sed 's/^/#   /' "$c/out"; sed 's/^/#   requested: /' "$c/urls"; failed=$((failed+1))
}
proved() { # both verifiers ran with the pinned identity
  grep -qF -- "$EXPECT_IDENTITY" "$c/cosign" && grep -qF -- "$EXPECT_ISSUER" "$c/cosign" \
    && grep -qF -- "$EXPECT_SOURCE" "$c/slsa" && grep -qF -- "$EXPECT_BUILDER" "$c/slsa"
}
installs() { # installs NAME API-PATH VERSION ENV=VAL... — installs VERSION via that endpoint
  name=$1 path=$2 want=$3; shift 3; run "$@"; ok=no
  if [ "$rc" -eq 0 ] && [ "$("$c/bin/cerebe" --version 2>&1)" = "cerebe v$want" ] \
     && [ "$("$c/bin/cyclone" --version 2>&1)" = "cyclone v$want" ] \
     && [ "$(sed -n 1p "$c/urls")" = "$API/$path" ] && ! grep -q evil "$c/urls" \
     && proved; then ok=yes; fi
  report "$ok" "$name"
}
lands() { # lands NAME ENV... — binaries installed. Used when a check was removed on purpose.
  name=$1; shift; run "$@"; ok=no
  if [ "$rc" -eq 0 ] && versions_are "$V"; then ok=yes; fi
  report "$ok" "$name"
}
drop_check() { # drop_check MARKER — copy of the installer without that call
  grep -v "# cerebe:check $1" "$INSTALLER" > "$W/drop-$1.sh"
  chmod 0755 "$W/drop-$1.sh"
}
refuses() { # refuses NAME "error text" BINARY ENV=VAL... — fails, says why, installs nothing
  name=$1 msg=$2 bin=$3; shift 3; run "$@"; ok=no
  if [ "$rc" -ne 0 ] && grep -qF -- "$msg" "$c/out" && [ ! -e "$c/bin/$bin" ]; then ok=yes; fi
  report "$ok" "$name"
}
also() { # also NAME CMD... — a further assertion about the previous case's requests
  name=$1; shift; n=$((n+1)); if "$@"; then report yes "$name"; else report no "$name"; fi
}
requested() { grep -q "$1" "$c/urls"; }
no_api_call() { ! grep -q '^https://api.github.com/' "$c/urls"; }
downloads_happened() { grep -q '/releases/download/' "$c/urls"; }
versions_are() { [ "$("$c/bin/cerebe" --version 2>&1)" = "cerebe v$1" ] && [ "$("$c/bin/cyclone" --version 2>&1)" = "cyclone v$1" ]; }
requested_nothing() { [ ! -s "$c/urls" ]; }
not() { ! "$@"; }

# --- resolution --------------------------------------------------------------
installs "latest release" latest "$V"
installs "pinned version" "tags/v$V" "$V" CEREBE_VERSION="$V"
installs "pinned version with a v prefix" "tags/v$V" "$V" CEREBE_VERSION="v$V"
B=8.18.0-beta.1; build_assets "$B" "$W/assets-beta"
installs "pinned prerelease" "tags/v$B" "$B" CEREBE_VERSION="$B" STUB_ASSETS="$W/assets-beta" \
  STUB_API_BODY="$(variant beta "s/8\.17\.1/$B/g")"
installs "compact JSON" latest "$V" STUB_API_BODY="$(compact)"
installs "CRLF JSON" latest "$V" STUB_API_BODY="$(crlf)"
installs "any owner in the download URLs" latest "$V" \
  STUB_API_BODY="$(variant renamed 's#github.com/example-owner/#github.com/renamed-owner/#g')"
also "  downloads came from that owner" requested 'github.com/renamed-owner/'

# --- API failures --------------------------------------------------------------
refuses "unknown version (404)" "release not found (HTTP 404)" cerebe STUB_API_CODE=404 CEREBE_VERSION=0.0.0
refuses "rate limited (403)" "(HTTP 403), usually the anonymous rate limit" cerebe STUB_API_CODE=403
refuses "rate limited (429)" "(HTTP 429), usually the anonymous rate limit" cerebe STUB_API_CODE=429
refuses "server error (500)" "GitHub API error (HTTP 500)" cerebe STUB_API_CODE=500
refuses "API unreachable" "could not reach the GitHub API" cerebe STUB_API_DOWN=1
refuses "pinned version that is not a version" "CEREBE_VERSION is not a release version: 8.17.1/../x" cerebe CEREBE_VERSION=8.17.1/../x
also "  rejected before any request" requested_nothing
refuses "pin of a bare v is not latest" "CEREBE_VERSION is not a release version: v" cerebe CEREBE_VERSION=v
also "  rejected before any request" requested_nothing
installs "empty CEREBE_VERSION means latest" latest "$V" CEREBE_VERSION=

# --- a caller-supplied release object (CEREBE_RELEASE_JSON) ----------------------
run CEREBE_VERSION="$V" CEREBE_RELEASE_JSON="$FIXTURE"
report "$([ "$rc" -eq 0 ] && versions_are "$V" && proved && echo yes || echo no)" "a supplied release object installs the pin"
also "  and makes no API call" no_api_call
also "  and says so" grep -qF "no GitHub API call" "$c/out"
also "  the downloads still happened (and were verified)" downloads_happened
refuses "a supplied object needs a pin" "CEREBE_RELEASE_JSON needs a CEREBE_VERSION pin" cerebe CEREBE_RELEASE_JSON="$FIXTURE"
also "  rejected before any request" requested_nothing
refuses "a supplied object for another version" "asked for v0.0.2 but GitHub returned v$V" cerebe \
  CEREBE_VERSION=0.0.2 CEREBE_RELEASE_JSON="$FIXTURE"
refuses "a supplied object that does not exist" "CEREBE_RELEASE_JSON is not a readable file" cerebe \
  CEREBE_VERSION="$V" CEREBE_RELEASE_JSON="$W/nope.json"
also "  rejected before any request" requested_nothing
refuses "a supplied object is checked like a response" "could not download slsa-verifier" cerebe \
  CEREBE_VERSION="$V" CEREBE_RELEASE_JSON="$FIXTURE" STUB_ASSETS="$(assets_with bytes3 append_byte "$A")"

# --- parse misses fail closed --------------------------------------------------
refuses "not a release object" "could not read the release tag" cerebe STUB_API_BODY="$(garbage)"
refuses "two tag_name members" "could not read the release tag" cerebe \
  STUB_API_BODY="$(variant twotags 's#"tag_name": "v8.17.1",#"tag_name": "v8.17.1", "tag_name": "v8.17.1",#')"
refuses "tag differs from the pin" "asked for v$V but GitHub returned v0.0.1" cerebe CEREBE_VERSION="$V" \
  STUB_API_BODY="$(variant wrongtag 's#"tag_name": "v8.17.1"#"tag_name": "v0.0.1"#')"
refuses "latest tag is not a plain version" "unexpected release version: 8.17.1/x" cerebe \
  STUB_API_BODY="$(variant slashtag 's#"tag_name": "v8.17.1"#"tag_name": "v8.17.1/x"#')"
refuses "no checksums.txt asset" "no checksums.txt in release v$V" cerebe \
  STUB_API_BODY="$(variant nosums 's#"browser_download_url": \("[^"]*/checksums.txt"\)#"removed_url": \1#')"
refuses "escaped value (valid JSON, never guessed at)" "no checksums.txt in release v$V" cerebe \
  STUB_API_BODY="$(variant escaped 's#example-owner/cerebe#example-owner\\/cerebe#g')"
refuses "non-GitHub download host" "no checksums.txt in release v$V" cerebe \
  STUB_API_BODY="$(variant foreign 's#https://github.com/#https://example.com/#g')"
also "  nothing requested from that host" not requested 'example.com'
refuses "asset URL only inside the body" "no $A in release v$V" cerebe \
  STUB_API_BODY="$(variant bodyonly "s#\"browser_download_url\": \(\"[^\"]*/$A\"\)#\"removed_url\": \1#")"
refuses "duplicate asset URL" "no $A in release v$V" cerebe \
  STUB_API_BODY="$(variant dup "s#\"assets\": \[#\"assets\": [{\"browser_download_url\": \"https://github.com/example-owner/cerebe/releases/download/v$V/$A\"},#")"
refuses "suffix and prefix look-alikes" "no $A in release v$V" cerebe \
  STUB_API_BODY="$(variant lookalike "s#/$A\"#/$A.sig\"#; s#/$Y\"#/x$A\"#")"

# --- integrity (unchanged checks, still enforced) ------------------------------
refuses "tampered checksums.txt" "checksum mismatch for $A" cerebe STUB_ASSETS="$(assets_with sums flip_checksums)"
refuses "tampered asset" "could not download slsa-verifier" cerebe STUB_ASSETS="$(assets_with bytes append_byte "$A")"
refuses "missing checksum line" "no checksum entry for $A" cerebe STUB_ASSETS="$(assets_with line drop_line "$A")"
refuses "tampered second binary" "could not download slsa-verifier" cyclone STUB_ASSETS="$(assets_with bytes2 append_byte "$Y")"
refuses "checksum bytes the signature does not cover" "could not download cosign" cerebe \
  STUB_ASSETS="$(assets_with sumbyte append_sums)"
saved=$INSTALLER
drop_check bundle
INSTALLER="$W/drop-bundle.sh"
lands "those bytes install once the bundle check is removed" STUB_ASSETS="$(assets_with sumbyte2 append_sums)"
INSTALLER=$saved
nobundle=$(variant nobundle 's#checksums.txt.sigstore.json#removed-bundle#')
refuses "no bundle" "has no checksums.txt.sigstore.json" cerebe STUB_API_BODY="$nobundle"
drop_check bundle
INSTALLER="$W/drop-bundle.sh"
lands "a missing bundle installs once the bundle check is removed" STUB_API_BODY="$nobundle"
INSTALLER=$saved
noprov=$(variant noprov 's#cerebe-cyclone.intoto.jsonl#removed-provenance#')
refuses "no provenance" "has no cerebe-cyclone.intoto.jsonl" cerebe STUB_API_BODY="$noprov"
drop_check provenance
INSTALLER="$W/drop-provenance.sh"
lands "missing provenance installs once the provenance check is removed" STUB_API_BODY="$noprov"
INSTALLER=$saved
sed 's#cli-release.yml@refs/heads/main#cli-release.yml@refs/heads/not-main#' "$saved" > "$W/wrong-id.sh"
chmod 0755 "$W/wrong-id.sh"
INSTALLER="$W/wrong-id.sh"
refuses "wrong identity" "could not download cosign" cerebe
also "  cosign was given the wrong identity" grep -q 'refs/heads/not-main' "$c/cosign"
grep -v -- '--certificate-identity' "$W/wrong-id.sh" > "$W/no-identity.sh"
chmod 0755 "$W/no-identity.sh"
INSTALLER="$W/no-identity.sh"
lands "the wrong identity is refused only by the identity flag"
INSTALLER=$saved
refuses "asset download fails" "download failed: $A" cerebe STUB_ASSETS="$(assets_with gone rm "$A")"

echo "1..$n"
if [ "$failed" -eq 0 ]; then echo "# all $n passed ($TEST_SH)"; else echo "# $failed of $n FAILED ($TEST_SH)"; fi
[ "$failed" -eq 0 ]
