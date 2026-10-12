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
need 'sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6' 'pins cosign-installer v4.1.2 by commit'
need 'cosign-release: v3.0.6' 'pins cosign v3.0.6'
need 'slsa-framework/slsa-verifier/actions/installer@ea584f4502babc6f60d9bc799dbbb13c1caa9ee6' 'pins the slsa-verifier installer v2.7.1 by commit'
need 'repositories/1181720228/releases' 'fetches the release with the job token'
need 'CEREBE_RELEASE_JSON' 'hands that object to install.sh'
# The path is literal text from action.yml.
# shellcheck disable=SC2016
need '${GITHUB_ACTION_PATH}/../install.sh' 'runs the install.sh that shipped with the action'
absent 'raw.githubusercontent.com' 'does not download a second install.sh'
absent 'CEREBE_SKIP' 'has no skip variable'
absent 'bypass' 'has no bypass'
echo "1..$n"
[ "$failed" -eq 0 ]
