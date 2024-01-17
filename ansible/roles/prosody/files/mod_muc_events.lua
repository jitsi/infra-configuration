module:set_global();

local jid = require "util.jid";
local http = require "net.http";
local json = require "cjson";
local inspect = require('inspect');
local socket = require "socket";
local uuid_gen = require "util.uuid".generate;
local jwt = module:require "luajwtjitsi";
local util = module:require "util.internal";
local is_healthcheck_room = module:require "util".is_healthcheck_room;

local event_count = module:measure("muc_events_rate", "rate")
local event_count_failed = module:measure("muc_events_failed", "rate")
local event_count_sent = module:measure("muc_events_sent", "rate")

local ASAPKeyPath
    = module:get_option_string("asap_key_path", '/etc/prosody/certs/asap.key');

local ASAPKeyId
    = module:get_option_string("asap_key_id", 'jitsi');

local ASAPIssuer
    = module:get_option_string("asap_issuer", 'jitsi');

local ASAPAudience
    = module:get_option_string("asap_audience", 'jitsi');

local ASAPTTL
    = module:get_option_number("asap_ttl", 3600);

local ASAPTTL_THRESHOLD
    = module:get_option_number("asap_ttl_threshold", 600);

local ASAPKey;

-- Read ASAP key once on module startup
local f = io.open(ASAPKeyPath, "r");
if f then
    ASAPKey = f:read("*all");
    f:close();
    if not ASAPKey then
        module:log("warn", "No ASAP Key read, disabling muc_events plugin");
        return
    end
else
    module:log("warn", "Error reading ASAP Key, disabling muc_events plugin");
    return
end

-- Cache for conference-related details: conf-details (muc_room_cache_size), conf-chat-history (muc_room_cache_size), conf-participants (maxParticipants*muc_room_cache_size), post-session-link (muc_room_cache_size)
local confCacheSize = module:get_option_number("conference_cache_size", 530000);
local function onConfCacheEvict(evictedKey, evictedValue)
    module:log("error", "Unexpected conference cache evict, this could lead to errors! For key %s, and value %s", evictedKey, evictedValue);
end
local confCache = require"util.cache".new(confCacheSize, onConfCacheEvict);

-- TODO: Figure out a less arbitrary default cache size.
local jwtKeyCacheSize = module:get_option_number("jwt_pubkey_cache_size", 128);
local jwtKeyCache = require"util.cache".new(jwtKeyCacheSize);


-- option to ignore events about the focus and other components
local blacklistPrefixes
    = module:get_option_array("muc_events_blacklist_prefixes", {'focus@auth.','recorder@recorder.','jvb@auth.','jibri@auth.','transcriber@recorder.'});

local roomBlacklistHostPrefixes
    = module:get_option_array("muc_events_blacklist_hosts", {'internal.auth.'});


local eventURL
    = module:get_option_string("muc_events_url", 'http://127.0.0.1:9880/');

local dropTenantPrefixes
    = module:get_option_array("muc_events_drop_tenant_prefixes", {'vpaas-magic-cookie-'});

local voChatHistoryURL
    = module:get_option_string("muc_chat_history_url");

local speakerStatsURL
    = module:get_option_string("muc_speaker_stats_url");

local transcriptionsURL
    = module:get_option_string("muc_transcriptions_url");

local eventAPIKey
    = module:get_option_string("muc_events_api_key", 'replaceme');

local muc_domain_prefix
    = module:get_option_string("muc_mapper_domain_prefix", "conference");

-- defaults to module.host, the module that uses the utility
local muc_domain_base
    = module:get_option_string("muc_mapper_domain_base", module.host);

-- The "real" MUC domain that we are proxying to
local muc_domain = module:get_option_string(
    "muc_mapper_domain", muc_domain_prefix.."."..muc_domain_base);

-- only the visitor prosody has main_domain setting
local is_visitor_prosody = module:get_option_string("main_domain") ~= nil;

