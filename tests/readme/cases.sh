#!/bin/sh
# Offline cases for tests/readme/run.sh. Each one writes a README, runs the
# check on it, and requires both the exit status and a fragment of what it said.
#
#   sh tests/readme/cases.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
check="$here/run.sh"
page='https://github.com/apps/cerebe-factory/installations/new'
good="$page?state=release-readme"
eol=$(printf '\r')
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ran=0
failed=0

# expect NAME STATUS FRAGMENT [LINE...]
expect() {
  name=$1 want=$2 fragment=$3
  shift 3
  if [ $# -eq 0 ]; then : > "$work/readme.md"; else printf '%s\n' "$@" > "$work/readme.md"; fi
  got=0
  out=$(sh "$check" "$work/readme.md" 2>&1) || got=$?
  ran=$((ran + 1))
  case $out in
    *"$fragment"*) seen=yes ;;
    *) seen=no ;;
  esac
  if [ "$got" -eq "$want" ] && [ "$seen" = yes ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: wanted exit $want and \"$fragment\", got exit $got: $out"
    failed=$((failed + 1))
  fi
}

# The exact link passes.
expect "the correct link" 0 "1 install link(s), each with state=release-readme" \
  "separate, hosted control plane: **[install the Cerebe Factory GitHub App]($good)**"
expect "two correct links on one line" 0 "2 install link(s)" \
  "[one]($good) and [two]($good)"
expect "the correct link with CRLF line endings" 0 "1 install link(s)" \
  "[install]($good)$eol"

# A link that is not exactly that fails, and says how many.
expect "a bare URL" 1 "1 of 1 install URL(s) are not inline links ending in" \
  "Install here: $page"
expect "a link with no state" 1 "1 of 1 install URL(s) are not inline links ending in" \
  "[install]($page)"
expect "a link with the wrong state" 1 "1 of 1 install URL(s) are not inline links ending in" \
  "[install]($page?state=site-home)"
expect "a link whose state is a prefix of ours" 1 "are not inline links ending in" \
  "[install]($page?state=release)"
expect "a link whose state continues ours" 1 "are not inline links ending in" \
  "[install]($good-evil)"
expect "a link whose state carries a campaign" 1 "are not inline links ending in" \
  "[install]($good.fall)"
expect "a link with more query after the state" 1 "are not inline links ending in" \
  "[install]($good&utm_source=a)"
expect "a link with a title" 1 "are not inline links ending in" \
  "[install]($good \"Install\")"
expect "one correct link and one bare, on one line" 1 "1 of 2 install URL(s) are not inline links ending in" \
  "[one]($good) and [two]($page)"
expect "a correct link and a bare URL in prose" 1 "1 of 2 install URL(s) are not inline links ending in" \
  "[install]($good)" "Or open $page for details."

# The right URL and state, but not an inline link.
expect "the correct URL as prose" 1 "are not inline links ending in" \
  "Install here: $good"
expect "the correct URL in prose, closed by a parenthesis" 1 "are not inline links ending in" \
  "No install link. Literal marker in prose: $good)"
expect "an autolink" 1 "are not inline links ending in" \
  "<$good>"
expect "a reference-style definition" 1 "are not inline links ending in" \
  "[install]: $good"
expect "an HTML anchor" 1 "are not inline links ending in" \
  "<a href=\"$good\">install</a>"

# HTML comments are not seen by a reader, so a commented-out link is no link.
expect "a link inside a one-line comment" 1 "links no Cerebe Factory install page" \
  "<!-- [install]($good) -->"
expect "a link inside a multi-line comment" 1 "links no Cerebe Factory install page" \
  "<!--" "[install]($good)" "-->"
expect "a comment that never closes hides the rest" 1 "links no Cerebe Factory install page" \
  "<!-- never closed" "[install]($good)"
expect "a link after a comment on its line" 0 "1 install link(s)" \
  "<!-- note --> [install]($good)"
expect "a link before a comment on its line" 0 "1 install link(s)" \
  "[install]($good) <!-- note -->"
expect "a link after a multi-line comment" 0 "1 install link(s)" \
  "<!--" "a note" "-->" "[install]($good)"
expect "a bare URL inside a comment beside the correct link" 0 "1 install link(s)" \
  "<!-- $page -->" "[install]($good)"
expect "a commented-out link does not excuse a bare URL" 1 "1 of 1 install URL(s) are not inline links ending in" \
  "<!-- [install]($good) -->" "Or open $page for details."

# Nothing to check.
expect "no install page at all" 1 "links no Cerebe Factory install page" \
  "Nothing to install here."
expect "another App's install page" 1 "links no Cerebe Factory install page" \
  "[install](https://github.com/apps/other-app/installations/new)"
expect "an empty file" 1 "links no Cerebe Factory install page"
got=0
out=$(sh "$check" "$work/missing.md" 2>&1) || got=$?
ran=$((ran + 1))
case $out in
  *"cannot read it"*) seen=yes ;;
  *) seen=no ;;
esac
if [ "$got" -eq 1 ] && [ "$seen" = yes ]; then
  echo "ok   a missing file"
else
  echo "FAIL a missing file: wanted exit 1 and \"cannot read it\", got exit $got: $out"
  failed=$((failed + 1))
fi

if [ "$failed" -ne 0 ]; then
  echo "$failed of $ran case(s) failed" >&2
  exit 1
fi
echo "$ran case(s) behave as stated"
