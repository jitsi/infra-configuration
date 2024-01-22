local util = module:require "util.internal";
local uuid_gen = require "util.uuid".generate;
local inspect = require('inspect');
local socket = require "socket";
local http = require "net.http";
local json = require "cjson";
local jid_bare = require 'util.jid'.bare;
local jid_split = require 'util.jid'.split;
local um_is_admin = require "core.usermanager".is_admin;
local st = require 'util.stanza';
local timer = require "util.timer";
local split_jid = require "util.jid".split;

local oss_util = module:require "util";
local is_healthcheck_room = oss_util.is_healthcheck_room;
local get_room_from_jid = oss_util.get_room_from_jid;
local internal_room_jid_match_rewrite = oss_util.internal_room_jid_match_rewrite;
local is_vpaas = oss_util.is_vpaas;

local MUC_NS = 'http://jabber.org/protocol/muc';

local SETTINGS_PROVISIONING_CHECK_AFTER_SECONDS = 1;

local function is_admin(jid)
    return um_is_admin(jid, module.host);
end

local JAAS_PREFIX = "vpaas-magic-cookie-"
local EGRESS_URL = module:get_option_string("muc_prosody_egress_url", "http://127.0.0.1:8062/v1/events");
local EGRESS_FALLBACK_URL = module:get_option_string("muc_prosody_egress_fallback_url");
local USAGE = "USAGE";
local PARTICIPANT_JOINED = "PARTICIPANT_JOINED";
local PARTICIPANT_JOINED_LOBBY = "PARTICIPANT_JOINED_LOBBY";
local PARTICIPANT_LEFT = "PARTICIPANT_LEFT";
local PARTICIPANT_LEFT_LOBBY = "PARTICIPANT_LEFT_LOBBY";
local ROOM_CREATED = "ROOM_CREATED";
local ROOM_DESTROYED = "ROOM_DESTROYED";
local LIVE_STREAM_STARTED = "LIVE_STREAM_STARTED";
local LIVE_STREAM_ENDED = "LIVE_STREAM_ENDED";
local RECORDING_STARTED = "RECORDING_STARTED";
local RECORDING_ENDED = "RECORDING_ENDED";
local SIP_CALL_IN_STARTED = "SIP_CALL_IN_STARTED";
local SIP_CALL_IN_ENDED = "SIP_CALL_IN_ENDED";
local SIP_CALL_OUT_STARTED = "SIP_CALL_OUT_STARTED";
local SIP_CALL_OUT_ENDED = "SIP_CALL_OUT_ENDED";
local SIP_PARTICIPANT_NOT_JOINED_YET = "SIP_PARTICIPANT_NOT_JOINED_YET";
local SIP_PARTICIPANT_ALREADY_JOINED = "SIP_PARTICIPANT_ALREADY_JOINED";
local DIAL_IN_STARTED = "DIAL_IN_STARTED";
local DIAL_IN_ENDED = "DIAL_IN_ENDED";
local DIAL_OUT_STARTED = "DIAL_OUT_STARTED";
local DIAL_OUT_ENDED = "DIAL_OUT_ENDED";
local TRANSCRIPTION_CHUNK_RECEIVED = "TRANSCRIPTION_CHUNK_RECEIVED";
local TRANSCRIPTION_STARTED = "TRANSCRIPTION_STARTED";
local TRANSCRIPTION_ENDED = "TRANSCRIPTION_ENDED";
local POLL_CREATED = "POLL_CREATED";
local POLL_ANSWER = "POLL_ANSWER";
local ROLE_CHANGED = "ROLE_CHANGED";

local muc_domain_base = module:get_option_string("muc_mapper_domain_base");
if muc_domain_base == nil then
    module:log('error', 'webhooks module not loaded missing muc_domain_base config');
    return
end

-- defaults to "conference"
local muc_domain_prefix = module:get_option_string("muc_mapper_domain_prefix", "conference");
-- The "real" MUC domain
local muc_domain = module:get_option_string("muc_mapper_domain", muc_domain_prefix .. "." .. muc_domain_base);
-- in case of breakout rooms we need the main muc to look for the main room
local main_muc_service;

local NICK_NS = "http://jabber.org/protocol/nick";
local JIGASI_CALL_DIRECTION_ATTR_NAME = "JigasiCallDirection";
local TRANSCRIBER_PREFIX = 'transcriber@recorder.';
local RECORDER_PREFIX = 'recorder@recorder.';

