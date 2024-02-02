local http = require "net.http";
local json = require "cjson";
local inspect = require('inspect');

local util = module:require "util.internal";
local oss_util = module:require "util";
local is_healthcheck_room = oss_util.is_healthcheck_room;
local is_vpaas = oss_util.is_vpaas;
local urlencode = require "util.http".urlencode;

local ASAPAudience
= module:get_option_string("asap_audience", 'jitsi');

local http_headers = {
    ["User-Agent"] = "Prosody (" .. prosody.version .. "; " .. prosody.platform .. ")",
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json"
};

local jaas_actuator_base_url
= module:get_option_string("muc_prosody_jaas_actuator_url", "https://api-vo-pilot.jitsi.net/jaas-actuator");

-- Module that gets the disabled features based on room customer id
-- and add it to session for imposing further restrictions
module:log("info", "Loading mod_muc_permissions_vpaas!");

local DEBUG = false;

-- Hook to assign disabled features for new rooms
module:hook("muc-room-pre-create", function(event)
    local room = event.room;
    if is_healthcheck_room(room.jid) or not is_vpaas(room) then
        return;
    end

    local meeting_fqn, customer_id = util.get_fqn_and_customer_id(room);

    local function cb(content_, code_, _, _)
        local room = room
        if code_ == 200 then
            local jaas_actuator_res = json.decode(content_);
            if DEBUG then module:log("debug", "Receive jaas actuator response %s", inspect(jaas_actuator_res)); end
            room._data.disabled_features = jaas_actuator_res.disabledFeatures;
            if room._data.disabled_features
                and type(room._data.disabled_features) == "table"
                and next(room._data.disabled_features) ~= nil then
                module:log("info", "disabled features: %s for customer_id: %s", inspect(room._data.disabled_features), customer_id);
            end

            if jaas_actuator_res.status ~= nil and (jaas_actuator_res.status == "BLOCKED" or jaas_actuator_res.status == "DELETED") then
                room._data.disabled_access = true;
            else
                room._data.disabled_access = false;
            end
        else
            module:log("warn", "External call to jaas-actuator failed, we do not set any disabled features")
            room._data.disabled_access = false;
            room._data.disabled_features = {};
        end
    end

    local jaas_actuator_customer_details_url = jaas_actuator_base_url .. "/v1/customers/" .. urlencode(customer_id);

    local headers = http_headers or {}
    headers['Authorization'] = util.generateToken(ASAPAudience)
    if DEBUG then
        module:log("debug",
            "Requesting jaas actuator customer details: fqn %s customer id %s auth %s",
            meeting_fqn, customer_id, headers['Authorization']);
    end

    local _ = http.request(jaas_actuator_customer_details_url, {
        headers = headers,
        method = "GET"
    }, cb);
end);

module:hook("muc-occupant-pre-join", function(event)
    local room, origin, stanza = event.room, event.origin, event.stanza;
    local occupant_jid = stanza.attr.from;

    if is_healthcheck_room(room.jid) or util.is_blacklisted(occupant_jid) then
        return;
    end

    if room ~= nil and room._data.disabled_features ~= nil then
        for _, disabled_feature in ipairs(room._data.disabled_features) do
            if DEBUG then module:log("debug", "Removing disabled feature %s from auth context", disabled_feature); end
            if origin.jitsi_meet_context_features then
                origin.jitsi_meet_context_features[disabled_feature] = "false";
            end
        end
    end
end);
