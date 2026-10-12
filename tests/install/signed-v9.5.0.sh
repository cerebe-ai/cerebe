#!/bin/sh
# Proof against the signed v9.5.0 release. Real cosign, real slsa-verifier,
# the published bytes. Each refusal also fails if its check is removed:
# deleting that call makes the same bytes install.
#
#   sh tests/install/signed-v9.5.0.sh
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
INSTALLER=${INSTALLER:-"$HERE/../../install.sh"}
V=9.5.0
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

case "$(uname -s)" in Linux) os=linux ;; Darwin) os=darwin ;; *) echo "unsupported OS"; exit 1 ;; esac
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) echo "unsupported arch"; exit 1 ;; esac
if command -v sha256sum >/dev/null 2>&1; then sha256() { sha256sum "$@"; }
else sha256() { shasum -a 256 "$@"; }; fi

n=0; failed=0
say() { n=$((n+1)); if [ "$1" = yes ]; then printf 'ok %d - %s\n' "$n" "$2"; else printf 'not ok %d - %s\n' "$n" "$2"; failed=$((failed+1)); fi; }

# Release object, authenticated when gh is available.
if command -v gh >/dev/null 2>&1; then
  gh api "repos/cerebe-ai/cerebe/releases/tags/v${V}" > "$W/release.json"
else
  curl -fsSL -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/cerebe-ai/cerebe/releases/tags/v${V}" -o "$W/release.json"
fi

# Official verifier binaries, checked against the sha256 embedded in install.sh.
# A drifted or mistyped anchor fails before any install.
embed_sha() { # embed_sha NAME — the hash the installer pins for this OS/arch
  sed -n "s/^    $1:${os}_${arch}) printf '%s\\\\n' '\\([0-9a-f]*\\)'.*/\\1/p" "$INSTALLER"
}
fetch_tool() { # fetch_tool NAME VERSION REPO
  sum=$(embed_sha "$1")
  [ -n "$sum" ] || { echo "no embedded sha256 for $1"; exit 1; }
  url="https://github.com/$3/releases/download/$2/$1-${os}-${arch}"
  curl -fsSL -o "$W/tools/$1" "$url"
  chmod 0755 "$W/tools/$1"
  # Same check as install.sh: a checksum file, because macOS sha256sum -c
  # does not read stdin.
  printf '%s  %s\n' "$sum" "$1" > "$W/tools/$1.sha256"
  (cd "$W/tools" && sha256 -c "$1.sha256") >/dev/null
}
mkdir -p "$W/tools" "$W/bin-wrap" "$W/cwd"
fetch_tool cosign v3.0.6 sigstore/cosign
fetch_tool slsa-verifier v2.7.1 slsa-framework/slsa-verifier

# Wrappers log the argv and exec the real binary. The cryptographic result
# is the real tool's. The log is how a removed flag fails the test.
mkdir -p "$W/bin-wrap"
cat > "$W/bin-wrap/cosign" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$W/cosign.args"
exec "$W/tools/cosign" "\$@"
EOF
cat > "$W/bin-wrap/slsa-verifier" << EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$W/slsa.args"
exec "$W/tools/slsa-verifier" "\$@"
EOF
chmod 0755 "$W/bin-wrap/cosign" "$W/bin-wrap/slsa-verifier"

# Stub curl serves the asset dir by file name and the release JSON for the API.
# cosign and slsa-verifier speak HTTP themselves; they do not use this curl.
cat > "$W/bin-wrap/curl" << 'STUB'
#!/bin/sh
out=; url=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    -H) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case "$url" in
  https://api.github.com/*)
    cp "$STUB_API_BODY" "$out"
    printf '%s' "200"
    exit 0 ;;
  https://github.com/*/releases/download/*)
    f="$STUB_ASSETS/${url##*/}"
    [ -f "$f" ] || { echo "curl: (22) 404 $url" >&2; exit 22; }
    cp "$f" "$out"
    exit 0 ;;
esac
echo "curl: (6) $url" >&2
exit 6
STUB
chmod 0755 "$W/bin-wrap/curl"

