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

# build_assets VERSION DIR — both binaries for every target, plus checksums.txt
build_assets() {
  mkdir -p "$2" "$W/src-$1"
  for b in cerebe cyclone; do
    printf '#!/bin/sh\necho "%s v%s"\n' "$b" "$1" > "$W/src-$1/$b"; chmod 0755 "$W/src-$1/$b"
    for t in darwin_amd64 darwin_arm64 linux_amd64 linux_arm64; do
      tar -czf "$2/${b}_$1_${t}.tar.gz" -C "$W/src-$1" "$b"
    done
  done
  (cd "$2" && sha256 ./*.tar.gz | sed 's#  \./#  #' > checksums.txt)
}
build_assets "$V" "$W/assets"

# Fixture and asset variants. Each prints the path of what it wrote.
variant() { sed "$2" "$FIXTURE" > "$W/$1.json"; printf '%s' "$W/$1.json"; }
compact() { sed 's/^[[:space:]]*//' "$FIXTURE" | tr -d '\n' > "$W/compact.json"; printf '%s' "$W/compact.json"; }
crlf() { awk '{ printf "%s\r\n", $0 }' "$FIXTURE" > "$W/crlf.json"; printf '%s' "$W/crlf.json"; }
garbage() { printf '{"message": "Bad credentials"}' > "$W/garbage.json"; printf '%s' "$W/garbage.json"; }
assets_with() { # assets_with NAME CMD... — a copy of the assets, edited by CMD inside it
  d="$W/assets-$1"; shift; cp -R "$W/assets" "$d"; (cd "$d" && "$@") || exit 1; printf '%s' "$d"
}
flip_checksums() { awk '{ c = substr($1, 1, 1); r = (c == "0") ? "1" : "0"; print r substr($0, 2) }' checksums.txt > s && mv s checksums.txt; }
append_byte() { printf X >> "$1"; }
drop_line() { grep -v " $1\$" checksums.txt > s; mv s checksums.txt; }

n=0; failed=0
run() { # run ENV=VAL... — the installer under $TEST_SH, from a clean non-git cwd
  n=$((n+1)); c="$W/case$n"; mkdir -p "$c/cwd"; : > "$c/urls"
  # TEST_SH may carry flags, e.g. "bash --posix", so it stays unquoted.
  # shellcheck disable=SC2086
  (cd "$c/cwd" && env PATH="$W/bin:$PATH" STUB_LOG="$c/urls" STUB_ASSETS="$W/assets" \
    STUB_API_BODY="$FIXTURE" CEREBE_INSTALL_DIR="$c/bin" "$@" $TEST_SH "$INSTALLER") > "$c/out" 2>&1
  rc=$?
}
report() { # report yes|no NAME
  if [ "$1" = yes ]; then printf 'ok %d - %s\n' "$n" "$2"; return; fi
  printf 'not ok %d - %s (rc=%s)\n' "$n" "$2" "$rc"
  sed 's/^/#   /' "$c/out"; sed 's/^/#   requested: /' "$c/urls"; failed=$((failed+1))
}
installs() { # installs NAME API-PATH VERSION ENV=VAL... — installs VERSION via that endpoint
  name=$1 path=$2 want=$3; shift 3; run "$@"; ok=no
  if [ "$rc" -eq 0 ] && [ "$("$c/bin/cerebe" --version 2>&1)" = "cerebe v$want" ] \
     && [ "$("$c/bin/cyclone" --version 2>&1)" = "cyclone v$want" ] \
     && [ "$(sed -n 1p "$c/urls")" = "$API/$path" ] && ! grep -q evil "$c/urls"; then ok=yes; fi
  report "$ok" "$name"
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
refuses "tampered asset" "checksum mismatch for $A" cerebe STUB_ASSETS="$(assets_with bytes append_byte "$A")"
refuses "missing checksum line" "no checksum entry for $A" cerebe STUB_ASSETS="$(assets_with line drop_line "$A")"
refuses "tampered second binary" "checksum mismatch for $Y" cyclone STUB_ASSETS="$(assets_with bytes2 append_byte "$Y")"
refuses "asset download fails" "download failed: $A" cerebe STUB_ASSETS="$(assets_with gone rm "$A")"

echo "1..$n"
if [ "$failed" -eq 0 ]; then echo "# all $n passed ($TEST_SH)"; else echo "# $failed of $n FAILED ($TEST_SH)"; fi
[ "$failed" -eq 0 ]