local event_count = module:measure("muc_webhooks_rate", "rate")
local event_count_failed = module:measure("muc_webhooks_failed", "rate")
local event_count_sent = module:measure("muc_webhooks_sent", "rate")
local event_count_retried_sent = module:measure("muc_webhooks_retried_sent", "rate")
local event_count_retried_failed = module:measure("muc_webhooks_retried_failed", "rate")

local KICKED_PARTICIPANTS_NICK = {}
local DISCONNECTED_PARTICIPANTS_JID = {}

-- List of the bare_jids of all moderator occupants (owners in main room) present in the lobby room.
-- Will be removed as they leave.
local moderator_occupants_in_lobby = {};

local function cb_retry(content_, code_, _, request_)
    if code_ == 200 or code_ == 204 then
        event_count_retried_sent()
        module:log("info", "Retry URL Callback: Code %s, Request (host %s, path %s)", code_, request_.host, request_.path);
    else
        event_count_retried_failed()
        module:log("error", "Retry URL Callback non successful: Code %s, Content %s", code_, content_);
    end
end

local function cb(content_, code_, response_, request_)
    if code_ == 200 or code_ == 204 then
        event_count_sent();
        module:log("debug", "URL Callback: Code %s, Content %s, Request (host %s, path %s, body %s), Response: %s",
                code_, content_, request_.host, request_.path, inspect(request_.body), inspect(response_));
    else
        event_count_failed();
        module:log("debug", "URL Callback non successful: Code %s, Content %s, Request (%s), Response: %s",
                code_, content_, inspect(request_), inspect(response_));

        -- for failed requests the response object is actually the request
        -- and the request is nil
        local headers = {};
        headers["User-Agent"] = util.http_headers_no_auth["User-Agent"]
        headers["Content-Type"] = util.http_headers_no_auth["Content-Type"]
        headers["Authorization"] = util.generateToken();

        http.request(EGRESS_FALLBACK_URL, {
            headers = headers,
            method = "POST",
            body = response_.body;
        }, cb_retry);
    end
end

-- whether this module is loaded for the breakout room muc component
-- we will mark all events that this is so, and will include the breakout room id (name)
local is_breakout = starts_with(module.host, 'breakout.');

local is_lobby = starts_with(module.host, 'lobby.');

-- Searches all rooms in the main muc component that holds a breakout room
-- caches it if found so we don't search it again
-- we should not cache objects in _data as this is being serialized when calling room:save()
local function get_main_room(breakout_room)
    if breakout_room.main_room then
        return breakout_room.main_room;
    end

    -- let's search all rooms to find the main room
    for room in main_muc_service.each_room() do
        if room._data and room._data.breakout_rooms_active and room._data.breakout_rooms[breakout_room.jid] then
            breakout_room.main_room = room;
            return room;
        end
    end
end

local function get_current_event_usage(session, customer_id, event_type, phone_no, call_direction)
    local current_usage_item = {};
    if event_type == DIAL_IN_STARTED or event_type == DIAL_OUT_STARTED then
        current_usage_item.deviceId = phone_no;
        current_usage_item.kid = JAAS_PREFIX .. customer_id .. "/" .. "dialIO";
        current_usage_item.customerId = customer_id;
        current_usage_item.callDirection = call_direction;
    else
        current_usage_item.customerId = customer_id;
        current_usage_item.deviceId = session.machine_uid;
        current_usage_item.kid = session.kid;
        current_usage_item.hasMauP = session.mau_p;
        if session.jitsi_meet_context_user then
            current_usage_item.userId = session.jitsi_meet_context_user.id;
            current_usage_item.email = session.jitsi_meet_context_user.email;
        end
    end
    return current_usage_item;
end

local function count_sip_participants(sip_participants)
    local count = 0;
    for _ in pairs(sip_participants) do
        count = count + 1;
    end
    return count;
end

