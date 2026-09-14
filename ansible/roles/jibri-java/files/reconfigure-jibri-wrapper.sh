#!/bin/bash
#
# consul-template command hook for the jibri xmpp.conf template.
#
# consul-template renders the template to a *candidate* file. This script
# validates the candidate, decides whether it is safe to promote it to the live
# xmpp.conf, and then asks jibri to reload (which makes jibri exit when idle so
# systemd restarts it with the new config).
#
# Design notes (see git history for the incident that motivated this):
#   * jibri has no config-file watcher of its own; the only thing that restarts
#     it on a config change is this script calling `service jibri reload`.
#   * jibri takes ~10s+ to boot (chrome warm-up in ExecStartPre). A reload issued
#     while the unit is still activating fails, and if this script exits non-zero
#     consul-template tears down its whole runner. So we wait for jibri to be
#     active, retry the reload with backoff, and *always* exit 0. Failures are
#     reported via statsd metrics and the log file instead.
#   * A render is checked against consul before it is promoted: the shard
#     registrations flap during releases, and a render taken from that partial
#     view would disconnect jibri from a healthy shard. check-jibri-xmpp-conf.py
#     asks whether the candidate still covers every shard consul reports as
#     passing. The check is absolute rather than a diff against the previous file,
#     because ansible and consul-template write the same hosts in different
#     formats, so it also works on the first render after an ansible run. On a
#     mismatch we settle and re-check; only a mismatch that persists rejects the
#     candidate, and consul-template's next render gets applied instead.
#
# Tunables (environment):
#   XMPP_CONF_FILE                live config        (default /etc/jitsi/jibri/xmpp.conf)
#   XMPP_CONF_CANDIDATE_FILE      rendered candidate (default ${XMPP_CONF_FILE}.candidate)
#   JIBRI_CONF_FILE               jibri.conf, used to find the internal API port
#   CONSUL_HTTP_ADDR              local consul agent (default http://127.0.0.1:8500)
#   XMPP_CONF_CHECK_SCRIPT        helper that checks a rendered config against consul
#                                 (default /usr/local/bin/check-jibri-xmpp-conf.py)
#   JIBRI_SETTLE_SECONDS          wait before re-checking consul on a mismatch (default 20)
#   JIBRI_ACTIVE_TIMEOUT_SECONDS  max wait for jibri.service to become active (default 120)
#   JIBRI_RELOAD_ATTEMPTS         reload attempts (default 3, backoff 5s/10s/20s)
#   JIBRI_LOCK_WAIT_SECONDS       max wait for the wrapper lock (default 120)
#   JIBRI_LOCK_FILE               wrapper lock (default /var/lock/reconfigure-jibri-wrapper.lock)
#   JIBRI_SERVICE_RELOAD_CMD      reload command (default "/usr/sbin/service jibri reload")

function timestamp() {
  date --utc +%Y-%m-%d_%H:%M:%S.Z
}

function log_msg() {
  echo "$(timestamp) [$$] jibri-wrapper: $1" | tee -a "$TEMPLATE_LOGFILE"
}

function metric() {
  # $1 metric name (suffix of jitsi.config.jibri.), $2 value
  echo -n "jitsi.config.jibri.$1:$2|c" | nc -4u -w1 localhost 8125
}

# extract the set of "host:port" entries from all xmpp-server-hosts lines in a file
function hosts_in() {
  [ -f "$1" ] || return 0
  grep 'xmpp-server-hosts' "$1" | grep -oE '"[^"]+"' | tr -d '"' | sort -u
}

# set difference: lines in $1 not in $2 (both newline separated strings)
function set_diff() {
  comm -23 <(echo "$1" | sed '/^$/d' | sort -u) <(echo "$2" | sed '/^$/d' | sort -u)
}

function count_lines() {
  echo "$1" | sed '/^$/d' | wc -l | tr -d ' '
}

