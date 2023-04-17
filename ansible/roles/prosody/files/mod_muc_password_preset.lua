module:set_global();

local json = require "util.json";
local async_handler_wrapper = module:require "util".async_handler_wrapper;
local jid = require "util.jid";
local timer = require "util.timer";
local http = require "net.http";
local inspect = require "inspect";

local util = module:require "util";
local room_jid_match_rewrite = util.room_jid_match_rewrite;
local internal_room_jid_match_rewrite = util.internal_room_jid_match_rewrite;
local is_healthcheck_room = util.is_healthcheck_room;
local starts_with = util.starts_with;
local is_vpaas = module:require "util.internal".is_vpaas;

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
    local room_address = internal_room_jid_match_rewrite(room.jid);
    local pURL = conferenceInfoURL .."?conferenceFullName="..room_address;

    module:log("info","Querying for password to %s", pURL);

    local function clearJicofoPending(room_instance)
        module:log("debug", "Unlock room jicofo %s", room_instance.jid)

        module:context(muc_domain):fire_event('jicofo-unlock-room', { room = room_instance; pass_preset_fired = true;});
    end

    local function timeoutPasswordQuery()
        clearJicofoPending(room)
    end

    local function cb(content_, code_, response_, request_)
        module:log("debug","Local room var is %s", room)

        -- create lobby and set moderator
        if code_ == 200 then
            local conference_res = json.decode(content_);
            module:log("debug","Receive conference info response %s",inspect(conference_res))
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
    end

    local headers = http_headers or {}
    headers['Authorization'] = generateToken()

    module:log("debug","Sending headers %s",inspect(headers));

    -- start timer to watch and timeout request
    timer.add_task(passwordTimeout, timeoutPasswordQuery)

    http.request(pURL, {
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

-- executed on every host added internally in prosody, including components
function process_host(host)
    if host == muc_domain then -- the conference muc component
        module:log("info","Hook to room pre-create on %s", host);

        module:context(host):hook("muc-room-pre-create", function(event)
            check_set_room_password(event.room);
        end);
        module:context(host):hook('jicofo-unlock-room', function(e)
            -- we do not block events we fired
            if e.pass_preset_fired then
                return;
            end

            -- we skip it for all rooms (this will not be fired for healthcheck rooms)
            -- as we do password check for all rooms and will fire it there always
            -- in case of success or in case of timeout or error
            return true;
        end, 1000); -- make sure we are the first listener
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
    end
end
