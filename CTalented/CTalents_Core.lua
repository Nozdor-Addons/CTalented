local ADDON_NAME = ...
local CT = {}
_G.CustomTalents = CT

local PREFIX_INFO  = "|cff00ff96[CT]|r "
local PREFIX_ERROR = "|cffff5555[CT]|r "

local function CT_PrintInfo(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX_INFO .. msg, 0, 1, 0.6)
end

local function CT_PrintError(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX_ERROR .. msg, 1, 0.3, 0.3)
end

local CLASS_ORDER = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
    "DEATHKNIGHT", "SHAMAN", "MAGE", "WARLOCK", "DRUID",
}

local function CT_LocalizedClassName(classKey)
    if LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classKey] then
        return LOCALIZED_CLASS_NAMES_MALE[classKey]
    elseif LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[classKey] then
        return LOCALIZED_CLASS_NAMES_FEMALE[classKey]
    end
    return classKey
end

CustomTalentsDB = CustomTalentsDB or {}
CustomTalentsData      = CustomTalentsData      or {}
CustomTalentsSpellData = CustomTalentsSpellData or {}

CustomTalentsDB.options = CustomTalentsDB.options or {}
local CT_Options = CustomTalentsDB.options

CT_SessionDisabled = false

--[[ ПОПАП

StaticPopupDialogs["CTALENTS_WARNING"] = {
    text = "СTalents установлен, аддон имеет функцию сбрасывать таланты, в следствии чего списывается золото, будьте осторожны",
    button1 = "Хорошо",
    button2 = "Нет",
    OnAccept = function()
    end,
    OnCancel = function()

        CT_SessionDisabled = true
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = false,
    preferredIndex = 3,
}

-- Вспомогательные функции (класс/спек и бд)]]

local function CT_GetClassKey()
    local _, class = UnitClass("player")
    return class or "UNKNOWN"
end

local function CT_GetSpecIndex0()
    if GetActiveTalentGroup then
        local g = GetActiveTalentGroup()
        if g then return g - 1 end
    end
    return 0
end

local function CT_GetTemplatesTable(forClass, forSpec)
    local classKey  = forClass  or CT_GetClassKey()
    local specIndex = (forSpec ~= nil) and forSpec or CT_GetSpecIndex0()

    CustomTalentsDB[classKey] = CustomTalentsDB[classKey] or {}
    CustomTalentsDB[classKey][specIndex] = CustomTalentsDB[classKey][specIndex] or {}

    return CustomTalentsDB[classKey][specIndex]
end

local function CT_GetTalentDataForPlayer()
    local classKey  = CT.viewClassKey or CT_GetClassKey()
    local specIndex = CT.viewSpecIndex
    if specIndex == nil then
        specIndex = CT_GetSpecIndex0()
    end

    local classDB = CustomTalentsData[classKey] or CustomTalentsData["DEFAULT"]
    if not classDB then return nil end

    return classDB[specIndex] or classDB[0]
end

local function CT_HandleRanks(...)
    local result = {}
    local first = ...
    if not first then
        return { inactive = true }
    end

    local pos, row, column, req = 1
    local c = string.byte(first, pos)

    if c == 42 then
        row, column = nil, -1
        pos = pos + 1
        c = string.byte(first, pos)
    elseif c > 32 and c <= 40 then
        column = c - 32
        if column > 4 then
            row = true
            column = column - 4
        end
        pos = pos + 1
        c = string.byte(first, pos)
    end

    -- пререквизит
    if c >= 65 and c <= 90 then
        req = c - 64
        pos = pos + 1
    elseif c >= 97 and c <= 122 then
        req = 96 - c
        pos = pos + 1
    end

    result[1] = tonumber(first:sub(pos))
    for i = 2, select("#", ...) do
        result[i] = tonumber((select(i, ...)))
    end

    local entry = {
        ranks  = result,
        row    = row,
        column = column,
        req    = req,
    }

    if not result[1] then
        entry.req      = nil
        entry.ranks    = nil
        entry.inactive = true
    end

    return entry
end

local function CT_NextTalentPos(row, column)
    column = column + 1
    if column >= 5 then
        return row + 1, 1
    else
        return row, column
    end
end

local function CT_HandleTalents(...)
    local result = {}
    for talent = 1, select("#", ...) do
        result[talent] = CT_HandleRanks(strsplit(";", (select(talent, ...))))
    end

    local row, column = 1, 1
    for index, talent in ipairs(result) do
        local drow, dcolumn = talent.row, talent.column

        if dcolumn == -1 then
            -- талант-заглушка
            talent.row, talent.column = result[index - 1].row, result[index - 1].column
            talent.inactive = true
        elseif dcolumn then
            if drow then
                row = row + 1
                column = dcolumn
            else
                column = column + dcolumn
            end
            talent.row, talent.column = row, column
        else
            talent.row, talent.column = row, column
        end

        if dcolumn ~= -1 or drow then
            row, column = CT_NextTalentPos(row, column)
        end

        if talent.req then
            talent.req = talent.req + index
        end
    end

    return result
end

local function CT_HandleTabs(...)
    local result = {}
    for tab = 1, select("#", ...) do
        result[tab] = CT_HandleTalents(strsplit(",", (select(tab, ...))))
    end
    return result
end

local function CT_UncompressSpellData(classKey)
    if not CustomTalentsSpellData then return nil end

    local data = CustomTalentsSpellData[classKey]
    if not data then return nil end

    if type(data) == "table" then
        return data
    end

    data = CT_HandleTabs(strsplit("|", data))
    CustomTalentsSpellData[classKey] = data
    return data
end

local function CT_FillTalentsFromSpellData(classKey)
    local tabs = CT_UncompressSpellData(classKey)
    if not tabs then return end

    local classDB = CustomTalentsData[classKey]
    if not classDB then return end

    -- Таблица соответствия spellId -> serverId для класса
    CT.serverIdBySpell[classKey] = CT.serverIdBySpell[classKey] or {}
    local serverMap    = CT.serverIdBySpell[classKey]
    local classServer  = CustomTalentsServerIds and CustomTalentsServerIds[classKey]

    for specIndex, spec in pairs(classDB) do
        if spec.trees then
            for tabIndex, tree in ipairs(spec.trees) do
                local tabInfo = tabs[tabIndex]
                if tabInfo then
                    local talents = {}
                    tree.talents = talents

                    -- Таблица serverId по имени таланта для этой ветки (tabIndex)
                    local tabServer = classServer and classServer[tabIndex]

                    for index, talent in ipairs(tabInfo) do
                        if not talent.inactive and talent.ranks and talent.ranks[1] then
                            local spellId = talent.ranks[1]
                            local name, _, icon = GetSpellInfo(spellId)

                            -- Поиск serverId по имени таланта
                            local serverId
                            if tabServer and name then
                                serverId = tabServer[name]
                                if serverId then
                                    serverMap[spellId] = serverId
                                end
                            end

                            talents[#talents + 1] = {
                                id       = spellId,
                                name     = name or ("Talent "..index),
                                row      = talent.row    or 1,
                                col      = talent.column or 1,
                                maxRank  = #talent.ranks or 1,
                                icon     = icon or "Interface\\Icons\\INV_Misc_QuestionMark",
                                spellIds = talent.ranks,
                                reqIndex = talent.req,
                                serverId = serverId,
                            }
                        end
                    end
                end
            end
        end
    end
end

-- Инициализация
local function CT_InitTalentsFromSpellData()
    if not CustomTalentsSpellData then return end
    for classKey in pairs(CustomTalentsSpellData) do
        CT_FillTalentsFromSpellData(classKey)
    end
end