local escaped_muc_domain_base = muc_domain_base:gsub("%p", "%%%1");
local escaped_muc_domain_prefix = muc_domain_prefix:gsub("%p", "%%%1");
-- The pattern used to extract the target subdomain
-- (e.g. extract 'foo' from 'foo.muc.example.com')
local target_subdomain_pattern
    = "^"..escaped_muc_domain_prefix..".([^%.]+)%."..escaped_muc_domain_base;

--- Utility function to check and convert a room JID from
-- virtual room1@muc.foo.example.com to real [foo]room1@muc.example.com
-- @param room_jid the room jid to match and rewrite if needed
-- @return returns room jid [foo]room1@muc.example.com when it has subdomain
-- otherwise room1@muc.example.com(the room_jid value untouched)
local function room_jid_match_rewrite(room_jid)
    local node, host, resource = jid.split(room_jid);
    local target_subdomain = host and host:match(target_subdomain_pattern);
    if not target_subdomain then
        module:log("debug", "No need to rewrite out 'to' %s", room_jid);
        return room_jid;
    end
    -- Ok, rewrite room_jid  address to new format
    local new_node, new_host, new_resource
        = "["..target_subdomain.."]"..node, muc_domain, resource;
    room_jid = jid.join(new_node, new_host, new_resource);
    module:log("debug", "Rewrote to %s", room_jid);
    return room_jid
end

local function remove_from_cache(key)
    confCache:set(key, nil);
end

local http_headers = {
    ["User-Agent"] = "Prosody ("..prosody.version.."; "..prosody.platform..")",
    ["x-api-key"] = eventAPIKey,
    ["Content-Type"] = "application/json"
};

local MUC_NS = "http://jabber.org/protocol/muc";
local NICK_NS = "http://jabber.org/protocol/nick";

local function shallow_copy(t)
    local t2 = {}
    for k,v in pairs(t) do
        t2[k] = v
    end
    return t2
end

local function generateToken(audience)
    audience = audience or ASAPAudience
    local t = os.time()
    local err
    local exp_key = 'asap_exp.'..audience
    local token_key = 'asap_token.'..audience
    local exp = jwtKeyCache:get(exp_key)
    local token = jwtKeyCache:get(token_key)

    --if we find a token and it isn't too far from expiry, then use it
    if token ~= nil and exp ~= nil then
        exp = tonumber(exp)
        if (exp - t) > ASAPTTL_THRESHOLD then
            return token
        end
    end

    --expiry is the current time plus TTL
    exp = t + ASAPTTL
    local payload = {
        iss = ASAPIssuer,
        aud = audience,
        nbf = t,
        exp = exp,
    }

    -- encode
    local alg = "RS256"
    token, err = jwt.encode(payload, ASAPKey, alg, {kid = ASAPKeyId})
    if not err then
        token = 'Bearer '..token
        jwtKeyCache:set(exp_key,exp)
        jwtKeyCache:set(token_key,token)
        return token
    else
        return ''
    end
end

local function round(num, numDecimalPlaces)
  local mult = 10^(numDecimalPlaces or 0)
  return math.floor(num * mult + 0.5) / mult
end

--- Finds and returns room by its jid
-- @param room_jid the room jid to search in the muc component
-- @return returns room if found or nil
local function get_room_from_jid(room_jid)
    local _, host = jid.split(room_jid);
    local component = hosts[host];
    if component then
        local muc = component.modules.muc
        if muc and rawget(muc,"rooms") then
            -- We're running 0.9.x or 0.10 (old MUC API)
            return muc.rooms[room_jid];
        elseif muc and rawget(muc,"get_room_from_jid") then
            -- We're running >0.10 (new MUC API)
            return muc.get_room_from_jid(room_jid);
        else
            return
        end
    end
end


local function presence_field(presence,field,ns)
    local t = presence:get_child(field,ns);
    if t then
        return t:get_text();
    else
        return nil;
    end
end

local function extract_field(o,field,ns)
    return presence_field(o:get_presence(),field,ns);
end

