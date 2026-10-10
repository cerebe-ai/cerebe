#!/bin/sh
# Every link in README.md to the Cerebe Factory GitHub App's install page names
# this README in GitHub's `state` (cerebe-ai/dark-factory Cycle 107 EC25): the
# App's Setup URL records it as where a developer first came from. A link
# without it, or a README with no install link at all, fails.
#
# Usage: sh tests/readme/run.sh [README.md]
set -eu
readme="${1:-README.md}"
page='https://github.com/apps/cerebe-factory/installations/new'
total=$(grep -oF "$page" "$readme" | wc -l | tr -d ' ')
tagged=$(grep -oF "$page?state=release-readme)" "$readme" | wc -l | tr -d ' ')
if [ "$total" -eq 0 ]; then
  echo "$readme links no Cerebe Factory install page" >&2
  exit 1
fi
if [ "$total" -ne "$tagged" ]; then
  echo "$readme: $((total - tagged)) of $total install link(s) lack ?state=release-readme" >&2
  exit 1
fi
echo "$readme: $total install link(s), each with state=release-readme"
