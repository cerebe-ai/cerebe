#!/bin/sh
# The setup action is the CI install method. It fails closed by running
# install.sh after the official cosign and slsa-verifier installers. Removing
# either installer, or the install.sh invocation, fails this test.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ACTION="$HERE/../../setup/action.yml"
n=0; failed=0
need() {
  n=$((n+1))
  if grep -qF -- "$1" "$ACTION"; then
    printf 'ok %d - %s\n' "$n" "$2"
  else
    printf 'not ok %d - %s\n' "$n" "$2"
    failed=$((failed+1))
  fi
}
absent() {
  n=$((n+1))
  if grep -qF -- "$1" "$ACTION"; then
    printf 'not ok %d - %s\n' "$n" "$2"
    failed=$((failed+1))
  else
    printf 'ok %d - %s\n' "$n" "$2"
  fi
}
need 'sigstore/cosign-installer@v4.1.2' 'uses the pinned cosign-installer'
need 'cosign-release: v3.0.6' 'pins cosign v3.0.6'
need 'slsa-framework/slsa-verifier/actions/installer@v2.7.1' 'uses the pinned slsa-verifier installer'
# The patterns are literal text from action.yml. They must not expand.
# shellcheck disable=SC2016
need 'raw.githubusercontent.com/${GITHUB_ACTION_REPOSITORY}/${ref}/install.sh' 'fetches install.sh from the same ref'
# shellcheck disable=SC2016
need 'sh "$script"' 'runs that install.sh'
absent 'CEREBE_SKIP' 'has no skip variable'
absent 'bypass' 'has no bypass'
echo "1..$n"
[ "$failed" -eq 0 ]
