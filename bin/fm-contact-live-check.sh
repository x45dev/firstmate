#!/usr/bin/env bash
# fm-contact-live-check.sh - prove that each deployed contact endpoint is really
# the intake handler, by asking it from this machine.
#
# Usage:
#   fm-contact-live-check.sh [check]
#   fm-contact-live-check.sh arm
#   fm-contact-live-check.sh disarm
#   fm-contact-live-check.sh --help
#
# `check` prints one line when firstmate should wake and prints nothing at all
# otherwise, so it composes with the existing watcher state-check contract
# instead of needing a schedule of its own. `arm` writes
# state/contact-live.check.sh and binds its bytes with fm-check-register.sh, so
# the watcher dispatches it on its normal FM_CHECK_INTERVAL cadence and turns
# its one line into a `check:` wake. `disarm` removes the shim, its trust
# binding, and the report record.
#
# The assertion is fixed here, and only the endpoint list is configuration: POST
# an empty JSON body to the endpoint and require HTTP 422 whose body names all
# four fields the real intake binds - name, email, message, turnstileToken. An
# empty body is deliberate. Validation rejects it before anything happens, so
# the probe can never store a message, send mail, or spend challenge quota, and
# that is what makes it safe to run against a live site on a schedule.
#
# turnstileToken is the field that carries the information. The contact stub
# that ships with the site template also answers 422 to an empty body, but it
# binds only name, email and message, so the status alone cannot tell a real
# intake from a stub that was never ported. Nothing but the field list can.
#
# This check runs from the operator's own machine on purpose: the same assertion
# from a cloud runner reads an edge challenge where the API's answer should be.
# docs/configuration.md owns that rationale and the endpoint-list schema.
#
# The probe carries no secret, no credential, and no header beyond the content
# type. Its whole value is that nothing has to be in the way for it to work, so
# a reading it cannot get honestly is reported as such rather than forced.
#
# Every distinct reading the answer supports is kept separate, because they name
# different problems in different systems:
#
#   contact stub deployed        422 that names name, email and message but not
#                                turnstileToken: the real intake was never ported.
#   stub refusing before it validates   501.
#   no origin secret, or origin down    503.
#   refused at the edge          403, or an HTML challenge or interstitial page
#                                where JSON belongs: the origin was never
#                                reached, so this says nothing about what is
#                                deployed.
#   unreachable                  no HTTP answer at all: the name does not
#                                resolve, nothing is serving it, or the
#                                handshake failed.
#
# What this script never does: it reports, and it repairs nothing. It never
# deploys, never retries past its bound, and never sends anything that would
# make an edge let it through.
#
# The endpoints live in config/watched-contacts.json, which is local and
# gitignored. Adding a site is a config edit, never a code change.
#
# Probing costs real time, so `check` runs its probes at most once per
# FM_CONTACT_CHECK_INTERVAL (default 900, 0 disables the gate, otherwise
# 60..86400) and stays silent in between. Each probe is bounded by
# FM_CONTACT_CHECK_PROBE_SECS (default 8, valid 1..30) and a whole sweep by
# FM_CONTACT_CHECK_BUDGET_SECS (default 20, valid 1..120).
#
# The sweep has to finish inside the watcher's own per check bound, because a
# run the watcher kills prints nothing and writes no record, so it would repeat
# that silence on every poll. That coupling is enforced rather than assumed: a
# budget larger than FM_CHECK_TIMEOUT (default 30, read from this check's own
# environment because the watcher runs it as a direct child) allows is cut down
# to what fits, and the cut is reported in the report line so the operator sees
# it. A budget that cannot be read as a whole number from 1 to 120 is still
# refused outright.
#
# The report record state/.contact-live is written only when a sweep runs to its
# end, and it carries the whole finding set the last report was made from, one
# finding per endpoint, so the same failure is reported once rather than on
# every poll. It is keyed by endpoint precisely so a failure that CLEARS is
# distinguishable from one that merely stopped being mentioned: an endpoint that
# had a finding and now has none is reported as recovered, by name. A sweep
# killed part way through leaves no record and is retried, instead of
# suppressing its finding.
#
# Silence is this check's way of saying every endpoint answered correctly, so it
# is never also the way it says it could not run. An absent or malformed
# endpoint list is a reported finding, and `arm` refuses outright rather than
# arming a check that cannot answer.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/watched-contacts.json"
RECORD="$STATE/.contact-live"
CHECK_ID=contact-live
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-contact-live-v1
# Wider than the digest default because one finding names a host, a status, and
# a short excerpt of what came back, and several sites can report in one sweep.
MAX_LINE=1000
# How much of an unexpected answer is quoted back. Enough to recognize what
# answered, short enough that four of them still fit the report line.
BODY_EXCERPT=120
# The fields the real intake binds. This is the assertion, not configuration.
INTAKE_FIELDS='name email message turnstileToken'
# The field whose absence separates a ported intake from the template's stub.
STUB_TELL=turnstileToken
# The intake's own path. Nothing routes on it; it only keeps a report line from
# repeating the one path every watched endpoint already has.
INTAKE_PATH=/api/contact

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-contact-live-check.sh [check]   report contact endpoints that are not the real intake (silent when every one is)
  fm-contact-live-check.sh arm       write and register state/contact-live.check.sh
  fm-contact-live-check.sh disarm    remove the check shim, its trust binding, and the record
  fm-contact-live-check.sh --help    print this help