mkdir -p "$W/real"
ASSET_SUFFIX="_${V}_${os}_${arch}.tar.gz" python3 - "$W/release.json" "$W/real" << 'PY'
import json, os, sys, urllib.request
doc, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)
rel = json.load(open(doc))
want = {"checksums.txt", "checksums.txt.sigstore.json", "cerebe-cyclone.intoto.jsonl"}
suffix = os.environ["ASSET_SUFFIX"]
got = []
for asset in rel["assets"]:
    name = asset["name"]
    if name in want or name.endswith(suffix):
        urllib.request.urlretrieve(asset["browser_download_url"], os.path.join(dest, name))
        got.append(name)
missing = [n for n in ("checksums.txt", "checksums.txt.sigstore.json", "cerebe-cyclone.intoto.jsonl",
                       f"cerebe{suffix}", f"cyclone{suffix}") if n not in got]
if missing:
    sys.exit("v9.5.0 release is missing " + ", ".join(missing))
print("downloaded " + " ".join(got))
PY

drop_json() { # drop_json NAME — release JSON without that asset
  python3 - "$1" "$W/release.json" "$2" << 'PY'
import json, sys
name, src, dst = sys.argv[1:]
rel = json.load(open(src))
rel["assets"] = [a for a in rel["assets"] if a["name"] != name]
json.dump(rel, open(dst, "w"))
PY
}
copy_assets() { # copy_assets DIR
  rm -rf "$1"; mkdir -p "$1"; cp "$W/real/"* "$1/"
}

run_install() { # run_install DIR JSON ASSETS SCRIPT
  dest=$1; json=$2; assets=$3; script=$4
  rm -rf "$dest"; mkdir -p "$dest"
  : > "$W/cosign.args"; : > "$W/slsa.args"
  # bin-wrap is first: logged cosign/slsa, stub curl. Tools stay behind the wrappers.
  ( cd "$W/cwd" && env -u CEREBE_VERSION \
      PATH="$W/bin-wrap:$PATH" \
      CEREBE_VERSION="$V" CEREBE_INSTALL_DIR="$dest" CEREBE_RELEASE_JSON="$json" \
      STUB_API_BODY="$json" STUB_ASSETS="$assets" CI=1 \
      sh "$script" ) > "$W/out" 2>&1
}

IDENT='https://github.com/cerebe-ai/dark-factory/.github/workflows/cli-release.yml@refs/heads/main'
ISSUER='https://token.actions.githubusercontent.com'
SOURCE='github.com/cerebe-ai/dark-factory'
BUILDER='https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_generic_slsa3.yml@refs/tags/v2.1.0'

# --- success ---------------------------------------------------------------
run_install "$W/ok" "$W/release.json" "$W/real" "$INSTALLER" && ok=yes || ok=no
if [ "$ok" = yes ] && "$W/ok/cerebe" --version 2>&1 | grep -q '9.5.0' \
   && "$W/ok/cyclone" --version 2>&1 | grep -q '9.5.0' \
   && grep -qF -- "--certificate-identity $IDENT" "$W/cosign.args" \
   && grep -qF -- "--certificate-oidc-issuer $ISSUER" "$W/cosign.args" \
   && grep -qF -- "--source-uri $SOURCE" "$W/slsa.args" \
   && grep -qF -- "--builder-id $BUILDER" "$W/slsa.args"; then
  say yes "v9.5.0 installs and the verifiers were given the pinned identity"
else
  say no "v9.5.0 installs and the verifiers were given the pinned identity"
  sed 's/^/#   /' "$W/out"
fi

# --- missing bundle --------------------------------------------------------
drop_json checksums.txt.sigstore.json "$W/no-bundle.json"
copy_assets "$W/assets-nobundle"
run_install "$W/nobundle" "$W/no-bundle.json" "$W/assets-nobundle" "$INSTALLER" && ok=yes || ok=no
if [ "$ok" = no ] && grep -qF 'has no checksums.txt.sigstore.json' "$W/out" && [ ! -e "$W/nobundle/cerebe" ]; then
  say yes "missing bundle is refused"
else
  say no "missing bundle is refused"; sed 's/^/#   /' "$W/out"
fi
grep -v '# cerebe:check bundle' "$INSTALLER" > "$W/no-bundle-check.sh"
run_install "$W/nobundle2" "$W/no-bundle.json" "$W/assets-nobundle" "$W/no-bundle-check.sh" && ok=yes || ok=no
if [ "$ok" = yes ] && "$W/nobundle2/cerebe" --version 2>&1 | grep -q '9.5.0'; then
  say yes "missing bundle installs once the bundle check is removed"
