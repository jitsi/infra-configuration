local http = require 'net.http';
local inspect = require('inspect');
local jid = require 'util.jid';
local json = require 'cjson';
local uuid_gen = require 'util.uuid'.generate;
local util = module:require 'util.internal';
local oss_util = module:require 'util';
local is_admin = oss_util.is_admin;
local is_healthcheck_room = oss_util.is_healthcheck_room;
local is_vpaas = oss_util.is_vpaas;

local NICK_NS = 'http://jabber.org/protocol/nick';

local PARTICIPANT_JOINED = 'PARTICIPANT_JOINED';
local PARTICIPANT_LEFT = 'PARTICIPANT_LEFT';
local ROOM_CREATED = 'ROOM_CREATED';
local USAGE = "USAGE";

local EGRESS_URL = module:get_option_string('muc_prosody_egress_url', 'http://127.0.0.1:8062/v1/events');
local EGRESS_FALLBACK_URL = module:get_option_string('muc_prosody_egress_fallback_url');

local event_count = module:measure('muc_webhooks_rate', 'rate')
local event_count_failed = module:measure('muc_webhooks_failed', 'rate');
local event_count_sent = module:measure('muc_webhooks_sent', 'rate');
local event_count_retried_sent = module:measure('muc_webhooks_retried_sent', 'rate');
local event_count_retried_failed = module:measure('muc_webhooks_retried_failed', 'rate');

-- this is the main virtual host of this vnode
local local_domain = module:get_option_string('muc_mapper_domain_base');
if not local_domain then
    module:log('warn', "No 'muc_mapper_domain_base' option set, disabling visitors webhooks plugin");
    return;
end

local function cb_retry(content_, code_, _, request_)
    if code_ == 200 or code_ == 204 then
        event_count_retried_sent()
        module:log('info', 'Retry URL Callback: Code %s, Request (host %s, path %s)', code_, request_.host, request_.path);
    else
        event_count_retried_failed()
        module:log('error', 'Retry URL Callback non successful: Code %s, Content %s', code_, content_);
    end
end

local function cb(content_, code_, response_, request_)
    if code_ == 200 or code_ == 204 then
        event_count_sent();
        module:log('debug', 'URL Callback: Code %s, Content %s, Request (host %s, path %s, body %s), Response: %s',
                code_, content_, request_.host, request_.path, inspect(request_.body), inspect(response_));
    else
        event_count_failed();
        module:log('debug', 'URL Callback non successful: Code %s, Content %s, Request (%s), Response: %s',
                code_, content_, inspect(request_), inspect(response_));

        -- for failed requests the response object is actually the request
        -- and the request is nil
        local headers = {};
        headers['User-Agent'] = util.http_headers_no_auth['User-Agent']
        headers['Content-Type'] = util.http_headers_no_auth['Content-Type']
        headers['Authorization'] = util.generateToken();

        http.request(EGRESS_FALLBACK_URL, {
            headers = headers,
            method = 'POST',
            body = response_.body;
        }, cb_retry);
    end
end

local function get_current_event_usage(session, customer_id)
    local current_usage_item = {};
    current_usage_item.customerId = customer_id;
    current_usage_item.deviceId = session.machine_uid;
    current_usage_item.kid = session.kid;
    current_usage_item.hasMauP = session.mau_p;
    if session.jitsi_meet_context_user then
        current_usage_item.userId = session.jitsi_meet_context_user.id;
        current_usage_item.email = session.jitsi_meet_context_user.email;
    end
    current_usage_item.visitor = true;
    return current_usage_item;
end