local function extract_occupant_details(occupant)
    local r;

    local occupant_jid =  occupant.jid;
    local cachedPDetails = confCache:get(occupant_jid);
    if cachedPDetails then
        cachedPDetails = json.decode(cachedPDetails);
        r = cachedPDetails.identity;
    end
    r = r or {};
    r['jid'] = occupant.jid;
    r['bare_jid'] = occupant.bare_jid;

    local t;
    if not r['email'] then
        t = extract_field(occupant,'email');
        if t then
            r['email'] = t;
        else
            if cachedPDetails ~= nil then
                r['email'] = cachedPDetails['email'];
            end
        end
    end

    if not r['name'] then
        t = extract_field(occupant,'nick',NICK_NS);
        if t then
            r['name'] = t;
        else
            if cachedPDetails ~= nil then
                r['name'] = cachedPDetails['name']
            end
        end
    end
    if not r['name'] then
        r['name'] = 'Guest';
    end

    return r;
end

local function isRoomTenantDropped(room_jid)
    local node, host, resource = jid.split(room_jid);
    for i, tPrefix in ipairs(dropTenantPrefixes) do
        if string.sub(node,1,string.len(tPrefix)+1) == '['..tPrefix then
            module:log("debug","Droplist tenant: %s found in %s ", tPrefix, node);
            return true;
        end
    end
end

local function isRoomBlacklisted(room_jid)
    local node, host, resource = jid.split(room_jid);
    for i, bPrefix in ipairs(roomBlacklistHostPrefixes) do
        if string.sub(host,1,string.len(bPrefix)) == bPrefix then
            module:log("debug","Blacklist host: %s found in %s ", bPrefix, host);
            return true;
        end
    end

    return false;
end

local function isBlacklisted(occupant)
    for i, bPrefix in ipairs(blacklistPrefixes) do
        if string.sub(occupant.bare_jid,1,string.len(bPrefix)) == bPrefix then
            module:log("debug","Blacklist prefix: %s found in %s ", bPrefix, occupant);
            return true;
        end
    end

    return false;
end

local function hasNonBlacklistedOccupants(room)
    for _, occupant in room:each_occupant() do
        if not isBlacklisted(occupant) then
            return true;
        end
    end
    return false;
end

local function cb(content_, code_, response_, request_)
    if code_ == 200 or code_ == 204 then
        module:log("debug", "URL Callback: Code %s, Content %s, Request (host %s, path %s, body %s), Response: %s",
                code_, content_, request_.host, request_.path, inspect(request_.body), inspect(response_));
    else
        module:log("warn", "URL Callback non successful: Code %s, Content %s, url (%s), Response: %s",
                code_, content_, request_.url, inspect(response_));
    end
end

local function event_cb(content_, code_, response_, request_)
    if code_ == 200 or code_ == 204 then
        -- increase event sent counter
        event_count_sent();
        module:log("debug", "URL Callback: Code %s, Content %s, Request (host %s, path %s, body %s), Response: %s",
                code_, content_, request_.host, request_.path, inspect(request_.body), inspect(response_));
    else
        -- increase event failure counter
        event_count_failed();
        module:log("warn", "URL Callback non successful: Code %s, Content %s, Request (%s), Response: %s",
                code_, content_, inspect(request_), inspect(response_));
    end
end

local function sendEvent(type,room_address,participant,group,pdetails,cdetails)
    local event_ts = round(socket.gettime()*1000);
    local out_event = {
        ["conference"] = room_address,
        ["conference_details"] = cdetails,
        ["event_type"] = "Participant"..type,
        ["participant"] = participant,
        ["group"] = group,
        ["participant_details"] = pdetails,
        ["event_ts"] = event_ts
    }
    module:log("debug","Sending event %s",inspect(out_event));

    local headers = http_headers or {}
    headers['Authorization'] = generateToken()

    module:log("debug","Sending headers %s",inspect(headers));

    -- increase event counter metric
    event_count();
    local request = http.request(eventURL, {
        headers = headers,
        method = "POST",
        body = json.encode(out_event)
    }, event_cb);