Endpoints are read from config/watched-contacts.json (local, gitignored).
See docs/configuration.md for the schema and docs/examples/watched-contacts.json for a starting point.
EOF
}

die_usage() {
  printf 'fm-contact-live-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

INTERVAL=${FM_CONTACT_CHECK_INTERVAL:-900}
case "$INTERVAL" in
  ''|*[!0-9]*)
    printf 'fm-contact-live-check: FM_CONTACT_CHECK_INTERVAL must be 0 or a whole number from 60 to 86400\n' >&2
    exit 2
    ;;
esac
if [ "$INTERVAL" -ne 0 ] && { [ "$INTERVAL" -lt 60 ] || [ "$INTERVAL" -gt 86400 ]; }; then
  printf 'fm-contact-live-check: FM_CONTACT_CHECK_INTERVAL must be 0 or a whole number from 60 to 86400\n' >&2
  exit 2
fi

PROBE_SECS=${FM_CONTACT_CHECK_PROBE_SECS:-8}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-contact-live-check: FM_CONTACT_CHECK_PROBE_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
if [ "$PROBE_SECS" -gt 30 ]; then
  printf 'fm-contact-live-check: FM_CONTACT_CHECK_PROBE_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
fi

BUDGET_SECS=${FM_CONTACT_CHECK_BUDGET_SECS:-20}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-contact-live-check: FM_CONTACT_CHECK_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
    exit 2
    ;;
esac
if [ "$BUDGET_SECS" -gt 120 ]; then
  printf 'fm-contact-live-check: FM_CONTACT_CHECK_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
  exit 2
fi

# The smallest bound a probe can be given, because fm_run_timed treats a
# non-positive bound as no bound.
PROBE_MIN_SECS=1
# Both clocks here count whole seconds, so a probe can start when the arithmetic
# says a second is left while almost none of it really is, and it still gets a
# full bound.
CLOCK_ROUNDING_SECS=1
# fm_run_timed asks its runner for -k 1, so a probe that does not stop on TERM is
# only killed a second after its bound.
KILL_GRACE_SECS=1

# The watcher's per check bound, read from this check's own environment. The
# watcher runs the check as a direct child, so an operator who raised it is seen
# here too, and when it is unset both sides resolve the same default.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
# The last probe of a sweep can end this far past the deadline, so that is what
# the budget has to leave the watcher's own bound.
BUDGET_MAX=$((CHECK_TIMEOUT - PROBE_MIN_SECS - CLOCK_ROUNDING_SECS - KILL_GRACE_SECS))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
# Cut rather than refuse. A refusal is reported once and then suppressed by the
# no-nag gate, which leaves the detector dead and quiet, and a check that goes
# silent is worse than a check that reports something awkward.
BUDGET_CUT_FROM=
if [ "$BUDGET_SECS" -gt "$BUDGET_MAX" ]; then
  BUDGET_CUT_FROM=$BUDGET_SECS
  BUDGET_SECS=$BUDGET_MAX
fi

# --- small helpers ----------------------------------------------------------

# The record epoch is overridable so a test can drive the cadence gate; the
# sweep budget always uses real time so a frozen epoch cannot disable it.
record_epoch_now() {
  case "${FM_CONTACT_CHECK_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_CONTACT_CHECK_NOW" ;;
  esac
}

real_epoch() { date +%s; }

