
local muc_service = module:depends("muc");
local room_mt = muc_service.room_mt;
local um_is_admin = require "core.usermanager".is_admin;
local jid_split = require "util.jid".split;

module:hook("muc-occupant-joined", function (event)
    local room, occupant = event.room, event.occupant;
    room:set_affiliation(true, occupant.bare_jid, "owner");
end, 2);
module:hook("muc-occupant-left", function (event)
    local room, occupant = event.room, event.occupant;
    room:set_affiliation(true, occupant.bare_jid, nil);
end, 2);

local function is_admin(jid)
    return um_is_admin(jid, module.host);
end

room_mt.get_affiliation = function (self, jid)
    if is_admin(jid) then return "owner"; end
    local node, host, resource = jid_split(jid);
    -- Affiliations are granted, revoked, and maintained based on the user's bare JID.
    local bare = node and node.."@"..host or host;
    local result = self._affiliations[bare];
    if not result and self._affiliations[host] == "outcast" then result = "outcast"; end -- host banned
    return result;
end

for room in muc_service:live_rooms() do
    for _, occupant in room:each_occupant() do
        room:set_affiliation(true, occupant.bare_jid, "owner");
    end
end