end

local function getChatHistoryKey(room_jid)
    return "chat@" .. room_jid;
end

local function loadConferenceDetails(room_jid)
    local cdetails = {};
    local cdetails_content = confCache:get(room_jid);
    if cdetails_content then
        cdetails = json.decode(cdetails_content);
        module:log("debug","Success retreiving conference details for room %s : %s",room_jid,inspect(cdetails))
    end
    return cdetails;
end

local function sendChatHistory(room_jid)
    if not voChatHistoryURL then
        module:log("debug", "No 'muc_chat_history_url' value set");
        return
    end

    local cdetails = loadConferenceDetails(room_jid);
    local timestamp = round(socket.gettime() * 1000);
    local meeting_fqn = util.get_fqn_and_customer_id(room_jid);
    local body = {
        ["roomAddress"] = room_jid,
        ["meetingFqn"] = meeting_fqn,
        ["messageType"] = "CHAT",
        ["sessionId"] = cdetails["session_id"],
        ["subject"] = cdetails["subject"],
        ["messages"] = confCache:get(getChatHistoryKey(room_jid)),
        ["timestamp"] = timestamp
    }
    local headers = http_headers or {}
    headers['Authorization'] = generateToken()

    module:log("debug", "Sending chat history %s to %s", inspect(body), voChatHistoryURL);
    local request = http.request(voChatHistoryURL, {
        headers = headers,
        method = "POST",
        body = json.encode(body)
    }, cb);
end

local function endConference(room)
    local room_jid = room.jid;
    module:log("debug", "Cleanup details for room %s", room_jid);
    sendChatHistory(room_jid);
    remove_from_cache(getChatHistoryKey(room_jid));
    remove_from_cache(room_jid);
    for _, occupant in room:each_occupant() do
        remove_from_cache(occupant.jid);
    end
end

local function appendToChatHistory(room_jid, occupant, content)
    local msgdetails = {};
    local occupant_jid = occupant.jid;
    msgdetails['jid'] = occupant.jid;
    msgdetails['bare_jid'] = occupant.bare_jid;
    msgdetails['timestamp'] = round(socket.gettime() * 1000);
    msgdetails['content'] = content;

    local participantDetails = confCache:get(occupant_jid);
    local pdetails = {};
    if participantDetails then
        pdetails = json.decode(participantDetails);
        msgdetails['name'] = pdetails['name'];
        msgdetails['email'] = pdetails['email'];
    end

    local chatHistoryKey = getChatHistoryKey(room_jid);
    local messages = confCache:get(chatHistoryKey);
    if messages == nil then
        messages = {};
    end
    table.insert(messages, msgdetails);
    confCache:set(chatHistoryKey, messages);

    module:log("debug", "Adding chat message to history for room %s: msgdetails %s", room_jid, inspect(msgdetails));
end

local function storeConferenceDetails(room_jid, cdetails)
    local new_content = json.encode(cdetails);
    confCache:set(room_jid, new_content);
    module:log("debug", "Storing conference details to room %s : %s", room_jid, inspect(cdetails))
end

local function attachSessionIdToSpeakerStats(room_jid, session_id)
    local room = get_room_from_jid(room_jid);
    if room == nil then
        log("warn", "Room with jid %s not found", room_jid);
        return;
    end
    if room.speakerStats == nil then
        room.speakerStats = {};
    end;
    room.speakerStats.sessionId = session_id;
end

local function loadConferenceSession(type, event)
    local room = event.room;
    module:log("debug", "Load conference session triggered by event type %s room %s", type, room.jid);
    local cdetails = loadConferenceDetails(room.jid);
    local session_id = cdetails["session_id"];

    if type == "Left" then
        cdetails["session_id"] = room._data.meetingId
        if not hasNonBlacklistedOccupants(room) then
            module:log("info", "End of conference session for room %s session_id %s", room.jid, session_id);
            endConference(room);
        end
    else
        if not session_id then
            session_id = room._data.meetingId or uuid_gen();
            cdetails["session_id"] = session_id;
            storeConferenceDetails(room.jid, cdetails);
            --TODO remove after speaker_stats is deployed
            attachSessionIdToSpeakerStats(room.jid, session_id);
            module:log("info", "Start new conference session for room %s: session_id %s", room.jid, session_id);
        else
            module:log("debug", "Conference session is in progress, for room %s, session_id %s", room.jid, session_id);
        end
    end

    return cdetails;
