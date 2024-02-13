---
--- This module is a Prosody module handling video/desktop sharing detection in MUC.
--- It does this by hooking into the pre-iq/full event and checking for the media type in the IQ stanzas - session-accept and source-add.
--- If the media type is video or desktop, it sets the room's had_video or had_desktop flag to true.
---

local jid = require "util.jid";
local get_room_from_jid = module:require "util".get_room_from_jid;

function handle_media_event(event)
    local stanza = event.stanza;
    if stanza.name == "iq" then
        local room_jid = jid.bare(stanza.attr.to);
        local room = get_room_from_jid(room_jid);

        if room == nil then
            return
        end

        if room.had_video then
            return
        end

        local mediaType = "audio";

        -- https://xmpp.org/extensions/xep-0339.html
        local jingle_source_add = stanza:get_child_with_attr("jingle", "urn:xmpp:jingle:1", "action", "source-add");
        if jingle_source_add then
            mediaType = jingle_source_add:find("content/{urn:xmpp:jingle:apps:rtp:1}description/{urn:xmpp:jingle:apps:rtp:ssma:0}source@videoType");
        else
            -- https://xmpp.org/extensions/xep-0166.html#def-action-session-accept
            local jingle_session_accept = stanza:get_child_with_attr("jingle", "urn:xmpp:jingle:1", "action", "session-accept");
            if jingle_session_accept then
                local content;

                for childnode in jingle_session_accept:children() do
                    if childnode then
                        if childnode.name == "content" and childnode.attr.name == "video" then
                            content = childnode;
                        end
                    end
                end

                if content then
                    mediaType = content:find("{urn:xmpp:jingle:apps:rtp:1}description@media")
                    if mediaType == "video" then
                        mediaType = content:find("{urn:xmpp:jingle:apps:rtp:1}description/{urn:xmpp:jingle:apps:rtp:ssma:0}source@videoType");
                    end;
                end
            end
        end

        if room.had_video == nil and (mediaType == "camera" or mediaType == "video") then
            room.had_video = true;
        end

        if room.had_desktop == nil and mediaType == "desktop" then
            room.had_video = true;
            room.had_desktop = true;
        end
    end
end

module:hook("pre-iq/full", handle_media_event, 0);