local function handle_usage_update(room, meeting_fqn, current_usage_item, breakout_room_id, is_sip_join)
    local usage_payload = {};
    local participants = room._data.participants_jid or {};
    local sip_participants = room._data.sip_participants_events or {};
    local customer_id;
    local has_sip_participants = count_sip_participants(sip_participants) ~= 0;

    if is_sip_join then
        if #participants == 1 then
            module:log("info", "Sip jibri joined and the participant was in the room %s", room.jid)
            customer_id = room._data.first_usage["customerId"]
            table.insert(usage_payload, room._data.first_usage);
        end
    else
        current_usage_item.isBreakout = is_breakout;
        current_usage_item.breakoutRoomId = breakout_room_id;
        customer_id = current_usage_item["customerId"];
        if #participants == 1 and not has_sip_participants then
            module:log("info", "First participant join the room without sip jibris %s", room.jid)
            room._data.first_usage = current_usage_item;
        elseif #participants == 1 and has_sip_participants then
            module:log("info", "Participant joined and the sip jibri was in the room %s", room.jid)
            room._data.first_usage = current_usage_item;
            table.insert(usage_payload, current_usage_item);
        elseif #participants == 2 then
            module:log("debug", "Second participant join the room %s", room.jid)
            table.insert(usage_payload, room._data.first_usage);
            table.insert(usage_payload, current_usage_item);
        elseif #participants > 2 then
            table.insert(usage_payload, current_usage_item);
        end
    end

    if #usage_payload > 0 then
        local usage_event = {
            ["idempotencyKey"] = uuid_gen(),
            ["sessionId"] = room._data.meetingId,
            ["customerId"] = customer_id,
            ["created"] = util.round(socket.gettime() * 1000),
            ["meetingFqn"] = meeting_fqn,
            ["eventType"] = USAGE,
            ["data"] = usage_payload
        }
        module:log("debug", "Usage event: %s", inspect(usage_event))
        event_count();
        http.request(EGRESS_URL, {
            headers = util.http_headers_no_auth,
            method = "POST",
            body = json.encode(usage_event);
        }, cb);
    end
end