end

local function processEvent(type,event)
    module:log("debug", "%s keys in confCache", confCache:count());
    local who = event.occupant;
    local room_address = event.room.jid;
    local pdetails = extract_occupant_details(event.occupant);

    -- search bare_jid for blacklisted prefixes before sending events
    if isBlacklisted(who) then
        module:log("debug", "processEvent: occupant is blacklisted %s", who);
        return;
    end

    -- search room jid for blacklisted prefixes before sending events
    if isRoomBlacklisted(room_address) then
        module:log("debug", "processEvent: room is blacklisted %s", room_address);
        return;
    end

    -- search room jid for tenancy prefixes before sending events
    if isRoomTenantDropped(room_address) then
        module:log("debug", "processEvent: room tenant is droplisted %s", room_address);
        return;
    end

    local cdetails = loadConferenceSession(type, event);

    local occupant_nick = event.occupant and event.occupant.nick;
    if type == "Joined" then
        local flip_participant_nick = event.room._data and event.room._data.flip_participant_nick
        if occupant_nick and flip_participant_nick and flip_participant_nick == occupant_nick then
            module:log("info", "Decorate participant joined event with flip for occupant nick %s", flip_participant_nick)
            pdetails["flip"] = true;
        else
            pdetails["flip"] = false;
        end
    elseif type == "Left" then
        local kicked_participant_nick = event.room._data and event.room._data.kicked_participant_nick
        if occupant_nick and kicked_participant_nick and kicked_participant_nick == occupant_nick then
            module:log("info", "Decorate participant left event with flip for occupant nick %s", kicked_participant_nick)
            pdetails["flip"] = true;
        else
            pdetails["flip"] = false;
        end
    end
    module:log("debug", "Room %s Who %s Type %s", room_address, who, type);

    -- for visitor prosody we report only events for visitors
    if is_visitor_prosody then
        pdetails["visitor"] = true;
    end

    sendEvent(type,room_address,who.jid,pdetails["group"],pdetails,cdetails);
end

local function handleOccupantJoined(event)
    -- we skip healthcheck rooms and any main participant on a visitor prosody
    if is_healthcheck_room(event.room.jid) or (is_visitor_prosody and event.occupant.role ~= 'visitor') then
        return;
    end

    local event_type = "Joined";
    local session = event.origin;
    local occupant_jid = event.occupant.jid;
    if session ~= nil then
        local identity = type(session.jitsi_meet_context_user) == "table"
                and shallow_copy(session.jitsi_meet_context_user) or nil;
        if identity ~= nil then
            identity.group = session.jitsi_meet_context_group;
            local pdetails_string = confCache:get(occupant_jid);
            local pdetails = pdetails_string ~= nil and json.decode(pdetails_string) or {};
            pdetails.identity = identity;
            confCache:set(occupant_jid, json.encode(pdetails));
        end
    end
    processEvent(event_type, event);
end

-- do not check occupant.role as it maybe already reset
local function handleOccupantLeft(event)
    local occupant_domain = jid.host(event.occupant.bare_jid);

    -- we skip healthcheck rooms and any main participant on a visitor prosody
    if is_healthcheck_room(event.room.jid) or (is_visitor_prosody and occupant_domain ~= muc_domain_base) then
        return;
    end

    local event_type = "Left";
    processEvent(event_type, event);
    local occupant_jid = event.occupant.jid;
    remove_from_cache(occupant_jid);
end

