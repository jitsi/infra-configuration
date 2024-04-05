local jwt = module:require "luajwtjitsi";
local jid = require "util.jid";
local json = require "cjson";
local inspect = require('inspect');

local Util = {}

-- required parameter for custom muc component prefix,
-- defaults to "conference"
local muc_domain_prefix = module:get_option_string("muc_mapper_domain_prefix", "conference");
local muc_domain_base = module:get_option_string("muc_mapper_domain_base");

if not muc_domain_base then
    module:log("warn", "No 'muc_domain_base' option set, disabling automated remapping of mucs");
    muc_domain_base = ""
end

local blacklist_prefix = module:get_option_array("muc_events_blacklist_prefixes", { 'focus@auth.', 'recorder@recorder.','recordera@recorder', 'recorderb@recorder', 'jvb@auth.', 'jibri@auth.','jibri@auth.','jibrib@auth.', 'transcriber@recorder.','transcribera@recorder.','transcriberb@recorder.', 'jigasi@auth.', 'jigasia@auth.','jigasib@auth.' });
local blacklist_domain_prefix = module:get_option_array("muc_events_blacklist_domain_prefixes", {'jigasia.', 'jigasib.' });

-- The "real" MUC domain that we are proxying to
local muc_domain = module:get_option_string("muc_mapper_domain", muc_domain_prefix .. "." .. muc_domain_base);

local ASAPKeyPath = module:get_option_string("asap_key_path", '/etc/prosody/certs/asap.key');
local ASAPAudience = module:get_option_string("asap_audience", 'jitsi');
local ASAPTTL_THRESHOLD = module:get_option_number("asap_ttl_threshold", 600);
local ASAPTTL = module:get_option_number("asap_ttl", 3600);
local ASAPIssuer = module:get_option_string("asap_issuer", 'jitsi');
local eventAPIKey = module:get_option_string("muc_events_api_key", 'replaceme');
local ASAPKeyId = module:get_option_string("asap_key_id", 'jitsi');

local jwtKeyCacheSize = module:get_option_number("jwt_pubkey_cache_size", 128);
local jwtKeyCache = require "util.cache".new(jwtKeyCacheSize);

local ASAPKey;
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

Util.OUTBOUND_SIP_JIBRI_PREFIXES = { 'outbound-sip-jibri@', 'sipjibriouta@', 'sipjibrioutb@' };
Util.INBOUND_SIP_JIBRI_PREFIXES = { 'inbound-sip-jibri@', 'sipjibriina@', 'sipjibriinb@' };

Util.FIRST_TRANSCRIPT_MESSAGE_POS = 1;

Util.http_headers = {
    ["User-Agent"] = "Prosody (" .. prosody.version .. "; " .. prosody.platform .. ")",
    ["x-api-key"] = eventAPIKey,
    ["Content-Type"] = "application/json"
};

Util.http_headers_no_auth = {
    ["User-Agent"] = "Prosody (" .. prosody.version .. "; " .. prosody.platform .. ")",
    ["Content-Type"] = "application/json"
}

function Util:generateToken(audience)
    audience = audience or ASAPAudience
    local t = os.time()
    local err
    local exp_key = 'asap_exp.' .. audience
    local token_key = 'asap_token.' .. audience
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
    token, err = jwt.encode(payload, ASAPKey, alg, { kid = ASAPKeyId })
    if not err then
        token = 'Bearer ' .. token
        jwtKeyCache:set(exp_key, exp)
        jwtKeyCache:set(token_key, token)
        return token
    else
        return ''
    end
end

function Util.shallow_copy(t)
    local t2 = {}
    for k, v in pairs(t) do
        t2[k] = v
    end
    return t2
end