# Ask check-jibri-xmpp-conf.py whether $1 still covers every shard consul reports.
# Echoes the helper's findings into the log. Returns the helper's exit status:
# 0 covered, 1 could not determine, 2 missing shards.
function check_against_consul() {
  local config="$1" output rc
  if [ ! -x "$XMPP_CONF_CHECK_SCRIPT" ]; then
    log_msg "$XMPP_CONF_CHECK_SCRIPT is missing or not executable"
    return 1
  fi
  output=$("$XMPP_CONF_CHECK_SCRIPT" --consul "$CONSUL_HTTP_ADDR" "$config" 2>&1)
  rc=$?
  while IFS= read -r line; do
    [ -n "$line" ] && log_msg "check: $line"
  done <<< "$output"
  return $rc
}

function jibri_internal_api_port() {
  local port=""
  if command -v hocon >/dev/null 2>&1; then
    port=$(hocon -f "$JIBRI_CONF_FILE" get jibri.api.http.internal-api-port 2>/dev/null || true)
  fi
  if [ -z "$port" ]; then
    port=$(grep -oE 'internal-api-port[[:space:]]*=[[:space:]]*[0-9]+' "$JIBRI_CONF_FILE" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
  fi
  [ -z "$port" ] && port=3333
  echo "$port"
}

# Wait until jibri.service is 'active' and its internal HTTP API answers.
# Returns 0 when ready, 1 when jibri is not running at all (inactive/failed),
# 2 on timeout.
function wait_for_jibri_ready() {
  local deadline=$(( $(date +%s) + JIBRI_ACTIVE_TIMEOUT_SECONDS ))
  local port state
  port=$(jibri_internal_api_port)
  while true; do
    state=$(systemctl is-active jibri 2>/dev/null)
    case "$state" in
      active)
        if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:${port}/"; then
          return 0
        fi
        ;;
      inactive|failed)
        # do not wait for something that is not coming back on its own
        return 1
        ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log_msg "timed out waiting for jibri.service to be ready (state=${state:-unknown})"
      return 2
    fi
    sleep 2
  done
}

[ -z "$TEMPLATE_LOGDIR" ] && TEMPLATE_LOGDIR="/var/log/jitsi/jibri-shards"
[ -d "$TEMPLATE_LOGDIR" ] || mkdir -p "$TEMPLATE_LOGDIR"
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/jibri-reconfigure.log"
[ -z "$XMPP_CONF_FILE" ] && XMPP_CONF_FILE="/etc/jitsi/jibri/xmpp.conf"
[ -z "$XMPP_CONF_CANDIDATE_FILE" ] && XMPP_CONF_CANDIDATE_FILE="${XMPP_CONF_FILE}.candidate"
[ -z "$JIBRI_CONF_FILE" ] && JIBRI_CONF_FILE="/etc/jitsi/jibri/jibri.conf"
[ -z "$CONSUL_HTTP_ADDR" ] && CONSUL_HTTP_ADDR="http://127.0.0.1:8500"
[ -z "$XMPP_CONF_CHECK_SCRIPT" ] && XMPP_CONF_CHECK_SCRIPT="/usr/local/bin/check-jibri-xmpp-conf.py"
[ -z "$JIBRI_SETTLE_SECONDS" ] && JIBRI_SETTLE_SECONDS=20
[ -z "$JIBRI_ACTIVE_TIMEOUT_SECONDS" ] && JIBRI_ACTIVE_TIMEOUT_SECONDS=120
[ -z "$JIBRI_RELOAD_ATTEMPTS" ] && JIBRI_RELOAD_ATTEMPTS=3
[ -z "$JIBRI_LOCK_WAIT_SECONDS" ] && JIBRI_LOCK_WAIT_SECONDS=120

[ -z "$JIBRI_LOCK_FILE" ] && JIBRI_LOCK_FILE="/var/lock/reconfigure-jibri-wrapper.lock"
[ -z "$JIBRI_SERVICE_RELOAD_CMD" ] && JIBRI_SERVICE_RELOAD_CMD="/usr/sbin/service jibri reload"
readonly LOCK_FD=200

log_msg "starting"
# always emit a 0 so the counters exist even on quiet hosts
metric "shards_update" 0
metric "shards_update_failed" 0
metric "shards_candidate_rejected" 0

