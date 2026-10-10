#!/bin/sh
# README.md must send people who want hosted review to the Cerebe Factory
# GitHub App with GitHub's `state` naming this README: the App's Setup URL
# records `state` as where a developer first came from, so an install link
# without it loses that.
#
# The check is exact. The README must carry this link, and every occurrence of
# the App's install page URL must be part of it:
#
#     [install the Cerebe Factory GitHub App](https://github.com/apps/cerebe-factory/installations/new?state=release-readme)
#
# So these fail, each counted in the message: a bare URL; a link with no state,
# another one, or more after it (release-readme-2, release-readme.fall,
# &utm_source=a); a link title; other link text; an image or an escaped bracket;
# and the same URL as prose, an autolink, a reference definition or an HTML
# anchor. The closing parenthesis is the end of the state: without it every
# longer value would pass.
#
# Only what a reader sees counts. HTML comments and fenced code blocks (``` or
# ~~~) are skipped, so a link that is commented out or shown as code is no link,
# and a comment marker inside a code block is just text. An unclosed comment or
# fence hides the rest of the file. The check reads the file and renders
# nothing: inline code, fences inside block quotes, indented code blocks and raw
# HTML blocks are not recognised, and neither is any spelling of the page but
# this one (http://, another letter case).
#
# Usage: sh tests/readme/run.sh [README.md]
set -eu

readme="${1:-README.md}"
page='https://github.com/apps/cerebe-factory/installations/new'
link="[install the Cerebe Factory GitHub App]($page?state=release-readme)"

if [ ! -r "$readme" ]; then
  echo "$readme: cannot read it" >&2
  exit 1
fi

# Count, in what a reader sees, the install page URL and the exact link. awk
# counts, because busybox's grep -o reports one match per line.
counts=$(awk -v page="$page" -v link="$link" '
  function count(text, needle,    n, i) {
    n = 0
    while ((i = index(text, needle)) > 0) {
      n++
      text = substr(text, i + length(needle))
    }
    return n
  }
  function exact(text,    n, i, c) {
    n = 0
    while ((i = index(text, link)) > 0) {
      c = (i > 1) ? substr(text, i - 1, 1) : ""
      if (c != "!" && c != "\\") n++
      text = substr(text, i + length(link))
    }
    return n
  }
  function fence_run(s,    n) {
    sub(/^[ \t]*/, "", s)
    fch = substr(s, 1, 1)
    if (fch != "`" && fch != "~") return 0
    n = 0
    while (substr(s, n + 1, 1) == fch) n++
    ftail = substr(s, n + 1)
    return n
  }
  function uncommented(s,    out, i) {
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
    return out
  }
  {
    if (fence_n) {
      if (fence_run($0) >= fence_n && fch == fence_ch && ftail ~ /^[ \t\r]*$/) fence_n = 0
      next
    }
    if (!hidden && (n = fence_run($0)) >= 3 && !(fch == "`" && index(ftail, "`") > 0)) {
      fence_n = n
      fence_ch = fch
      next
    }
    out = uncommented($0)
    total += count(out, page)
    good += exact(out)
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
  echo "$readme: $((total - good)) of $total install URL(s) are not part of the link $link" >&2
  exit 1
fi
echo "$readme: $total install link(s), each with state=release-readme"
