-- enable this under the main muc component

local st = require('util.stanza');
local uuid = require 'util.uuid'.generate;
local json = require 'cjson.safe';

local util = module:require 'util';
local is_admin = util.is_admin;
local get_focus_occupant = util.get_focus_occupant;
local is_feature_allowed = util.is_feature_allowed;
local is_healthcheck_room = util.is_healthcheck_room;
local internal_room_jid_match_rewrite = util.internal_room_jid_match_rewrite;

local muc_domain_base = module:get_option_string('muc_mapper_domain_base');
if not muc_domain_base then
    module:log('error', 'No "muc_domain_base" option set, d isabling automated recordings');
    return;
end
local parentCtx = module:context(muc_domain_base);
if parentCtx == nil then
    module:log('error', 'Failed to start - unable to get parent context for host: %s', tostring(muc_domain_base));
    return;
end
local token_util = module:require 'token/util'.new(parentCtx);

module:hook('muc-occupant-joined', function (event)
    local room = event.room;
    local session = event.origin;
    local stanza = event.stanza;
    local occupant = event.occupant;
    local token = session.auth_token;

    if is_healthcheck_room(room.jid) or is_admin(occupant.jid) or not token then
        return;
    end

    if not room.transcription_auto_started and room._data.auto_transcriptions then
        -- TODO for jaas we need to start everything after jaas_actuator response (mod_muc_permissions_vpaas.lua)

        local is_session_allowed = is_feature_allowed(
            'transcription',
            session.jitsi_meet_context_features,
            session.granted_jitsi_meet_context_features,
            room:get_affiliation(stanza.attr.from) == 'owner');

        if not token_util:verify_room(session, room.jid) or not is_session_allowed then
            return;
        end

        module:log('info', 'Auto-transcribing the meeting %s', room.jid);

        if not room.jitsiMetadata then
            room.jitsiMetadata = {};
        end
        if not room.jitsiMetadata.recording then
            room.jitsiMetadata.recording = {};
        end
        room.jitsiMetadata.recording.isTranscribingEnabled = true;
        module:context(module.host):fire_event('room-metadata-changed', { room = room; });

        local room_jid_str = internal_room_jid_match_rewrite(room.jid)

        room.transcription_auto_started = true;

        room:route_stanza(st.iq({ type = 'set', id = uuid() .. ':sendIQ', from = occupant.jid, to =  room.jid..'/focus' })
            :tag('dial', { xmlns = 'urn:xmpp:rayo:1', from = 'fromnumber', to = 'jitsi_meet_transcribe' })
            :tag('header', { xmlns = 'urn:xmpp:rayo:1', name = 'JvbRoomName', value = room_jid_str }):up()
            :tag('header', { xmlns = 'urn:xmpp:rayo:1', name = 'auto-started', value = 'true' })
        );
    end

    if not room.recording_auto_started and room._data.auto_video_recording then
        local is_session_allowed = is_feature_allowed(
            'recording',
            session.jitsi_meet_context_features,
            session.granted_jitsi_meet_context_features,
            room:get_affiliation(stanza.attr.from) == 'owner');

        if not token_util:verify_room(session, room.jid) or not is_session_allowed then
            return;
        end

        module:log('info', 'Auto-recording the meeting %s', room.jid);

        room.recording_auto_started = true;
        room._data.recorderType = 'recorder';

        local metadata = {
            file_recording_metadata = {
                share = true;
                initiator = {
                    id =  session.jitsi_meet_context_user.id;
                    group = session.jitsi_meet_context_group;
                };
            };
        };
        room:route_stanza(st.iq({
                type = 'set',
                id = uuid() .. ':sendIQ',
                from = occupant.jid,
                to =  room.jid..'/focus'
            }):tag('jibri', {
                xmlns = 'http://jitsi.org/protocol/jibri',
                action = 'start',
                recording_mode = 'file',
                app_data = json.encode(metadata)
            }));
    end
end, -10) -- make sure we are last in the chain so all moderator adjustments are done
