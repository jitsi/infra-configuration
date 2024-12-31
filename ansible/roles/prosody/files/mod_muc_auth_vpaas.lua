-- Loaded only under main muc module
local json_safe = require "cjson.safe";
local basexx = require "basexx";
local cache = require "util.cache";

local st = require "util.stanza";
local timer = require "util.timer";

local um_is_admin = require "core.usermanager".is_admin;

local inspect = require('inspect');

local util_internal = module:require "util.internal";
local util = module:require "util";
local is_healthcheck_room = util.is_healthcheck_room;
local is_vpaas = util.is_vpaas;
local starts_with = util.starts_with;

local log = module._log;
local host = module.host;
local VPAAS_PREFIX = "vpaas-magic-cookie";
local CACHE_EXPIRATION_SECONDS = 3600;

local kid_parse_cache = cache.new(1000);

local parentHostName = string.gmatch(tostring(host), "%w+.(%w.+)")();
if parentHostName == nil then
    module:log("error", "Failed to start - unable to get parent hostname");
    return;
end

local parentCtx = module:context(parentHostName);
if parentCtx == nil then
    module:log("error",
        "Failed to start - unable to get parent context for host: %s",
        tostring(parentHostName));
    return;
end

local vpaas_asap_key_server = parentCtx:get_option_string("vpaas_asap_key_server");
if vpaas_asap_key_server == nil then
    module:log('error', 'vpaas not enabled, missing vpaas_asap_key_server config');
    return;
end

local token_util = module:require "token/util".new(parentCtx);

local DEBUG = false;

local function is_admin(jid)
    return um_is_admin(jid, module.host);
end

function invalidate_cache()
    token_util:clear_asap_cache()
    return CACHE_EXPIRATION_SECONDS;
end

timer.add_task(CACHE_EXPIRATION_SECONDS, invalidate_cache)

-- gets or creates an entry in the cache for the specified kid
-- checks is it vpass and extract the tenant (everything before the /) in the kid
local function get_kid_parse_cache_obj(kid)
    local kid_parse_cache_obj = kid_parse_cache:get(kid);
    if not kid_parse_cache_obj then
        kid_parse_cache_obj = {};

        kid_parse_cache_obj.is_vpaas = starts_with(kid, VPAAS_PREFIX);

        local tenant = kid:match("^(.*)%/.*$")
        kid_parse_cache_obj.tenant = tenant;

        kid_parse_cache:set(kid, kid_parse_cache_obj);
    end
    return kid_parse_cache_obj;
end

-- Retrieve the public key from VPAAS bucket
-- based on the hash of the kid
local function process_vpaas_token(session)
    if DEBUG then module:log("debug", "Fetching VPAAS public key form server %s", vpaas_asap_key_server); end

    if session.auth_token ~= nil then
        local jwt_encoded_header = session.auth_token:find("%.");
        if not jwt_encoded_header then
            return { res = false, error = "not-allowed", reason = "invalid token" };
        end
        local header, err = json_safe.decode(basexx.from_url64(session.auth_token:sub(1, jwt_encoded_header - 1)));
        if err then
            return { res = false, error = "not-allowed", reason = "bad token format" };
        end
        local kid = header["kid"];
        if kid == nil then
            return { res = false, error = "not-allowed", reason = "'kid' claim is missing" };
        end
        if type(kid) ~= "string" then
            module:log("warn", "kid in wrong format: %s", inspect(kid));
            return { res = false, error = "not-allowed", reason = "'kid' claim is in wrong format" };
        end

        local kid_parse_cache_obj = get_kid_parse_cache_obj(kid);

        if not kid_parse_cache_obj.is_vpaas then
            if DEBUG then module.log("debug", "Not a VPAAS user for pre validation"); end
            return nil;
        end

        if kid_parse_cache_obj.tenant == nil then
            return { res = false, error = "not-allowed", reason = "invalid kid format for vpaas" };
        end

        -- save kid on the session for post validation
        session.kid = kid;

        -- namespace the public key in order to avoid extra storage
        token_util:set_asap_key_server(vpaas_asap_key_server .. "/" .. kid_parse_cache_obj.tenant)
        local public_key = token_util:get_public_key(kid);
        if public_key == nil then
            return { res = false, error = "not-allowed", reason = "could not obtain public key" };
        end
        session.public_key = public_key;

        -- mark in session that context is required and later when verifying and parsing
        -- it can detect problems and fire not-allowed
        session.contextRequired = true;
    end
    return nil;
end

