#!/bin/bash

set -x

[ -e "build-versions.properties" ] && rm build_versions.properties

LOCAL_PATH=$(dirname "${BASH_SOURCE[0]}")

# first configure and update jitsi repo
"$LOCAL_PATH/configure-jitsi-repo.sh"

if [[ $? -ne 0 ]]; then
    echo "Failed to configure jitsi repo, failing job..."
    exit 2
fi

sudo apt -y install extrepo
sudo extrepo enable prosody
sudo apt update

[ -z "$PROSODY_VERSION" ] && export PROSODY_VERSION=$(apt-cache madison prosody-0.12 | awk '{print $3;}' | head -1 |  cut -d'-' -f1)

# find meta version
[ -z "$JITSI_MEET_META_VERSION" ] && JITSI_MEET_META_VERSION=$(apt-cache madison jitsi-meet | awk '{print $3;}' | head -1 |  cut -d'-' -f1)

git clone https://github.com/jitsi/jitsi-meet-debian-meta.git

. jitsi-meet-debian-meta/get-versions.sh "$JITSI_MEET_META_VERSION-1"
JITSI_MEET_META_VERSION=$(echo "$JITSI_MEET_META_VERSION" | cut -d'.' -f3)

jitsi_videobridge_min=$(apt-cache madison jitsi-videobridge2 | awk '{print $3;}' | head -1 | cut -d'-' -f1,2,3)

jicofo_min=${jicofo_min#1.0-}
jitsi_meet_web_min=${jitsi_meet_web_min#1.0.}
[ -z "$JITSI_MEET_VERSION" ] && export JITSI_MEET_VERSION=${jitsi_meet_web_min}
[ -z "$JVB_VERSION" ] && export JVB_VERSION=${jitsi_videobridge_min}
[ -z "$JICOFO_VERSION" ] && export JICOFO_VERSION=${jicofo_min}

echo "JVB_VERSION=$JVB_VERSION">> build_versions.properties
echo "JICOFO_VERSION=$JICOFO_VERSION" >> build_versions.properties
echo "JITSI_MEET_VERSION=$JITSI_MEET_VERSION" >> build_versions.properties
echo "JITSI_MEET_META_VERSION=$JITSI_MEET_META_VERSION" >> build_versions.properties
# echo "PROSODY_FROM_URL=$PROSODY_FROM_URL" >> build_versions.properties
echo "PROSODY_VERSION=$PROSODY_VERSION" >> build_versions.properties
# echo "PROSODY_PACKAGE_VERSION=$PROSODY_PACKAGE_VERSION" >> build_versions.properties
