module:set_global();

local json = require "util.json";
local async_handler_wrapper = module:require "util".async_handler_wrapper;
local jid = require "util.jid";
local timer = require "util.timer";

local room_jid_match_rewrite = module:require "util".room_jid_match_rewrite;
local is_healthcheck_room = module:require "util".is_healthcheck_room;
local is_vpaas = module:require "util.internal".is_vpaas;
local http = require "net.http";

local inspect = require "inspect";

local tostring = tostring;
local neturl = require "net.url";
local parse = neturl.parseQuery;
local jwt = require "luajwtjitsi";

-- will be initialized once the main virtual host module is initialized
local token_util;

-- TODO: Figure out a less arbitrary default cache size.
local cacheSize = module:get_option_number("jwt_pubkey_cache_size", 128);
local cache = require"util.cache".new(cacheSize);

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


-- required parameter for custom muc component prefix,
-- defaults to "conference"
local muc_domain_prefix
    = module:get_option_string("muc_mapper_domain_prefix", "conference");

local muc_domain_base = module:get_option_string("muc_mapper_domain_base");
if not muc_domain_base then
    module:log("warn", "No 'muc_domain_base' option set, disabling automated remapping of mucs");
    muc_domain_base = ""
end

-- The "real" MUC domain that we are proxying to
local muc_domain
    = module:get_option_string("muc_mapper_domain", muc_domain_prefix.."."..muc_domain_base);

local auth_domain_prefix
    = module:get_option_string("auth_domain_prefix", "auth");
-- The 'auth' internal domain used by jicofo
local auth_domain
    = module:get_option_string("auth_domain", auth_domain_prefix.."."..muc_domain_base);

-- option to enable/disable room API token verifications
local enableTokenVerification
    = module:get_option_boolean("enable_password_token_verification", true);

local asapKeyServer
    = module:get_option_string("prosody_password_public_key_repo_url", "");

local conferenceInfoURL
    = module:get_option_string("muc_conference_info_url", "");

local passwordTimeout
    = module:get_option_number("muc_password_timeout", 3);

local http_headers = {
    ["User-Agent"] = "Prosody ("..prosody.version.."; "..prosody.platform..")",
    ["Content-Type"] = "application/json"
};

if conferenceInfoURL == "" then
    module:log("warn", "No 'muc_conference_info_url' option set, disabling preset passwords");
    return
end

-- store iqs we had filtered before sent to jicofo
local pendingPresences = {}
-- store jids of rooms which are currently waiting for password query to finish
local pendingPasswordQueries = {}

-- Utility function to check and convert a room JID from real [foo]room1@muc.example.com to virtual room1@muc.foo.example.com
local function room_jid_match_rewrite_from_internal(room_jid)
    local node, host, resource = jid.split(room_jid);
    if host ~= muc_domain or not node then
        module:log("debug", "No need to rewrite %s (not from the MUC host)", room_jid);

        return room_jid;
    end
    local target_subdomain, target_node = node:match("^%[([^%]]+)%](.+)$");
    if not (target_node and target_subdomain) then
        module:log("debug", "Not rewriting... unexpected node format: %s", node);
        return room_jid;
    end
    -- Ok, rewrite room_jid address to pretty format
    local new_node, new_host, new_resource = target_node, muc_domain_prefix..".".. target_subdomain.."."..muc_domain_base, resource;
    room_jid = jid.join(new_node, new_host, new_resource);
    module:log("debug", "Rewrote to %s", room_jid);
    return room_jid
end

--- Verifies room name, domain name with the values in the token
-- @param token the token we received
-- @param room_address the full room address jid
-- @return true if values are ok or false otherwise
function verify_token(token, room_address)
    if not enableTokenVerification then
        return true;
    end

    -- if enableTokenVerification is enabled and we do not have token
    -- stop here, cause the main virtual host can have guest access enabled
    -- (allowEmptyToken = true) and we will allow access to rooms info without
    -- a token
    if token == nil then
        module:log("warn", "no token provided");
        return false;
    end

    local session = {};
    session.auth_token = token;
    local verified, reason, msg = token_util:process_and_verify_token(session);
    if not verified then
        module:log("warn", "not a valid token %s %s", tostring(reason), tostring(msg));
        return false;
    end

    -- accepting server tokens, which currently do not specify room permissions, so skip this check
    -- if not token_util:verify_room(session, room_address) then
    --     log("warn", "Token %s not allowed to join: %s",
    --         tostring(token), tostring(room_address));
    --     return false;
    -- end

    return true;