# ---------------------------------------------------------------------------
# serialize: never let two invocations race each other
# ---------------------------------------------------------------------------
eval "exec $LOCK_FD>$JIBRI_LOCK_FILE"
if ! flock -w "$JIBRI_LOCK_WAIT_SECONDS" $LOCK_FD; then
  log_msg "could not acquire lock within ${JIBRI_LOCK_WAIT_SECONDS}s, another reconfigure is still running; skipping"
  metric "shards_update_lock_timeout" 1
  exit 0
fi

CONFIG_TIMESTAMP=$(timestamp)

# ---------------------------------------------------------------------------
# validate the candidate
# ---------------------------------------------------------------------------
if [ ! -s "$XMPP_CONF_CANDIDATE_FILE" ]; then
  log_msg "candidate $XMPP_CONF_CANDIDATE_FILE is missing or empty; rejecting"
  metric "shards_candidate_rejected" 1
  metric "shards_candidate_empty" 1
  exit 0
fi

cp "$XMPP_CONF_CANDIDATE_FILE" "$TEMPLATE_LOGDIR/xmpp.conf.candidate.$CONFIG_TIMESTAMP"

if ! grep -q 'jibri.api.xmpp.environments' "$XMPP_CONF_CANDIDATE_FILE"; then
  log_msg "candidate does not look like a jibri xmpp config; rejecting"
  metric "shards_candidate_rejected" 1
  metric "shards_candidate_invalid" 1
  exit 0
fi

NEW_HOSTS=$(hosts_in "$XMPP_CONF_CANDIDATE_FILE")
LIVE_HOSTS=$(hosts_in "$XMPP_CONF_FILE")
NEW_COUNT=$(count_lines "$NEW_HOSTS")
LIVE_COUNT=$(count_lines "$LIVE_HOSTS")
metric "shards_candidate_hosts" "$NEW_COUNT"

if [ "$NEW_COUNT" -eq 0 ]; then
  log_msg "candidate contains no xmpp-server-hosts (live has $LIVE_COUNT); rejecting"
  metric "shards_candidate_rejected" 1
  metric "shards_candidate_empty" 1
  exit 0
fi

if [ -f "$XMPP_CONF_FILE" ] && cmp -s "$XMPP_CONF_CANDIDATE_FILE" "$XMPP_CONF_FILE"; then
  log_msg "candidate is identical to live config; nothing to do"
  metric "shards_update_noop" 1
  exit 0
fi

# ---------------------------------------------------------------------------
# informational: how the candidate differs from the live file.
#
# This is logging only and must not drive the decision. The live file may have
# been written by ansible, whose xmpp.conf.j2 lists bare addresses with the port
# on a separate line, while consul-template renders "address:port" per block, so
# on the first render after an ansible run every host reads as both added and
# removed. Ports are kept verbatim either way: Nomad shards in a pool share an IP
# and differ only by port, so normalizing the port away would hide the loss of a
# co-located shard, which is the very thing being guarded against.
# ---------------------------------------------------------------------------
REMOVED_HOSTS=$(set_diff "$LIVE_HOSTS" "$NEW_HOSTS")
ADDED_HOSTS=$(set_diff "$NEW_HOSTS" "$LIVE_HOSTS")
REMOVED_COUNT=$(count_lines "$REMOVED_HOSTS")
ADDED_COUNT=$(count_lines "$ADDED_HOSTS")

[ "$ADDED_COUNT" -gt 0 ] && log_msg "candidate adds $ADDED_COUNT entry(ies) vs live: $(echo $ADDED_HOSTS)"
[ "$REMOVED_COUNT" -gt 0 ] && log_msg "candidate drops $REMOVED_COUNT entry(ies) vs live: $(echo $REMOVED_HOSTS)"
[ "$ADDED_COUNT" -gt 0 ] && metric "shards_added" "$ADDED_COUNT"
[ "$REMOVED_COUNT" -gt 0 ] && metric "shards_removed" "$REMOVED_COUNT"

# ---------------------------------------------------------------------------
# the decision: does the candidate still cover every shard consul reports?
# ---------------------------------------------------------------------------
check_against_consul "$XMPP_CONF_CANDIDATE_FILE"
CHECK_RC=$?