function handle_occupant_access(event, event_type)
    local room = event.room;

    -- in case of breakout rooms this is the main room jid where this breakout room is used,
    -- otherwise this is just the room jid
    local main_room = room;
    local breakout_room_id;
    if is_breakout then
        main_room = get_main_room(room);
        breakout_room_id = jid_split(room.jid);
    end
    if is_lobby then
        main_room = room.main_room;
    end

    local occupant = event.occupant;
    local stanza = event.stanza;
    local final_event_type = event_type
    local dial_participants = room._data.dial_participants or {};

    if not is_healthcheck_room(room.jid) and (not util.is_blacklisted(occupant) or util.has_prefix(occupant.jid, TRANSCRIBER_PREFIX) or util.has_prefix(occupant.jid, RECORDER_PREFIX)) then
        module:log("debug", "Will send participant event %s for room %s is_breakout (%s, main room jid:%s)", occupant.jid, room.jid, is_breakout, main_room.jid);
        local meeting_fqn, customer_id = util.get_fqn_and_customer_id(main_room);
        local session = event.origin;
        local payload = {};
        if session and session.auth_token then
            -- replace user name from the jwt claim with the name from the pre-join screen
            local occupant_nick = stanza:get_child('nick', NICK_NS);
            if occupant_nick then
                local pre_join_screen_name = occupant_nick:get_text()
                if pre_join_screen_name and session.jitsi_meet_context_user then
                    session.jitsi_meet_context_user["name"] = pre_join_screen_name;
                end
            end
            payload = type(session.jitsi_meet_context_user) == "table" and util.shallow_copy(session.jitsi_meet_context_user) or {}
            if session.jitsi_meet_context_group then
                payload.group = session.jitsi_meet_context_group;
            end
        end
        payload.participantJid = occupant.bare_jid;
        -- dial check
        if dial_participants[occupant.jid] ~= nil then
            module:log("debug", "dial participant %s leave room %s", occupant.jid, room.jid)
            if dial_participants[occupant.jid] == "in" then
                final_event_type = DIAL_IN_ENDED;
            elseif dial_participants[occupant.jid] == "out" then
                final_event_type = DIAL_OUT_ENDED
            end
        end
        local initiator;
        if stanza then
            initiator = stanza:get_child('initiator', 'http://jitsi.org/protocol/jigasi');
            if initiator and stanza.attr.type ~= 'unavailable' then
                module:log("debug", "dial participant %s joined room %s", occupant.jid, room.jid)
                local nick = stanza:get_child('nick', NICK_NS);
                if nick then
                    payload.nick = nick:get_text();
                end
                local call_direction;
                initiator:maptags(function(tag)
                    if tag.name == "header" and tag.attr.name == JIGASI_CALL_DIRECTION_ATTR_NAME then
                        call_direction = tag.attr.value;
                    end
                    return tag;
                end);
                payload.direction = call_direction;
                room._data.dial_participants = room._data.dial_participants or {}
                room._data.dial_participants[occupant.jid] = call_direction;
                if call_direction == "in" then
                    final_event_type = DIAL_IN_STARTED
                elseif call_direction == "out" then
                    final_event_type = DIAL_OUT_STARTED
                end
            end
        end

        -- transcriber check
        if stanza and util.has_prefix(occupant.jid, TRANSCRIBER_PREFIX) then
            local presence_type = stanza.attr.type;
            if not presence_type then
                module:log("debug", "Transcriber %s join the room %s", occupant.jid, room.jid)
                final_event_type = TRANSCRIPTION_STARTED
            elseif presence_type == 'unavailable' then
                module:log("debug", "Transcriber %s leave the room %s", occupant.jid, room.jid)
                final_event_type = TRANSCRIPTION_ENDED
            end
        end

        if not is_lobby then
            payload.isBreakout = is_breakout;
            payload.breakoutRoomId = breakout_room_id;
        end

        local participant_access_event = {
            ["idempotencyKey"] = uuid_gen(),
            ["sessionId"] = main_room._data.meetingId,
            ["created"] = util.round(socket.gettime() * 1000),
            ["meetingFqn"] = meeting_fqn,
            ["eventType"] = final_event_type,
            ["data"] = payload
        }
        if is_vpaas(main_room) then
            participant_access_event["customerId"] = customer_id
        else
            -- standalone customer
            if session then
                participant_access_event["customerId"] = session.jitsi_meet_context_group
            end
        end

        -- live stream/recording
        if util.has_prefix(occupant.jid, RECORDER_PREFIX) then
            local recorderType = event.room._data.recorderType;
            if final_event_type == PARTICIPANT_JOINED then
                module:log("debug", "Recorder %s joined", event.occupant.jid)
                if recorderType == 'recorder' then
                    participant_access_event["eventType"] = RECORDING_STARTED
                elseif recorderType == 'live_stream' then
                    participant_access_event["eventType"] = LIVE_STREAM_STARTED
                end
            elseif final_event_type == PARTICIPANT_LEFT then
                module:log("debug", "Recorder %s left", event.occupant.jid)
                if recorderType == 'recorder' then
                    participant_access_event["eventType"] = RECORDING_ENDED
                elseif recorderType == 'live_stream' then
                    participant_access_event["eventType"] = LIVE_STREAM_ENDED
                end
            end
            local rec_payload = {}
            rec_payload.conference = internal_room_jid_match_rewrite(room.jid);
            participant_access_event["data"] = rec_payload
        end

        -- sip call
        -- sip participant will send at least 2 presence events on each join
        -- one for the first join, containing basic info
        -- another one shortly after, containing additional info, such as the participant's sip_address
        -- multiple other presence updates can be sent apart from the 2 mandatory presences
        -- we process only the first presence containing the sip address
        if event_type == PARTICIPANT_JOINED and util.is_sip_jibri_join(stanza) then
            room._data.sip_participants_events = room._data.sip_participants_events or {}
            -- we must send sip address on the webhook
            local sip_address = stanza:get_child_text('sip_address');
            local is_new_sip_participant = (not room._data.sip_participants_events[occupant.jid]) or (room._data.sip_participants_events[occupant.jid] == SIP_PARTICIPANT_NOT_JOINED_YET);

            if sip_address and is_new_sip_participant then
                local sip_jibri_prefix = util.get_sip_jibri_prefix(stanza);

                if sip_jibri_prefix == util.INBOUND_SIP_JIBRI_PREFIX then
                    participant_access_event["eventType"] = SIP_CALL_IN_STARTED;
                    final_event_type = SIP_CALL_IN_STARTED;
                elseif sip_jibri_prefix == util.OUTBOUND_SIP_JIBRI_PREFIX then
                    participant_access_event["eventType"] = SIP_CALL_OUT_STARTED;
                    final_event_type = SIP_CALL_OUT_STARTED;
                end

                participant_access_event["data"]["sipAddress"] = sip_address
                local nick = stanza:get_child('nick', NICK_NS);
                if nick then
                    participant_access_event["data"]["nick"] = nick:get_text();
                end

                room._data.sip_participants_events[occupant.jid] = participant_access_event["eventType"];
                module:log("info", "%s: sip participant %s joined the room %s", participant_access_event["eventType"], occupant.jid, room.jid)
            elseif sip_address and not is_new_sip_participant then
                module:log("debug", "Ignoring the sip participant %s presence update for room %s", occupant.jid, room.jid)
                final_event_type = SIP_PARTICIPANT_ALREADY_JOINED;
            else
                -- no sip_address
                module:log("debug", "Ignoring the sip participant %s presence for room %s, as it has no sip address", occupant.jid, room.jid)
                final_event_type = SIP_PARTICIPANT_NOT_JOINED_YET;
                room._data.sip_participants_events[occupant.jid] = SIP_PARTICIPANT_NOT_JOINED_YET;
            end
        elseif event_type == PARTICIPANT_LEFT and room._data.sip_participants_events and room._data.sip_participants_events[occupant.jid] then
            if room._data.sip_participants_events[occupant.jid] == SIP_CALL_IN_STARTED then
                participant_access_event["eventType"] = SIP_CALL_IN_ENDED;
                final_event_type = SIP_CALL_IN_ENDED;
            elseif room._data.sip_participants_events[occupant.jid] == SIP_CALL_OUT_STARTED then
                participant_access_event["eventType"] = SIP_CALL_OUT_ENDED;
                final_event_type = SIP_CALL_OUT_ENDED;
            elseif room._data.sip_participants_events[occupant.jid] == SIP_PARTICIPANT_NOT_JOINED_YET then
                final_event_type = SIP_PARTICIPANT_NOT_JOINED_YET;
            end
            room._data.sip_participants_events[occupant.jid] = nil
            if not (final_event_type == SIP_PARTICIPANT_NOT_JOINED_YET) then
                module:log("info", "%s: sip participant %s left the room %s", participant_access_event["eventType"], occupant.jid, room.jid)
            end
        end

        if final_event_type == SIP_PARTICIPANT_NOT_JOINED_YET or final_event_type == SIP_PARTICIPANT_ALREADY_JOINED then
            module:log("debug", "Ignoring sip event %s, the event either does not contain the sip_address, or is a presence update which we don't send as webhook: %s", event_type, stanza);
            return
        end

        if not util.is_blacklisted(occupant) and is_vpaas(main_room)
                and (final_event_type == PARTICIPANT_JOINED or final_event_type == PARTICIPANT_LEFT)
                and event.origin and not event.origin.auth_token then
            module:log("warn", "Occupant %s tried to join a jaas room %s without a token", occupant.jid, room.jid)
            -- do not send join/left/usage events for JaaS participants without a jwt.
            return
        end

        -- lobby events
        if is_lobby then
            if final_event_type == PARTICIPANT_JOINED then
                module:log("debug", "Occupant %s joined lobby room %s", occupant.jid, room.jid);
                if main_room:get_affiliation(occupant.bare_jid) == 'owner' or occupant.role == "moderator" then
                    moderator_occupants_in_lobby[occupant.bare_jid] = 'owner';
                    return;
                end
                participant_access_event["eventType"] = PARTICIPANT_JOINED_LOBBY;
            elseif final_event_type == PARTICIPANT_LEFT then
                module:log("debug", "Occupant %s left lobby room %s", occupant.jid, room.jid);
                if moderator_occupants_in_lobby[occupant.bare_jid] ~= nil then
                    -- clear from list
                    moderator_occupants_in_lobby[occupant.bare_jid] = nil;
                    return;
                end
                participant_access_event["eventType"] = PARTICIPANT_LEFT_LOBBY;
            end
        end

        -- add reason for participant left
        if final_event_type == PARTICIPANT_LEFT or final_event_type == DIAL_OUT_ENDED or final_event_type == SIP_CALL_IN_ENDED or final_event_type == SIP_CALL_OUT_ENDED then
            local _, _, resource = split_jid(occupant.nick);
            -- check if the participant switch the main for the breakout room or vice versa
            local status_tag = stanza and stanza:get_child('status') or nil;
            if status_tag and status_tag:get_text() == 'switch_room' then
                payload.disconnectReason = 'switch_room'
            elseif status_tag and status_tag:get_text() == 'unrecoverable_error' then
                payload.disconnectReason = 'unrecoverable_error'
            elseif KICKED_PARTICIPANTS_NICK[resource] then
                payload.disconnectReason = 'kicked'
                KICKED_PARTICIPANTS_NICK[resource] = nil
            elseif DISCONNECTED_PARTICIPANTS_JID[occupant.jid] then
                payload.disconnectReason = 'unknown'
                DISCONNECTED_PARTICIPANTS_JID[occupant.jid] = nil
            else
                payload.disconnectReason = 'left'
            end
        end

        module:log("debug", "Participant event %s", inspect(participant_access_event))

        event_count();
        http.request(EGRESS_URL, {
            headers = util.http_headers_no_auth,
            method = "POST",
            body = json.encode(participant_access_event);
        }, cb);

        -- send MAU usage for normal participants and dial calls only
        -- live stream/recording/sip calls are billed based on duration and not MAU
        if not util.is_blacklisted(occupant) and is_vpaas(main_room) and event_type == PARTICIPANT_JOINED then
            local is_sip_jibri_event = final_event_type == SIP_CALL_IN_STARTED or final_event_type == SIP_CALL_OUT_STARTED or final_event_type == SIP_CALL_IN_ENDED or final_event_type == SIP_CALL_OUT_ENDED
            if not is_breakout then
                if not is_sip_jibri_event then
                    local participants = room._data.participants_jid or {};
                    table.insert(participants, occupant.bare_jid);
                    room._data.participants_jid = participants;
                    local current_usage_item = get_current_event_usage(session, customer_id, final_event_type, payload.nick, payload.direction);
                    handle_usage_update(main_room, meeting_fqn, current_usage_item, breakout_room_id, is_sip_jibri_event);
                else
                    handle_usage_update(main_room, meeting_fqn, nil, breakout_room_id, is_sip_jibri_event)
                end
            end
        end
    end