end

local function starts_with(str, start)
    return str:sub(1, #start) == start
end
--- Handles request for retrieving the room participants details
-- @param event the http event, holds the request query
-- @return GET response, containing a json with participants details
function handle_get_room_password (event)
    module:log("info","Request for room password received: reqid %s",event.request.headers["request_id"])
    if (not event.request.url.query) then
        return { status_code = 400 };
    end
	local params = parse(event.request.url.query);
	local room_name = params["room"];
	local domain_name = params["domain"];
    local subdomain = params["subdomain"];
    local conference = params["conference"];

    local room_address;

    if (not conference) and ((not room_name) or (not domain_name)) then
        return { status_code = 400 };
    end

    if conference then
        room_address = room_jid_match_rewrite(conference)
    else
        room_address
        = jid.join(room_name, muc_domain_prefix.."."..domain_name);

        if subdomain and subdomain ~= "" then
            room_address = "["..subdomain.."]"..room_address;
        end
    end


    -- verify access
    local token = event.request.headers["authorization"]
    if starts_with(token,'Bearer ') then
        token = token:sub(8,#token)
    end

    --    module:log("debug","incoming token %s",token)
    if not verify_token(token, room_address) then
        return { status_code = 403 };
    end

    local room = get_room_from_jid(room_address);

    if room then
        room_details = {};
        room_details["conference"] = room_address;
        room_details["password"] = room:get_password() or "";
        room_details["lobby"] = room._data ~= nil and room._data.lobbyroom ~= nil;

        local GET_response = {
            headers = {
                content_type = "application/json";
            };
            body = json.encode(room_details);
        };
        module:log("debug","Sending response for room password: %s",inspect(GET_response))

        return GET_response;
    end

    -- default case, return 404
    return { status_code = 404 };

end


local function generateToken(audience)
    audience = audience or ASAPAudience
    local t = os.time()
    local err
    local exp_key = 'asap_exp.'..audience
    local token_key = 'asap_token.'..audience
    local exp = cache:get(exp_key)
    local token = cache:get(token_key)

    local f = io.open(ASAPKeyPath, "r");

    local ASAPKey = f:read("*all");
    f:close();

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
        cache:set(exp_key,exp)
        cache:set(token_key,token)
        return token
    else
        return ''
    end
end

-- Starts the query for password to the service
-- adds a timeout so we do not force jicofo to wait a lot
-- in case of no response or slow response we let participants through
-- without requiring a password
local function queryForPassword(room)
    local room_address = room_jid_match_rewrite_from_internal(room.jid);
    local pURL = conferenceInfoURL .."?conferenceFullName="..room_address;

    module:log("info","Querying for password to %s", pURL);

    local function clearJicofoPending(room)
        module:log("debug", "Clearing pending jicofo response if exists")

        -- send the stanza if it exists
        if pendingPresences[room.jid] ~= nil then
            module:log("debug", "Send initial presence stanza:%s", pendingPresences[room.jid])

            module:send(pendingPresences[room.jid]);

            pendingPresences[room.jid] = nil
        end
    end

    local function timeoutPasswordQuery()
        local room = room

        -- clear waiting queries on timeout
        pendingPasswordQueries[room.jid] = nil

        if pendingPresences[room.jid] ~= nil then
            module:log("warn", "Timeout triggered for password query after %s seconds for room %s", passwordTimeout, room.jid);
        end

        -- check for paused jicofo iq, send if found
        clearJicofoPending(room)
    end

    local function cb(content_, code_, response_, request_)
        local room = room
        module:log("debug","Local room var is %s",room)
        -- clear waiting queries on response
        pendingPasswordQueries[room.jid] = nil

        if pendingPresences[room.jid] ~= nil then

            -- create lobby and set moderator
            if code_ == 200 then
                local conference_res = json.decode(content_);
                module:log("debug","Receive conference response from vmms %s",inspect(conference_res))
                room._data.moderator_id = conference_res.moderatorId;
                room._data.starts_with_lobby = conference_res.lobbyEnabled or false;
                room._data.max_occupants = conference_res.maxOccupants;
                if room._data.starts_with_lobby then
                    room._data.lobby_type = conference_res.lobbyType or 'WAIT_FOR_APPROVAL'
                    module:log("debug", "Will create %s lobby for room jid = %s", room._data.lobby_type, room.jid);
                    module:fire_event("create-lobby-room", { room = room; });
                end
            else
                module:log("warn", "External call failed, we do not set lobby and everybody authenticated is moderator")
                room._data.moderator_id = nil;
                room._data.starts_with_lobby = false;
                -- propagate the error to lib-jitsi-meet if is a JaaS meeting
                if is_vpaas(room.jid) then
                    local err = json.decode(content_)
                    module:log("debug", "Propagate error %s", inspect(err))
                    local status = err.status
                    local messageKey = err.messageKey
                    if status and status == 400 and messageKey and messageKey == 'settings.provisioning.exception' then
                        room._data.jaas_err = err.message;
                    end
                end
            end

            -- from this point we should parse the response and grab the password
            -- then we just run room:set_password()
            local logLevel = 'error';
            if code_ == 200 then
                logLevel = 'debug';
                local r = json.decode(content_)
                if r['passcodeProtected'] then
                    if r['passcode'] and r['passcode'] ~= "" then
                        module:log("info", "Found passcode in response, setting for room %s", room)
                        room:set_password(r['passcode'])
                    end
                end
            elseif code_ == 404 then
                logLevel = 'debug'
                module:log("debug", "Conference was not found");
            end
            module:log(logLevel,
                "URL Callback Code Content Response: %s %s %s",
                code_, content_, inspect(response_));
            clearJicofoPending(room)
        else
            module:log("error","Password http request finished with no pending presences for room:%s", room.jid);
        end
    end

    local headers = http_headers or {}
    headers['Authorization'] = generateToken()

    module:log("debug","Sending headers %s",inspect(headers));

    -- start timer to watch and timeout request
    timer.add_task(passwordTimeout, timeoutPasswordQuery)

    pendingPasswordQueries[room.jid] = true;
    local request = http.request(pURL, {
        headers = headers,
        method = "GET",
    }, cb);
end

-- query for password for non health check room requests
function check_set_room_password(room)
    if is_healthcheck_room(room.jid) then
        return
    end

    module:log("debug","%s room create started, checking for preset password, lobby and moderator", room);
    -- first check blacklist of room name
    -- fetch password from external service, set when ready
    queryForPassword(room)
end

-- Finds is the presence in the event for creating the room and addressed
-- to jicofo when entering the conference muc component
function filterJicofoPresence(event)
    local stanza = event.stanza;
    local x = stanza:get_child('x', 'http://jabber.org/protocol/muc#user');

    -- skip non join presences or health check presences
    if x == nil or is_healthcheck_room(stanza.attr.from) then
        return nil;
    end

    -- let's check is this for jicofo in the conference muc component
    -- if there is a password query pending we want to filter all presences
    -- after the initial on (status code 201) there can be several others (status code 110)
    -- but as jicofo is an admin and there will be no actual changes in the affiliation and role
    -- we can just skip those (that's we are skiping them and not storing)
    if string.find(stanza.attr.from, muc_domain..'/focus') then
        local roomJid = stanza.attr.from:sub(1,-(string.len('/focus') + 1));

        if pendingPasswordQueries[roomJid] ~= nil then
            module:log("debug","Found room stanza from jicofo %s", stanza);
            if not pendingPresences[roomJid] then
                pendingPresences[roomJid] = stanza;
            end
            return true;
        end
    end

end

-- executed on every host added internally in prosody, including components
function process_host(host)
    if host == muc_domain then -- the conference muc component
        module:log("info","Hook to room pre-create on %s", host);

        module:context(host):hook("muc-room-pre-create", function(event)
            check_set_room_password(event.room);
        end);
    end

end

if prosody.hosts[muc_domain] == nil then
    module:log("info","No muc component found, will listen for it: %s", muc_domain)

    -- when a host or component is added
    prosody.events.add_handler("host-activated", process_host);
else
    process_host(muc_domain);
end

-- module API called on virtual host added, passing the host module
function module.add_host(host_module)
    if host_module.host == muc_domain_base then -- the main virtual host
        module:log("info","Initialize token_util using %s", host_module.host)

        token_util = module:require "token/util".new(host_module);

        if asapKeyServer then
            -- init token util with our asap keyserver
            token_util:set_asap_key_server(asapKeyServer)
        end

        module:log("info","Adding http handler for /room-password on %s", host_module.host);
        host_module:depends("http");
        host_module:provides("http", {
            default_path = "/";
            route = {
                ["GET room-password"] = function (event) return async_handler_wrapper(event,handle_get_room_password) end;
            };
        });

    elseif host_module.host == auth_domain then
        module:log("info","Hook to presences before sending them to jicofo for %s", host_module.host)

        host_module:hook("presence/full", filterJicofoPresence, 1200);
    end
end