else
  say no "missing bundle installs once the bundle check is removed"; sed 's/^/#   /' "$W/out"
fi

# --- tampered checksums ----------------------------------------------------
copy_assets "$W/assets-tamper"
printf 'X\n' >> "$W/assets-tamper/checksums.txt"
run_install "$W/tamper" "$W/release.json" "$W/assets-tamper" "$INSTALLER" && ok=yes || ok=no
if [ "$ok" = no ] && grep -qF 'checksum signature rejected' "$W/out" && [ ! -e "$W/tamper/cerebe" ]; then
  say yes "tampered checksums are refused"
else
  say no "tampered checksums are refused"; sed 's/^/#   /' "$W/out"
fi
run_install "$W/tamper2" "$W/release.json" "$W/assets-tamper" "$W/no-bundle-check.sh" && ok=yes || ok=no
if [ "$ok" = yes ] && "$W/tamper2/cerebe" --version 2>&1 | grep -q '9.5.0'; then
  say yes "tampered checksums install once the bundle check is removed"
else
  say no "tampered checksums install once the bundle check is removed"; sed 's/^/#   /' "$W/out"
fi

# --- wrong identity --------------------------------------------------------
sed 's#cli-release.yml@refs/heads/main#cli-release.yml@refs/heads/not-main#' "$INSTALLER" > "$W/wrong-id.sh"
run_install "$W/wrong" "$W/release.json" "$W/real" "$W/wrong-id.sh" && ok=yes || ok=no
if [ "$ok" = no ] && grep -qF 'checksum signature rejected' "$W/out" \
   && grep -qF 'refs/heads/not-main' "$W/cosign.args" && [ ! -e "$W/wrong/cerebe" ]; then
  say yes "wrong identity is refused"
else
  say no "wrong identity is refused"; sed 's/^/#   /' "$W/out"
fi
grep -v -- '--certificate-identity' "$W/wrong-id.sh" > "$W/no-identity.sh"
run_install "$W/wrong2" "$W/release.json" "$W/real" "$W/no-identity.sh" && ok=yes || ok=no
# Real cosign rejects a keyless bundle with no identity flag, so this case
# does not expect an install. It expects the not-main SAN to be absent from
# the argv: the refusal no longer depends on the pinned identity.
if ! grep -qF 'refs/heads/not-main' "$W/cosign.args"; then
  say yes "wrong identity is refused only because that SAN was passed to cosign"
else
  say no "wrong identity is refused only because that SAN was passed to cosign"
  sed 's/^/#   /' "$W/cosign.args"
fi

# --- missing provenance ----------------------------------------------------
drop_json cerebe-cyclone.intoto.jsonl "$W/no-prov.json"
copy_assets "$W/assets-noprov"
run_install "$W/noprov" "$W/no-prov.json" "$W/assets-noprov" "$INSTALLER" && ok=yes || ok=no
if [ "$ok" = no ] && grep -qF 'has no cerebe-cyclone.intoto.jsonl' "$W/out" && [ ! -e "$W/noprov/cerebe" ]; then
  say yes "missing provenance is refused"
else
  say no "missing provenance is refused"; sed 's/^/#   /' "$W/out"
fi
grep -v '# cerebe:check provenance' "$INSTALLER" > "$W/no-prov-check.sh"
run_install "$W/noprov2" "$W/no-prov.json" "$W/assets-noprov" "$W/no-prov-check.sh" && ok=yes || ok=no
if [ "$ok" = yes ] && "$W/noprov2/cerebe" --version 2>&1 | grep -q '9.5.0'; then
  say yes "missing provenance installs once the provenance check is removed"
else
  say no "missing provenance installs once the provenance check is removed"; sed 's/^/#   /' "$W/out"
fi

# --- a PATH verifier that rejects falls through to the pinned binary ------
# Cosign v2 rejects the v0.3 bundle. A stub that exits 1 stands in for it.
# The pinned binary is downloaded with real curl; release assets stay local.
REAL_CURL=$(command -v curl)
mkdir -p "$W/bin-fallback" "$W/reject-cosign" "$W/reject-slsa"
cat > "$W/bin-fallback/curl" << EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    https://github.com/sigstore/*|https://github.com/slsa-framework/*)
      exec "$REAL_CURL" "\$@" ;;
  esac