function Util.get_fqn_and_customer_id(room)
    -- we cache fqn and customer_id on room object
    if room.fqn ~= nil then
        return room.fqn, room.customer_id;
    end

    local room_jid = room.jid;
    local node = jid.split(room_jid);
    local tenant, conference_name = node:match("^%[([^%]]+)%](.+)$");
    if not (tenant and conference_name) then
        module:log("debug", "Conference without tenant: %s", node);
        room.fqn = node;
        return node;
    end
    local _, customer_id = tenant:match("^(vpaas%-magic%-cookie%-)(.*)$")
    local fqn = tenant .. "/" .. conference_name;
    module:log("debug", "Retrieve fqn %s from room %s", fqn, room_jid);
    room.fqn = fqn;
    room.customer_id = customer_id;
    return fqn, customer_id
end

function Util.round(num, numDecimalPlaces)
    local mult = 10 ^ (numDecimalPlaces or 0)
    return math.floor(num * mult + 0.5) / mult
end

-- Check if the occupant is a regular user
-- @param occupant from event or occupant jid
function Util.is_blacklisted(occupant)
    local occupant_jid;
    if not occupant then
        return false;
    end

    if not occupant.bare_jid then
        occupant_jid = occupant
    else
        occupant_jid = occupant.bare_jid;
    end

    for _, prefix in ipairs(blacklist_prefix) do
        if string.sub(occupant_jid, 1, string.len(prefix)) == prefix then
            module:log("debug", "Occupant %s is blacklisted ", occupant_jid);
            return true;
        end
    end
    local occupant_domain = jid.host(occupant_jid);
    for _, prefix in ipairs(blacklist_domain_prefix) do
        if string.sub(occupant_domain, 1, string.len(prefix)) == prefix then
            module:log("debug", "Occupant %s is blacklisted by domain", occupant_jid);
            return true;
        end
    end
    return false;
end

function Util.get_sip_jibri_prefix(stanza)
    if not stanza then
        return nil;
    end

    local email = stanza:get_child_text('email');
    return get_sip_jibri_email_prefix(email);
end

local function extract_field_text(o, field, ns)
    if o ~= nil then
        local t = o:get_child(field, ns);
        if t then
            local extractedText = t:get_text();
            if extractedText ~= "userdata: (nil)" then
                return extractedText;
            end
        else
            return ""
        end
    end
    return "";
end

local function extract_object(o, objectName)
    if o ~= nil then
        return o:get_child(objectName);
    end
    return nil;
end

function Util.extract_occupant_identity_user(occupant)
    local r;

    local occupant_jid = occupant.jid;
    r = r or {};
    r['jid'] = occupant.jid;
    r['bare_jid'] = occupant.bare_jid;

    local presence = occupant:get_presence();
    if presence then
        local identity = extract_object(presence, 'identity');
        if identity then
            local user = extract_object(identity, 'user');
            r['email'] = extract_field_text(user, 'email');
            r['id'] = extract_field_text(user, 'id');
            r['name'] = extract_field_text(user, 'name');
        end
    end
    return r;
end

function Util.get_final_transcription(event)
    local transcription_message = event.stanza:get_child("json-message","http://jitsi.org/jitmeet");
    if transcription_message then
        -- module:log("debug","Sending transcriptions for Event: %s room %s: with transcription json: %s",event,event.room.jid,transcription_message:get_text());
        local transcription = json.decode(transcription_message:get_text());
        if transcription["transcript"] == nil then
            return;
        end
        --skip interim messages
        if transcription["is_interim"] then
            return;
        end
        local text_message = transcription["transcript"][Util.FIRST_TRANSCRIPT_MESSAGE_POS]["text"];
        --do not send empty messages
        if text_message == '' then
            return;
        end
        --extract user full jid
        local jid_bare = require "util.jid".bare;
        local user_id = transcription["participant"].id;
        local who = event.room:get_occupant_by_nick(jid_bare(event.room.jid) .. "/" .. user_id);
        local full_jid = who and who["jid"];
        transcription["jid"] = full_jid;
        --extract session id
        transcription["session_id"] = event.room._data.meetingId;
        local meeting_fqn, customer_id = Util.get_fqn_and_customer_id(event.room);
        transcription["fqn"] = meeting_fqn;
        transcription["customer_id"] = customer_id;
        -- module:log("debug", "Transcription %s", inspect(transcription));
        return transcription;
    end
end

return Util;
