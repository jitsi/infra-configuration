#!/usr/bin/env bash
#
# vault-seal-watchdog.sh
#
# Restarts vault.service if the node has been sealed (or unreachable) for
# several consecutive checks. Vault seals itself when it hits an unrecoverable
# storage error during post-unseal (e.g. a transient OCI Object Storage 5xx
# while restoring leases/entities) and then keeps running *sealed* -- it does
# not exit, so systemd's Restart=on-failure never fires and the node stays dark
# until an operator restarts it by hand.
#
# Because these nodes use auto-unseal (ocikms), a plain `systemctl restart`
# re-unseals the node automatically. This watchdog turns a stuck seal into a
# ~1-2 minute blip instead of a manual-recovery outage (see JIT vault runbook).
#
# Driven by vault-seal-watchdog.timer (runs every 60s). Safe to run on standby
# nodes: a healthy standby returns 429 and is treated as healthy.
set -euo pipefail

HEALTH_URL="${VAULT_WATCHDOG_HEALTH_URL:-https://127.0.0.1:8200/v1/sys/health}"
STATE_DIR="/run/vault-seal-watchdog"
FAIL_FILE="$STATE_DIR/consecutive_bad"
LAST_RESTART_FILE="$STATE_DIR/last_restart"

# How many consecutive bad checks before we act (guards against normal startup /
# leadership-transition blips). With a 60s timer this is ~2 minutes of sealed.
FAIL_THRESHOLD="${VAULT_WATCHDOG_FAIL_THRESHOLD:-2}"
# Never restart more often than this many seconds (guards against a tight
# restart<->seal loop when storage is genuinely down for an extended period).
MIN_RESTART_INTERVAL="${VAULT_WATCHDOG_MIN_RESTART_INTERVAL:-180}"

mkdir -p "$STATE_DIR"

# /v1/sys/health status codes:
#   200 initialized+unsealed+active   429 unsealed+standby
#   472 DR secondary active           473 performance standby
#   501 not initialized               503 sealed
# We only act on 503 (sealed) or a connection failure (000).
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH_URL")" || code=000

case "$code" in
  200|429|472|473|501)
    # healthy (or deliberately uninitialized) -- reset the failure counter
    rm -f "$FAIL_FILE"
    exit 0
    ;;
esac

fails=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$fails" > "$FAIL_FILE"
logger -t vault-seal-watchdog "vault health returned ${code} (sealed/unreachable); consecutive=${fails}/${FAIL_THRESHOLD}"

if [ "$fails" -lt "$FAIL_THRESHOLD" ]; then
  exit 0
fi

now="$(date +%s)"
last="$(cat "$LAST_RESTART_FILE" 2>/dev/null || echo 0)"
if [ "$(( now - last ))" -lt "$MIN_RESTART_INTERVAL" ]; then
  logger -t vault-seal-watchdog "vault still bad but last restart was $(( now - last ))s ago (< ${MIN_RESTART_INTERVAL}s); skipping"
  exit 0
fi

logger -t vault-seal-watchdog "vault sealed/unreachable for ${fails} checks (code=${code}); restarting vault.service"
echo "$now" > "$LAST_RESTART_FILE"
rm -f "$FAIL_FILE"
systemctl restart vault.service