local function CT_AutoFillTalentsForClass(classKey)
    local playerClass = CT_GetClassKey()
    if classKey ~= playerClass then return end

    if not GetNumTalentTabs or not GetTalentInfo then return end

    local numTabs = GetNumTalentTabs()
    if not numTabs or numTabs <= 0 then return end

    CustomTalentsData[classKey] = CustomTalentsData[classKey] or {}

    -- Перебор всех спеков
    for specIndex = 0, 8 do
        local spec = CustomTalentsData[classKey][specIndex]
        if spec and spec.trees then
            for tabIndex = 1, numTabs do
                local tree = spec.trees[tabIndex]
                if tree then
                    tree.talents = {}

                    local numTalents = GetNumTalents(tabIndex)
                    for talentIndex = 1, numTalents do
                        local name, icon, tier, column, rank, maxRank = GetTalentInfo(tabIndex, talentIndex)
                        if name then
                            local id = tabIndex * 1000 + talentIndex -- временный ID

                            table.insert(tree.talents, {
                                id         = id,
                                name       = name,
                                row        = tier,
                                col        = column,
                                maxRank    = maxRank or 1,
                                icon       = icon,
                                blizzTab   = tabIndex,
                                blizzIndex = talentIndex,
                            })
                        end
                    end
                end
            end
        end
    end
end

-- Текущее состояние шаблона

CT.currentTemplate = nil
CT.talentButtons   = {}
CT.treeFrames      = {}
CT.totalPoints     = 0
CT.viewClassKey  = nil
CT.viewSpecIndex = nil
CT.arrowTextures  = {}

CT.serverIdBySpell = CT.serverIdBySpell or {}

local function CT_GetViewClassAndSpec()
    local classKey  = CT.viewClassKey  or CT_GetClassKey()
    local specIndex = CT.viewSpecIndex
    if specIndex == nil then
        specIndex = CT_GetSpecIndex0()
    end
    return classKey, specIndex
end

-- Шаблоны в чат

local CT_CHAT_LINK_TYPE   = "CTALENT"
local CT_CHAT_LINK_VERSION = 2

local function CT_GetOrderedTalents(classKey, specIndex)
    classKey  = classKey  or CT_GetClassKey()
    if specIndex == nil then
        specIndex = CT_GetSpecIndex0()
    end

    local classDB = CustomTalentsData[classKey]
    if not classDB then return nil end

    local spec = classDB[specIndex]
    if not spec or not spec.trees then return nil end

    local ordered = {}

    for treeIndex, tree in ipairs(spec.trees) do
        if tree.talents then
            local list = {}
            for _, t in ipairs(tree.talents) do
                table.insert(list, t)
            end
            table.sort(list, function(a, b)
                local ra = a.row or a.tier or 0
                local rb = b.row or b.tier or 0
                if ra ~= rb then
                    return ra < rb
                end
                local ca = a.col or a.column or 0
                local cb = b.col or b.column or 0
                if ca ~= cb then
                    return ca < cb
                end
                local ida = a.id or 0
                local idb = b.id or 0
                return ida < idb
            end)

            for _, t in ipairs(list) do
                table.insert(ordered, t)
            end
        end
    end

    if #ordered == 0 then
        return nil
    end

    return ordered
end

local function CT_MakeHyperlinkFromData(data)
    local info = CT_DecodeTemplateLinkData(data)
    if not info then return nil end

    local classKey  = info.classKey
    local tplName   = info.name or "Без имени"

    -- Текст ссылки: "Шаблон талантов (Название шаблона)"
    local displayName = string.format("Шаблон талантов (%s)", tplName)

    -- На всякий случай убираем '|' из текста
    displayName = displayName:gsub("|", "/")

    -- Скелет ссылки нашего типа
    local baseLink = string.format("|H%s:%s|h[%s]|h", CT_CHAT_LINK_TYPE, data, displayName)

    -- Красим по цвету класса, если можем
    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[classKey] then
        local c = RAID_CLASS_COLORS[classKey]
        local r = math.floor((c.r or 1) * 255 + 0.5)
        local g = math.floor((c.g or 1) * 255 + 0.5)
        local b = math.floor((c.b or 1) * 255 + 0.5)
        return string.format("|cff%02x%02x%02x%s|r", r, g, b, baseLink)
    end

    return baseLink
end

local function CT_ChatFilter(self, event, msg, author, ...)
    local changed = false

    msg = msg:gsub("%{%{CTALENT:([^}]+)%}%}", function(data)
        local link = CT_MakeHyperlinkFromData(data)
        if not link then
            return "{неверный шаблон}"
        end
        changed = true
        return link
    end)

    if changed then
        return false, msg, author, ...
    end

    return false, msg, author, ...
end

local CT_CHAT_EVENTS = {
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
    "CHAT_MSG_EMOTE",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_GUILD",
    "CHAT_MSG_OFFICER",
    "CHAT_MSG_WHISPER",
    "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_CHANNEL",
}

for _, ev in ipairs(CT_CHAT_EVENTS) do
    ChatFrame_AddMessageEventFilter(ev, CT_ChatFilter)
end

local function CT_EncodeTemplateForChat(t)
    if not t or not t.talents then return nil end

    local classKey  = t.classKey  or CT_GetClassKey()
    local specIndex = (t.specIndex ~= nil) and t.specIndex or CT_GetSpecIndex0()

    local ordered = CT_GetOrderedTalents(classKey, specIndex)
    if not ordered then
        CT_PrintError("Не удалось подготовить данные талантов для отправки шаблона.")
        return nil
    end

    local chars = {}
    for i, info in ipairs(ordered) do
        local id   = info.id
        local rank = tonumber(t.talents[id] or 0) or 0
        if rank < 0 then rank = 0 end
        if rank > 15 then rank = 15 end
        chars[i] = string.format("%X", rank)
    end

    local ranks = table.concat(chars)

    local name = t.name or ""
    local nameHex = name:gsub(".", function(c)
        return string.format("%02X", string.byte(c))
    end)

    return string.format("%d:%s:%d:%s:%s",
        CT_CHAT_LINK_VERSION, classKey, specIndex, ranks, nameHex)
end

-- декодер данных шаблона строки

function CT_DecodeTemplateLinkData(data)
    if not data then return end

    local versionStr, rest = data:match("^([^:]+):(.+)$")
    if not versionStr or not rest then return end

    local version = tonumber(versionStr) or 1
    local classKey, specIndex, ranks, name

    if version >= 2 then
        local specStr, ranksStr, nameHex
        classKey, specStr, ranksStr, nameHex = rest:match("^([^:]+):([^:]+):([^:]+):(.+)$")
        if not classKey or not specStr or not ranksStr then
            return
        end
        specIndex = tonumber(specStr) or 0
        ranks     = ranksStr

        if nameHex and nameHex ~= "" then
            name = nameHex:gsub("(%x%x)", function(cc)
                local n = tonumber(cc, 16)
                return n and string.char(n) or ""
            end)
        end
    else
        local specStr, ranksStr
        classKey, specStr, ranksStr = rest:match("^([^:]+):([^:]+):(.+)$")
        if not classKey or not specStr or not ranksStr then
            return
        end
        specIndex = tonumber(specStr) or 0
        ranks     = ranksStr
        name      = nil
    end

    return {
        version   = version,
        classKey  = classKey,
        specIndex = specIndex,
        ranks     = ranks,
        name      = name,
    }
end

local function CT_GetTemplateDisplayName(t)
    if not t then return "Шаблон" end
    local classKey  = t.classKey or CT_GetClassKey()
    local specIndex = (t.specIndex ~= nil) and t.specIndex or CT_GetSpecIndex0()

    local baseName = t.name or "Шаблон"
    local className = CT_LocalizedClassName(classKey)

    return string.format("[%s]", baseName)
end

local function CT_MakeTemplateShareText(t)
    local data = CT_EncodeTemplateForChat(t)
    if not data then return nil end
    return string.format("{{CTALENT:%s}}", data)
end

-- Вставка ссылки в активный чат
local function CT_GetChatEditBox()
    if ChatEdit_GetActiveWindow then
        local eb = ChatEdit_GetActiveWindow()
        if eb then return eb end
    end
    if ChatFrame1EditBox then
        return ChatFrame1EditBox
    end
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox then
        return DEFAULT_CHAT_FRAME.editBox
    end
