#!/usr/bin/env bash
# Tests for fm-contact-live-check.sh, the deployed contact endpoint assertion.
#
# The reading that matters most is the one the status alone cannot give. The
# site template ships a contact STUB that answers an empty JSON body with the
# same HTTP 422 the real intake does, and binds name, email and message. Only
# the real intake also binds turnstileToken, so a check that stops at the status
# passes a site whose intake was never ported. test_a_stub_is_named_as_a_stub
# reproduces that shape and asserts the report says the stub is deployed; no
# build that reads only the status can pass it.
#
# The second reading that matters is the one that made this check local in the
# first place: an edge that answers with a challenge page where the API's JSON
# belongs. That is not a deployment fault at all, and
# test_a_challenge_page_is_not_read_as_a_deployment asserts the report says so
# rather than blaming the site.
#
# Every case drives the real script and real curl against a local fixture server
# on the loopback interface, so no case reaches a live site, and no case fakes
# the HTTP client whose answers this check exists to read.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-contact-live-check.sh"
CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-contact-live-check)

command -v python3 >/dev/null 2>&1 || fail "test needs python3 for the fixture endpoint"
command -v curl >/dev/null 2>&1 || fail "test needs curl, which is what the check asks with"
command -v jq >/dev/null 2>&1 || fail "test needs jq, which is what the check reads its endpoint list with"

# --- the fixture endpoint ---------------------------------------------------
#
# One loopback server that answers /api/contact/<mode> with that mode's reply,
# and /api/contact with whatever mode its control file names at that moment.
# The control file is what lets a case change one endpoint's answer without
# changing its URL, which is exactly what a real site does when it is fixed, and
# what the recovery report has to be able to tell apart from an endpoint that
# was removed from the list.

SERVER_PY="$TMP_ROOT/endpoint.py"
SERVER_PID=
PORT_FILE="$TMP_ROOT/port"
MODE_FILE="$TMP_ROOT/mode"

cat > "$SERVER_PY" <<'PY'
import http.server
import json
import sys
import time

MODE_FILE = sys.argv[1]
PORT_FILE = sys.argv[2]


def missing(fields):
    return json.dumps({
        "detail": [
            {"type": "missing", "loc": ["body", f], "msg": "Field required", "input": {}}
            for f in fields
        ]
    }).encode()


CHALLENGE = (
    b'<!DOCTYPE html><html><head><title>Just a moment...</title></head>'
    b'<body><div id="cf-challenge-running"></div>'
    b'<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1"></script>'
    b'</body></html>'
)
PLAIN_PAGE = b'<html><body><h1>404 Not Found</h1><p>nginx</p></body></html>'

REPLIES = {
    # The real intake: 422 naming every field it binds.
    "real": (422, "application/json", missing(["name", "email", "message", "turnstileToken"])),
    # The template's stub: the same status, one field short.
    "stub": (422, "application/json", missing(["name", "email", "message"])),
    # A 422 that is short of more than the stub tell.
    "partial": (422, "application/json", missing(["name"])),
    "notimplemented": (501, "application/json", b'{"detail":"Not Implemented"}'),
    "nosecret": (503, "application/json", b'{"detail":"Service Unavailable"}'),
    "forbidden": (403, "application/json", b'{"detail":"Forbidden"}'),
    "challenge": (403, "text/html; charset=UTF-8", CHALLENGE),
    "interstitial": (200, "text/html; charset=UTF-8", PLAIN_PAGE),
    "accepted": (200, "application/json", b'{"ok":true}'),
}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def do_POST(self):
        mode = self.path.rsplit("/", 1)[-1]
        if self.path == "/api/contact":
            try:
                with open(MODE_FILE) as handle:
                    mode = handle.read().strip()
            except OSError:
                mode = "real"
        if mode == "hang":
            time.sleep(30)
            return
        status, ctype, body = REPLIES.get(mode, REPLIES["real"])
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY

start_server() {
  local waited=0
  printf 'real\n' > "$MODE_FILE"
  python3 "$SERVER_PY" "$MODE_FILE" "$PORT_FILE" &
  SERVER_PID=$!
  while [ ! -s "$PORT_FILE" ]; do
    waited=$((waited + 1))
    [ "$waited" -le 100 ] || fail "the fixture endpoint never reported a port"
    sleep 0.1
  done
  PORT=$(cat "$PORT_FILE")
}

stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

cleanup() {
  stop_server
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

start_server

# The endpoint URL for one fixture mode. The path carries the mode, so several
# endpoints in one list can answer differently in the same sweep.
mode_url() {
  printf 'http://127.0.0.1:%s/api/contact/%s\n' "$PORT" "$1"
}

# The one endpoint whose answer follows the control file rather than its path.
switchable_url() {
  printf 'http://127.0.0.1:%s/api/contact\n' "$PORT"
}

set_mode() {
  printf '%s\n' "$1" > "$MODE_FILE"
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

# write_endpoints <home> <url>...: the endpoint list, in the order given.
write_endpoints() {
  local home=$1 url json=
  shift
  for url in "$@"; do
    json="$json${json:+,}{\"url\":\"$url\"}"
  done
  printf '{"endpoints":[%s]}\n' "$json" > "$home/config/watched-contacts.json"
}

# The watcher check timeout is pinned to its documented default, because the
# sweep budget is cut to fit it and an operator's ambient value would otherwise
# add a report line to cases that mean to be silent. The cases that exercise the
# cut and the bound set their own values.
run_check() {
  local home=$1 out=$2
  shift 2
  local status=0
  env FM_CHECK_TIMEOUT=30 "$@" FM_HOME="$home" FM_CONTACT_CHECK_INTERVAL=0 "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

# --- the silent path --------------------------------------------------------

test_every_real_intake_is_silent() {
  local home out
  home=$(make_home silent)
  write_endpoints "$home" "$(mode_url real)" "$(switchable_url)"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a fleet whose endpoints all answer correctly was not silent: $(cat "$out")"
  assert_present "$home/state/.contact-live" "a completed sweep left no report record"
  pass "every endpoint answering the intake assertion is silent"
}

# --- the reading the status alone cannot give -------------------------------

test_a_stub_is_named_as_a_stub() {
  local home out report
  home=$(make_home stub)
  write_endpoints "$home" "$(mode_url stub)"
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "is running the contact stub, not the real intake" \
    "a 422 that binds only name, email and message was not read as the stub"
  assert_contains "$report" "turnstileToken" "the report did not name the field that separates the stub from the intake"
  assert_contains "$report" "127.0.0.1:$PORT" "the report did not say which host answered"
  pass "a 422 without turnstileToken is reported as the stub, not as a pass"
}

test_a_422_short_of_more_than_the_stub_tell_is_not_called_a_stub() {
  local home out report
  # A 422 that is missing three of the four fields is not the template's stub.
  # Reporting it as one would send someone to port an intake that is already
  # there, so the two readings stay apart.
  home=$(make_home partial)
  write_endpoints "$home" "$(mode_url partial)"
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "answered HTTP 422 without naming email, message, turnstileToken" \
    "a 422 short of three fields was not reported as such"
  assert_not_contains "$report" "is running the contact stub" \
    "a 422 short of three fields was misreported as the template's stub"
  pass "a 422 short of more than the stub tell is reported without blaming the stub"
}

# --- the readings that are not about the deployment at all ------------------

test_a_challenge_page_is_not_read_as_a_deployment() {
  local home out report
  # This is the shape that made the same assertion useless from a cloud runner:
  # a bot-protection challenge answers where the API's JSON belongs. The origin
  # was never reached, so the answer says nothing about what is deployed, and a
  # report that blamed the site would be worse than no report.
  home=$(make_home challenge)
  write_endpoints "$home" "$(mode_url challenge)"
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "was refused at the edge" "a challenge page was not read as an edge refusal"
  assert_contains "$report" "bot-protection challenge" "the report did not name the challenge it read"
  assert_contains "$report" "says nothing about what is deployed" \
    "the report did not say the reading proves nothing about the deployment"
  assert_not_contains "$report" "contact stub" "an edge refusal was misreported as a deployment fault"
  pass "a challenge page is reported as an edge refusal that proves nothing about the deployment"
}

test_an_html_page_without_a_challenge_marker_is_still_an_edge_refusal() {
  local home out report
  home=$(make_home interstitial)
  write_endpoints "$home" "$(mode_url interstitial)"
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "was refused at the edge" "an HTML page answering HTTP 200 was not read as an edge refusal"
  assert_contains "$report" "HTML page where the intake answers JSON" "the report did not say what answered instead"
  assert_not_contains "$report" "which the intake never returns" \
    "an HTML page was read as an unexpected status rather than as a page"
  pass "an HTML page where JSON belongs is an edge refusal whatever status it carries"
}

test_a_403_is_an_edge_refusal() {
  local home out report
  home=$(make_home forbidden)
  write_endpoints "$home" "$(mode_url forbidden)"
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "was refused at the edge: HTTP 403" "a 403 was not read as an edge refusal"
  assert_contains "$report" "says nothing about what is deployed" \
    "a 403 was not reported as proving nothing about the deployment"
  pass "a 403 is reported as an edge refusal that proves nothing about the deployment"
}

# --- the readings that are about the deployment -----------------------------

test_a_501_is_the_stub_refusing_before_it_validates() {
  local home out report
  home=$(make_home notimplemented)
  write_endpoints "$home" "$(mode_url notimplemented)"
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "refusing before it validates: HTTP 501" "a 501 was not read as the stub refusing early"
  pass "a 501 is reported as the stub refusing before it validates"
}

test_a_503_is_a_missing_origin_secret_or_a_down_origin() {
  local home out report
  home=$(make_home nosecret)
  write_endpoints "$home" "$(mode_url nosecret)"
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "HTTP 503" "a 503 was not reported with its status"
  assert_contains "$report" "no origin secret, or the origin is down" "a 503 did not carry both of its causes"
  pass "a 503 is reported as a missing origin secret or a down origin"
}

test_an_unexpected_status_is_reported_with_what_came_back() {
  local home out report
  home=$(make_home accepted)
  write_endpoints "$home" "$(mode_url accepted)"
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "answered HTTP 200, which the intake never returns for an empty body" \
    "a 200 to an empty body was not reported"
  assert_contains "$report" '{"ok":true}' "the report did not quote what actually came back"
  pass "a status the intake never returns is reported with the answer it carried"
}

# --- no HTTP answer at all --------------------------------------------------

test_a_name_that_does_not_resolve_is_reported() {
  local home out report
  home=$(make_home unresolved)
  write_endpoints "$home" 'http://contact-live-check-no-such-host.invalid/api/contact'
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "is unreachable: the name does not resolve" \
    "a host that does not resolve was not reported as unreachable"
  pass "a name that does not resolve is reported as unreachable, not as a deployment fault"
}

test_nothing_serving_the_port_is_reported() {
  local home out report
  home=$(make_home unserved)
  # Port 1 on the loopback interface, which no ordinary service binds.
  write_endpoints "$home" 'http://127.0.0.1:1/api/contact'
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "is unreachable: nothing accepted a connection" \
    "a refused connection was not reported as nothing serving the endpoint"
  pass "an endpoint nothing is serving is reported as unreachable"
}

test_an_endpoint_that_hangs_is_bounded_and_reported() {
  local home out report started elapsed
  home=$(make_home hang)
  write_endpoints "$home" "$(mode_url hang)" "$(mode_url real)"
  out="$home/out.txt"
  started=$(date +%s)
  run_check "$home" "$out" FM_CONTACT_CHECK_PROBE_SECS=2 FM_CONTACT_CHECK_BUDGET_SECS=20
  elapsed=$(($(date +%s) - started))
  report=$(cat "$out")
  assert_contains "$report" "is unreachable: it did not answer inside its bound" \
    "an endpoint that never answers was not reported as bounded out"
  [ "$elapsed" -lt 15 ] || fail "a hanging endpoint held the sweep for ${elapsed}s instead of stopping at its bound"
  pass "an endpoint that hangs is cut off at its bound and reported as such"
}

test_the_sweep_says_which_endpoint_it_did_not_reach() {
  local home out report
  # A sweep that cannot finish must say so. Reporting only what it managed to
  # ask would present the endpoints it never reached as healthy, which is the
  # one thing silence is reserved for.
  home=$(make_home budget)
  write_endpoints "$home" "$(mode_url hang)" "$(mode_url stub)"
  out="$home/out.txt"
  run_check "$home" "$out" FM_CONTACT_CHECK_PROBE_SECS=3 FM_CONTACT_CHECK_BUDGET_SECS=2
  report=$(cat "$out")
  assert_contains "$report" "check incomplete: the time budget ran out before" \
    "a sweep that ran out of budget did not say which endpoint it never reached"
  assert_contains "$report" "/api/contact/stub" "the incomplete report did not name the endpoint it stopped before"
  pass "a sweep that runs out of budget names the endpoint it never reached"
}

# --- the report record ------------------------------------------------------

test_an_unchanged_failure_is_reported_once() {
  local home out
  home=$(make_home once)
  write_endpoints "$home" "$(switchable_url)"
  set_mode stub
  out="$home/first.txt"
  run_check "$home" "$out"
  assert_grep "is running the contact stub" "$out" "the first sweep did not report the stub"

  out="$home/second.txt"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "an unchanged failure was reported again: $(cat "$out")"
  pass "an unchanged failure is reported once, not on every poll"
}

test_a_changed_failure_is_reported_again() {
  local home out
  home=$(make_home changed)
  write_endpoints "$home" "$(switchable_url)"
  set_mode stub
  run_check "$home" "$home/first.txt"
  assert_grep "is running the contact stub" "$home/first.txt" "the first sweep did not report the stub"

  set_mode notimplemented
  out="$home/second.txt"
  run_check "$home" "$out"
  assert_grep "refusing before it validates" "$out" "a failure that changed shape was suppressed as unchanged"
  pass "a failure that changes is reported again"
}

test_a_cleared_failure_is_reported_as_recovered() {
  local home out report
  # Without this the record could only say that the report changed, and a
  # failure that cleared would look exactly like one that stopped being
  # mentioned.
  home=$(make_home recovered)
  write_endpoints "$home" "$(switchable_url)"
  set_mode stub
  run_check "$home" "$home/first.txt"
  assert_grep "is running the contact stub" "$home/first.txt" "the first sweep did not report the stub"

  set_mode real
  out="$home/second.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "recovered and answering the intake assertion again" \
    "a failure that cleared was silently forgotten instead of reported as recovered"
  assert_contains "$report" "127.0.0.1:$PORT" "the recovery did not name the endpoint that recovered"

  out="$home/third.txt"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a recovery was reported twice: $(cat "$out")"
  pass "a failure that clears is reported as a recovery, once"
}

test_an_endpoint_removed_from_the_list_is_not_reported_as_recovered() {
  local home out
  # Removing an endpoint is not evidence that it was fixed. Only an endpoint
  # this sweep actually got a good answer out of has recovered.
  home=$(make_home removed)
  write_endpoints "$home" "$(mode_url stub)" "$(mode_url real)"
  run_check "$home" "$home/first.txt"
  assert_grep "is running the contact stub" "$home/first.txt" "the first sweep did not report the stub"

  write_endpoints "$home" "$(mode_url real)"
  out="$home/second.txt"
  run_check "$home" "$out"
  assert_no_grep "recovered" "$out" "an endpoint that was removed from the list was reported as recovered"
  pass "an endpoint removed from the list is not reported as recovered"
}

test_probes_are_skipped_between_intervals() {
  local home out
  home=$(make_home interval)
  write_endpoints "$home" "$(switchable_url)"
  set_mode real
  out="$home/first.txt"
  env FM_CHECK_TIMEOUT=30 FM_HOME="$home" FM_CONTACT_CHECK_INTERVAL=900 FM_CONTACT_CHECK_NOW=1000 \
    "$CHECK" >"$out" 2>&1 || fail "the first sweep failed"

  # Inside the interval the sweep does not run at all, so a failure that has
  # appeared since is not seen yet, and nothing is printed.
  set_mode stub
  out="$home/second.txt"
  env FM_CHECK_TIMEOUT=30 FM_HOME="$home" FM_CONTACT_CHECK_INTERVAL=900 FM_CONTACT_CHECK_NOW=1500 \
    "$CHECK" >"$out" 2>&1 || fail "the gated sweep failed"
  [ ! -s "$out" ] || fail "a sweep ran inside its own interval: $(cat "$out")"

  out="$home/third.txt"
  env FM_CHECK_TIMEOUT=30 FM_HOME="$home" FM_CONTACT_CHECK_INTERVAL=900 FM_CONTACT_CHECK_NOW=2000 \
    "$CHECK" >"$out" 2>&1 || fail "the sweep past the interval failed"
  assert_grep "is running the contact stub" "$out" "the sweep past its interval did not probe"
  pass "probes are skipped between intervals and resume after one"
}

# --- configuration is never silence -----------------------------------------

test_absent_configuration_is_reported_not_silent() {
  local home out report
  # Silence means every endpoint answered correctly. A check with no endpoint
  # list has established nothing, so it must never borrow that meaning.
  home=$(make_home no-config)
  out="$home/out.txt"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" "no contact endpoint list at" "an absent endpoint list was silent"
  assert_contains "$report" "nothing is being checked" "an absent endpoint list did not say what that costs"
  pass "an absent endpoint list is an actionable report, not silence"
}

test_malformed_configuration_is_reported_not_silent() {
  local home out
  home=$(make_home bad-config)
  printf '%s\n' '{"endpoints":[{"url":"x45.dev/api/contact"}]}' > "$home/config/watched-contacts.json"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_grep "must be an http or https url" "$out" "an endpoint url with no scheme was accepted or ignored"

  printf '%s\n' 'not json at all' > "$home/config/watched-contacts.json"
  out="$home/broken.txt"
  run_check "$home" "$out"
  assert_grep "is not valid JSON" "$out" "an unparsable endpoint list was silent"
  pass "a malformed endpoint list is an actionable report, not silence"
}

test_an_oversized_budget_is_cut_to_fit_and_reported() {
  local home out
  # The sweep has to end inside the watcher's own per check bound: a run the
  # watcher kills prints nothing and records nothing, so it would repeat that
  # silence on every poll.
  home=$(make_home budget-cut)
  write_endpoints "$home" "$(mode_url real)"
  out="$home/out.txt"
  local status=0
  env FM_CHECK_TIMEOUT=10 FM_HOME="$home" FM_CONTACT_CHECK_INTERVAL=0 FM_CONTACT_CHECK_BUDGET_SECS=60 \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check with an oversized budget exit"
  assert_grep "sweep budget 60s cut to 7s" "$out" "an oversized sweep budget was not cut to fit the watcher timeout"
  pass "a sweep budget larger than the watcher timeout is cut to fit and the cut is reported"
}

test_invalid_environment_and_action_refuse() {
  local home status
  home=$(make_home refuse)
  write_endpoints "$home" "$(mode_url real)"

  status=0
  env FM_HOME="$home" FM_CONTACT_CHECK_INTERVAL=30 "$CHECK" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an interval below its floor"

  status=0
  env FM_HOME="$home" FM_CONTACT_CHECK_PROBE_SECS=0 "$CHECK" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a probe bound of zero"

  status=0
  env FM_HOME="$home" FM_CONTACT_CHECK_BUDGET_SECS=999 "$CHECK" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a sweep budget above its ceiling"

  status=0
  env FM_HOME="$home" "$CHECK" sniff >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "an unknown action"
  pass "an unusable bound or action is refused outright"
}

# --- arming -----------------------------------------------------------------

test_arm_registers_the_check_and_disarm_removes_it() {
  local home
  home=$(make_home arm)
  write_endpoints "$home" "$(mode_url stub)"
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "arm failed"
  assert_present "$home/state/contact-live.check.sh" "arm did not write the check shim"
  assert_present "$home/state/contact-live.check-trust" "arm did not register the check's bytes"
  [ "$(stat -c %a "$home/state/contact-live.check.sh" 2>/dev/null \
    || stat -f %Lp "$home/state/contact-live.check.sh")" = 700 ] \
    || fail "the check shim is not a private executable"
  # The registration the watcher will make: the trust binding has to cover the
  # bytes that are actually there.
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-check-lib.sh"
    fm_custom_check_registered "$2" contact-live' _ "$ROOT" "$home/state" \
    || fail "fm-check-register.sh did not accept the shim arm wrote"

  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "re-arming failed"
  assert_grep 'fm-custom-check-v1' "$home/state/contact-live.check-trust" "re-arming lost the trust binding"

  FM_HOME="$home" "$CHECK" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/contact-live.check.sh" "disarm left the check shim behind"
  assert_absent "$home/state/contact-live.check-trust" "disarm left the trust binding behind"
  assert_absent "$home/state/.contact-live" "disarm left the report record behind"
  pass "arm registers a trusted check and disarm removes every trace"
}

test_arm_refuses_an_endpoint_list_it_cannot_use() {
  local home status
  # An armed check whose list cannot be read could only ever report its own
  # configuration problem, and the no-nag record would report that once and then
  # go quiet for good. Refusing at arm time is what keeps that from happening.
  home=$(make_home arm-bad-config)
  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm with no endpoint list exit"
  assert_absent "$home/state/contact-live.check.sh" "arm wrote a shim with no endpoint list"

  printf '%s\n' '{"endpoints":[]}' > "$home/config/watched-contacts.json"
  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm with an empty endpoint list exit"
  assert_absent "$home/state/contact-live.check.sh" "arm wrote a shim for an empty endpoint list"
  pass "arm refuses an endpoint list it cannot use"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home target mode status
  # A stale or hostile symlink at the shim path must be refused rather than
  # followed: following it would write the shim body into a file someone else
  # owns and then make that file executable.
  home=$(make_home arm-symlink)
  write_endpoints "$home" "$(mode_url real)"
  target="$TMP_ROOT/arm-symlink/not-the-shim.txt"
  printf 'a file the shim must not touch\n' > "$target"
  mode=$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")
  ln -s "$target" "$home/state/contact-live.check.sh"

  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm over a symlink exit"
  [ "$(cat "$target")" = 'a file the shim must not touch' ] || fail "arm followed the symlink and overwrote its target"
  [ "$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")" = "$mode" ] \
    || fail "arm changed the mode of the symlink's target"
  assert_absent "$home/state/contact-live.check-trust" "arm registered a shim it refused to write"
  pass "a symlink at the shim path is refused instead of followed"
}

test_a_failed_registration_leaves_no_unregistered_shim() {
  local home target status
  # An unregistered shim in state/ is not inert: the watcher rejects it every
  # cycle and wakes firstmate about unauthenticated state checks until someone
  # deletes it by hand.
  home=$(make_home arm-register-fail)
  write_endpoints "$home" "$(mode_url real)"
  target="$TMP_ROOT/arm-register-fail/not-the-trust.txt"
  printf 'a file the trust binding must not touch\n' > "$target"
  ln -s "$target" "$home/state/contact-live.check-trust"

  status=0
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "arm with an unusable trust path exit"
  assert_absent "$home/state/contact-live.check.sh" "a failed registration left an unregistered check shim behind"
  [ "$(cat "$target")" = 'a file the trust binding must not touch' ] || fail "arm wrote through the trust symlink"
  pass "a failed registration never leaves a shim without a matching trust binding"
}

test_arm_resolves_a_relative_home_into_the_shim() {
  local home out status
  # The watcher runs the shim from its own working directory, so a relative home
  # has to be resolved before it is persisted. Otherwise the shim reads whatever
  # sits under the watcher's directory, finds no endpoint list, and reports that
  # instead of the endpoints it was armed for.
  home=$(make_home arm-relative)
  write_endpoints "$home" "$(mode_url stub)"

  status=0
  (cd "$TMP_ROOT" && FM_HOME=arm-relative "$CHECK" arm >/dev/null 2>&1) || status=$?
  expect_code 0 "$status" "arm with a relative home exit"

  out="$home/out.txt"
  status=0
  (cd / && env -u FM_HOME FM_CHECK_TIMEOUT=30 FM_CONTACT_CHECK_INTERVAL=0 \
    "$home/state/contact-live.check.sh" >"$out" 2>&1) || status=$?
  expect_code 0 "$status" "shim run from another directory exit"
  assert_contains "$(cat "$out")" "is running the contact stub" \
    "the shim read a different home than the one it was armed for"
  pass "a relative home is resolved before it is persisted into the shim"
}

test_armed_check_wakes_the_watcher_with_the_report() {
  local home out err status
  # End to end through the real watcher: the armed check must reach it as a
  # `check:` wake carrying the same stub report, with no new machinery.
  home=$(make_home wake)
  write_endpoints "$home" "$(mode_url stub)"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$home/state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$home/state/.pr-check-migration-v1"
  chmod 0600 "$home/state/.pr-check-migration-scan-v1" "$home/state/.pr-check-migration-v1"
  FM_HOME="$home" "$CHECK" arm >/dev/null || fail "could not arm the contact endpoint check"

  out="$home/out.txt"
  err="$home/err.txt"
  status=0
  env FM_HOME="$home" FM_CHECK_TIMEOUT=30 FM_CONTACT_CHECK_INTERVAL=0 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds 10 >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$out")" "check:" "the armed check did not reach the watcher as a check wake"
  assert_contains "$(cat "$out")" "contact endpoints:" "the wake did not carry the contact endpoint report"
  assert_contains "$(cat "$out")" "is running the contact stub" "the wake did not carry the stub reading"
  pass "the armed check reaches the watcher as an ordinary check wake"
}

test_every_real_intake_is_silent
test_a_stub_is_named_as_a_stub
test_a_422_short_of_more_than_the_stub_tell_is_not_called_a_stub
test_a_challenge_page_is_not_read_as_a_deployment
test_an_html_page_without_a_challenge_marker_is_still_an_edge_refusal
test_a_403_is_an_edge_refusal
test_a_501_is_the_stub_refusing_before_it_validates
test_a_503_is_a_missing_origin_secret_or_a_down_origin
test_an_unexpected_status_is_reported_with_what_came_back
test_a_name_that_does_not_resolve_is_reported
test_nothing_serving_the_port_is_reported
test_an_endpoint_that_hangs_is_bounded_and_reported
test_the_sweep_says_which_endpoint_it_did_not_reach
test_an_unchanged_failure_is_reported_once
test_a_changed_failure_is_reported_again
test_a_cleared_failure_is_reported_as_recovered
test_an_endpoint_removed_from_the_list_is_not_reported_as_recovered
test_probes_are_skipped_between_intervals
test_absent_configuration_is_reported_not_silent
test_malformed_configuration_is_reported_not_silent
test_an_oversized_budget_is_cut_to_fit_and_reported
test_invalid_environment_and_action_refuse
test_arm_registers_the_check_and_disarm_removes_it
test_arm_refuses_an_endpoint_list_it_cannot_use
test_arm_refuses_a_symlink_at_the_shim_path
test_a_failed_registration_leaves_no_unregistered_shim
test_arm_resolves_a_relative_home_into_the_shim
test_armed_check_wakes_the_watcher_with_the_report
