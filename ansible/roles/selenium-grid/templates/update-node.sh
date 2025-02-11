#!/bin/bash
set -e
set -x

export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin

NODE_SESSIONS_STAT="http://localhost:5555/wd/hub/sessions"
AUTO_UPDATE_NODE_URL="http://localhost:3000/auto_upgrade_webdriver"
FF_LATEST_STABLE_URL="https://download.mozilla.org/?product=firefox-latest&os=linux64&lang=en-US"
FF_LATEST_BETA_URL="https://download.mozilla.org/?product=firefox-beta-latest&os=linux64&lang=en-US"

# if there was update out will have element saying:
# "Update was detected for one or more versions of the drivers. You may need to restart Grid Extras for new versions to work"
UPDATED_RES=`curl -sS ${AUTO_UPDATE_NODE_URL} | jq -r ".out | length"`

[ "$UPDATED_RES" == "1" ] && RESTART_NODE="true"

# Update chrome
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -q -y -o Acquire::ForceIPv4=true -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" google-chrome-stable google-chrome-beta

# Update firefox
# get latest versions info
wget -O /tmp/firefox_versions.json  https://product-details.mozilla.org/1.0/firefox_versions.json
LATEST_STABLE=`cat /tmp/firefox_versions.json | jq -r ".LATEST_FIREFOX_VERSION"`
CURRENT_STABLE=`cat /opt/mozilla/firefox_versions.json | jq -r ".LATEST_FIREFOX_VERSION"`
LATEST_BETA=`cat /tmp/firefox_versions.json | jq -r ".LATEST_FIREFOX_RELEASED_DEVEL_VERSION"`
CURRENT_BETA=`cat /opt/mozilla/firefox_versions.json | jq -r ".LATEST_FIREFOX_RELEASED_DEVEL_VERSION"`

# downloads latest firefox from $1 and move it to /opt/mozilla/$2
function updateFirefox() {
    local URL=$1
    local DEST=$2
    echo "Updating ${DEST}"

    cd /tmp
    wget -O ff.tar.xz ${URL}
    tar xvf ff.tar.xz > /dev/null

    rm -rf /opt/mozilla/${DEST}
    mv firefox /opt/mozilla/${DEST}
}

[ "${LATEST_STABLE}" != "${CURRENT_STABLE}" ] && updateFirefox ${FF_LATEST_STABLE_URL} "firefox-stable"
[ "${LATEST_BETA}" != "${CURRENT_BETA}" ] && updateFirefox ${FF_LATEST_BETA_URL} "firefox-beta"

# updating latest descriptions
mv /tmp/firefox_versions.json /opt/mozilla/firefox_versions.json

if [ "${RESTART_NODE}" == "true" ];
then
    # waits for no active sessions, to restart node
    while
        sleep 1
        [ "`curl -sS ${NODE_SESSIONS_STAT} | jq -r ".value | length"`" != "0" ]
    do true; done
    /usr/sbin/service selenium-grid-extras-node restart
fi
