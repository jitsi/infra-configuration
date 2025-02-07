local jwt = module:require "luajwtjitsi";
local jid = require "util.jid";
local json = require "cjson";
local inspect = require('inspect');

local oss_util = module:require "util";

local Util = {}

-- required parameter for custom muc component prefix,
-- defaults to "conference"
local muc_domain_prefix = module:get_option_string("muc_mapper_domain_prefix", "conference");
local muc_domain_base = module:get_option_string("muc_mapper_domain_base");

if not muc_domain_base then
    module:log("warn", "No 'muc_domain_base' option set, disabling automated remapping of mucs");
    muc_domain_base = ""
end

-- The "real" MUC domain that we are proxying to
local muc_domain = module:get_option_string("muc_mapper_domain", muc_domain_prefix .. "." .. muc_domain_base);

local ASAPKeyPath = module:get_option_string("asap_key_path", '/etc/prosody/certs/asap.key');
local ASAPAudience = module:get_option_string("asap_audience", 'jitsi');
local ASAPTTL_THRESHOLD = module:get_option_number("asap_ttl_threshold", 600);
local ASAPTTL = module:get_option_number("asap_ttl", 3600);
local ASAPIssuer = module:get_option_string("asap_issuer", 'jitsi');
local ASAPKeyId = module:get_option_string("asap_key_id", 'jitsi');

local jwtKeyCacheSize = module:get_option_number("jwt_pubkey_cache_size", 128);
local jwtKeyCache = require "util.cache".new(jwtKeyCacheSize);

local ASAPKey;
local f = io.open(ASAPKeyPath, "r");
if f then
    ASAPKey = f:read("*all");
    f:close();
    if not ASAPKey then
        module:log("warn", "No ASAP Key read, disabling generate asap token");
        return
    end
else
    module:log("warn", "Error reading ASAP Key, disabling generate asap token");
    return
end

Util.FIRST_TRANSCRIPT_MESSAGE_POS = 1;

Util.http_headers = {
    ["User-Agent"] = "Prosody (" .. prosody.version .. "; " .. prosody.platform .. ")",
    ["Content-Type"] = "application/json"
};

Util.http_headers_no_auth = {
    ["User-Agent"] = "Prosody (" .. prosody.version .. "; " .. prosody.platform .. ")",
    ["Content-Type"] = "application/json"
}

function Util:generateToken(audience)
    if not ASAPKey then
        return ''
    end

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

function Util.get_sip_jibri_prefix(stanza)
    if not stanza then
        return nil;
    end

    local email = stanza:get_child_text('email');
    return oss_util.get_sip_jibri_email_prefix(email);
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

return Util;
