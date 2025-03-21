local filters = require 'util.filters';
local jid_bare = require "util.jid".bare;
local jid_host = require "util.jid".host;
local inspect = require('inspect');
local util = module:require "util.internal";
local oss_util = module:require "util";
local oss_is_admin = oss_util.is_admin;
local is_healthcheck_room = oss_util.is_healthcheck_room;
local presence_check_status = oss_util.presence_check_status;
local is_vpaas = oss_util.is_vpaas;
local MUC_NS = 'http://jabber.org/protocol/muc';

local lobby_muc_component_config = 'lobby.' .. module:get_option_string("muc_mapper_domain_base");
if lobby_muc_component_config == nil then
    module:log('error', 'lobby not enabled missing lobby_muc config');
    return ;
end

local LOBBY_TYPES = { WAIT_FOR_APPROVAL = 'WAIT_FOR_APPROVAL', WAIT_FOR_MODERATOR = 'WAIT_FOR_MODERATOR', }
local lobby_host;
local lobby_muc_service;

-- List of the bare_jids of all occupants that are currently joining (went through pre-join) and will be promoted
-- as moderators. As pre-join (where added) and joined event (where removed) happen one after another this list should
-- have length of 1, because of the single-threaded prosody.
local joining_moderator_participants = {};

local DEBUG = false;

-- Set affiliation as owner and role
-- as moderator for a participant
local function make_occupant_moderator(event, single_moderator, user_id)
    local occupant_jid = event.stanza.attr.from;
    local room = event.room;
    local affiliation, role = "owner", "moderator";

    if single_moderator then
        module:log("info", "Single moderator jid: %s user_id: %s for room: %s ", occupant_jid, user_id, room.jid)
    end
    if DEBUG then
        module:log("debug",
            "Set affiliation: %s and role: %s for participant jid = %s from room jid = %s  ",
            affiliation, role, occupant_jid, room.jid);
    end
    room:set_affiliation(true, jid_bare(occupant_jid), affiliation)
    event.occupant.role = role;
    event.room:save_occupant(event.occupant);
end

-- Check whether an occupant will be promoted to moderator
-- This is called on pre-join and if it is to be promoted to moderator later
-- we just mark it by adding the bare_jid into joining_moderator_participants
-- @param event - the muc event.
local function check_for_moderator_rights(event)
    local room_jid = event.room.jid;

    if is_healthcheck_room(room_jid) then
        return;
    end

    local occupant = event.occupant;

    if DEBUG then module:log("debug", "Occupant with jid %s pre join the room %s", occupant.bare_jid, room_jid); end
    -- get non guest occupant info
    local session = event.origin;
    local identity;
    if session ~= nil then
        identity = type(session.jitsi_meet_context_user) == "table"
                and util.shallow_copy(session.jitsi_meet_context_user) or nil
        if identity ~= nil then
            identity.group = session.jitsi_meet_context_group;
        end
    end
    if identity == nil then
        if DEBUG then module:log("debug",
            "Not set affiliation and role for anonymous user with jid = %s", occupant.bare_jid); end
        return ;
    end
    if DEBUG then module:log("debug", "Occupant %s has identity = %s", occupant.bare_jid, inspect(identity)); end
    if is_vpaas(event.room) then
        identity.is_vpaas = true;

        -- for VPaaS moderation is enabled per user using the moderator claim from jwt
        local is_vpaas_moderator = identity.moderator;
        if is_vpaas_moderator == "true" or is_vpaas_moderator == true then
            if DEBUG then module:log("debug", "User with id %s is moderator for vpaas room", identity.id); end
            joining_moderator_participants[occupant.bare_jid] = identity;
        else
            if DEBUG then module:log("debug", "User with id %s is not moderator for vpaas room", identity.id); end
        end
    elseif event.room._data.moderator_id == nil then
        -- only for non '/' tenants where url tenant is not matching the token tenant
        if session.jitsi_meet_tenant_mismatch and session.jitsi_web_query_prefix ~= '' then
            util.clear_auth(session);
        else
            if DEBUG then module:log("debug", "Room %s is not moderated", room_jid); end
            joining_moderator_participants[occupant.bare_jid] = identity;
        end
    else
        -- Check if the occupant is moderator
        -- using moderator_id attribute set in the muc_password_preset plugin
        if identity.id == event.room._data.moderator_id or identity.group == event.room._data.moderator_id then
            identity.single_moderator = identity.id == event.room._data.moderator_id;
            joining_moderator_participants[occupant.bare_jid] = identity;
        end
    end
end

