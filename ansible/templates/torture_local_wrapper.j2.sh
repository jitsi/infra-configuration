#!/bin/bash
SSH_CONFIG="{{ infra_path }}/config/ssh.config"
BLIP_SCRIPT="{{ infra_path }}/scripts/blip.sh"
export BLIP_SSH="ssh -F $SSH_CONFIG -l {{ ansible_ssh_user }}"
export TORTURE_EXCLUDE_TESTS="{{ jitsi_torture_exclude_tests }}"
export TORTURE_INCLUDE_TESTS="{{ jitsi_torture_include_tests }}"

LOG_FILE="{{ jitsi_torture_path_tempdir.path }}/torture.log"

function cleanup() {
  rm -f {{ jitsi_torture_path_tempdir.path }}/test-reports.zip
  zip -q -r {{ jitsi_torture_path_tempdir.path }}/test-reports.zip target/chrome-2-chrome
}
trap cleanup EXIT

cd {{ jitsi_torture_path }}

{% if jitsi_torture_auth0_jwts is defined %}
  TENANT1=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant1.name`
  TENANT1_PARTICIPANT1_ROOM=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant1.participant1.room`
  TENANT1_PARTICIPANT1_JWT=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant1.participant1.jwt`
  TENANT1_PARTICIPANT2_ROOM=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant1.participant2.room`
  TENANT1_PARTICIPANT2_JWT=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant1.participant2.jwt`
  TENANT1_PARTICIPANT3_ROOM=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant1.participant3.room`
  TENANT1_PARTICIPANT3_JWT=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant1.participant3.jwt`
  TENANT1_PARTICIPANT3_PASSCODE=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant1.participant3.passcode`
  TENANT2=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant2.name`
  TENANT2_PARTICIPANT1_ROOM=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant2.participant1.room`
  TENANT2_PARTICIPANT1_JWT=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant2.participant1.jwt`
  TENANT2_PARTICIPANT2_JWT=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant2.participant2.jwt`
  TENANT3=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant3.name`
  TENANT3_PARTICIPANT1_ROOM=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant3.participant1.room`
  TENANT3_PARTICIPANT1_JWT=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant3.participant1.jwt`
  TENANT3_PARTICIPANT2_ROOM=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant3.participant2.room`
  TENANT3_PARTICIPANT2_JWT=`echo {{ jitsi_torture_auth0_jwts }} | jq -r .tenant3.participant2.jwt`
{% endif %}

