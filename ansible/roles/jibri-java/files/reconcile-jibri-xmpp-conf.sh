#!/bin/bash
#
# Promote a consul-template render that never got applied.
#
# consul-template only runs its command when the rendered content *changes*. If
# reconfigure-jibri-wrapper.sh is killed before it promotes the candidate (the
# ansible run restarting the consul-template service mid-settle does exactly
# this), the next render produces identical content, so no command fires and the
# live xmpp.conf stays stale until some unrelated catalog change comes along.
# This runs from cron, notices candidate and live have drifted, and re-invokes
# the wrapper, which is idempotent and takes the same lock as consul-template's
# own invocation.
#
# Environment:
#   XMPP_CONF_FILE            live config        (default /etc/jitsi/jibri/xmpp.conf)
#   XMPP_CONF_CANDIDATE_FILE  rendered candidate (default ${XMPP_CONF_FILE}.candidate)
#   JIBRI_WRAPPER             wrapper to invoke  (default /usr/local/bin/reconfigure-jibri-wrapper.sh)

[ -z "$XMPP_CONF_FILE" ] && XMPP_CONF_FILE="/etc/jitsi/jibri/xmpp.conf"
[ -z "$XMPP_CONF_CANDIDATE_FILE" ] && XMPP_CONF_CANDIDATE_FILE="${XMPP_CONF_FILE}.candidate"
[ -z "$JIBRI_WRAPPER" ] && JIBRI_WRAPPER="/usr/local/bin/reconfigure-jibri-wrapper.sh"
[ -z "$TEMPLATE_LOGDIR" ] && TEMPLATE_LOGDIR="/var/log/jitsi/jibri-shards"
[ -z "$TEMPLATE_LOGFILE" ] && TEMPLATE_LOGFILE="$TEMPLATE_LOGDIR/jibri-reconfigure.log"

# nothing rendered yet (consul-template not running, or not enabled on this host)
[ -s "$XMPP_CONF_CANDIDATE_FILE" ] || exit 0

# already applied: the common case, stay silent so cron does not spam the log
cmp -s "$XMPP_CONF_CANDIDATE_FILE" "$XMPP_CONF_FILE" && exit 0

[ -d "$TEMPLATE_LOGDIR" ] || mkdir -p "$TEMPLATE_LOGDIR"
echo "$(date --utc +%Y-%m-%d_%H:%M:%S.Z) [$$] jibri-reconcile: candidate differs from live config, invoking wrapper" | tee -a "$TEMPLATE_LOGFILE"

exec "$JIBRI_WRAPPER"
