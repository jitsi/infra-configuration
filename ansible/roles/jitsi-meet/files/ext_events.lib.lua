local asap = module:require "asap"

local http = require "net.http"
local inspect = require "inspect"
local jid = require "util.jid"
local json = require "cjson";

local invite_api = module:get_option_string("invite_api")
local cancel_api = module:get_option_string("cancel_api")
local missed_api = module:get_option_string("missed_api")

local state = module:shared("muc_poltergeist/state")

local asap_config = {
    ttl = module:get_option_number("asap_ttl", 3600),
    threshold = module:get_option_number("asap_ttl_threshold", 600),
    key_path = module:get_option_string("asap_key_path", '/etc/prosody/certs/asap.key'),
    key_id = module:get_option_string("asap_key_id", 'jitsi'),
    issuer = module:get_option_string("asap_issuer", 'jitsi'),
    cache_size = module:get_option_number("jwt_pubkey_cache_size", 128)
}

local token_generator = asap(
    asap_config.key_path,
    asap_config.key_id,
    asap_config.issuer,
    asap_config.threshold,
    asap_config.cache_size
)

local function missed(stanza, call_id)
    local req_data = {}
    -- Check for an associated conversation resource. If none exists
    -- then there can be no missed call notification.
    local room, _, _ = jid.split(stanza.attr.from)
    if state[room] and state[room][call_id] then
        req_data["conversationId"] = state[room][call_id]["conversation"]
    end
    if req_data["conversationId"] == nil then
        module:log("info", "Not sending missed call b/c there is no conversation.")
        return
    end

    req_data["fromUser"] = stanza:get_child("identity"):get_child("creator_user"):get_child_text("id")
    req_data["fromSite"] = stanza:get_child("identity"):get_child_text("creator_group")

    local token = assert(
        token_generator:generate("hc-video-events", asap_config.ttl),
        "unable to generate token"
    )

    local headers = {
        ["User-Agent"]    = "Prosody ("..prosody.version.."; "..prosody.platform..")",
        ["Content-Type"]  = "application/json",
        ["Authorization"] = token
    }

    local function cb(content_, code_, response_, request_)
        if request_ == nil then
            module:log("error", "Unable to generate external request for missed call.")
            return
        end
        if code_ ~= 200 then
            module:log(
                "error",
                "non-200 response triggering missed call notification: %s %s %s %s",
                code_,
                content_,
                inspect(response_),
                inspect(request_)
            )
        end
        module:log("info", "Triggered Stride call missed %s", call_id)
    end

    local request = http.request(
        missed_api,
        {
            headers = headers,
            method  = "POST",
            body    = json.encode(req_data)
        },
        cb
    )
    return request
end

local function cancel (stanza, url, reason, call_id)
    if not cancel_api then
        module:log("error", "cancel api is not configured")
        return
    end

    local call_event = {
        ["toUser"]     = stanza:get_child("identity"):get_child("user"):get_child_text("id"),
        --TODO : start using the correct site instead of the work-around
        --["toSite"]     = stanza:get_child("identity"):get_child_text("group")
        ["toSite"]     = stanza:get_child("identity"):get_child_text("creator_group"),
        ["fromUser"]   = stanza:get_child("identity"):get_child("creator_user"):get_child_text("id"),
        ["fromSite"]   = stanza:get_child("identity"):get_child_text("creator_group"),
        ["callID"]     = call_id,
        ["meetingURL"] = url,
        ["reason"] = reason
    }

    local token = assert(
        token_generator:generate("hc-video-events", asap_config.ttl),
        "unable to generate token"
    )

    local headers = {
        ["User-Agent"]    = "Prosody ("..prosody.version.."; "..prosody.platform..")",
        ["Content-Type"]  = "application/json",
        ["Authorization"] = token
    }

    local function cb(content_, code_, response_, request_)
        if request_ == nil then
            module:log("error", "Unable to generate external request for cancel.")
            return
        end
        if code_ ~= 200 then
            module:log(
                "error",
                "non-201 response triggering call cancel: %s %s %s %s",
                code_,
                content_,
                inspect(response_),
                inspect(request_)
            )
            return
        end
        local callID = json.decode(request_.body).callID
        module:log("info", "Triggered Stride call cancel %s", callID)
    end

    local request = http.request(
        cancel_api,
        {
            headers = headers,
            method  = "POST",
            body    = json.encode(call_event)
        },
        cb
    )
    return request
end

local function invite (stanza, url, call_id)
    if not invite_api then
        module:log("error", "invite api is not configured")
        return
    end

    local call_event = {
        ["toUser"]     = stanza:get_child("identity"):get_child("user"):get_child_text("id"),
        --TODO : start using the correct site instead of the work-around
        --["toSite"]     = stanza:get_child("identity"):get_child_text("group")
        ["toSite"]     = stanza:get_child("identity"):get_child_text("creator_group"),
        ["fromUser"]   = stanza:get_child("identity"):get_child("creator_user"):get_child_text("id"),
        ["fromSite"]   = stanza:get_child("identity"):get_child_text("creator_group"),
        ["callID"]     = call_id,
        ["meetingURL"] = url
    }

    -- Add a conversation id to the call event if one is stored in poltergeist state.
    local room, _, _ = jid.split(stanza.attr.from)
    if state[room] and state[room][call_id] then
        call_event["conversation"] = state[room][call_id]["conversation"]
    end

    local token = assert(
        token_generator:generate("hc-video-events", asap_config.ttl),
        "unable to generate token"
    )

    local headers = {
        ["User-Agent"]    = "Prosody ("..prosody.version.."; "..prosody.platform..")",
        ["Content-Type"]  = "application/json",
        ["Authorization"] = token
    }

    local function cb(content_, code_, response_, request_)
        if request_ == nil then
            module:log("error", "Unable to generate external request for invite.")
            return
        end
        if code_ ~= 200 then
            module:log(
                "error",
                "non-201 response triggering call invite: %s %s %s %s",
                code_,
                content_,
                inspect(response_),
                inspect(request_)
            )
            return
        end
        local callID = json.decode(request_.body).callID
        module:log("info", "Triggered Stride call invite %s", callID)
    end

    local request = http.request(
        invite_api,
        {
            headers = headers,
            method  = "POST",
            body    = json.encode(call_event)
        },
        cb
    )
    return request
end

local function speaker_stats (room, roomSpeakerStats)
    module:log("debug", "Will send speaker stats for %s: %s", room.jid, inspect(roomSpeakerStats));
    module:fire_event("send-speaker-stats", {room = room; roomSpeakerStats = roomSpeakerStats;});
end

local ext_events = {
    invite = invite,
    cancel = cancel,
    missed = missed,
    speaker_stats = speaker_stats
}

return ext_events
