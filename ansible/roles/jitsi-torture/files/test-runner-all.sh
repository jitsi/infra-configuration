#!/bin/bash
set -x
HOST=$1
#JVB_ADDRESS=$2

[ -z "$TORTURE_EXCLUDE_TESTS" ] && TORTURE_EXCLUDE_TESTS="PSNRTest,LipSyncTest,RingOverlayTest,Peer2PeerTest,TCPTest"

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

#start Xvfb before the build
Xvfb :1 -screen 0 1024x768x24 -noreset 2>/dev/null &
export DISPLAY=":1"

TORTURE_PATH=/usr/share/jitsi-meet-torture

if [ ! -d jitsi-meet-torture ]; then
    git clone https://github.com/jitsi/jitsi-meet-torture.git $TORTURE_PATH/jitsi-meet-torture
fi


BROWSER="google-chrome"

cd jitsi-meet-torture || exit

eval $XVFB mvn test \
 -DforkCount=0 \
 -Djitsi-meet.instance.url="https://$HOST" \
 -Dtest.report.directory=target/chrome-2-chrome \
 -Djitsi-meet.tests.toExclude=$TORTURE_EXCLUDE_TESTS \
 -Dchrome.enable.headless=true \
 -Dchrome.disable.sandbox=true >> $LOG_FILE  2>&1

killall /usr/bin/google-chrome-unstable || true
killall /usr/bin/google-chrome-beta|| true
killall /usr/bin/google-chrome|| true
