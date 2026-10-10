#!/bin/sh
# README.md must send people who want hosted review to the Cerebe Factory
# GitHub App with GitHub's `state` naming this README: the App's Setup URL
# records `state` as where a developer first came from, so an install link
# without it loses that.
#
# The check is exact. In the README as a reader sees it (HTML comments removed;
# an unclosed <!-- hides the rest of the file, as it does in a browser), every
# occurrence of the App's install page URL must be the destination of an
# inline Markdown link that carries that state and nothing after it:
#
#     [text](https://github.com/apps/cerebe-factory/installations/new?state=release-readme)
#
# and there must be at least one. A bare URL, a link with no state or another
# one, a state with more after it (release-readme-2, release-readme.fall,
# &utm_source=a), a link title, and the same URL as an autolink, a reference
# definition or an HTML anchor all fail, each counted in the message. The
# closing parenthesis is the end of the state: without it every longer value
# would pass.
#
# The check reads the file and renders nothing, so a complete link inside a
# fenced code block still counts, and only this spelling of the page is
# recognised (not http://, nor another letter case).
#
# Usage: sh tests/readme/run.sh [README.md]
set -eu

readme="${1:-README.md}"
page='https://github.com/apps/cerebe-factory/installations/new'
link="]($page?state=release-readme)"

if [ ! -r "$readme" ]; then
  echo "$readme: cannot read it" >&2
  exit 1
fi

# In the README without its HTML comments (a reader never sees them, so a link
# that is commented out is not a link), count the install page URL and the
# exact link. awk counts, because busybox's grep -o reports one match per line.
counts=$(awk -v page="$page" -v link="$link" '
  function count(text, needle,    n, i) {
    n = 0
    while ((i = index(text, needle)) > 0) {
      n++
      text = substr(text, i + length(needle))
    }
    return n
  }
  {
    s = $0
    out = ""
    while (s != "") {
      if (hidden) {
        i = index(s, "-->")
        if (i == 0) break
        s = substr(s, i + 3)
        hidden = 0
      } else {
        i = index(s, "<!--")
        if (i == 0) { out = out s; break }
        out = out substr(s, 1, i - 1)
        s = substr(s, i + 4)
        hidden = 1
      }
    }
    total += count(out, page)
    good += count(out, link)
  }
  END { print total + 0, good + 0 }' "$readme")
read -r total good <<EOF
$counts
EOF

if [ "$total" -eq 0 ]; then
  echo "$readme links no Cerebe Factory install page" >&2
  exit 1
fi
if [ "$total" -ne "$good" ]; then
  echo "$readme: $((total - good)) of $total install URL(s) are not inline links ending in $link" >&2
  exit 1
fi
echo "$readme: $total install link(s), each with state=release-readme"