end

function handle_broadcast_presence(event)
    local room = event.room;
    local stanza = event.stanza;

    -- sip participant will send at least 2 presence events on each join
    -- one for the first join, containing basic info
    -- and another one shortly after, containing additional info, such as the participant's sip_address
    -- multiple other presence updates can be sent apart from the 2 mandatory presences
    -- we process only the first presence containing the sip address
    if not is_healthcheck_room(room.jid) and util.is_sip_jibri_join(stanza) then
        local sip_address = stanza:get_child_text('sip_address');
        if sip_address then
            handle_occupant_access(event, PARTICIPANT_JOINED)
        end
    end
end

function handle_room_event(event, event_type)
    local room = event.room;

    local main_room = room;
    local breakout_room_id;
    if is_breakout then
        main_room = get_main_room(room);
        breakout_room_id = jid_split(room.jid);
    end

    if  is_lobby then
        return;
    end

    if is_healthcheck_room(room.jid) or not main_room then
        return;
    end

    module:log("debug", "Will send room event for %s", room.jid);
    local meeting_fqn, customer_id = util.get_fqn_and_customer_id(main_room);
    local payload = {};
    payload.conference = internal_room_jid_match_rewrite(main_room.jid);

    payload.isBreakout = is_breakout;
    payload.breakoutRoomId = breakout_room_id;

    local room_event = {
        ["idempotencyKey"] = uuid_gen(),
        ["sessionId"] = main_room._data.meetingId,
        ["created"] = util.round(socket.gettime() * 1000),
        ["meetingFqn"] = meeting_fqn,
        ["eventType"] = event_type,
        ["data"] = payload
    }
    if is_vpaas(main_room) then
        room_event["customerId"] = customer_id
    end

    event_count();
    http.request(EGRESS_URL, {
        headers = util.http_headers_no_auth,
        method = "POST",
        body = json.encode(room_event);
    }, cb);