end

local function CT_InsertTemplateLinkToChat()
    local t = CT.currentTemplate
    if not t or not t.talents then
        CT_PrintError("Нет активного шаблона для отправки.")
        return
    end

    local shareText = CT_MakeTemplateShareText(t)
    if not shareText then return end

    local editBox = CT_GetChatEditBox()
    if not editBox then
        if ChatFrame_OpenChat and DEFAULT_CHAT_FRAME then
            ChatFrame_OpenChat("", DEFAULT_CHAT_FRAME)
            editBox = CT_GetChatEditBox()
        end
    end

    if not editBox then
        CT_PrintError("Не удалось найти окно ввода чата.")
        return
    end

    if ChatEdit_ActivateChat then
        ChatEdit_ActivateChat(editBox)
    end
    editBox:Insert(shareText)
end

-- Видимость кнопки применения и чекбокса

local function CT_UpdateApplyVisibility()
    if not frame or not frame.applyButton or not frame.applyCheck then
        return
    end

    local btn   = frame.applyButton
    local check = frame.applyCheck

    local playerClass = CT_GetClassKey()
    local viewClass   = CT.viewClassKey or playerClass
    local isOwnClass  = (viewClass == playerClass)

    btn:SetShown(isOwnClass)
    check:SetShown(isOwnClass)

    if not isOwnClass then
        btn:Disable()
        btn:SetAlpha(1.0)
        check:SetChecked(false)
        return
    end

    if btn._cooldownActive then
        btn:Disable()
        btn:SetAlpha(0.4)
        return
    end

    btn:SetAlpha(1.0)

    if check:GetChecked() then
        btn:Enable()
    else
        btn:Disable()
    end
end

CT_UpdateApplyVisibility()

local frame
local nameEditBox
local dropdownFrame

local function CT_NewEmptyTemplate(name, forClass, forSpec)
    local classKey  = forClass  or CT_GetClassKey()
    local specIndex = (forSpec ~= nil) and forSpec or CT_GetSpecIndex0()

    local t = {
        name      = name or "Новый шаблон",
        classKey  = classKey,
        specIndex = specIndex,
        talents   = {},
    }

    CT.currentTemplate = t
    CT.viewClassKey    = classKey
    CT.viewSpecIndex   = specIndex

    CT_UpdateApplyVisibility()

    return t
end

local function CT_SaveCurrentTemplate()
    local t = CT.currentTemplate
    if not t or not t.name or t.name == "" then
        CT_PrintError("Нет активного шаблона или не задано имя.")
        return
    end

    local classKey  = t.classKey  or CT_GetClassKey()
    local specIndex = (t.specIndex ~= nil) and t.specIndex or CT_GetSpecIndex0()

    t.classKey  = classKey
    t.specIndex = specIndex

    local templates = CT_GetTemplatesTable(classKey, specIndex)
    templates[t.name] = t

    CT_PrintInfo("Шаблон '" .. t.name .. "' сохранён.")
end

local function CT_LoadTemplateByName(name)
    if not name or name == "" then
        CT_PrintError("Не задано имя шаблона.")
        return
    end

    local templates = CT_GetTemplatesTable()
    local t = templates[name]
    if not t then
        CT_PrintError("Шаблон '" .. name .. "' не найден для текущего класса/спеки.")
        return
    end

    CT.currentTemplate = t
    CT_PrintInfo("Загружен шаблон '" .. name .. "'.")
end

local function CT_DeleteTemplateByName(name)
    if not name or name == "" then
        CT_PrintError("Не задано имя шаблона.")
        return
    end

    local t = CT.currentTemplate
    local classKey  = t and t.classKey  or CT_GetClassKey()
    local specIndex = t and t.specIndex or CT_GetSpecIndex0()

    local templates = CT_GetTemplatesTable(classKey, specIndex)

    if not templates[name] then
        CT_PrintError("Шаблон '" .. name .. "' не найден.")
        return
    end

    templates[name] = nil
    CT_PrintInfo("Шаблон '" .. name .. "' удалён.")
end

function CT_ImportTemplateFromChat(data, text, button, chatFrame)
    if not data or data == "" then return end

    local info = CT_DecodeTemplateLinkData(data)
    if not info then
        CT_PrintError("Некорректная ссылка на шаблон талантов.")
        return
    end

    local classKey  = info.classKey
    local specIndex = info.specIndex or 0
    local ranks     = info.ranks or ""

    local ordered = CT_GetOrderedTalents(classKey, specIndex)
    if not ordered then
        CT_PrintError("Нет данных талантов для класса " .. tostring(classKey) ..
            ", спека " .. tostring(specIndex) .. ".")
        return
    end

    if #ranks < #ordered then
        CT_PrintError("Ссылка на шаблон повреждена (неполные данные).")
        return
    end

    local templateName = info.name

    if (not templateName or templateName == "") and type(text) == "string" then
        local inBrackets = text:match("%[(.-)%]")
        if inBrackets and inBrackets ~= "" then
            local inner = inBrackets:match("^Шаблон талантов%s*%((.*)%)$")
            if inner and inner ~= "" then
                templateName = inner
            else
                templateName = inBrackets
            end
        end
    end

    if not templateName or templateName == "" then
        templateName = "Импорт из чата"
    end

    local t = {
        name      = templateName,
        classKey  = classKey,
        specIndex = specIndex,
        talents   = {},
    }

    for i, talentInfo in ipairs(ordered) do
        local ch   = ranks:sub(i, i)
        local rank = tonumber(ch, 16) or 0
        if rank > 0 then
            t.talents[talentInfo.id] = rank
        end
    end

    CT.currentTemplate = t
    CT.viewClassKey    = classKey
    CT.viewSpecIndex   = specIndex

    CT_SaveCurrentTemplate()

    if not frame then
        CT_CreateFrame()
    end

    CT_BuildTalentGrid()
    CT_UpdateButtonsFromTemplate()
    CT_UpdateApplyVisibility()

    if frame and not frame:IsShown() then
        frame:Show()
    end

    if nameEditBox and nameEditBox.SetText then
        nameEditBox:SetText(t.name or "")
    end

    CT_PrintInfo("Импортирован шаблон талантов: '" .. (t.name or "?") .. "'.")
end

-- Хук на клики по ссылкам в чате
local CT_Orig_SetItemRef = SetItemRef

local function CT_GetChatEditBox()
    if ChatEdit_GetActiveWindow then
        local eb = ChatEdit_GetActiveWindow()
        if eb then return eb end
    end
    if ChatFrame1EditBox then
        return ChatFrame1EditBox
    end
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.editBox then
        return DEFAULT_CHAT_FRAME.editBox
    end
end

SetItemRef = function(link, text, button, chatFrame)
    if type(link) == "string" then
        local linkType, data = link:match("^(.-):(.*)$")
        if linkType == CT_CHAT_LINK_TYPE and data then

            if IsShiftKeyDown() then
                local editBox = CT_GetChatEditBox()
                if not editBox then
                    if ChatFrame_OpenChat and DEFAULT_CHAT_FRAME then
                        ChatFrame_OpenChat("", DEFAULT_CHAT_FRAME)
                        editBox = CT_GetChatEditBox()
                    end
                end
                if editBox then
                    if ChatEdit_ActivateChat then
                        ChatEdit_ActivateChat(editBox)
                    end
                    local marker = string.format("{{CTALENT:%s}}", data)
                    editBox:Insert(marker)
                end
                return
            end
            CT_ImportTemplateFromChat(data, text, button, chatFrame)
            return
        end
    end

    if CT_Orig_SetItemRef then
        return CT_Orig_SetItemRef(link, text, button, chatFrame)
    end
end

-- Применение шаблона через RequestServerAction

