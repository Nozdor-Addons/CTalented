local ADDON_NAME = "CTalented"

local PREFIX_INFO  = "|cff00ff96[CT]|r "
local PREFIX_ERROR = "|cffff4040[CT]|r "

local function CT_PrintInfo(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX_INFO .. tostring(msg or ""))
    end
end

local function CT_PrintError(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX_ERROR .. tostring(msg or ""))
    end
end

CustomTalentedDB = CustomTalentedDB or {
    templates = {},
}