# Findings are accumulated as one "<key><US><text>" line each. The key is the
# endpoint the finding is about, which is what lets a later sweep say that this
# endpoint recovered rather than only that the report changed.
UNIT_SEP=$(printf '\037')
FINDING_LINES=
# The endpoints this sweep actually got an answer out of, one per line. Recovery
# is read from these alone: an endpoint the budget never reached, or one the
# operator has since removed, was not observed to recover.
PROBED_KEYS=
DEADLINE=0
INCOMPLETE_REPORTED=0
# The key findings that are about the sweep or the configuration rather than
# about one endpoint.
SWEEP_KEY='(sweep)'
CONFIG_KEY='(configuration)'

emit() {
  local key=$1 text
  text=$(printf '%s' "$2" | tr '\t\r\n' '   ')
  FINDING_LINES="$FINDING_LINES$key$UNIT_SEP$text
"
}

finding_texts() {
  local key text out=
  while IFS=$UNIT_SEP read -r key text; do
    [ -n "$key" ] || continue
    if [ -z "$out" ]; then
      out=$text
    else
      out="$out; $text"
    fi
  done <<EOF
$FINDING_LINES
EOF
  printf '%s' "$out"
}

finding_keys() {
  local key text
  while IFS=$UNIT_SEP read -r key text; do
    [ -n "$key" ] || continue
    printf '%s\n' "$key"
  done <<EOF
$FINDING_LINES
EOF
}

budget_exhausted() {
  [ "$(real_epoch)" -ge "$DEADLINE" ]
}

# True while the sweep budget still has room for another probe. When it does not,
# it records once which endpoint the sweep did not reach, so a sweep that cannot
# finish says so rather than being killed by the watcher with nothing printed.
budget_allows() {
  local label=$1
  budget_exhausted || return 0
  if [ "$INCOMPLETE_REPORTED" -eq 0 ]; then
    INCOMPLETE_REPORTED=1
    emit "$SWEEP_KEY" "check incomplete: the time budget ran out before $label"
  fi
  return 1
}

# The bound for one probe: the probe bound, cut down to whatever the sweep
# budget has left, so no probe can run past the end of the sweep. Never below
# PROBE_MIN_SECS, because fm_run_timed treats a non-positive bound as no bound.
probe_bound() {
  local left
  left=$((DEADLINE - $(real_epoch)))
  if [ "$left" -lt "$PROBE_MIN_SECS" ]; then
    printf '%s\n' "$PROBE_MIN_SECS"
  elif [ "$left" -lt "$PROBE_SECS" ]; then
    printf '%s\n' "$left"
  else
    printf '%s\n' "$PROBE_SECS"
  fi
}