mvn test \
 -Dthreadcount=2 \
 -Dorg.jitsi.meet.test.util.blip_script=$BLIP_SCRIPT \
 -Dorg.jitsi.malleus.max_disrupted_bridges_pct={{ jitsi_malleus_max_disrupted_bridges_pct }} \
 -Dorg.jitsi.malleus.conferences={{ jitsi_malleus_conferences }} \
 -Dorg.jitsi.malleus.join_delay={{ jitsi_malleus_join_delay }} \
 -Dorg.jitsi.malleus.use_load_test={{ jitsi_malleus_use_load_test }} \
 -Dorg.jitsi.malleus.participants={{ jitsi_malleus_participants }} \
 -Dorg.jitsi.malleus.senders={{ jitsi_malleus_video_senders }} \
 -Dorg.jitsi.malleus.audio_senders={{ jitsi_malleus_audio_senders }} \
 -Dorg.jitsi.malleus.duration={{ jitsi_malleus_duration }} \
 -Dorg.jitsi.malleus.enable_p2p=false \
 -Dremote.address={{ jitsi_torture_grid_address }} \
 -Dremote.resource.path=/usr/share/jitsi-meet-torture \
 -Dweb.participant1.isRemote=true \
 -Dweb.participant2.isRemote=true \
 -Dweb.participant3.isRemote=true \
 -Dweb.participant4.isRemote=true \
 -Dchrome.enable.headless=true \
 -Dwdm.gitHubTokenName={{ torture_github_user }} \
 -Dwdm.gitHubTokenSecret={{ torture_github_token }} \
 -Djitsi-meet.instance.url="https://{{ hcv_domain }}{{ test_subdir }}" \
 -DhostResolverRules="MAP {{ hcv_domain }} {{ shard_ip_address }}" \
 -DallowInsecureCerts=true \
 -Dorg.jitsi.iframe.page_path="{{ jitsi_torture_iframe_page }}" \
 -Dtest.report.directory=target/chrome-2-chrome \
 -Djitsi-meet.tests.toExclude=$TORTURE_EXCLUDE_TESTS \
 -Djitsi-meet.tests.toInclude=$TORTURE_INCLUDE_TESTS \
{% if prosody_muc_moderated_subdomains is defined %}
 -Dorg.jitsi.moderated.room.tenant_name="{{ prosody_muc_moderated_subdomains | first }}" \
{% endif %}
{% if jitsi_torture_tenant_jwt is defined %}
 -Dorg.jitsi.moderated.room.token="{{ jitsi_torture_tenant_jwt }}" \
{% endif %}
{% if jitsi_torture_auth0_jwts is defined %}
 -Dorg.jitsi.misc.single.tenant_name="${TENANT1}" \
 -Dorg.jitsi.misc.single.moderator.room_name="${TENANT1_PARTICIPANT1_ROOM}" \
 -Dorg.jitsi.misc.single.moderator.token="${TENANT1_PARTICIPANT1_JWT}" \
 -Dorg.jitsi.misc.single.non.moderator1.token="${TENANT1_PARTICIPANT2_JWT}" \
 -Dorg.jitsi.misc.single.non.moderator2.token="${TENANT2_PARTICIPANT1_JWT}"\
 -Dorg.jitsi.misc.tenant.tenant_name="${TENANT2}"\
 -Dorg.jitsi.misc.tenant.moderator1.token="${TENANT2_PARTICIPANT1_JWT}"\
 -Dorg.jitsi.misc.tenant.moderator2.token="${TENANT2_PARTICIPANT2_JWT}"\
 -Dorg.jitsi.misc.tenant.moderator1.room_name="${TENANT2_PARTICIPANT1_ROOM}"\
 -Dorg.jitsi.misc.tenant.non.moderator.token="${TENANT1_PARTICIPANT1_JWT}" \
 -Dorg.jitsi.misc.all.tenant_name="${TENANT1}"\
 -Dorg.jitsi.misc.all.moderator1.token="${TENANT1_PARTICIPANT2_JWT}"\
 -Dorg.jitsi.misc.all.moderator.room_name="${TENANT1_PARTICIPANT2_ROOM}"\
 -Dorg.jitsi.misc.all.moderator2.token="${TENANT1_PARTICIPANT1_JWT}" \
 -Dorg.jitsi.misc.pass.tenant_name="${TENANT1}"\
 -Dorg.jitsi.misc.pass.moderator1.token="${TENANT1_PARTICIPANT1_JWT}"\
 -Dorg.jitsi.misc.pass.moderator2.token="${TENANT1_PARTICIPANT2_JWT}"\
 -Dorg.jitsi.misc.pass.moderator.room_name="${TENANT1_PARTICIPANT3_ROOM}" \
 -Dorg.jitsi.misc.pass.moderator.room_pass="${TENANT1_PARTICIPANT3_PASSCODE}" \
 -Dorg.jitsi.misc.lobby.tenant_name="${TENANT3}" \
 -Dorg.jitsi.misc.lobby.moderator.token="${TENANT3_PARTICIPANT1_JWT}" \
 -Dorg.jitsi.misc.lobby.moderator.room_name="${TENANT3_PARTICIPANT1_ROOM}" \
 -Dorg.jitsi.misc.lobby.non.moderator1.token="${TENANT3_PARTICIPANT2_JWT}" \
 -Dorg.jitsi.misc.lobby.non.moderator1.room_name="${TENANT3_PARTICIPANT2_ROOM}" \
 -Dorg.jitsi.misc.lobby.non.moderator2.token="${TENANT1_PARTICIPANT1_JWT}" \
{% endif %}
 -Dchrome.disable.nosanbox=true >> $LOG_FILE  2>&1