end

function handle_jibri_event(event)
    if is_breakout or is_lobby then
        return
    end
    local stanza = event.stanza;
    if stanza.name == "iq" then
        local jibri = stanza:get_child('jibri', 'http://jitsi.org/protocol/jibri');
        if jibri then
            if not jibri.attr.action then
                return
            end
            local node, _ = jid_split(jid_bare(event.stanza.attr.to));
            local room_jid = node .. '@' .. module.host;
            local room = get_room_from_jid(room_jid)
            -- determine the event type: recording or live stream start or end
            if jibri.attr.action == 'start' then
                module:log("debug", "Start streaming for room %s", room.jid)
                if jibri.attr.recording_mode == 'stream' then
                    room._data.recorderType = 'live_stream'
                elseif jibri.attr.recording_mode == 'file' then
                    room._data.recorderType = 'recorder'
                else
                    module:log("warn", "Unknown jibri event")
                end
            end
        end
    end
end

-- process a host module directly if loaded or hooks to wait for its load
function process_host_module(name, callback)
    local function process_host(host)
        if host == name then
            callback(module:context(host), host);
        end
    end

    if prosody.hosts[name] == nil then
        module:log('info', 'No host/component found, will wait for it: %s', name)

        -- when a host or component is added
        prosody.events.add_handler('host-activated', process_host);
    else
        process_host(name);
    end
end