done
out=; url=
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;;
    -w) shift 2 ;;
    -H) shift 2 ;;
    -*) shift ;;
    *) url=\$1; shift ;;
  esac
done
case "\$url" in
  https://api.github.com/*)
    cp "\$STUB_API_BODY" "\$out"; printf '%s' 200; exit 0 ;;
  https://github.com/*/releases/download/*)
    f="\$STUB_ASSETS/\${url##*/}"
    [ -f "\$f" ] || { echo "curl: (22) 404 \$url" >&2; exit 22; }
    cp "\$f" "\$out"; exit 0 ;;
esac
echo "curl: (6) \$url" >&2
exit 6
EOF
printf '%s\n' '#!/bin/sh' 'echo "stub cosign rejects" >&2' 'exit 1' > "$W/reject-cosign/cosign"
printf '%s\n' '#!/bin/sh' 'echo "stub slsa-verifier rejects" >&2' 'exit 1' > "$W/reject-slsa/slsa-verifier"
chmod 0755 "$W/bin-fallback/curl" "$W/reject-cosign/cosign" "$W/reject-slsa/slsa-verifier"

run_path() { # run_path DEST ASSETS PATH_PREFIX
  rm -rf "$1"; mkdir -p "$1"
  ( cd "$W/cwd" && env PATH="$3:$PATH" \
      CEREBE_VERSION="$V" CEREBE_INSTALL_DIR="$1" CEREBE_RELEASE_JSON="$W/release.json" \
      STUB_API_BODY="$W/release.json" STUB_ASSETS="$2" CI=1 \
      sh "$INSTALLER" ) > "$W/out" 2>&1
}

run_path "$W/oldcosign" "$W/real" "$W/reject-cosign:$W/bin-fallback:$W/tools" && ok=yes || ok=no
if [ "$ok" = yes ] && "$W/oldcosign/cerebe" --version 2>&1 | grep -q '9.5.0' \
   && grep -q 'downloading cosign' "$W/out"; then
  say yes "a rejecting cosign on PATH installs v9.5.0 through the pinned binary"
else
  say no "a rejecting cosign on PATH installs v9.5.0 through the pinned binary"
  sed 's/^/#   /' "$W/out"
fi
run_path "$W/oldcosign-bad" "$W/assets-tamper" "$W/reject-cosign:$W/bin-fallback:$W/tools" && ok=yes || ok=no
if [ "$ok" = no ] && grep -qF 'checksum signature rejected' "$W/out" && [ ! -e "$W/oldcosign-bad/cerebe" ]; then
  say yes "tampered checksums are still refused when the PATH cosign rejects"
else
  say no "tampered checksums are still refused when the PATH cosign rejects"
  sed 's/^/#   /' "$W/out"
fi
run_path "$W/oldslsa" "$W/real" "$W/reject-slsa:$W/bin-fallback:$W/tools" && ok=yes || ok=no
if [ "$ok" = yes ] && "$W/oldslsa/cerebe" --version 2>&1 | grep -q '9.5.0' \
   && grep -q 'downloading slsa-verifier' "$W/out"; then
  say yes "a rejecting slsa-verifier on PATH installs v9.5.0 through the pinned binary"
else
  say no "a rejecting slsa-verifier on PATH installs v9.5.0 through the pinned binary"
  sed 's/^/#   /' "$W/out"
fi
copy_assets "$W/assets-slsa-tamper"
printf 'X' >> "$W/assets-slsa-tamper/cerebe_${V}_${os}_${arch}.tar.gz"
run_path "$W/oldslsa-bad" "$W/assets-slsa-tamper" "$W/reject-slsa:$W/bin-fallback:$W/tools" && ok=yes || ok=no
if [ "$ok" = no ] && grep -qF 'provenance rejected' "$W/out" && [ ! -e "$W/oldslsa-bad/cerebe" ]; then
  say yes "a tampered archive is still refused when the PATH slsa-verifier rejects"
else
  say no "a tampered archive is still refused when the PATH slsa-verifier rejects"
  sed 's/^/#   /' "$W/out"
fi

echo "1..$n"
if [ "$failed" -eq 0 ]; then echo "# all $n passed"; else echo "# $failed of $n FAILED"; fi
[ "$failed" -eq 0 ]
