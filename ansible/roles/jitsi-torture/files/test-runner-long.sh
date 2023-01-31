#!/bin/bash
HOST=$1
DURATION=$2
#JVB_ADDRESS=$2
BROWSER="google-chrome"

export DBUS_SESSION_BUS_ADDRESS=/dev/null

[ -z "$TEST_DURATION" ] && TEST_DURATION=350
[ -z "$TEST_DOMAIN" ] && TEST_DOMAIN="lonely.jitsi.net"

[ -z "$HOST" ] && HOST=$TEST_DOMAIN

[ -z "$DURATION" ] && DURATION=$TEST_DURATION

export TMPDIR=$(mktemp -d)
LOG_FILE="${TMPDIR}/log1-long.log"

function cleanup() {
  cp $LOG_FILE ~/$HOST-torture.log
  rm -f ~/$HOST-test-reports.zip
  zip -q -r ~/$HOST-test-reports.zip test-reports

  rm -rf $TMPDIR
}
trap cleanup EXIT

Xvfb :2 -screen 0 1024x768x24 -noreset 2>/dev/null &
export DISPLAY=":2"

if [ ! -d jitsi-meet-torture-long ]; then
	git clone https://github.com/jitsi/jitsi-meet-torture.git jitsi-meet-torture-long
fi

cd jitsi-meet-torture-long
eval $XVFB mvn test  -DforkCount=0 -Djitsi-meet.instance.url="https://$HOST" -Dlonglived.duration=$DURATION -Djitsi-meet.tests.toRun="SetupConference,LongLivedTest,DisposeConference" -Dbrowser.owner=chrome -Dbrowser.second.participant=chrome > $LOG_FILE 2>&1
