local json_safe = require "cjson.safe";
local jwt = require "luajwtjitsi";
local basexx = require "basexx";

local st = require "util.stanza";
local timer = require "util.timer";

local util_internal = module:require "util.internal";
local util = module:require "util";
local is_healthcheck_room = util.is_healthcheck_room;
local starts_with = util.starts_with;

local log = module._log;
local host = module.host;
local VPAAS_PREFIX = "vpaas-magic-cookie";
local CACHE_EXPIRATION_SECONDS = 3600;

local parentHostName = string.gmatch(tostring(host), "%w+.(%w.+)")();
if parentHostName == nil then
    log("error", "Failed to start - unable to get parent hostname");
    return;
end

local parentCtx = module:context(parentHostName);
if parentCtx == nil then
    log("error",
        "Failed to start - unable to get parent context for host: %s",
        tostring(parentHostName));
    return;
end

local vpaas_asap_key_server = parentCtx:get_option_string("vpaas_asap_key_server");
if vpaas_asap_key_server == nil then
    log('error', 'vpaas not enabled, missing vpaas_asap_key_server config');
    return;
end

local token_util = module:require "token/util".new(parentCtx);

function invalidate_cache()
    token_util:clear_asap_cache()
    return CACHE_EXPIRATION_SECONDS;
end

timer.add_task(CACHE_EXPIRATION_SECONDS, invalidate_cache)

-- Retrieve the public key from VPAAS bucket
-- based on the hash of the kid
local function process_vpaas_token(session)
    module:log("debug", "Fetching VPAAS public key form server %s", vpaas_asap_key_server);

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
        if not starts_with(kid, VPAAS_PREFIX) then
            module.log("debug", "Not a VPAAS user for pre validation");
            return nil
        end
        local tenant, _ = kid:match("^(.*)%/(.*)$")
        if tenant == nil then
            return { res = false, error = "not-allowed", reason = "invalid kid format for vpaas" };
        end
        -- save kid on the session for post validation
        session.kid = kid;
        -- namespace the public key in order to avoid extra storage
        token_util:set_asap_key_server(vpaas_asap_key_server .. "/" .. tenant)
        local public_key = token_util:get_public_key(kid);
        if public_key == nil then
            return { res = false, error = "not-allowed", reason = "could not obtain public key" };
        end
        session.public_key = public_key;

        local data, msg = jwt.decode(session.auth_token);
        if data == nil or data.context == nil then
            return { res = false, error = "not-allowed", reason = "JWT cannot be decoded" };
        end

        -- save mauP claim from jwt - this customer specific claim, used to determine whether to increase
        -- their usage in billing-counter
        session.mau_p = data.context.mauP;
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

    if starts_with(kid, VPAAS_PREFIX) then
        module:log("debug", "Post validate VPAAS token");
        if kid == nil then
            return { res = false, error = "not-allowed", reason = "'kid' is missing from session" };
        end
        if tenant == nil then
            return { res = false, error = "not-allowed", reason = "'tenant' is missing from session" };
        end
        -- kid for vpaas will look like vpaas-magic-cookie-ee798cd9-2f54-4fa8-97f6-f99225543d61/ee798cd9-2f54-4fa8-97f6-f99225543d61
        -- vpaas-magic-cookie is prefix for all vpaas customers
        -- first uuid is the customer id
        -- a customer can change the public key so the last uuid after /
        -- uniquely identifies the key for that customer
        local _, tenant_uuid_from_kid, _ = kid:match("^(vpaas%-magic%-cookie%-)(.+)(/.+)$");
        local _, tenant_uuid = tenant:match("^(vpaas%-magic%-cookie%-)(.+)$")
        if tenant_uuid_from_kid ~= tenant_uuid then
            return { res = false, error = "not-allowed", reason = "kid and jwt tenant do not match" };
        end
    else
        module:log("debug", "Not a VPAAS user for post validation");
        if tenant ~= nil and starts_with(tenant, VPAAS_PREFIX) then
            -- VO/standalone customer with VPAAS tenant on SUB claim
            return { res = false, error = "not-allowed", reason = "vo customer with vpaas tenant" };
        end
    end

    return nil
end

local function deny_access(origin, stanza, room_disabled_access, room_jid, occupant)
    local token = origin.auth_token;
    local tenant = origin.jitsi_meet_domain;
    if not is_healthcheck_room(room_jid) and not util_internal.is_blacklisted(occupant) then
        local initiator = stanza:get_child('initiator', 'http://jitsi.org/protocol/jigasi');
        if initiator then
            module:log("debug", "Let Jigasi pass throw");
            return nil;
        end

        if util_internal.is_sip_jibri_join(stanza) then
            module:log("info", "Let Sip Jibri pass through %s", occupant);
            return nil;
        end

        if room_jid == nil or not util_internal.is_vpaas(room_jid) then
            module:log("debug", "Skip VPAAS related verifications for non VPAAS room %s", room_jid);
            return nil;
        end

        log("debug", "Will verify if VPAAS room: %s has token on user %s pre-join", room_jid, occupant);
        if token == nil then
            log("warn", "VPASS room %s does not have a token", room_jid);
            origin.send(st.error_reply(stanza, "cancel", "not-allowed", "VPASS room disabled for guests"));
            return true;
        end

        if token ~= nil and not starts_with(tenant, VPAAS_PREFIX) then
            log("warn", "VPASS room %s is disabled for tenant %s", room_jid, tenant);
            origin.send(st.error_reply(stanza, "cancel", "not-allowed", "VPASS room disabled for 8x8 users"));
            return true;
        end

        if room_disabled_access then
            log("warn", "VPASS room %s has access disabled due to blocked or deleted tenant %s", room_jid, tenant);
            origin.send(st.error_reply(stanza, "cancel", "not-allowed", "VPASS room disabled due to blocked or deleted tenant"));
            return true;
        end
    end

    return nil;
end

prosody.events.add_handler("pre-jitsi-authentication-fetch-key", function(session)
    return process_vpaas_token(session);
end)

prosody.events.add_handler("post-jitsi-authentication", function(session)
    return validate_vpaas_token(session);
end)

module:hook("muc-occupant-pre-join", function(event)
    local room, origin, stanza = event.room, event.origin, event.stanza;
    local occupant_jid = stanza.attr.from;
    local room_disabled_access = room._data.disabled_access;
    local room_jid = stanza.attr.to;

    -- Returning any value other than nil will halt processing of the event, and return that value to the code that fired the event.
    -- https://prosody.im/doc/developers/moduleapi#modulehook_event_name_handler_priority
    return deny_access(origin, stanza, room_disabled_access, room_jid, occupant_jid);
end, 15); -- We want this to be executed after token verification (priority 99) and before the other
          -- modules max-occupants (p:10) or rate limiting (p:9)