-- Check if user_id or group of the occupants
-- are equal to the moderator_id and
-- set the affiliation and role accordingly
-- if a room has lobby enabled before the meeting
-- we set the role on pre-join otherwise on joined.
local function handle_occupant_join(event)
    local occupant = event.occupant;
    local promote_to_moderator_identity = joining_moderator_participants[occupant.bare_jid];

    if promote_to_moderator_identity == nil then
        return;
    end

    -- clear it
    joining_moderator_participants[occupant.bare_jid] = nil;

    make_occupant_moderator(event, promote_to_moderator_identity.single_moderator, promote_to_moderator_identity.id);

    if promote_to_moderator_identity.is_vpaas then
        local room = event.room
        -- for VPaaS moderation is enabled per user using the moderator claim from jwt
        local is_vpaas_moderator = promote_to_moderator_identity.moderator;
        if is_vpaas_moderator == "true" or is_vpaas_moderator == true then
            if DEBUG then module:log("debug",
                "User with id %s is moderator for vpaas room", promote_to_moderator_identity.id); end
            local lobby_type = room._data.lobby_type;
            if lobby_type and lobby_type == LOBBY_TYPES.WAIT_FOR_MODERATOR then
                module:log("info", "First moderator joins room with auto closable lobby, destroy lobby")
                room:set_members_only(false);
                lobby_host:fire_event('destroy-lobby-room', {
                    room = room,
                    newjid = room.jid,
                    message = 'First moderator joins room with auto closable lobby',
                });
            end
        end
    end
end

module:hook('muc-disco#info', function(event)
    local room = event.room;
    if (room._data.lobbyroom and room:get_members_only() and room._data.moderator_id) then
        table.insert(event.form, {
            name = 'muc#roominfo_moderator_identity';
            label = 'Room is moderated';
            value = '';
        });
        event.formdata['muc#roominfo_moderator_identity'] = room._data.moderator_id;
    end
end);

module:hook("muc-occupant-pre-join", function(event)
    local room, occupant = event.room, event.occupant;

    if is_healthcheck_room(room.jid) or is_admin(occupant.bare_jid) then
        return;
    end

    local lobby = room._data.starts_with_lobby;

    check_for_moderator_rights(event);

    if lobby then
        if DEBUG then module:log("debug", "Set moderator on occupant-pre-join because meeting starts with lobby"); end
        handle_occupant_join(event);
    end
end,2);

module:hook("muc-occupant-joined", function(event)
    local room, occupant = event.room, event.occupant;

    if is_healthcheck_room(room.jid) or is_admin(occupant.bare_jid) then
        return;
    end

    local lobby = room._data.starts_with_lobby;

    if not lobby then
        if DEBUG then module:log("debug",
            "Set moderator on muc-occupant-joined because meeting starts without lobby enabled"); end
        handle_occupant_join(event);
    end
end,2);

module:hook("muc-occupant-left", function(event)
    local room = event.room;

    if is_healthcheck_room(room.jid) then
        return
    end

    local has_persistent_lobby = room._data.starts_with_lobby;

    if DEBUG then module:log("debug", "Occupant %s left the main room %s", event.occupant.jid, room.jid); end

    -- destroy main room when there are no participants in the lobby or in the main room
    -- and lobby is enabled before the meeting
    if has_persistent_lobby and not room:has_occupant() and room._data.lobbyroom ~= nil then
        local lobby_room_obj = lobby_muc_service.get_room_from_jid(room._data.lobbyroom);
        if lobby_room_obj and not lobby_room_obj:has_occupant() then
            if event.room._data.room_destroyed_triggered == nil then
                -- this will be triggered when there are only non-moderators in the main room and jicofo,
                -- the persistent lobby is enabled and Jicofo leaves.
                if DEBUG then module:log("debug", "Trigger destroy main room"); end
                event.room._data.room_destroyed_triggered = true;
                module:fire_event("muc-room-destroyed", { room = room });
            end
        end
    end
    -- if the persistent lobby is disabled during the meeting
    --  and the last participant leaves the main room
    if has_persistent_lobby and room ~= nil and not room:has_occupant() and room._data.lobbyroom == nil then
        if event.room._data.room_destroyed_triggered == nil then
            module:log("info", "Trigger destroy main room after persistent lobby is disable");
            event.room._data.room_destroyed_triggered = true;
            module:fire_event("muc-room-destroyed", { room = room });
        end
    end

    -- remove in meeting Lobby if there are no
    -- moderators left in the main room except for Jicofo
    -- to let the other participants in the meeting
    if not has_persistent_lobby and room._data.lobbyroom then
        local room_moderators = {}
        for _, occupant in room:each_occupant() do
            if DEBUG then module:log("debug", "Remaining occupant %s has role %s", occupant.jid, occupant.role); end
            if occupant.role == "moderator" then
                table.insert(room_moderators, occupant.jid);
            end
        end

        -- check if jicofo is the only moderator left
        if #room_moderators == 1 then
            if room._data.lobbyroom then
                room:set_members_only(false);
                module:log("info", "Last moderator leaves, destroy lobby")
                lobby_host:fire_event('destroy-lobby-room', {
                    room = room,
                    newjid = nil,
                    message = 'Last moderator left, close lobby room',
                });
            end
        end
    end
end, 1);

