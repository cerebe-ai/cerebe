#!/bin/sh
# Exercise the shipped dispatch without curl, tar or checksum tools on PATH.
# The native Windows jobs separately verify MSYS conversion and real installs.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
INSTALLER=${INSTALLER:-"$HERE/../../install.sh"}
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT HUP INT TERM
mkdir -p "$W/bin" "$W/caller with spaces"
cat > "$W/bin/uname" <<'SH'
#!/bin/sh
printf '%s\n' "$HANDOFF_OS"
SH
cat > "$W/bin/powershell.exe" <<'SH'
#!/bin/sh
printf '%s\n' "$PWD" "$CI" "$CEREBE_INSTALL_DIR" "${CEREBE_RELEASE_JSON:-}" "$CEREBE_SENTINEL" \
  "$CEREBE_EMPTY" "$MSYS2_ENV_CONV_EXCL" "$@" > "$HANDOFF_TRACE"
exit "$HANDOFF_EXIT"
SH
chmod +x "$W/bin/uname" "$W/bin/powershell.exe"
# TEST_SH intentionally permits a shell plus options (e.g. bash --posix).
# shellcheck disable=SC2086
set -- ${TEST_SH:-sh}
shell_path=$(command -v "$1")
shift
export CI='ci /literal:with spaces' CEREBE_INSTALL_DIR='C:\caller path\bin'
export CEREBE_RELEASE_JSON=''
export CEREBE_SENTINEL='/literal/path:/second path' CEREBE_EMPTY=''
export HANDOFF_TRACE="$W/trace"
for HANDOFF_OS in MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0; do
  export HANDOFF_OS
  for MSYS2_ENV_CONV_EXCL in '' KEEP_ME '*'; do
    export MSYS2_ENV_CONV_EXCL
    case "$MSYS2_ENV_CONV_EXCL" in
      '*') expected_exclusion='*' ;;
      '') expected_exclusion='CI=;CEREBE_' ;;
      *) expected_exclusion='KEEP_ME;CI=;CEREBE_' ;;
    esac
    for HANDOFF_EXIT in 0 37; do
      export HANDOFF_EXIT
      code=0
      (cd "$W/caller with spaces"; PATH="$W/bin" "$shell_path" "$@" "$INSTALLER") \
        > "$W/output" 2>&1 || code=$?
      [ "$code" -eq "$HANDOFF_EXIT" ] || { cat "$W/output"; exit 1; }
      printf '%s\n' "$W/caller with spaces" "$CI" "$CEREBE_INSTALL_DIR" \
        "$CEREBE_RELEASE_JSON" "$CEREBE_SENTINEL" "$CEREBE_EMPTY" "$expected_exclusion" \
        -NoProfile -ExecutionPolicy ByPass -Command \
        'irm https://cerebe.ai/install.ps1 | iex' > "$W/expected"
      diff -u "$W/expected" "$HANDOFF_TRACE"
      echo "ok: $HANDOFF_OS delegates with cwd/env/arguments and exit $HANDOFF_EXIT"
    done
  done
done
cat > "$W/bin/cygpath" <<'SH'
#!/bin/sh
[ "$1" = '-w' ] || exit 23
case "$2" in
  '/posix/install dir') printf '%s\n' 'C:\native install' ;;
  '/posix/release.json') printf '%s\n' 'C:\native release.json' ;;
  *) exit 23 ;;
esac
SH
chmod +x "$W/bin/cygpath"
export HANDOFF_EXIT=0 MSYS2_ENV_CONV_EXCL=KEEP_ME
for HANDOFF_OS in MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0; do
  export HANDOFF_OS CEREBE_INSTALL_DIR='/posix/install dir' CEREBE_RELEASE_JSON='/posix/release.json'
  (cd "$W/caller with spaces"; PATH="$W/bin" "$shell_path" "$@" "$INSTALLER")
  printf '%s\n' "$W/caller with spaces" "$CI" 'C:\native install' 'C:\native release.json' \
    "$CEREBE_SENTINEL" "$CEREBE_EMPTY" 'KEEP_ME;CI=;CEREBE_' \
    -NoProfile -ExecutionPolicy ByPass -Command \
    'irm https://cerebe.ai/install.ps1 | iex' > "$W/expected"
  diff -u "$W/expected" "$HANDOFF_TRACE"
  echo "ok: $HANDOFF_OS translates only the two known POSIX paths"
done
for field in CEREBE_INSTALL_DIR CEREBE_RELEASE_JSON; do
  export CEREBE_INSTALL_DIR='C:\native install' CEREBE_RELEASE_JSON='/unconvertible'
  if [ "$field" = CEREBE_INSTALL_DIR ]; then export CEREBE_INSTALL_DIR='/unconvertible'; fi
  rm -f "$HANDOFF_TRACE"
  code=0
  PATH="$W/bin" "$shell_path" "$@" "$INSTALLER" > "$W/output" 2>&1 || code=$?
  [ "$code" -ne 0 ]
  grep -q "could not translate $field" "$W/output"
  [ ! -f "$HANDOFF_TRACE" ]
  echo "ok: failed $field conversion stops before PowerShell"
done
rm "$W/bin/cygpath"
export CEREBE_INSTALL_DIR='relative target/bin' CEREBE_RELEASE_JSON='relative release.json'
(cd "$W/caller with spaces"; PATH="$W/bin" "$shell_path" "$@" "$INSTALLER")
printf '%s\n' "$W/caller with spaces" "$CI" "$CEREBE_INSTALL_DIR" "$CEREBE_RELEASE_JSON" \
  "$CEREBE_SENTINEL" "$CEREBE_EMPTY" 'KEEP_ME;CI=;CEREBE_' \
  -NoProfile -ExecutionPolicy ByPass -Command \
  'irm https://cerebe.ai/install.ps1 | iex' > "$W/expected"
diff -u "$W/expected" "$HANDOFF_TRACE"
echo 'ok: relative overrides are unchanged and need no cygpath'
export CEREBE_INSTALL_DIR='//server/share/bin' CEREBE_RELEASE_JSON='//server/share/release.json'
(cd "$W/caller with spaces"; PATH="$W/bin" "$shell_path" "$@" "$INSTALLER")
printf '%s\n' "$W/caller with spaces" "$CI" "$CEREBE_INSTALL_DIR" "$CEREBE_RELEASE_JSON" \
  "$CEREBE_SENTINEL" "$CEREBE_EMPTY" 'KEEP_ME;CI=;CEREBE_' \
  -NoProfile -ExecutionPolicy ByPass -Command \
  'irm https://cerebe.ai/install.ps1 | iex' > "$W/expected"
diff -u "$W/expected" "$HANDOFF_TRACE"
echo 'ok: native UNC overrides are unchanged and need no cygpath'
export CEREBE_INSTALL_DIR='/posix/install dir'
code=0
PATH="$W/bin" "$shell_path" "$@" "$INSTALLER" > "$W/output" 2>&1 || code=$?
[ "$code" -ne 0 ]
grep -q 'required tool not found: cygpath' "$W/output"
echo 'ok: a POSIX path names a missing cygpath'
rm "$W/bin/powershell.exe"
code=0
PATH="$W/bin" "$shell_path" "$@" "$INSTALLER" > "$W/output" 2>&1 || code=$?
[ "$code" -ne 0 ]
grep -q 'required tool not found: powershell.exe' "$W/output"
echo 'ok: missing PowerShell is named'