function handle_poll_created(pollData)
    local main_room = pollData.room;
    local breakout_room_id;
    if is_breakout then
        main_room = get_main_room(pollData.room);
        breakout_room_id = jid_split(pollData.room.jid);
    end

    local sessionId = main_room._data.meetingId;
    local meetingFqn, customerId = util.get_fqn_and_customer_id(main_room);

    local who = pollData.room:get_occupant_by_nick(jid_bare(pollData.room.jid) .. "/" .. pollData.poll.senderId);
    local user = util.extract_occupant_identity_user(who)

    local eventData = {
        pollId = pollData.poll.pollId,
        question = pollData.poll.question,
        answers = pollData.poll.answers,
        user = {
            name = pollData.poll.senderName,
            participantJid = user['bare_jid'],
            email = user['email'],
            id = user['id']
        },
        isBreakout = is_breakout,
        breakoutRoomId = breakout_room_id
    }

    local poll_created_event = {
        ["idempotencyKey"] = uuid_gen(),
        ["sessionId"] = sessionId,
        ["customerId"] = customerId,
        ["created"] = util.round(socket.gettime() * 1000),
        ["meetingFqn"] = meetingFqn,
        ["eventType"] = POLL_CREATED,
        ["data"] = eventData
    }
    module:log("debug", "Poll creeated event: %s", inspect(poll_created_event))
    event_count();
    http.request(EGRESS_URL, {
        headers = util.http_headers_no_auth,
        method = "POST",
        body = json.encode(poll_created_event);
    }, cb);
end

function handle_poll_answered(answerData)
    local main_room = answerData.room;
    local breakout_room_id;
    if is_breakout then
        main_room = get_main_room(answerData.room);
        breakout_room_id = jid_split(answerData.room.jid);
    end

    local sessionId = main_room._data.meetingId;
    local meetingFqn, customerId = util.get_fqn_and_customer_id(main_room);

    local who = answerData.room:get_occupant_by_nick(jid_bare(answerData.room.jid) .. "/" .. answerData.voterId);
    local user = util.extract_occupant_identity_user(who)

    local eventData = {
        pollId = answerData.pollId,
        answers = answerData.answers,
        user = {
            name = answerData.voterName,
            participantJid = user['bare_jid'],
            email = user['email'],
            id = user['id']
        },
        isBreakout = is_breakout,
        breakoutRoomId = breakout_room_id
    }

    local poll_answered_event = {
        ["idempotencyKey"] = uuid_gen(),
        ["sessionId"] = sessionId,
        ["customerId"] = customerId,
        ["created"] = util.round(socket.gettime() * 1000),
        ["meetingFqn"] = meetingFqn,
        ["eventType"] = POLL_ANSWER,
        ["data"] = eventData
    }
    module:log("debug", "Poll answer event: %s", inspect(poll_answered_event))
    event_count();
    http.request(EGRESS_URL, {
        headers = util.http_headers_no_auth,
        method = "POST",
        body = json.encode(poll_answered_event);
    }, cb);
end

module:hook("muc-occupant-joined", function(event)
    local room, occupant = event.room, event.occupant;
    local main_room = room;
    if is_breakout then
        main_room = get_main_room(room);
    end

    if is_healthcheck_room(room.jid) or is_admin(occupant.bare_jid) then
        return ;
    end

    if is_vpaas(main_room) then
        timer.add_task(SETTINGS_PROVISIONING_CHECK_AFTER_SECONDS, function(_)
            if room._data.jaas_err then
                local stanza = st.message({ type = 'error', from = room.jid; to = occupant.jid; })
                                 :tag("settings-error")
                                 :tag("text")
                                 :text(room._data.jaas_err):up():up();
                room:route_stanza(stanza);
            end
        end)
    end
end, 2);

--- Persist the nick of the participant that was kicked in order
--- to decorate the left event with the reason of disconnect
local function handle_kick(event)
    local stanza = event.stanza;
    local stanza_type = stanza.attr.type;
    local child = stanza:get_child('query', MUC_NS .. '#admin');
    if stanza_type and stanza_type == 'set' and child then
        local item = child:get_child('item')
        if item then
            local reason = item:get_child('reason')
            if reason and reason:get_text() == 'You have been kicked.' and item.attr.role == 'none' then
                module:log("debug", "Participant nick %s was kicked from the meeting", item.attr.nick)
                KICKED_PARTICIPANTS_NICK[item.attr.nick] = true
            end
        end
    end
end

--- Persist the full jid of the participant that experience an abnormal disconnect
--- in order to decorate the left event with the reason of disconnect
local function handle_pre_resource_unbind(event)
    local error = event.error
    local participant_jid = event.session.full_jid
    if error then
        if participant_jid then
            module:log("warn", "Participant %s disconnected abnormally error %s", participant_jid, error)
            DISCONNECTED_PARTICIPANTS_JID[participant_jid] = true
        end
    end
end