local function handleBroadcastPresence(event)
    module:log("debug", "%s keys in confCache", confCache:count());
    local type = "Update";
    local occupant = event.occupant;
    local occupant_jid = occupant.jid;
    local room_jid = event.room.jid;

    -- search bare_jid for blacklisted prefixes before broadcasting events
    if isBlacklisted(occupant) then
        module:log("debug", "handleBroadcastPresence: occupant is blacklisted %s", occupant.bare_jid);
        return;
    end

    -- search room jid for blacklisted prefixes before sending events
    if isRoomBlacklisted(room_jid) then
        module:log("debug", "handleBroadcastPresence: room is blacklisted %s", room_jid);
        return;
    end

    -- search room jid for tenancy prefixes before sending events
    if isRoomTenantDropped(room_jid) then
        module:log("debug", "handleBroadcastPresence: room tenant is droplisted %s", room_jid);
        return;
    end

    module:log("debug", "handleBroadcastPresence Room %s Who %s Type %s", room_jid, occupant_jid, type);
    local nick = presence_field(event.stanza,'nick', NICK_NS);
    local email = presence_field(event.stanza,'email');

    if nick or email then
        module:log("debug", "handleBroadcastPresence email %s nick %s", nick, email);
        local content = confCache:get(occupant_jid);

        module:log("debug", "handleBroadcastPresence old content %s", content);

        if content == nil then
            local new_content = json.encode({["name"] = nick,["email"] = email });
            module:log("debug", "handleBroadcastPresence no old content for %s, saving item %s", occupant_jid, new_content);
            -- If the key is not found in the cache then it's a new participant, so do nothing except store it
            confCache:set(occupant_jid, new_content);
        else
            local pdetails = json.decode(content);
            pdetails = pdetails or {};
            if pdetails.name ~= nick or pdetails.email ~= email then
                pdetails.name = nick or pdetails.name;
                pdetails.email = email or pdetails.email;
                --update the cache with the latest
                confCache:set(occupant_jid, json.encode(pdetails));
                module:log("debug", "handleBroadcastPresence sending event %s", json.encode(pdetails));
                sendEvent(type, room_jid, occupant_jid,false, extract_occupant_details(occupant));
            end
        end
    else
        module:log("debug","handleBroadcastPresence empty nick and email, skipping broadcast");
    end
end

local function processSubjectUpdate(occupant, room_jid, new_subject)
    module:log("debug", "%s keys in confCache", confCache:count());
    module:log("debug", "processSubjectUpdate from_who %s, room_address %s, new_subject %s", occupant, room_jid, new_subject);
    local type = "SubjectUpdate";
    local occupant_jid = occupant.jid;

    -- extract participant details
    local pdetails = {};
    local participantContent = confCache:get(occupant_jid);
    if participantContent then
        pdetails = json.decode(participantContent);
    end
    pdetails['jid'] = occupant.jid;
    pdetails['bare_jid'] = occupant.bare_jid;

    -- search bare_jid for blacklisted prefixes before sending events
    if isBlacklisted(occupant) then
        module:log("debug", "processSubjectUpdate occupant is blacklisted %s", occupant);
        return;
    end

    -- search room jid for blacklisted prefixes before sending events
    if isRoomBlacklisted(room_jid) then
        module:log("debug", "processSubjectUpdate: room is blacklisted %s", room_jid);
        return;
    end

    -- search room jid for tenancy prefixes before sending events
    if isRoomTenantDropped(room_jid) then
        module:log("debug", "processSubjectUpdate: room tenant is droplisted %s", room_jid);
        return;
    end

    local cdetails = loadConferenceDetails(room_jid);
    cdetails["subject"] = new_subject;
    storeConferenceDetails(room_jid, cdetails);

    module:log("debug", "processSubjectUpdate sending event type %s, room_address %s", type, room_jid);
    sendEvent(type, room_jid, pdetails['jid'], false, pdetails, cdetails);
end

