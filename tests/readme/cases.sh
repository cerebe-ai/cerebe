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
text='install the Cerebe Factory GitHub App'
link="[$text]($good)"
bad="are not part of the link"
none="links no Cerebe Factory install page"
fence='```'
fence4='````'
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
  case "$out" in
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
  "separate, hosted control plane: **$link**"
expect "two correct links on one line" 0 "2 install link(s)" \
  "$link and $link"
expect "the correct link with CRLF line endings" 0 "1 install link(s)" \
  "$link$eol"

# Anything else that names the install page fails, and the message counts it.
expect "a bare URL" 1 "1 of 1 install URL(s) $bad" \
  "Install here: $page"
expect "a link with no state" 1 "1 of 1 install URL(s) $bad" \
  "[$text]($page)"
expect "a link with the wrong state" 1 "1 of 1 install URL(s) $bad" \
  "[$text]($page?state=site-home)"
expect "a link whose state is a prefix of ours" 1 "$bad" \
  "[$text]($page?state=release)"
expect "a link whose state continues ours" 1 "$bad" \
  "[$text]($good-evil)"
expect "a link whose state carries a campaign" 1 "$bad" \
  "[$text]($good.fall)"
expect "a link with more query after the state" 1 "$bad" \
  "[$text]($good&utm_source=a)"
expect "a link with a title" 1 "$bad" \
  "[$text]($good \"Install\")"
expect "other link text" 1 "$bad" \
  "[click here]($good)"
expect "a linked image" 1 "$bad" \
  "[![badge](https://example.com/badge.svg)]($good)"
expect "one correct link and one bare, on one line" 1 "1 of 2 install URL(s) $bad" \
  "$link and [two]($page)"
expect "a correct link and a bare URL in prose" 1 "1 of 2 install URL(s) $bad" \
  "$link" "Or open $page for details."

# The right URL and state, but not that link.
expect "the correct URL as prose" 1 "$bad" \
  "Install here: $good"
expect "the correct URL in prose, closed by a parenthesis" 1 "$bad" \
  "No install link. Literal marker in prose: $good)"
expect "an orphan ]( suffix" 1 "$bad" \
  "Not a link: ]($good)"
expect "an escaped opening bracket" 1 "$bad" \
  "\\[$text]($good)"
expect "an image" 1 "$bad" \
  "![$text]($good)"
expect "an autolink" 1 "$bad" \
  "<$good>"
expect "a reference-style definition" 1 "$bad" \
  "[$text]: $good"
expect "an HTML anchor" 1 "$bad" \
  "<a href=\"$good\">$text</a>"

# HTML comments are not seen by a reader, so a commented-out link is no link.
expect "a link inside a one-line comment" 1 "$none" \
  "<!-- $link -->"
expect "a link inside a multi-line comment" 1 "$none" \
  "<!--" "$link" "-->"
expect "a comment that never closes hides the rest" 1 "$none" \
  "<!-- never closed" "$link"
expect "a commented-out link does not excuse a bare URL" 1 "1 of 1 install URL(s) $bad" \
  "<!-- $link -->" "Or open $page for details."
expect "a link after a comment on its line" 0 "1 install link(s)" \
  "<!-- note --> $link"
expect "a link before a comment on its line" 0 "1 install link(s)" \
  "$link <!-- note -->"
expect "a link after a multi-line comment" 0 "1 install link(s)" \
  "<!--" "a note" "-->" "$link"
expect "a bare URL inside a comment beside the correct link" 0 "1 install link(s)" \
  "<!-- $page -->" "$link"

# So is code: a fenced block is skipped, and a comment marker inside one is just text.
expect "a link inside a fenced block" 1 "$none" \
  "$fence" "$link" "$fence"
expect "a link inside a ~~~ fenced block" 1 "$none" \
  "~~~" "$link" "~~~"
expect "a link inside an indented fenced block" 1 "$none" \
  "- step one" "  ${fence}sh" "  $link" "  $fence"
expect "a fence that never closes hides the rest" 1 "$none" \
  "$fence" "$link"
expect "a bare URL inside a fenced block is ignored" 0 "1 install link(s)" \
  "$link" "$fence" "$page" "$fence"
expect "a comment marker inside a fenced block does not hide the link after it" 0 "1 install link(s)" \
  "$fence" "<!-- html" "$fence" "$link"
expect "a fence marker inside a comment is not a fence" 0 "1 install link(s)" \
  "<!--" "$fence" "-->" "<!-- $page -->" "$link"
expect "a fence closed by its own length" 0 "1 install link(s)" \
  "$fence4" "<!-- x" "$fence4" "$link"
expect "a shorter fence line does not close a longer fence" 0 "1 install link(s)" \
  "$fence4" "$fence" "$page" "$fence4" "$link"
expect "a different fence character does not close a fence" 0 "1 install link(s)" \
  "$fence" "~~~" "$page" "$fence" "$link"
expect "a closing fence cannot carry text" 0 "1 install link(s)" \
  "$fence" "${fence}sh" "$page" "$fence" "$link"
expect "backticks around code on one line are not a fence" 0 "1 install link(s)" \
  "${fence}npm install${fence}" "$link"
expect "a ~~~ fence skips a comment marker" 0 "1 install link(s)" \
  "~~~" "<!-- x" "~~~" "$link"
expect "an indented fence skips a comment marker" 0 "1 install link(s)" \
  "  $fence" "<!-- x" "  $fence" "$link"

# Nothing to check.
expect "no install page at all" 1 "$none" \
  "Nothing to install here."
expect "another App's install page" 1 "$none" \
  "[$text](https://github.com/apps/other-app/installations/new)"
expect "an empty file" 1 "$none"
got=0
out=$(sh "$check" "$work/missing.md" 2>&1) || got=$?
ran=$((ran + 1))
case "$out" in
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
