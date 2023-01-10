#!/bin/bash
HOST=$1
#JVB_ADDRESS=$2
BROWSER="google-chrome"
export DBUS_SESSION_BUS_ADDRESS=/dev/null

export TMPDIR=$(mktemp -d)
LOG_FILE="${TMPDIR}/log1.log"

function cleanup() {
  cp $LOG_FILE ~/$HOST-torture.log
  rm -f ~/$HOST-test-reports.zip
  zip -q -r ~/$HOST-test-reports.zip target/chrome-2-chrome

  rm -rf $TMPDIR
}
trap cleanup EXIT

Xvfb :1 -screen 0 1024x768x24 -noreset 2>/dev/null &
export DISPLAY=":1"

if [ ! -d jitsi-meet-torture ]; then
	git clone https://github.com/jitsi/jitsi-meet-torture.git jitsi-meet-torture
fi

cd jitsi-meet-torture

eval $XVFB mvn test \
 -DforkCount=0 \
 -Djitsi-meet.instance.url="https://$HOST" \
 -Dtest.report.directory=target/chrome-2-chrome \
 -Djitsi-meet.tests.toRun=SetupConference,DisposeConference \
 -Dchrome.enable.headless=true \
 -Dchrome.disable.sandbox=true >> $LOG_FILE  2>&1

RET=$?

killall /usr/bin/google-chrome-unstable >/dev/null 2>&1|| true
killall /usr/bin/google-chrome-beta>/dev/null 2>&1|| true
killall /usr/bin/google-chrome>/dev/null 2>&1|| true

exit $RET
