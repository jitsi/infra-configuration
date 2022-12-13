-- XEP-0215 implementation for time-limited turn credentials
-- Copyright (C) 2012-2013 Philipp Hancke
-- This file is MIT/X11 licensed.

local st = require "util.stanza";
local hmac_sha1 = require "util.hashes".hmac_sha1;
local base64 = require "util.encodings".base64;
local async_handler_wrapper = module:require "util".async_handler_wrapper;
local json = require "util.json";
local array = require"util.array";

local tostring = tostring;
local neturl = require "net.url";
local parse = neturl.parseQuery;

local os_time = os.time;
local secret = module:get_option_string("turncredentials_secret");
local host = module:get_option_string("turncredentials_host"); -- use ip addresses here to avoid further dns lookup latency
local hosts = module:get_option("turncredentials") or {};
local port = module:get_option_string("turncredentials_port", "3478");
local ttl = module:get_option_number("turncredentials_ttl", 86400);
if not (secret and (host or next(hosts) ~= nil)) then
    module:log("error", "turncredentials not configured");
    return;
end

function generate_turn_user()
    local now = os_time() + ttl;
    local userpart = tostring(now);
    local nonce = base64.encode(hmac_sha1(secret, tostring(userpart), false));
    return userpart,nonce;
end

function generate_turn_hosts()
    local credentials_hosts = array();

    userpart,nonce = generate_turn_user();

    if host then
        credentials_hosts:push({ type = "stun", host = host, port = port });
        credentials_hosts:push({ type = "turn", host = host, port = port, transport = "tcp", username = userpart, password = nonce, ttl = ttl});
        credentials_hosts:push({ type = "turn", host = host, port = port, transport = "udp", username = userpart, password = nonce, ttl = ttl});
    else
        for idx, item in pairs(hosts) do
            if item.type == "stun" or item.type == "stuns" then
                credentials_hosts:push({ type = item.type, host = item.host, port = item.port or "3478"});
            elseif item.type == "turn" or item.type == "turns" then
                credentials_hosts:push({
                    type = item.type,
                    host = item.host,
                    port = item.port,
                    transport = item.transport,
                    username = userpart,
                    password = nonce,
                    ttl = ttl});
            end
        end
    end
    return credentials_hosts
end

--- Handles request for retrieving the room participants details
-- @param event the http event, holds the request query
-- @return GET response, containing a json with participants details
function handle_get_turn_credentials (event)

    local credentials_array = generate_turn_hosts()

    local GET_response = {
        headers = {
            content_type = "application/json";
        };
        body = json.encode(credentials_array);
    };
    return GET_response;
end;

function module.load()
    module:depends("http");
    module:provides("http", {
        default_path = "/";
        route = {
            ["GET turn-credentials"] = function (event) return async_handler_wrapper(event,handle_get_turn_credentials) end;
        };
    });
end