-- process a host module directly if loaded or hooks to wait for its load
function process_host_module(name, callback)
    local function process_host(host)
        if host == name then
            callback(module:context(host), host);
        end
    end

    if prosody.hosts[name] == nil then
        module:log('debug', 'No host/component found, will wait for it: %s', name)

        -- when a host or component is added
        prosody.events.add_handler('host-activated', process_host);
    else
        process_host(name);
    end
end

function process_lobby_muc_loaded(lobby_muc, host_module)
    module:log('info', 'Lobby muc loaded');
    lobby_host = module:context(host_module);
    lobby_muc_service = lobby_muc;

    -- make the main room persistent if it has lobby
    -- enabled before the meeting in order to control
    -- the room lifecycle
    host_module:hook("muc-occupant-joined", function(event)
        local lobby_room = event.room
        local main_room = lobby_room.main_room;
        local has_persistent_lobby = main_room._data.starts_with_lobby;
        if DEBUG then module:log("debug", "Occupant %s joined lobby room", event.occupant.jid); end

        if has_persistent_lobby then
            if DEBUG then module:log("debug", "Make room %s persistent", main_room.jid); end
            main_room.destroying = true;
        end
    end)

    -- destroy main room if there are no participants in the main
    -- room and in the lobby. The main room destruction will
    -- trigger lobby destruction in the lobby_rooms plugin
    host_module:hook("muc-occupant-left", function(event)
        if DEBUG then module:log("debug", "Occupant %s left lobby room", event.occupant.jid); end
        local lobby_room = event.room
        local main_room = lobby_room.main_room;
        local has_persistent_lobby = main_room._data.starts_with_lobby;

        if has_persistent_lobby and not lobby_room:has_occupant() and main_room ~= nil and not main_room:has_occupant() then
            if event.room._data.room_destroyed_triggered == nil then
                if DEBUG then module:log("debug", "Trigger destroy main room"); end
                event.room._data.room_destroyed_triggered = true;
                module:fire_event("muc-room-destroyed", { room = main_room });
            end
        end
    end, 0);
end


-- process or waits to process the lobby muc component
process_host_module(lobby_muc_component_config, function(host_module, host)
    -- lobby muc component created
    module:log('info', 'Lobby component loaded %s', host);

    local muc_module = prosody.hosts[host].modules.muc;
    if muc_module then
        process_lobby_muc_loaded(muc_module, host_module);
    else
        module:log('debug', 'Will wait for muc to be available');
        prosody.hosts[host].events.add_handler('module-loaded', function(event)
            if (event.module == 'muc') then
                process_lobby_muc_loaded(prosody.hosts[host].modules.muc, host_module);
            end
        end);
    end
end);

-- Filters self-presences to a jid that exist in joining_participants array
-- We want to filter those presences where we send first `participant` and just after it `moderator`
function filter_stanza(stanza)
    -- when joining_moderator_participants is empty there is nothing to filter
    if next(joining_moderator_participants) == nil or not stanza.attr or not stanza.attr.to or stanza.name ~= "presence" then
        return stanza;
    end

    -- we want to filter presences only on this host for allowners and skip anything like lobby etc.
    local host_from = jid_host(stanza.attr.from);
    if host_from ~= module.host then
        return stanza;
    end

    local bare_to = jid_bare(stanza.attr.to);
    if stanza:get_error() and joining_moderator_participants[bare_to] then
        -- pre-join succeeded but joined did not so we need to clear cache
        joining_moderator_participants[bare_to] = nil;
        return stanza;
    end

    local muc_x = stanza:get_child('x', MUC_NS..'#user');
    if not muc_x then
        return stanza;
    end

    if joining_moderator_participants[bare_to] and presence_check_status(muc_x, '110') then
        -- skip the local presence for participant
        return nil;
    end

    -- skip sending the 'participant' presences to all other people in the room
    for item in muc_x:childtags('item') do
        if joining_moderator_participants[jid_bare(item.attr.jid)] then
            return nil;
        end
    end

    return stanza;
end
function filter_session(session)
    -- domain mapper is filtering on default priority 0, and we need it after that
    filters.add_filter(session, 'stanzas/out', filter_stanza, -1);
end

-- enable filtering presences
filters.add_filter_hook(filter_session);