local function occupant_affiliation_changed(event)
    if event.actor and event.affiliation == 'owner' then
        local room = event.room;
        local granted_to_occupant = {};
        -- event.jid is the bare jid of participant
        for _, occupant in room:each_occupant() do
            if occupant.bare_jid == event.jid then
                granted_to_occupant = occupant;
                module:log("debug", "Participant %s was promoted to moderator by %s", occupant.jid, event.actor)
            end
        end

        local eventData = {
            grantedBy = {
                participantJid = event.actor
            },
            grantedTo = {
                participantJid = granted_to_occupant.jid
            },
            role = granted_to_occupant.role
        }

        local sessionId = room._data.meetingId;
        local meetingFqn, customerId = util.get_fqn_and_customer_id(room);

        local role_change_event = {
            ["idempotencyKey"] = uuid_gen(),
            ["sessionId"] = sessionId,
            ["customerId"] = customerId,
            ["created"] = util.round(socket.gettime() * 1000),
            ["meetingFqn"] = meetingFqn,
            ["eventType"] = ROLE_CHANGED,
            ["data"] = eventData
        }

        module:log("debug", "Role change event: %s", inspect(role_change_event))
        event_count();
        http.request(EGRESS_URL, {
            headers = util.http_headers_no_auth,
            method = "POST",
            body = json.encode(role_change_event);
        }, cb);
    end
end

local function handle_transcription_chunk(event)
    local subject = event.stanza:get_child("subject");
    if subject then
        return;
    end

    if event.stanza.attr.type == "groupchat" then
        local body = event.stanza:get_child("body")
        if body then
            return;
        end

        local transcription = util.get_final_transcription(event)
        if transcription then
            local participant = {
                ["name"] = transcription["participant"]["name"],
                ["userId"] = transcription["participant"]["identity_id"],
                ["id"] = transcription["participant"]["id"],
                ["avatarUrl"] = transcription["participant"]["avatar_url"],
                ["email"] = transcription["participant"]["email"]
            }
            local data = {
                ["messageID"] = transcription["message_id"],
                ["participant"] = participant,
                ["language"] = transcription["language"],
                ["final"] = transcription["transcript"][util.FIRST_TRANSCRIPT_MESSAGE_POS]["text"]
            }
            local transcription_chunk_received_event = {
                ["idempotencyKey"] = uuid_gen(),
                ["sessionId"] = transcription["session_id"],
                ["customerId"] = transcription["customer_id"],
                ["created"] = util.round(socket.gettime() * 1000),
                ["meetingFqn"] = transcription["fqn"],
                ["eventType"] = TRANSCRIPTION_CHUNK_RECEIVED,
                ["data"] = data
            }
            module:log("debug", "Transcription chunk received event: %s", inspect(transcription_chunk_received_event))
            event_count();
            http.request(EGRESS_URL, {
                headers = util.http_headers_no_auth,
                method = "POST",
                body = json.encode(transcription_chunk_received_event);
            }, cb);
        end
    end
end

process_host_module(muc_domain_base, function(host_module, host)
    module:log('info', 'Main component loaded %s', host);
    host_module:hook("pre-iq/full", handle_jibri_event, -2);
    host_module:hook("pre-iq/bare", handle_kick, -10);
    host_module:hook("pre-resource-unbind", handle_pre_resource_unbind, 10);
end);

-- in case of breakout rooms we need the main muc to look for the main room
process_host_module(muc_domain, function(host_module, host)
    local muc_module = prosody.hosts[host].modules.muc;
    if muc_module then
        main_muc_service = muc_module;
        module:log('info', 'Found main_muc_service: %s', main_muc_service);
    else
        module:log('info', 'Will wait for muc to be available');
        prosody.hosts[host].events.add_handler('module-loaded', function(event)
            if (event.module == 'muc') then
                main_muc_service = prosody.hosts[host].modules.muc;
                module:log('info', 'Found(on loaded) main_muc_service: %s', main_muc_service);
            end
        end);
    end
end);

module:hook("muc-occupant-joined", function(event)
    handle_occupant_access(event, PARTICIPANT_JOINED);
end, -1)
module:hook("muc-broadcast-presence", function(event)
    handle_broadcast_presence(event);
end, -1)
module:hook("muc-occupant-left", function(event)
    handle_occupant_access(event, PARTICIPANT_LEFT)
end, -1)
module:hook("muc-room-created", function(event)
    handle_room_event(event, ROOM_CREATED)
end, -1)
module:hook("muc-room-destroyed", function(event)
    handle_room_event(event, ROOM_DESTROYED)
end, -1)

module:hook("poll-created", function(pollData)
    handle_poll_created(pollData)
end, -1)

module:hook("answer-poll", function(answerData)
    handle_poll_answered(answerData)
end, -1)

module:hook("muc-set-affiliation", function(event)
    occupant_affiliation_changed(event);
end, -1);

module:hook("muc-broadcast-message", function(event)
    handle_transcription_chunk(event)
end, -1);