-- Validate if the tenant from sub claim matches the kid
-- return nil if successful false otherwise
local function validate_vpaas_token(session)
    local tenant = session.jitsi_meet_domain;
    local kid = session.kid;

    -- authenticated user but is not VPaaS
    if kid == nil then
        return nil
    end

    if not session.auth_token then
        return nil
    end

    local kid_parse_cache_obj = get_kid_parse_cache_obj(kid);
    if kid_parse_cache_obj.is_vpaas then
        if DEBUG then module:log("debug", "Post validate VPAAS token"); end
        if tenant == nil then
            return { res = false, error = "not-allowed", reason = "'tenant' is missing from session" };
        end
        if kid_parse_cache_obj.tenant ~= tenant then
            return { res = false, error = "not-allowed", reason = "kid and jwt tenant do not match" };
        end
    else
        if DEBUG then module:log("debug", "Not a VPAAS user for post validation"); end
        if tenant ~= nil and type(tenant) ~= "string" then
            module:log("warn", "tenant in wrong format: %s", inspect(tenant));
        elseif tenant ~= nil and starts_with(tenant, VPAAS_PREFIX) then
            -- VO/standalone customer with VPAAS tenant on SUB claim
            return { res = false, error = "not-allowed", reason = "vo customer with vpaas tenant" };
        end
    end

    return nil
end

local function deny_access(origin, stanza, room_disabled_access, room, occupant)
    local room_jid = room.jid;
    local token = origin.auth_token;
    local tenant = origin.jitsi_meet_domain;

    if is_healthcheck_room(room_jid)
        or is_admin(occupant.bare_jid)

        -- Skip VPAAS related verifications for non VPAAS room
        or not is_vpaas(room)

        -- Let Jigasi or transcriber pass throw
        or util.is_sip_jigasi(stanza)
        or util.is_transcriber_jigasi(stanza)

        -- is jibri
        or util.is_jibri(occupant)

        -- Let Sip Jibri pass through
        or util.is_sip_jibri_join(stanza) then
        return nil;
    end

    if DEBUG then module:log("debug",
        "Will verify if VPAAS room: %s has token on user %s pre-join", room_jid, occupant); end

    -- we allow participants from the main prosody to connect without token to the visitor one
    if token == nil and origin.type ~= 's2sin' then
        module:log("warn", "VPAAS room %s does not have a token", room_jid);
        origin.send(st.error_reply(stanza, "cancel", "not-allowed", "VPAAS room disabled for guests"));
        return true;
    end

    -- This is the case when a participant with a valid token (8x8) access a jaas room, we want it to join as a guest
    if token ~= nil and not starts_with(tenant, VPAAS_PREFIX) then
        if room._data.vpaas_guest_access then
            -- make sure it is not authenticated user, a guest (no features are set)
            origin.auth_token = nil;
            origin.jitsi_meet_room = nil;
            origin.jitsi_meet_domain = nil;
            origin.jitsi_meet_str_tenant = nil;
            origin.jitsi_meet_context_user = nil;
            origin.jitsi_meet_context_group = nil;
            origin.jitsi_meet_context_features = nil;
            origin.jitsi_meet_context_room = nil;
            origin.contextRequired = nil;
            origin.public_key = nil;
            origin.kid = nil;
            -- let's mark this session that we cleared the token
            origin.vpaas_guest_access = true;

            return nil;
        end

        module:log("warn", "VPAAS room %s is disabled for tenant %s", room_jid, tenant);
        origin.send(st.error_reply(stanza, "cancel", "not-allowed", "VPAAS room disabled for 8x8 users"));
        return true;
    end

    if room_disabled_access then
        module:log("warn", "VPAAS room %s has access disabled due to blocked or deleted tenant %s", room_jid, tenant);
        origin.send(st.error_reply(stanza, "cancel", "not-allowed", "VPAAS room disabled due to blocked or deleted tenant"));
        return true;
    end

    return nil;
end

prosody.events.add_handler("pre-jitsi-authentication-fetch-key", function(session)
    return process_vpaas_token(session);
end)

prosody.events.add_handler("post-jitsi-authentication", function(session)
    return validate_vpaas_token(session);
end)

prosody.events.add_handler('jitsi-authentication-token-verified', function(event)
    local session, claims = event.session, event.claims;
    -- save mauP claim from jwt - this customer specific claim, used to determine whether to increase
    -- their usage in billing-counter
    if claims.context then
        session.mau_p = claims.context.mauP;
    end
end)

module:hook("muc-occupant-pre-join", function(event)
    local room, origin, stanza = event.room, event.origin, event.stanza;
    local occupant_jid = stanza.attr.from;
    local room_disabled_access = room._data.disabled_access;

    -- Returning any value other than nil will halt processing of the event, and return that value to the code that fired the event.
    -- https://prosody.im/doc/developers/moduleapi#modulehook_event_name_handler_priority
    return deny_access(origin, stanza, room_disabled_access, room, occupant_jid);
end, 15); -- We want this to be executed after token verification (priority 99) and before the other
          -- modules max-occupants (p:10) or rate limiting (p:9)