local function handle_usage_update(room, meeting_fqn, current_usage_item)
    local usage_payload = {};
    local participants = room._data.participants_jid or {};
    local customer_id;

    customer_id = current_usage_item['customerId'];
    if #participants == 1 then
        room._data.first_usage = current_usage_item;
    elseif #participants == 2 then
        module:log('debug', 'Second participant join the room %s', room.jid)
        table.insert(usage_payload, room._data.first_usage);
        table.insert(usage_payload, current_usage_item);
    elseif #participants > 2 then
        table.insert(usage_payload, current_usage_item);
    end

    if #usage_payload > 0 then
        local usage_event = {
            ['idempotencyKey'] = uuid_gen(),
            ['sessionId'] = room._data.meetingId,
            ['customerId'] = customer_id,
            ['created'] = util.round(socket.gettime() * 1000),
            ['meetingFqn'] = meeting_fqn,
            ['eventType'] = USAGE,
            ['data'] = usage_payload
        }
        module:log('debug', 'Usage event: %s', inspect(usage_event))
        event_count();
        http.request(EGRESS_URL, {
            headers = util.http_headers_no_auth,
            method = 'POST',
            body = json.encode(usage_event);
        }, cb);
    end
end

function handle_occupant_access(event, event_type)
    local occupant, room, stanza = event.occupant, event.room, event.stanza;
    local occupant_domain = jid.host(occupant.bare_jid);

    if is_healthcheck_room(room.jid)
        or is_admin(occupant.bare_jid)
        or not is_vpaas(room)
        or occupant_domain ~= local_domain then
        return;
    end

    -- in case of breakout rooms this is the main room jid where this breakout room is used,
    -- otherwise this is just the room jid
    local main_room = room;

    local final_event_type = event_type;

    module:log('debug', 'Will send participant event %s for room %s', occupant.jid, main_room.jid);
    local meeting_fqn, customer_id = util.get_fqn_and_customer_id(main_room);
    local session = event.origin;
    local payload = {};
    if session and session.auth_token then
        -- replace user name from the jwt claim with the name from the pre-join screen
        local occupant_nick = stanza:get_child('nick', NICK_NS);
        if occupant_nick then
            local pre_join_screen_name = occupant_nick:get_text()
            if pre_join_screen_name and session.jitsi_meet_context_user then
                session.jitsi_meet_context_user['name'] = pre_join_screen_name;
            end
        end
        payload = type(session.jitsi_meet_context_user) == 'table' and util.shallow_copy(session.jitsi_meet_context_user) or {}
        if session.jitsi_meet_context_group then
            payload.group = session.jitsi_meet_context_group;
        end
    end
    payload.participantJid = occupant.bare_jid;
    payload.participantFullJid = occupant.jid;
    payload.isVisitor = true;

    local participant_access_event = {
        ['idempotencyKey'] = uuid_gen(),
        ['sessionId'] = main_room._data.meetingId,
        ['created'] = util.round(socket.gettime() * 1000),
        ['meetingFqn'] = meeting_fqn,
        ['eventType'] = final_event_type,
        ['data'] = payload
    }
    if is_vpaas(main_room) then
        participant_access_event['customerId'] = customer_id
    else
        -- standalone customer
        if session then
            participant_access_event['customerId'] = session.jitsi_meet_context_group
        end
    end

    if is_vpaas(main_room)
            and (final_event_type == PARTICIPANT_JOINED or final_event_type == PARTICIPANT_LEFT)
            and event.origin and not event.origin.auth_token then
        module:log('warn', 'Occupant %s tried to join a jaas room %s without a token', occupant.jid, room.jid)
        -- do not send join/left/usage events for JaaS participants without a jwt.
        return
    end

    module:log('debug', 'Participant event %s', inspect(participant_access_event))

    event_count();
    http.request(EGRESS_URL, {
        headers = util.http_headers_no_auth,
        method = 'POST',
        body = json.encode(participant_access_event);
    }, cb);

    -- send MAU usage for normal participants and dial calls only
    -- live stream/recording/sip calls are billed based on duration and not MAU
    if event_type == PARTICIPANT_JOINED then
        local participants = room._data.participants_jid or {};
        table.insert(participants, occupant.bare_jid);
        room._data.participants_jid = participants;
        local current_usage_item = get_current_event_usage(session, customer_id);
        handle_usage_update(main_room, meeting_fqn, current_usage_item);
    end
end

module:hook('muc-occupant-joined', function(event)
    handle_occupant_access(event, PARTICIPANT_JOINED);
end, -1)
module:hook('muc-occupant-left', function(event)
    handle_occupant_access(event, PARTICIPANT_LEFT)
end, -1)
