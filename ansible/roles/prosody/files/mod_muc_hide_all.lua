-- This module makes all MUCs in Prosody unavialable on disco#items query

module:hook("muc-room-pre-create", function(event)
    event.room:set_hidden(true);
end, -1);