local function handleBroadcastMessage(event)
    module:log("debug", "handleBroadcastMessage Event %s: Room %s Stanza %s", event, event.room, event.stanza);

    local subject = event.stanza:get_child("subject");
    if subject then
        module:log("debug", "handleBroadcastMessage Event %s: has subject %s, continue processing", event, subject:get_text());
        local who = event.room:get_occupant_by_nick(event.stanza.attr.from);
        processSubjectUpdate(who, event.room.jid, subject:get_text());
        return;
    end

    local body = event.stanza:get_child("body");
    if event.stanza.attr.type == "groupchat" then
        if body then
            module:log("debug", "handleBroadcastMessage Event %s: has type %s, continue processing", event, "groupchat");
            local who = event.room:get_occupant_by_nick(event.stanza.attr.from);
            appendToChatHistory(event.stanza.attr.to, who, body:get_text());
            return;
        else
            --handle transcription messages
            if transcriptionsURL == nil or transcriptionsURL == "" then
                module:log("debug", "Transcriptions is disabled for room %s", event.room.jid);
                return;
            end

            local transcription = util.get_final_transcription(event);
            if transcription then
                local request_body = json.encode(transcription);
                local headers = http_headers or {};
                headers['Authorization'] = generateToken();
                http.request(transcriptionsURL, {
                    headers = headers,
                    method = "POST",
                    body = request_body;
                }, cb);
            end
        end
    end
end

local function attachMachineUid(event)
    module:log("debug","attach machine uid %s",event)
    local stanza, session = event.stanza, event.origin;
    -- the sending iq to jicofo method for retrieving the machine_uid is deprecated as we will be moving away from it
    -- where the initial conference iq will be sent over http
    if stanza.name == "iq" then
        local conference = stanza:get_child('conference', 'http://jitsi.org/protocol/focus');
        if conference then
            local machine_uid = conference.attr['machine-uid'];
            if machine_uid then
                module:log("debug", "found machine_uid %s", machine_uid)
                if session ~= nil then
                    session.machine_uid = machine_uid;
                end
            end
        end
    elseif session and not session.machine_uid and stanza.name == 'presence' then
        local join = stanza:get_child('x', MUC_NS);
        if join then
            session.machine_uid = join:get_child_text('billingid', MUC_NS);
            module:log('debug', 'found machine_uid %s', session.machine_uid)
        end
    end
end

local function attachJibriSessionId(event)
    module:log("debug","jibri iq search begun %s",event)
    local stanza = event.stanza;
    if stanza.name == "iq" then
        local jibri = stanza:get_child('jibri', 'http://jitsi.org/protocol/jibri');
        if jibri then
            if jibri.attr.action == 'start' then

                local update_app_data = false;
                local app_data = jibri.attr.app_data;
                if app_data then
                    app_data = json.decode(app_data);
                    module:log("debug","jibri app data found %s",inspect(app_data));
                else
                    app_data = {};
                end
                if app_data.file_recording_metadata == nil then
                    app_data.file_recording_metadata = {};
                end

                if jibri.attr.room then
                    local jibri_room = jibri.attr.room;
                    module:log("debug","jibri start found %s",jibri_room)
                    jibri_room = room_jid_match_rewrite(jibri_room)
                    module:log("debug","jibri room rewrite %s",jibri_room)
                    local conference_details = loadConferenceDetails(jibri_room)
                    if conference_details then
                        app_data.file_recording_metadata.conference_details = conference_details
                        update_app_data = true;
                        module:log("debug","jibri conference details added %s",inspect(conference_details))
                    end
                else
                    module:log("debug","jibri start iq has no room, coming from participant %s",jibri)

                    -- no room is because the iq received by the initiator in the room
                    local session = event.origin;
                    -- if a token is provided, add data to app_data
                    if session ~= nil then
                        local initiator = {};

                        if session.jitsi_meet_context_user ~= nil then
                            initiator.id = session.jitsi_meet_context_user.id;
                        end
                        if session.jitsi_meet_context_group ~= nil then
                            initiator.group = session.jitsi_meet_context_group;
                        end

                        app_data.file_recording_metadata.initiator = initiator
                        update_app_data = true;
                    end

                end

                if update_app_data then
                    app_data = json.encode(app_data);
                    module:log("debug","jibri final app data %s",app_data)
                    jibri.attr.app_data = app_data;
                    jibri:up()
                    stanza:up()
                    module:log("debug","jibri iq final %s",jibri)
                end
            end
        end
    end