local function CT_SendTalentPoints(entries, classKey, talentId, rank)
    rank = tonumber(rank) or 0
    if rank <= 0 then return end

    local serverId = talentId
    if CT.serverIdBySpell
       and CT.serverIdBySpell[classKey]
       and CT.serverIdBySpell[classKey][talentId]
    then
        serverId = CT.serverIdBySpell[classKey][talentId]
    end

    local level = rank - 1 -- 0 = первый ранг, 1 = второй и т.д.
    if level < 0 then level = 0 end

    entries[#entries + 1] = string.format("%d:%d", serverId, level)
end

-- Проверка шаблонов

--[[local function CT_IsTemplateEqualToCurrentTalents()
    local t = CT.currentTemplate
    if not t or not t.talents then return false end

    local playerClass = CT_GetClassKey()
    if t.classKey and t.classKey ~= playerClass then
        return false
    end

    local currentSpec = CT_GetSpecIndex0()
    if t.specIndex ~= nil and t.specIndex ~= currentSpec then
        return false
    end

    if not GetTalentInfo then
        return false
    end

    for talentId, btn in pairs(CT.talentButtons) do
        local info = btn.talentInfo
        if info and info.blizzTab and info.blizzIndex then
            local _, _, _, _, rank = GetTalentInfo(info.blizzTab, info.blizzIndex)
            local templateRank = tonumber(t.talents[talentId] or 0) or 0
            if (tonumber(rank) or 0) ~= templateRank then
                return false
            end
        end
    end

    for talentId, templateRank in pairs(t.talents) do
        templateRank = tonumber(templateRank) or 0
        if templateRank > 0 then
            local btn  = CT.talentButtons[talentId]
            local info = btn and btn.talentInfo
            if not (info and info.blizzTab and info.blizzIndex) then
                return false
            end
        end
    end

    return true
end--]]

function CT_ApplyCurrentTemplate(doReset)
    if doReset == nil then
        doReset = true
    end

    if CT_SessionDisabled then
        CT_PrintError("CTalents отключён на эту сессию.")
        return
    end

    if not RequestServerAction then
        CT_PrintError("RequestServerAction недоступна, применение невозможно.")
        return
    end

    local t = CT.currentTemplate
    if not t or not t.talents then
        CT_PrintError("Нет активного шаблона.")
        return
    end

    if InCombatLockdown and InCombatLockdown() then
        CT_PrintError("Нельзя применять шаблон в бою.")
        return
    end

    -- Если текущие таланты уже полностью совпадают с шаблоном – ничего не делаем
    --if CT_IsTemplateEqualToCurrentTalents() then
    --    CT_PrintInfo("Текущие таланты уже полностью совпадают с выбранным шаблоном, сброс не требуется.")
    --    return
    --end

    -- Сброс талантов
    if doReset then
        RequestServerAction("10")
    end

    local applyClass = t.classKey or CT_GetClassKey()

    -- Собираем таланты и их позицию
    local ordered = {}

    -- t.talents: [talentId] = rank
    for talentId, rank in pairs(t.talents) do
        rank = tonumber(rank) or 0
        if rank > 0 then
            local treeIndex, row, col = 99, 99, 99

            -- Данные из кнопки (актуальное дерево в UI)
            local btn = CT.talentButtons and CT.talentButtons[talentId]
            if btn and btn.talentInfo then
                treeIndex = btn.treeIndex or treeIndex
                local info = btn.talentInfo
                row = info.row or row
                col = info.col or info.column or col
            end

            table.insert(ordered, {
                talentId  = talentId,
                rank      = rank,
                treeIndex = treeIndex,
                row       = row,
                col       = col,
            })
        end
    end

    -- Сортировка веток
    table.sort(ordered, function(a, b)
        if a.treeIndex ~= b.treeIndex then
            return a.treeIndex < b.treeIndex
        elseif a.row ~= b.row then
            return a.row < b.row
        elseif a.col ~= b.col then
            return a.col < b.col
        else
            return a.talentId < b.talentId
        end
    end)

    -- Собор в 1 строку
    local entries = {}

    for _, item in ipairs(ordered) do
        CT_SendTalentPoints(entries, applyClass, item.talentId, item.rank)
    end

    if #entries > 0 then
        local payload = table.concat(entries, ",")
        local msg = "9|" .. payload
        RequestServerAction(msg)
        -- CT_PrintInfo("RequestServerAction: " .. msg) -- отладка
    end

    CT_PrintInfo("Шаблон '" .. (t.name or "?") .. "' применён.")
end

-- Обновление UI

local function CT_EnforceTemplateConstraints()
    local t = CT.currentTemplate
    if not t or not t.talents then return end

    local classKey  = t.classKey or CT_GetClassKey()
    local specIndex = t.specIndex
    if specIndex == nil then
        specIndex = CT_GetSpecIndex0()
    end

    local classDB = CustomTalentsData[classKey]
    if not classDB or not classDB[specIndex] or not classDB[specIndex].trees then
        return
    end

    local trees = classDB[specIndex].trees

    local changed = true
    while changed do
        changed = false

        for treeIndex, tree in ipairs(trees) do
            local treeTalents = tree.talents
            if treeTalents and #treeTalents > 0 then
                -- Считаем очки по рядам ветки
                local rowPoints = {}
                for _, talent in ipairs(treeTalents) do
                    local row = talent.row or 1
                    local r   = t.talents[talent.id] or 0
                    rowPoints[row] = (rowPoints[row] or 0) + r
                end

                -- Считаем суммарные очки до каждого ряда
                local maxRow = 0
                for row in pairs(rowPoints) do
                    if row > maxRow then maxRow = row end
                end

                local spentBeforeRow = {}
                local cum = 0
                for row = 1, maxRow do
                    spentBeforeRow[row] = cum
                    cum = cum + (rowPoints[row] or 0)
                end

                -- Проверяем таланты
                for index, talent in ipairs(treeTalents) do
                    local id      = talent.id
                    local curRank = t.talents[id] or 0
                    if curRank > 0 then
                        local allowed = talent.maxRank or 1
                        local row     = talent.row or 1

                        local required    = (row - 1) * 5
                        local spentBefore = spentBeforeRow[row] or 0
                        if spentBefore < required then
                            allowed = 0
                        end

                        -- Пререквизит
                        local reqIndex = talent.reqIndex or talent.req
                        if reqIndex and reqIndex > 0 then
                            local reqTalent = treeTalents[reqIndex]
                            if reqTalent then
                                local reqId   = reqTalent.id
                                local reqRank = t.talents[reqId] or 0
                                local reqMax  = reqTalent.maxRank
                                    or (reqTalent.spellIds and #reqTalent.spellIds)
                                    or 1

                                -- Требование полной прокачки пререквизита
                                if reqRank < reqMax then
                                    allowed = 0
                                end
                            end
                        end

                        if curRank > allowed then
                            t.talents[id] = allowed
                            changed = true
                        end
                    end
                end
            end
        end
    end
end

local function CT_GetTreeTalentsForCurrentTemplate(treeIndex)
    local t = CT.currentTemplate
    if not t or not t.talents then return nil end

    local classKey  = t.classKey or CT_GetClassKey()
    local specIndex = t.specIndex
    if specIndex == nil then
        specIndex = CT_GetSpecIndex0()
    end

    local classDB = CustomTalentsData[classKey]
    local spec    = classDB and classDB[specIndex]
    local trees   = spec and spec.trees
    local tree    = trees and trees[treeIndex]

    if not tree or not tree.talents then
        return nil
    end

    return tree.talents
end

function CT_UpdateButtonsFromTemplate()
    local t = CT.currentTemplate
    if not t or not t.talents then return end
    CT_EnforceTemplateConstraints()

    local total   = 0
    local perTree = {}      -- количество очков в каждой ветке
    local ranks   = {}      -- кэш рангов по кнопкам

    -- Первый проход: считаем ранги и очки по веткам
    for talentId, btn in pairs(CT.talentButtons) do
        local rank = 0
        if CT.currentTemplate and CT.currentTemplate.talents then
            rank = CT.currentTemplate.talents[talentId] or 0
        end
        ranks[btn] = rank
        total = total + rank

        local ti = btn.treeIndex or 1
        perTree[ti] = (perTree[ti] or 0) + rank
    end

    CT.totalPoints = total
    if frame and frame.pointsText then
        frame.pointsText:SetText("Очки талантов: " .. total .. " / 71")
    end

    -- Второй проход: доступность талантов, цвета и выцветание
    local hasTemplate = CT.currentTemplate and CT.currentTemplate.talents
    local talentsTbl  = hasTemplate and CT.currentTemplate.talents or nil

    for btn, rank in pairs(ranks) do
        local ti        = btn.treeIndex or 1
        local info      = btn.talentInfo or {}
        local row       = info.row or 1
        local maxRank   = info.maxRank or 1

        local spentBefore = 0
        if hasTemplate and talentsTbl then
            local treeTalents = CT_GetTreeTalentsForCurrentTemplate and CT_GetTreeTalentsForCurrentTemplate(ti)
            if treeTalents then
                for _, t in ipairs(treeTalents) do
                    local tRow = t.row or 1
                    if tRow < row then
                        spentBefore = spentBefore + (talentsTbl[t.id] or 0)
                    end
                end
            end
        end

        local required      = (row - 1) * 5
        local tierUnlocked  = not hasTemplate or (spentBefore >= required)
        local hasFreePoints = total < 71

        -- Пререквизит
        local prereqOk = true
        local reqIndex = info.reqIndex or info.req
        if hasTemplate and talentsTbl and reqIndex and reqIndex > 0 then
            local treeTalents = CT_GetTreeTalentsForCurrentTemplate and CT_GetTreeTalentsForCurrentTemplate(ti)
            if treeTalents and treeTalents[reqIndex] then
                local reqTalent = treeTalents[reqIndex]
                local reqId     = reqTalent.id
                local reqRank   = talentsTbl[reqId] or 0
                local reqMax    = reqTalent.maxRank
                                  or (reqTalent.spellIds and #reqTalent.spellIds)
                                  or 1
                if reqRank < reqMax then
                    prereqOk = false
                end
            else
                prereqOk = false
            end
        end

        local canIncrease = hasFreePoints and rank < maxRank and tierUnlocked and prereqOk

        -- Иконка
        if btn.icon then
            if hasTemplate and rank == 0 and not canIncrease then
                btn.icon:SetDesaturated(true)
            else
                btn.icon:SetDesaturated(false)
            end
        end

        btn.rank = rank

        -- Текст отображения ранга
        if btn.rankText then
            if rank == 0 then
                if hasTemplate and canIncrease then
                    btn.rankText:SetText("0")
                    btn.rankText:SetTextColor(0, 1, 0)
                else
                    btn.rankText:SetText("")
                end
            else
                btn.rankText:SetText(rank)
                if rank < maxRank then
                    btn.rankText:SetTextColor(0, 1, 0)
                else
                    btn.rankText:SetTextColor(1, 0.82, 0)
                end
            end
        end
    end

    for idx, treeFrame in pairs(CT.treeFrames) do
        if treeFrame.clearButton then
            local spent = perTree[idx] or 0
            treeFrame.clearButton:SetShown(spent > 0)
        end
    end
end

local function CT_SetCurrentTemplateName(name)
    if not CT.currentTemplate then
        CT_NewEmptyTemplate(name)
    else
        CT.currentTemplate.name = name
    end
end

-- Кнопки талантов

local function CT_GetNextRankDescription(spellId)
    if not spellId or not GameTooltip.SetHyperlink then return nil end

    if not CT.HiddenTooltip then
        CT.HiddenTooltip = CreateFrame("GameTooltip", "CT_HiddenTooltip", UIParent, "GameTooltipTemplate")
        CT.HiddenTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end

    local tip = CT.HiddenTooltip
    tip:ClearLines()
    tip:SetHyperlink("spell:" .. spellId)

    local text = ""
    for i = 2, tip:NumLines() do
        local line = _G["CT_HiddenTooltipTextLeft"..i]
        if line then
            local t = line:GetText()
            if t and t ~= "" then
                if text == "" then
                    text = t
                else
                    text = text .. "\n" .. t
                end
            end
        end
    end

    if text ~= "" then
        return text
    end
end

local function CT_ShowTalentTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

    local info     = self.talentInfo or {}
    local rank     = self.rank or 0
    local maxRank  = info.maxRank or 0
    local spellIds = info.spellIds

    if spellIds and spellIds[1] and GameTooltip.SetHyperlink then
        local useRank   = rank > 0 and rank or 1
        local currentId = spellIds[useRank] or spellIds[#spellIds] or spellIds[1]
        GameTooltip:SetHyperlink("spell:" .. currentId)
    else
        GameTooltip:SetText(info.name or ("Talent " .. tostring(self.talentId)), 1, 1, 1)
    end

    if spellIds and rank > 0 and maxRank and rank < maxRank then
        local nextId = spellIds[rank + 1]
        if nextId then
            local desc = CT_GetNextRankDescription(nextId)
            if desc then
                GameTooltip:AddLine(" ", 1, 1, 1)
                GameTooltip:AddLine("Следующий уровень:", 1, 1, 1)
                GameTooltip:AddLine(desc, 1, 0.82, 0, true)
            end
        end
    end

    if maxRank and maxRank > 0 then
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddLine(string.format("Уровень: %d / %d", rank, maxRank), 1, 1, 1)
    end

    GameTooltip:Show()
end

local function CT_GetTreeTalentsForCurrentTemplate(treeIndex)
    local t = CT.currentTemplate
    if not t or not t.talents then return nil end

    local classKey  = t.classKey or CT_GetClassKey()
    local specIndex = t.specIndex
    if specIndex == nil then
        specIndex = CT_GetSpecIndex0()
    end

    local classDB = CustomTalentsData[classKey]
    local spec    = classDB and classDB[specIndex]
    local trees   = spec and spec.trees
    local tree    = trees and trees[treeIndex]

    if not tree or not tree.talents then
        return nil
    end

    return tree.talents
end

-- Проверка, можно ли уменьшить ранг таланта
local function CT_CanDecreaseTalent(treeIndex, talentId)
    local t = CT.currentTemplate
    if not t or not t.talents then return false end

    local treeTalents = CT_GetTreeTalentsForCurrentTemplate(treeIndex)
    if not treeTalents then
        return true
    end

    local ranks = {}
    for _, talent in ipairs(treeTalents) do
        ranks[talent.id] = t.talents[talent.id] or 0
    end

    local current = ranks[talentId] or 0
    if current <= 0 then
        return false
    end

    ranks[talentId] = current - 1

    local rowTotals = {}
    local maxRow    = 0
    for _, talent in ipairs(treeTalents) do
        local row = talent.row or 1
        local r   = ranks[talent.id] or 0

        if r > 0 then
            rowTotals[row] = (rowTotals[row] or 0) + r
        end

        if row > maxRow then
            maxRow = row
        end
    end

    local spentBeforeRow = {}
    local cum = 0
    for row = 1, maxRow do
        spentBeforeRow[row] = cum
        cum = cum + (rowTotals[row] or 0)
    end

    for index, talent in ipairs(treeTalents) do
        local row  = talent.row or 1
        local rank = ranks[talent.id] or 0

        if rank > 0 then
            local required   = (row - 1) * 5
            local spentAbove = spentBeforeRow[row] or 0

            if spentAbove < required then
                return false
            end

            local reqIndex = talent.reqIndex or talent.req
            if reqIndex and reqIndex > 0 then
                local reqTalent = treeTalents[reqIndex]
                if not reqTalent then
                    return false
                end

                local reqId   = reqTalent.id
                local reqRank = ranks[reqId] or 0
                local reqMax  = reqTalent.maxRank
                                or (reqTalent.spellIds and #reqTalent.spellIds)
                                or 1

                if reqRank < reqMax then
                    return false
                end
            end
        end
    end

    return true
end

local function CT_OnTalentButtonClick(self, button)
    if not CT.currentTemplate then
        CT_NewEmptyTemplate("NewTemplate")
    end

    local talents = CT.currentTemplate.talents
    local id      = self.talentId
    local info    = self.talentInfo or {}
    local oldRank = talents[id] or 0
    local rank    = oldRank
    local total   = CT.totalPoints or 0
    local treeIdx = self.treeIndex or 1

    if button == "LeftButton" then
        local maxRank = info.maxRank or 1
        if rank < maxRank then
            local row      = info.row or 1
            local required = (row - 1) * 5

            local spentBefore = CT_GetTreePointsBeforeRow(treeIdx, row)

            if spentBefore < required then
                return
            end

            if total >= 71 then
                CT_PrintError("Максимум очков талантов: 71.")
                return
            end

            local reqIndex = info.reqIndex or info.req
            if reqIndex and reqIndex > 0 then
                local treeTalents = CT_GetTreeTalentsForCurrentTemplate(treeIdx)
                if treeTalents and treeTalents[reqIndex] then
                    local reqTalent = treeTalents[reqIndex]
                    local reqId     = reqTalent.id
                    local reqRank   = talents[reqId] or 0
                    local reqMax    = reqTalent.maxRank
                                      or (reqTalent.spellIds and #reqTalent.spellIds)
                                      or 1

                    if reqRank < reqMax then
                        return
                    end
                end
            end

            rank = rank + 1
        end

    elseif button == "RightButton" then
        if rank > 0 then
            if not CT_CanDecreaseTalent(treeIdx, id) then
                return
            end

            rank = rank - 1
        end
    end

    if rank == oldRank then
        return
    end

    talents[id] = rank
    CT_UpdateButtonsFromTemplate()
    if GameTooltip:IsOwned(self) then
        CT_OnTalentButtonEnter(self)
    end
end

function CT_OnTalentButtonEnter(self)
    CT_ShowTalentTooltip(self)
end

function CT_OnTalentButtonLeave(self)
    GameTooltip:Hide()
end

-- Фрейм ветки

function CT_GetTreeSpent(treeIndex)
    local spent = 0

    if CT.currentTemplate and CT.currentTemplate.talents then
        local talents = CT.currentTemplate.talents
        for talentId, btn in pairs(CT.talentButtons) do
            if btn.treeIndex == treeIndex then
                spent = spent + (talents[talentId] or 0)
            end
        end
    end

    return spent
end

function CT_GetTreePointsBeforeRow(treeIndex, row)
    local spent = 0

    if CT.currentTemplate and CT.currentTemplate.talents then
        local talents = CT.currentTemplate.talents
        for talentId, btn in pairs(CT.talentButtons) do
            if btn.treeIndex == treeIndex then
                local info  = btn.talentInfo or {}
                local tRow  = info.row or 1
                if tRow < row then
                    spent = spent + (talents[talentId] or 0)
                end
            end
        end
    end

    return spent
end

local function CT_ClearTree(treeIndex)
    if not CT.currentTemplate or not CT.currentTemplate.talents then
        return
    end

    local talents = CT.currentTemplate.talents

    for talentId, btn in pairs(CT.talentButtons) do
        if btn.treeIndex == treeIndex then
            talents[talentId] = 0
            btn.rank = 0
        end
    end

    CT_UpdateButtonsFromTemplate()
end

local function CT_CreateTreeFrame(parent, treeData, treeIndex)
    local tree = CreateFrame("Frame", nil, parent)
    tree:SetSize(210, 440)

    local startY = -80
    local treeOffsetX = 220
    local baseX = 20 + (treeIndex - 1) * treeOffsetX

    tree:SetPoint("TOPLEFT", parent, "TOPLEFT", baseX, startY)

    -- Фон ветки талантов
    local bg = tree:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()

    local texName = treeData.background or "bg-priest-holy"
    local path
    if string.find(texName, "\\") then
        path = texName
    else
        path = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Textures\\" .. texName
    end

    bg:SetTexture(path)
    bg:SetTexCoord(0, 1, 0, 1)
    tree.bg = bg

    -- Рамка заголовка
    local header = CreateFrame("Frame", nil, tree)
    header:SetSize(180, 39)
    header:SetPoint("TOP", tree, "TOP", 0, -8)
    header:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 12,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    header:SetBackdropColor(0, 0, 0, 0.8)
    tree.header = header

    local icon = header:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("LEFT", header, "LEFT", 4, 0)
    icon:SetTexture(treeData.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    tree.icon = icon

    -- Кнопка очистки ветки
    local clear = CreateFrame("Button", nil, header)
    clear:SetSize(18, 18)
    clear:SetPoint("RIGHT", header, "RIGHT", -4, 0)

    local clearTex = clear:CreateTexture(nil, "ARTWORK")
    clearTex:SetAllPoints()
    -- Стандартная иконка
    clearTex:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    clearTex:SetVertexColor(1, 0, 0)
    clear.texture = clearTex

    clear:SetScript("OnClick", function()
        CT_ClearTree(treeIndex)
    end)
    clear:Hide()

    clear:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Очистить ветку", 1, 1, 1)
        GameTooltip:AddLine("Сбрасывает все очки в этой ветке шаблона.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
        self.texture:SetVertexColor(1, 0.3, 0.3)
    end)
    clear:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        self.texture:SetVertexColor(1, 0, 0)
    end)
    tree.clearButton = clear

    local fs = header:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    fs:SetPoint("RIGHT", clear, "LEFT", -4, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText(treeData.name or ("Tree " .. treeIndex))
    fs:SetTextColor(1, 0.82, 0)
    tree.name = fs

    return tree
end

-- Стрелки пререквизитов

local BRANCH_TEX = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Textures\\branches-normal"
local ARROW_TEX  = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Textures\\arrows-normal"

local function CT_ClearAllArrows()
    if not CT.arrowTextures then return end
    for treeIndex, list in pairs(CT.arrowTextures) do
        if type(list) == "table" then
            for _, tex in ipairs(list) do
                if tex.Hide then
                    tex:Hide()
                    -- tex:SetParent(nil)
                end
            end
        end
        CT.arrowTextures[treeIndex] = nil
    end
end

local function CT_GetArrowList(treeIndex)
    CT.arrowTextures = CT.arrowTextures or {}
    if not CT.arrowTextures[treeIndex] then
        CT.arrowTextures[treeIndex] = {}
    end
    return CT.arrowTextures[treeIndex]
end

local function CT_DrawArrow(treeIndex, fromTalent, toTalent)
    local treeFrame = CT.treeFrames[treeIndex]
    if not treeFrame then return end
    if not fromTalent or not toTalent then return end

    local list = CT_GetArrowList(treeIndex)

    -- Эти значения должны соответствовать CT_BuildTalentGrid
    local slotSize = 30
    local cellW    = 38
    local cellH    = 34
    local xOffset  = 33
    local yOffset  = -60

    local function getCenter(row, col)
        local x = xOffset + (col - 1) * cellW + slotSize * 0.5
        local y = yOffset - (row - 1) * cellH - slotSize * 0.5
        return x, y
    end

    local fx, fy = getCenter(fromTalent.row or 1, fromTalent.col or 1)
    local tx, ty = getCenter(toTalent.row or 1,   toTalent.col or 1)

    -- вертикальные связи (одна колонка)
    if (fromTalent.col == toTalent.col) then
        local dist = ty - fy
        if math.abs(dist) < 20 then
            return
        end

        local isDown = dist < 0
        local height = math.abs(dist) - 18
        if height < 8 then
            height = 8
        end

        local midY = (fy + ty) * 0.5

        local branch = treeFrame:CreateTexture(nil, "BORDER")
        branch:SetTexture(BRANCH_TEX)
        branch:SetWidth(12)
        branch:SetHeight(height)
        branch:SetPoint("CENTER", treeFrame, "TOPLEFT", fx, midY)

        branch:SetTexCoord(0.12890625, 0.12890625 + 0.125, 0.0, 0.96875)
        table.insert(list, branch)

        local arrow = treeFrame:CreateTexture(nil, "OVERLAY")
        arrow:SetTexture(ARROW_TEX)
        arrow:SetWidth(16)
        arrow:SetHeight(16)
        arrow:SetTexCoord(0.0, 0.5, 0.0, 1.0)

        if isDown then
            arrow:SetPoint("CENTER", treeFrame, "TOPLEFT", tx, ty + 10)
        else
            arrow:SetPoint("CENTER", treeFrame, "TOPLEFT", tx, ty - 10)
        end

        table.insert(list, arrow)
    end

end

local function CT_DrawPrereqArrows(treeIndex, talents)
    if not talents or not CT.treeFrames[treeIndex] then return end

    local list = CT_GetArrowList(treeIndex)
    for i = #list, 1, -1 do
        local tex = list[i]
        if tex and tex.Hide then
            tex:Hide()
            -- tex:SetParent(nil)
        end
        list[i] = nil
    end

    for idx, talent in ipairs(talents) do
        local reqIndex = talent.reqIndex or talent.req
        if reqIndex and talents[reqIndex] then
            CT_DrawArrow(treeIndex, talents[reqIndex], talent)
        end
    end
end

-- Сетка талантов

function CT_BuildTalentGrid()
    if not frame then return end

    -- Очистка старых данных
    for _, btn in pairs(CT.talentButtons) do
        btn:Hide()
        btn:SetParent(nil)
    end
    CT.talentButtons = {}

    for _, tf in pairs(CT.treeFrames) do
        tf:Hide()
        tf:SetParent(nil)
    end
    CT.treeFrames = {}

    CT_ClearAllArrows()

    -- Получаем данные для текущего отображаемого класса/спека
    local data = CT_GetTalentDataForPlayer()
    if not data or not data.trees then
        CT_PrintError("Нет данных талантов для этого класса/спеки (заглушка).")
        return
    end

    local slotSize = 30
    local cellW    = 38   -- расстояние между колонками
    local cellH    = 34   -- расстояние между рядами
    local xOffset  = 33   -- отступ слева внутри дерева
    local yOffset  = -60  -- отступ от верха дерева до первой строки (под хедером)

    for treeIndex, treeData in ipairs(data.trees) do
        local treeFrame = CT_CreateTreeFrame(frame, treeData, treeIndex)
        CT.treeFrames[treeIndex] = treeFrame

        -- Автогенерация заглушек, если talents пуст
        local talents = treeData.talents
        if (not talents or #talents == 0) and treeData.gridRows and treeData.gridCols then
            talents = {}
            for row = 1, treeData.gridRows do
                for col = 1, treeData.gridCols do
                    local id = treeIndex * 1000 + (row - 1) * treeData.gridCols + col -- уникальный ID
                    table.insert(talents, {
                        id      = id,
                        name    = string.format("Talent %d", id),
                        row     = row,
                        col     = col,
                        maxRank = 5,
                        icon    = "Interface\\Icons\\INV_Misc_QuestionMark",
                    })
                end
            end
            treeData.talents = talents
        end

        for _, talent in ipairs(talents or {}) do
            local btn = CreateFrame("Button", nil, treeFrame)
            btn:SetSize(slotSize, slotSize)

            local x = xOffset + (talent.col - 1) * cellW
            local y = yOffset - (talent.row - 1) * cellH

            btn:SetPoint("TOPLEFT", treeFrame, "TOPLEFT", x, y)

            -- Фон слота таланта
            local slot = btn:CreateTexture(nil, "BACKGROUND")
            slot:SetAllPoints()
            slot:SetTexture("Interface\\Buttons\\UI-EmptySlot")
            btn.slot = slot

            -- Иконка таланта
            local icon = btn:CreateTexture(nil, "ARTWORK")
            icon:SetTexture(talent.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            icon:SetAllPoints()
            icon:SetDesaturated(true)
            btn.icon = icon

            local rankText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            rankText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
            rankText:SetText("")
            btn.rankText = rankText

            btn.talentId   = talent.id
            btn.talentInfo = talent
            btn.rank       = 0
            btn.treeIndex  = treeIndex
            btn.blizzTab    = talent.blizzTab
            btn.blizzIndex  = talent.blizzIndex

            btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            btn:SetScript("OnClick", CT_OnTalentButtonClick)
            btn:SetScript("OnEnter", CT_OnTalentButtonEnter)
            btn:SetScript("OnLeave", CT_OnTalentButtonLeave)

            CT.talentButtons[talent.id] = btn
        end
        CT_DrawPrereqArrows(treeIndex, talents)
    end

    CT_UpdateButtonsFromTemplate()
end

-- Меню шаблонов

local function CT_ShowTemplateMenu(anchor)
    if not dropdownFrame then
        dropdownFrame = CreateFrame("Frame", "CustomTalentsDropdown", UIParent, "UIDropDownMenuTemplate")
    end

    local menu = {}

    for _, classKey in ipairs(CLASS_ORDER) do
        local className = CT_LocalizedClassName(classKey)

        local displayName = className
        if RAID_CLASS_COLORS and RAID_CLASS_COLORS[classKey] then
            local c = RAID_CLASS_COLORS[classKey]
            displayName = string.format("|cff%02x%02x%02x%s|r",
                c.r * 255, c.g * 255, c.b * 255, className)
        end

        local classEntry = {
            text = displayName,
            hasArrow = true,
            notCheckable = true,
            menuList = {},
        }

        table.insert(classEntry.menuList, {
            text = "Новый шаблон",
            notCheckable = true,
            func = function()
                local specIndex = (classKey == CT_GetClassKey()) and CT_GetSpecIndex0() or 0
                local t = CT_NewEmptyTemplate("Новый шаблон", classKey, specIndex)
                CT.currentTemplate = t
                CT.viewClassKey    = classKey
                CT.viewSpecIndex   = specIndex

                if nameEditBox then
                    nameEditBox:SetText(t.name)
                end

                CT_BuildTalentGrid()
                CT_UpdateButtonsFromTemplate()
                CT_UpdateApplyVisibility()
            end,
        })

        -- Разделитель списка шаблонов
        local hasTemplates = false
        local classDB = CustomTalentsDB[classKey]

        if classDB then
            for specIndex, templates in pairs(classDB) do
                for name, tpl in pairs(templates) do
                    if not hasTemplates then
                        table.insert(classEntry.menuList, {
                            text = "— сохранённые шаблоны —",
                            notCheckable = true,
                            disabled = true,
                        })
                        hasTemplates = true
                    end

                    local specText = (tpl.specIndex or specIndex) + 1
                    local itemText = string.format("%s", name)

                    table.insert(classEntry.menuList, {
                        text = itemText,
                        notCheckable = true,
                        func = function()
                            CT.currentTemplate = tpl
                            CT.viewClassKey    = tpl.classKey or classKey
                            CT.viewSpecIndex   = tpl.specIndex or specIndex

                            if nameEditBox then
                                nameEditBox:SetText(tpl.name or name)
                            end

                            CT_BuildTalentGrid()
                            CT_UpdateButtonsFromTemplate()
                            CT_UpdateApplyVisibility()
                        end,
                    })
                end
            end
        end

        table.insert(menu, classEntry)
    end

    EasyMenu(menu, dropdownFrame, anchor, 0, 0, "MENU")
end

-- Главное окно аддона

local function CT_CreateFrame()
    if frame then return end

    frame = CreateFrame("Frame", "CustomTalentsFrame", UIParent)
    frame:SetSize(690, 560)
    frame:SetPoint("CENTER")

    frame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile     = true,
        tileSize = 16,
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -6)
    title:SetText("CTalents")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local nameLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -30)
    nameLabel:SetText("Имя шаблона:")

    nameEditBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    nameEditBox:SetSize(150, 20)
    nameEditBox:SetPoint("LEFT", nameLabel, "RIGHT", 8, 0)
    nameEditBox:SetAutoFocus(false)
    nameEditBox:SetScript("OnEnterPressed", function(self)
        CT_SetCurrentTemplateName(self:GetText())
        self:ClearFocus()
    end)

    local saveButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    saveButton:SetSize(80, 22)
    saveButton:SetPoint("LEFT", nameEditBox, "RIGHT", 8, 0)
    saveButton:SetText("Сохранить")
    saveButton:SetScript("OnClick", function()
        local n = nameEditBox:GetText()
        if n and n ~= "" then
            CT_SetCurrentTemplateName(n)
        end
        CT_SaveCurrentTemplate()
    end)

    local deleteButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    deleteButton:SetSize(80, 22)
    deleteButton:SetPoint("LEFT", saveButton, "RIGHT", 4, 0)
    deleteButton:SetText("Удалить")
    deleteButton:SetScript("OnClick", function()
        local n = nameEditBox and nameEditBox:GetText() or ""

        if n and n ~= "" then
            CT_DeleteTemplateByName(n)
        end

        local classKey  = CT_GetClassKey()
        local specIndex = CT_GetSpecIndex0()

        CT.currentTemplate = {
            name      = "",
            classKey  = classKey,
            specIndex = specIndex,
            talents   = {},
        }

        CT.viewClassKey  = classKey
        CT.viewSpecIndex = specIndex

        if nameEditBox and nameEditBox.SetText then
            nameEditBox:SetText("")
        end

        CT_UpdateButtonsFromTemplate()
        CT_UpdateApplyVisibility()
    end)

    local applyButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    applyButton:SetSize(230, 22)
    applyButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -53)
    applyButton:SetText("Сбросить таланты и применить")

    local applyCheck = CreateFrame("CheckButton", "CustomTalentsApplyCheck", frame, "ChatConfigCheckButtonTemplate")
    applyCheck:SetSize(24, 24)
    applyCheck:SetPoint("RIGHT", applyButton, "LEFT", -3, -1)
    _G[applyCheck:GetName().."Text"]:SetText("")
    applyCheck:SetChecked(false)

    local APPLY_COOLDOWN_SECONDS = 3

    applyButton:SetScript("OnClick", function(self)
        if self._cooldownActive then
            return
        end

        local playerClass = CT_GetClassKey()
        local viewClass   = CT.viewClassKey or playerClass
        if viewClass ~= playerClass then
            return
        end

        if not applyCheck:GetChecked() then
            CT_PrintInfo("Сперва поставьте галочку.")
            return
        end

        if CT_IsTemplateEqualToCurrentTalents and CT_IsTemplateEqualToCurrentTalents() then
            CT_PrintInfo("Текущие таланты уже полностью совпадают с шаблоном.")
            return
        end

        applyCheck:SetChecked(false)

        if GetTime then
            self._cooldownActive  = true
            self._cooldownEndTime = GetTime() + APPLY_COOLDOWN_SECONDS

            CT_UpdateApplyVisibility()

            self:SetScript("OnUpdate", function(btn, elapsed)
                if not btn._cooldownActive or not GetTime then
                    btn:SetScript("OnUpdate", nil)
                    return
                end

                if GetTime() >= (btn._cooldownEndTime or 0) then
                    btn._cooldownActive  = false
                    btn._cooldownEndTime = nil
                    btn:SetScript("OnUpdate", nil)

                    CT_UpdateApplyVisibility()
                end
            end)
        end

        CT_ApplyCurrentTemplate(true)
    end)

    applyCheck:SetScript("OnClick", function()
        CT_UpdateApplyVisibility()
    end)

    frame.applyButton = applyButton
    frame.applyCheck  = applyCheck

        local applyNoResetButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    applyNoResetButton:SetSize(160, 22)
    applyNoResetButton:SetPoint("TOPRIGHT", applyButton, "BOTTOMRIGHT", 0, 45)
    applyNoResetButton:SetText("Применить без сброса")

    applyNoResetButton:SetScript("OnClick", function()
        local playerClass = CT_GetClassKey()
        local viewClass   = CT.viewClassKey or playerClass
        if viewClass ~= playerClass then
            return
        end

        --if CT_IsTemplateEqualToCurrentTalents and CT_IsTemplateEqualToCurrentTalents() then
        --    CT_PrintInfo("Текущие таланты уже полностью совпадают с шаблоном.")
        --    return
        --end

        CT_ApplyCurrentTemplate(false)
    end)

    frame.applyNoResetButton = applyNoResetButton

    local templateButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    templateButton:SetSize(90, 22)
    templateButton:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -6)
    templateButton:SetText("Шаблоны")
    templateButton:SetScript("OnClick", function(self)
        CT_ShowTemplateMenu(self)
    end)

    local shareButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    shareButton:SetSize(110, 22)
    shareButton:SetPoint("LEFT", templateButton, "RIGHT", 4, 0)
    shareButton:SetText("Ссылка в чат")
    shareButton:SetScript("OnClick", function()
        CT_InsertTemplateLinkToChat()
    end)

    local resetButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    resetButton:SetSize(80, 24)
    resetButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 14)
    resetButton:SetText("Сброс")
    resetButton:SetScript("OnClick", function()
        if CT.currentTemplate and CT.currentTemplate.talents then
            for k in pairs(CT.currentTemplate.talents) do
                CT.currentTemplate.talents[k] = 0
            end
        end
        CT_UpdateButtonsFromTemplate()
    end)

    local pointsText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pointsText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 16)
    pointsText:SetText("Очки талантов: 0 / 71")
    frame.pointsText = pointsText

    CT_UpdateApplyVisibility()
    CT_BuildTalentGrid()
    frame:Hide()
end

-- Кнопка на стандартном TalentFrame

local function CT_ToggleFrame()
    if CT_SessionDisabled then
        CT_PrintError("CTalents отключён до следующего входа в игру (вы выбрали \"Нет\" в предупреждении).")
        return
    end
    if not frame then
        CT_CreateFrame()
    end
    if frame:IsShown() then
        frame:Hide()
    else
        if not CT.currentTemplate then
            CT_NewEmptyTemplate("Новый шаблон")
        end

        CT_BuildTalentGrid()
        CT_UpdateButtonsFromTemplate()
        CT_UpdateApplyVisibility()
        frame:Show()
    end
end

local function CT_CreateTalentFrameButton()
    if not PlayerTalentFrame then return end
    if PlayerTalentFrame.CustomTalentsButton then return end

    local btn = CreateFrame("Button", "CustomTalentsToggleButton", PlayerTalentFrame, "UIPanelButtonTemplate")
    btn:SetSize(80, 22)
    btn:SetText("Шаблоны")
    btn:SetPoint("TOPRIGHT", PlayerTalentFrame, "TOPRIGHT", -40, -35)
    btn:SetScript("OnClick", CT_ToggleFrame)

    PlayerTalentFrame.CustomTalentsButton = btn
end

-- Инициализация аддона

initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "PLAYER_LOGIN" then
        CT.viewClassKey  = CT_GetClassKey()
        CT.viewSpecIndex = CT_GetSpecIndex0()
        -- Инициализируем таланты из локальной CustomTalentsSpellData
        CT_InitTalentsFromSpellData()

        CT_PrintInfo("Загружен. Кнопка 'Шаблоны' на окне талантов.")
        if IsAddOnLoaded("Blizzard_TalentUI") then
            CT_CreateTalentFrameButton()
        end

        if not CT_Options.neverShowWarning then
            StaticPopup_Show("CTALENTS_WARNING")
        end

    elseif event == "ADDON_LOADED" and arg1 == "Blizzard_TalentUI" then
        CT_CreateTalentFrameButton()
    end
end)
