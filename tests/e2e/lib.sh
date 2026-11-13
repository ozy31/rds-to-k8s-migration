# Helpers for the end-to-end tests. Sourced.
# shellcheck shell=bash
set -euo pipefail
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }

# acked <pod>: sequence numbers the writer got a commit for.
acked() { kubectl -n app logs "$1" | awk '$1 == "ok" {print $2}' | sort -n; }

# write_gap_ms <pod> <from ms>: the longest time between two acknowledged
# writes after <from>: what a client saw as write downtime.
write_gap_ms() {
  kubectl -n app logs "$1" | awk -v from="$2" '$1 == "ok" && $3 >= from { if (prev) { g = $3 - prev; if (g > max) max = g } prev = $3 } END { print max + 0 }'
}

# missing <acked file> <present file>: acknowledged but absent.
missing() { comm -23 <(sort "$1") <(sort "$2") | wc -l | tr -d ' '; }

wait_until() { # wait_until <timeout s> <command...>
  local t=$1; shift
  for ((i = 0; i < t; i++)); do "$@" && return 0; sleep 1; done
  return 1
}