# What a report line calls an endpoint. The host is what the operator thinks in,
# so that is the whole label for the intake's own path, and any other path is
# named as well so two endpoints on one host never report as the same thing.
endpoint_label() {
  local rest=${1#*://} host path
  host=${rest%%/*}
  path=${rest#"$host"}
  case "$path" in
    ''|/|"$INTAKE_PATH") printf '%s\n' "$host" ;;
    *) printf '%s%s\n' "$host" "$path" ;;
  esac
}

excerpt() {
  local text
  text=$(printf '%s' "$1" | tr '\t\r\n' '   ' | tr -s ' ')
  if [ "${#text}" -gt "$BODY_EXCERPT" ]; then
    printf '%s...' "${text:0:$BODY_EXCERPT}"
  else
    printf '%s' "$text"
  fi
}

# True when the body names <field>. The field has to stand as its own token, so
# the name inside turnstileToken is never read as the name field, and a body
# that names its fields in prose reads the same as one that names them in JSON.
body_names_field() {
  local body_file=$1 field=$2
  grep -qE "(^|[^A-Za-z0-9_])$field([^A-Za-z0-9_]|\$)" "$body_file" 2>/dev/null
}

# True when what came back is a page rather than the API's JSON. The API answers
# JSON on every path this check exercises, so HTML at all means something else
# answered and the origin was never reached.
looks_like_page() {
  local body_file=$1 ctype=$2
  case "$ctype" in
    *html*) return 0 ;;
  esac
  head -c 512 "$body_file" 2>/dev/null | grep -qiE '^[[:space:]]*<(!doctype|html)'
}

# The well-known shapes an interposed bot-protection challenge leaves in the
# body. Naming one is better than reporting a bare page, but a page that matches
# none of them is still a page, so this only sharpens the wording.
looks_like_challenge() {
  local body_file=$1
  grep -qiE 'cf-chl|__cf_chl|challenge-platform|challenges\.cloudflare|just a moment|checking your browser|attention required|enable javascript and cookies' \
    "$body_file" 2>/dev/null
}

# --- endpoint registry ------------------------------------------------------

CONFIG_PROBLEM=

config_validate() {
  local problem status
  if ! command -v jq >/dev/null 2>&1; then
    CONFIG_PROBLEM='jq is required to read the contact endpoint list'
    return 1
  fi
  problem=$(jq -r '
    def endpoint_problem($e):
      if ($e | type) != "object" then "every entry in endpoints must be an object"
      elif ($e.url | type) != "string" or ($e.url | length) == 0 then "every endpoint needs a non-empty url"
      elif ($e.url | test("^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$") | not)
        then "endpoint url \($e.url) must be an http or https url with a plain host and path, and no user info, query, or fragment"
      else empty
      end;
    def problems:
      if type != "object" then ["the top level must be an object"]
      elif (.endpoints | type) != "array" then ["endpoints must be an array"]
      elif (.endpoints | length) == 0 then ["endpoints must list at least one endpoint"]
      else
        [.endpoints[] | endpoint_problem(.)]
        + (if ([.endpoints[] | select((.url | type) == "string") | .url] | (unique | length) != length)
           then ["each endpoint url may appear only once"] else [] end)
      end;
    problems | .[0] // "ok"
  ' "$CONFIG" 2>/dev/null)
  status=$?
  if [ "$status" -ne 0 ] || [ -z "$problem" ]; then
    CONFIG_PROBLEM='the contact endpoint list is not valid JSON'
    return 1
  fi
  if [ "$problem" != ok ]; then
    CONFIG_PROBLEM=$problem
    return 1
  fi
  CONFIG_PROBLEM=
  return 0
}

config_urls() {
  jq -r '.endpoints[].url' "$CONFIG" 2>/dev/null
}

# --- the probe --------------------------------------------------------------

PROBE_CODE=
PROBE_CTYPE=
PROBE_BODY=
PROBE_ERROR=
PROBE_STATUS=0

# One bounded request. curl gets the bound too, so an endpoint that stalls is
# curl's own timeout with its own exit status rather than a killed process, and
# fm_run_timed stays as the backstop that owns the hard bound.
probe() {
  local url=$1 tmp_dir=$2 bound written
  PROBE_CODE=
  PROBE_CTYPE=
  PROBE_BODY="$tmp_dir/body"
  PROBE_ERROR=
  : > "$PROBE_BODY"
  bound=$(probe_bound)
  written=$(fm_run_timed "$bound" curl \
    --silent --show-error --globoff \
    --request POST \
    --header 'Content-Type: application/json' \
    --data '{}' \
    --max-time "$bound" \
    --output "$PROBE_BODY" \
    --write-out '%{http_code}\t%{content_type}' \
    "$url" 2>"$tmp_dir/err")
  PROBE_STATUS=$?
  PROBE_ERROR=$(head -n 1 "$tmp_dir/err" 2>/dev/null)
  PROBE_CODE=${written%%	*}
  PROBE_CTYPE=${written#*	}
  [ "$PROBE_CODE" != "$written" ] || PROBE_CTYPE=
  return 0
}

# Why no HTTP answer arrived. curl's exit statuses separate the causes the
# operator would act on differently, and anything else is quoted rather than
# guessed at.
transport_reason() {
  local status=$1 detail=$2
  case "$status" in
    6) printf 'the name does not resolve' ;;
    7) printf 'nothing accepted a connection' ;;
    28) printf 'it did not answer inside its bound' ;;
    124) printf 'it did not answer inside its bound and had to be killed' ;;
    35|51|58|59|60|66|77|83|91) printf 'the TLS handshake failed' ;;
    52) printf 'the connection closed with an empty reply' ;;
    56) printf 'the connection broke while the reply was being read' ;;
    *)
      if [ -n "$detail" ]; then
        printf 'curl exit %s: %s' "$status" "$(excerpt "$detail")"
      else
        printf 'curl exit %s' "$status"
      fi
      ;;
  esac
}

# Read one answer into exactly one finding, or into silence. The readings are
# kept apart on purpose: they name faults in different systems, and collapsing
# them into "the contact check failed" is what would make the report useless.
endpoint_findings() {
  local url=$1 tmp_dir=$2 host code missing named field

  host=$(endpoint_label "$url")
  PROBED_KEYS="$PROBED_KEYS$url
"
  probe "$url" "$tmp_dir"

  if [ "$PROBE_STATUS" -ne 0 ] || [ -z "$PROBE_CODE" ] || [ "$PROBE_CODE" = 000 ]; then
    emit "$url" "$host is unreachable: $(transport_reason "$PROBE_STATUS" "$PROBE_ERROR")"
    return 0
  fi

  code=$PROBE_CODE

  # Checked before the status readings, because an edge that answers instead of
  # the origin can pick any status it likes, and every one of them would
  # otherwise be read as something the deployment did.
  if looks_like_page "$PROBE_BODY" "$PROBE_CTYPE"; then
    if looks_like_challenge "$PROBE_BODY"; then
      emit "$url" "$host was refused at the edge: HTTP $code carried a bot-protection challenge page, so the origin was never reached and this says nothing about what is deployed"
    else
      emit "$url" "$host was refused at the edge: HTTP $code carried an HTML page where the intake answers JSON, so the origin was never reached and this says nothing about what is deployed"
    fi
    return 0
  fi

  case "$code" in
    422)
      missing=
      named=
      for field in $INTAKE_FIELDS; do
        if body_names_field "$PROBE_BODY" "$field"; then
          named="$named${named:+, }$field"
        else
          missing="$missing${missing:+, }$field"
        fi
      done
      [ -n "$missing" ] || return 0
      if [ "$missing" = "$STUB_TELL" ]; then
        emit "$url" "$host is running the contact stub, not the real intake: HTTP 422 named $named but not $STUB_TELL, so the real intake was never ported"
      else
        emit "$url" "$host answered HTTP 422 without naming $missing: named ${named:-nothing the intake binds} in $(excerpt "$(cat "$PROBE_BODY" 2>/dev/null)")"
      fi
      ;;
    501)
      emit "$url" "$host has the contact stub refusing before it validates: HTTP 501"
      ;;
    503)
      emit "$url" "$host answered HTTP 503: the edge holds no origin secret, or the origin is down"
      ;;
    403)
      emit "$url" "$host was refused at the edge: HTTP 403, so the origin was never reached and this says nothing about what is deployed"
      ;;
    *)
      emit "$url" "$host answered HTTP $code, which the intake never returns for an empty body: $(excerpt "$(cat "$PROBE_BODY" 2>/dev/null)")"
      ;;
  esac
  return 0
}

# --- report record ----------------------------------------------------------

RECORD_EPOCH=0
RECORD_FINDINGS=

record_read() {
  local line first=1
  RECORD_EPOCH=0
  RECORD_FINDINGS=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || { RECORD_FINDINGS=; return 0; }
      continue
    fi
    case "$line" in
      epoch=*)
        line=${line#epoch=}
        case "$line" in
          ''|*[!0-9]*) RECORD_EPOCH=0 ;;
          *) RECORD_EPOCH=$line ;;
        esac
        ;;
      finding=*) RECORD_FINDINGS="$RECORD_FINDINGS${line#finding=}
" ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() {
  local tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    printf '%s' "$FINDING_LINES" | while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf 'finding=%s\n' "$line"
    done
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# The endpoints the last report named that answered correctly this time, as
# their labels. This is the whole reason the record is keyed by endpoint:
# without it a recovery and a finding that merely stopped being mentioned look
# identical. An endpoint is only counted here when this sweep actually got an
# answer out of it, so a budget that ran out early, or an endpoint the operator
# has removed from the list, is never reported as recovered.
recovered_labels() {
  local key text current out=
  current=$(finding_keys)
  while IFS=$UNIT_SEP read -r key text; do
    [ -n "$key" ] || continue
    case "$key" in
      "$SWEEP_KEY"|"$CONFIG_KEY") continue ;;
    esac
    printf '%s\n' "$PROBED_KEYS" | grep -qxF -- "$key" || continue
    printf '%s\n' "$current" | grep -qxF -- "$key" && continue
    out="$out${out:+, }$(endpoint_label "$key")"
  done <<EOF
$RECORD_FINDINGS
EOF
  printf '%s' "$out"
}

# --- actions ----------------------------------------------------------------

SWEEP_TMP_DIR=

# shellcheck disable=SC2329  # Registered by action_check's signal trap.
sweep_tmp_cleanup() {
  [ -z "$SWEEP_TMP_DIR" ] || rm -rf -- "$SWEEP_TMP_DIR"
  SWEEP_TMP_DIR=
}

action_check() {
  local url line now texts recovered

  record_read
  now=$(record_epoch_now)
  if [ "$INTERVAL" -ne 0 ] && [ "$RECORD_EPOCH" -gt 0 ] \
    && [ "$now" -ge "$RECORD_EPOCH" ] && [ $((now - RECORD_EPOCH)) -lt "$INTERVAL" ]; then
    return 0
  fi

  DEADLINE=$(($(real_epoch) + BUDGET_SECS))

  if [ -n "$BUDGET_CUT_FROM" ]; then
    emit "$SWEEP_KEY" "sweep budget ${BUDGET_CUT_FROM}s cut to ${BUDGET_SECS}s to stay inside the watcher check timeout of ${CHECK_TIMEOUT}s"
  fi

  if [ ! -f "$CONFIG" ]; then
    # Not silence. Silence here means every endpoint answered correctly, so a
    # check that could not run has to say so instead of borrowing that meaning.
    emit "$CONFIG_KEY" "no contact endpoint list at $CONFIG, so nothing is being checked"
  elif ! command -v curl >/dev/null 2>&1; then
    emit "$CONFIG_KEY" "curl is required to ask a contact endpoint anything"
  elif ! config_validate; then
    emit "$CONFIG_KEY" "contact endpoint list: $CONFIG_PROBLEM"
  else
    # The watcher kills a sweep that outruns its bound, so the working directory
    # is reaped on the way out rather than only at the end of a run that
    # completes.
    SWEEP_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-contact-live.XXXXXX" 2>/dev/null) || {
      printf 'fm-contact-live-check: cannot create a working directory\n' >&2
      return 1
    }
    trap sweep_tmp_cleanup EXIT HUP INT TERM
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      budget_allows "$(endpoint_label "$url")" || break
      endpoint_findings "$url" "$SWEEP_TMP_DIR"
    done < <(config_urls)
    sweep_tmp_cleanup
    trap - EXIT HUP INT TERM
  fi

  texts=$(finding_texts)
  recovered=$(recovered_labels)

  line=
  if [ -n "$texts" ] || [ -n "$recovered" ]; then
    line="contact endpoints:${texts:+ }$texts"
    if [ -n "$recovered" ]; then
      line="$line${texts:+;} recovered and answering the intake assertion again: $recovered"
    fi
    # Capped through the shared cut so an over-long report carries the same
    # visible truncation marker the digests use, instead of ending mid-finding
    # as if that were all of it.
    fm_cap_line_var "$line" "$MAX_LINE"
    line=$FM_LINE_CAP_LINE
  fi

  # The whole finding set decides whether this is news, not the cut line: a
  # finding that lands past the cut leaves the printed line unchanged and would
  # otherwise be suppressed for good. A recovery is news by construction,
  # because the set it is computed from is exactly the set that changed.
  #
  # Report before recording, so a record that cannot be written costs a repeated
  # report rather than a lost one.
  if [ -n "$line" ] && [ "$FINDING_LINES" != "$RECORD_FINDINGS" ]; then
    printf '%s\n' "$line"
  fi
  record_write || true
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-contact-live-check.sh - contact endpoint poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-contact-live-check.sh") check"
}

# Write the shim the way this repo writes its other trusted check shims: the
# guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-contact-live-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# Keep a byte copy of a shim that is already in place, so a failed arm can put
# back the shim a working home was already using rather than an equivalent
# rewrite. The trust binding is over the bytes, so a rewrite would satisfy it
# too, but a home that was armed stays armed with what it had.
shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-contact-live-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So the one rule after a
# failed or interrupted arm is that the home never holds a shim without a
# matching trust binding. The shim a working home had is put back and kept only
# when it is still bound; otherwise the shim goes, so the home is plainly not
# armed and the failure is the only thing the operator has to act on.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-contact-live-check: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if [ ! -f "$CONFIG" ]; then
    printf 'fm-contact-live-check: no contact endpoint list at %s\n' "$CONFIG" >&2
    return 1
  fi
  if ! config_validate; then
    printf 'fm-contact-live-check: %s (%s)\n' "$CONFIG_PROBLEM" "$CONFIG" >&2
    return 1
  fi
  # Arming a check that has no way to ask anything would leave a home holding a
  # detector that can only ever report its own missing tool.
  if ! command -v curl >/dev/null 2>&1; then
    printf 'fm-contact-live-check: curl is required to ask a contact endpoint anything\n' >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-contact-live-check: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-contact-live-check: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-contact-live-check: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-contact-live-check: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