if [ $CHECK_RC -eq 2 ]; then
  log_msg "candidate is missing shard(s) that consul reports as passing; settling ${JIBRI_SETTLE_SECONDS}s and re-checking"
  metric "shards_candidate_incomplete" 1
  sleep "$JIBRI_SETTLE_SECONDS"

  check_against_consul "$XMPP_CONF_CANDIDATE_FILE"
  CHECK_RC=$?
  case $CHECK_RC in
    0)
      log_msg "consul caught up with the candidate; accepting"
      ;;
    2)
      log_msg "candidate is still missing shard(s) after settling; render was taken from a transient view, rejecting candidate and keeping live config"
      metric "shards_candidate_rejected" 1
      metric "shards_candidate_incomplete_confirmed" 1
      exit 0
      ;;
    *)
      log_msg "could not re-check against consul; accepting candidate as rendered"
      metric "shards_check_unverified" 1
      ;;
  esac
elif [ $CHECK_RC -ne 0 ]; then
  log_msg "could not check the candidate against consul at $CONSUL_HTTP_ADDR; accepting candidate as rendered"
  metric "shards_check_unverified" 1
fi

# ---------------------------------------------------------------------------
# promote candidate -> live (atomically, preserving ownership/mode)
# ---------------------------------------------------------------------------
[ -f "$XMPP_CONF_FILE" ] && cp "$XMPP_CONF_FILE" "$TEMPLATE_LOGDIR/xmpp.conf.previous.$CONFIG_TIMESTAMP"
TMP_LIVE="${XMPP_CONF_FILE}.tmp.$$"
if ! cp "$XMPP_CONF_CANDIDATE_FILE" "$TMP_LIVE"; then
  log_msg "failed to stage new live config; aborting"
  metric "shards_update_failed" 1
  rm -f "$TMP_LIVE"
  exit 0
fi
chown --reference="$XMPP_CONF_CANDIDATE_FILE" "$TMP_LIVE" 2>/dev/null
chmod --reference="$XMPP_CONF_CANDIDATE_FILE" "$TMP_LIVE" 2>/dev/null
mv -f "$TMP_LIVE" "$XMPP_CONF_FILE"
log_msg "promoted candidate to $XMPP_CONF_FILE ($LIVE_COUNT -> $NEW_COUNT hosts)"
metric "shards_update" 1

# ---------------------------------------------------------------------------
# reload jibri, tolerating an in-flight (re)start
# ---------------------------------------------------------------------------
wait_for_jibri_ready
READY_RC=$?
if [ $READY_RC -eq 1 ]; then
  log_msg "jibri.service is not running ($(systemctl is-active jibri 2>/dev/null)); new config will be read on next start, skipping reload"
  metric "shards_update_reload_skipped" 1
  exit 0
fi

RET=1
ATTEMPT=1
BACKOFF=5
while [ $ATTEMPT -le "$JIBRI_RELOAD_ATTEMPTS" ]; do
  log_msg "reloading jibri (attempt $ATTEMPT/$JIBRI_RELOAD_ATTEMPTS)"
  $JIBRI_SERVICE_RELOAD_CMD
  RET=$?
  [ $RET -eq 0 ] && break
  log_msg "jibri reload failed (rc=$RET)"
  if [ $ATTEMPT -lt "$JIBRI_RELOAD_ATTEMPTS" ]; then
    sleep $BACKOFF
    BACKOFF=$(( BACKOFF * 2 ))
    wait_for_jibri_ready
  fi
  ATTEMPT=$(( ATTEMPT + 1 ))
done

if [ $RET -gt 0 ]; then
  log_msg "update failed: jibri did not accept the reload after $JIBRI_RELOAD_ATTEMPTS attempts"
  metric "shards_update_failed" 1
  # legacy metric name, kept so existing dashboards/alerts keep working
  metric "shards_update_update_failed" 1
else
  log_msg "update successful"
fi

# give jibri time to exit (when idle) so a follow-up render finds the unit
# restarting rather than about to restart
log_msg "sleep 10 after reload"
sleep 10

log_msg "complete"

# Never propagate a failure to consul-template: a non-zero exit here kills the
# whole consul-template runner, which is far worse than one missed reload.
exit 0