end

-- Checks for billingid in presence to attach it as machine_uid to the session
local function handleOccupantPreJoin(event)
    if is_healthcheck_room(event.room.jid) then
        return;
    end

    attachMachineUid(event);
end

local function handleSpeakerStats(event)
    if speakerStatsURL == nil or speakerStatsURL == "" then
        module:log("debug", "Sending speaker stats is disabled. Not sending speaker stats for %s", event.room.jid);
        return;
    end
    if not event.roomSpeakerStats then
        return;
    end
    local requestBody = { sessionId = event.roomSpeakerStats.sessionId; isBreakoutRoom = event.roomSpeakerStats.isBreakout or false; breakoutRoomId = event.roomSpeakerStats.breakoutRoomId; speakerStats = {}; };
    if requestBody.isBreakoutRoom then
        module:log("debug", "Speaker stats is not handled for breakout rooms for now.");
        return;
    end
    for user_jid, speakerTime in pairs(event.roomSpeakerStats) do
        if (user_jid ~= "dominantSpeakerId" and user_jid ~= "sessionId" and user_jid ~= "isBreakout" and user_jid ~= "breakoutRoomId") then
            if not util.is_blacklisted(user_jid) then
                if speakerTime.context_user ~= nil then
                    requestBody.speakerStats[user_jid] = { time = speakerTime.totalDominantSpeakerTime; name = speakerTime.context_user.name; email = speakerTime.context_user.email; id = speakerTime.context_user.id; };
                else
                    requestBody.speakerStats[user_jid] = { time = speakerTime.totalDominantSpeakerTime;};
                end
            end
        end
    end
    if (next(requestBody.speakerStats) ~= nil) then
        if event.room then
            local room = event.room
            local main_room_jid;
            if room.main_room then
                -- breakout room cached by speakerstats module
                main_room_jid = room.main_room.jid;
            else
                main_room_jid = room.jid;
            end
            requestBody.meetingFqn = util.get_fqn_and_customer_id(main_room_jid);
        end
        requestBody.timestamp = round(socket.gettime() * 1000)
        module:log("info", "Sending speaker stats for %s", event.room.jid);
        module:log("debug", "Request body for speaker stats %s", inspect(requestBody));
        local headers = http_headers or {};
        headers['Authorization'] = generateToken();

        http.request(speakerStatsURL, {
            headers = headers,
            method = "POST",
            body = json.encode(requestBody);
        }, cb);
    else
        module:log("info", "No speaker stats to send for %s", event.room.jid);
    end
end

local function handleRoomDestroyed(event)
    local room = event.room;
    local room_jid = room.jid;
    remove_from_cache(room_jid);
    for _, occupant in room:each_occupant() do
        remove_from_cache(occupant.jid);
    end
    remove_from_cache(getChatHistoryKey(room_jid));
    module:log("debug", "%s keys in confCache after room %s was destroyed", confCache:count(), room.jid);
end

function module.add_host(host_module)
    module:log("info",
               "Loading mod_muc_events for host %s!", host_module.host);

    if not is_visitor_prosody then
        host_module:hook("pre-iq/full",attachJibriSessionId);
        host_module:hook("pre-iq/host", attachMachineUid);
        host_module:hook("muc-broadcast-message", handleBroadcastMessage);
        host_module:hook("send-speaker-stats", handleSpeakerStats);
    end

    host_module:hook('muc-occupant-pre-join', handleOccupantPreJoin, 1000);

    host_module:hook("muc-occupant-left", handleOccupantLeft);
    host_module:hook("muc-occupant-joined", handleOccupantJoined);
    host_module:hook("muc-broadcast-presence", handleBroadcastPresence);
    host_module:hook("muc-room-destroyed", handleRoomDestroyed);
end
