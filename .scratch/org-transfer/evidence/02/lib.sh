# Sourced by settings.sh and org.sh. One helper, get, makes every read.
# Needs an authenticated gh and jq on PATH.
# shellcheck shell=sh
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }

tmp=$(mktemp -d) || fail 'mktemp failed'
trap 'rm -rf "${tmp:?}"' EXIT

# Every projection may call scrub, which drops the keys that name an object
# rather than describe it: ids, node ids, URLs and timestamps. What is left is
# what 03 diffs.
jq_defs='def scrub: walk(if type == "object" then with_entries(select(.key | test("^(id|node_id)$|(^|_)url$|_at$") | not)) else . end);'

# get <heading> <endpoint> <jq filter>: one GET, headers included. It prints
# the heading, the HTTP status and, for a 2xx body, the projection. A 403 or
# 404 is an answer, recorded with GitHub's message, and the script goes on; so
# is a 204. Anything else, no response at all (gh not logged in, no network),
# a rate limit, or a second page the script would not read, stops it. The
# status is left in $status and the body in $tmp/body for a follow-up read.
# per_page goes in the endpoint: gh's -f and -F would turn the GET into a POST.
get() {
  printf '\n== %s: gh api %s\n' "$1" "$2"
  : >"$tmp/out"
  gh api -i "$2" >"$tmp/out" 2>"$tmp/err" || :
  [ -s "$tmp/out" ] || fail "gh api $2: no response: $(cat "$tmp/err")"
  tr -d '\r' <"$tmp/out" |
    awk -v h="$tmp/head" -v b="$tmp/body" '
      BEGIN { printf "" > h; printf "" > b }
      body { print > b; next }
      /^$/ { body = 1; next }
      { print > h }'
  status=$(sed -n '1s/^HTTP\/[0-9.]* \([0-9][0-9]*\).*/\1/p' "$tmp/head")
  [ -n "$status" ] || fail "gh api $2: no HTTP status line"
  if grep -qi '^link:.*rel="next"' "$tmp/head"; then
    fail "gh api $2: more than one page; raise per_page or read the next"
  fi
  case $status in
    2??)
      if [ ! -s "$tmp/body" ]; then
        printf 'status: %s (no body)\n' "$status"
        return 0
      fi
      printf 'status: %s\n' "$status"
      v=$(jq -r -S "$jq_defs $3" "$tmp/body") || fail "gh api $2: jq failed"
      printf '%s\n' "${v:-(empty)}"
      ;;
    403 | 404)
      msg=$(jq -r '.message // ""' "$tmp/body" 2>/dev/null) || msg=''
      case $msg in
        *'rate limit'*) fail "gh api $2: $msg" ;;
      esac
      printf 'status: %s %s\n' "$status" "$msg"
      ;;
    *) fail "gh api $2: HTTP $status: $(cat "$tmp/body")" ;;
  esac
}

# header <subject>: when, with which tools, and what was read.
header() {
  v=$(gh --version) || fail 'gh --version failed'
  v=$(printf '%s\n' "$v" | head -n 1)
  j=$(jq --version) || fail 'jq --version failed'
  printf 'date: %s\n%s\n%s\n%s\n' "$(date -u +%Y-%m-%dT%H:%MZ)" "$v" "$j" "$1"
}
