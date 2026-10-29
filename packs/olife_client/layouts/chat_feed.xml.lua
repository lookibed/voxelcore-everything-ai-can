-- Olife chat feed glue (layouts/chat_feed.xml)
local CH = require "olife_client:chat"
function on_open() CH.feed_opened(document) end
