#!/usr/bin/env bash
# relevio: print the Areas value for a handoff's commit range.
#
# The `Areas:` field is what lets a future session on another branch discover
# that yours was here. It is derived from git, never guessed, and this script
# is the single definition of that derivation so the /handoff command does not
# have to re-type a pipeline. The subtlety it hides: `Commits: a..b` names an
# INCLUSIVE range, while git's `a..b` excludes `a`, so an agent typing the
# obvious thing would silently drop its own first commit.
#
# Usage: relevio-areas.sh <first>..<last>
#        relevio-areas.sh none
#
# Exit 0 prints the value to paste after "Areas: ". Exit 2 if the range no
# longer resolves (rebased or squashed history), in which case it says so
# rather than printing a value that would be wrong.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/relevio-handoffs-lib.sh"

case "${1:-}" in
  -h|--help) relevio_usage "${BASH_SOURCE[0]}"; exit 0 ;;
  '') die "no commit range given (usage: relevio-areas.sh <first>..<last>, or: none)" ;;
esac

TOP="$(relevio_top)"
areas_for_range "$1" \
  || die "the range $1 does not resolve in this repository (rebased or squashed history?), so Areas cannot be derived from it. Set the field by hand, or to \"none\"."
