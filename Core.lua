-- Tally: core (events, saved data, helpers, slash commands)
local ADDON, ns = ...

ns.GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

---------------------------------------------------------------------------
-- Event bus. RegisterEvent errors on events a client doesn't have, so it's
-- wrapped in pcall to keep one missing event from breaking the addon.
---------------------------------------------------------------------------
-- Errors go to chat once each (WoW hides Lua errors by default), and are kept for /tally debug
local seenErrors = {}
function ns.ReportError(err)
    err = tostring(err)
    ns.lastError = err
    if not seenErrors[err] then
        seenErrors[err] = true
        print("|cffff4040Tally error:|r " .. err .. " |cff888888(please send this to the author)|r")
    end
    geterrorhandler()(err) -- also to WoW's error handler, so BugSack and similar catch it
end

local bus = CreateFrame("Frame")
local handlers = {}
function ns:On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        pcall(bus.RegisterEvent, bus, event)
    end
    table.insert(handlers[event], fn)
end
bus:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(handlers[event]) do
        local ok, err = pcall(fn, ...)
        if not ok then ns.ReportError(err) end
    end
end)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
function ns.Print(msg)
    print("|cff33ff99Tally|r: " .. tostring(msg))
end

function ns.IDFromLink(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

function ns.ItemName(id)
    local name = ns.GetItemInfo(id)
    if name then return name end
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    return "item:" .. id
end

function ns.Commas(n)
    local s = tostring(math.floor(n or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

function ns.Pct(x)
    return math.floor(x * 100 + 0.5)
end

function ns.Money(c)
    if not c then return "|cff888888--|r" end
    local neg = c < 0
    c = math.floor(math.abs(c) + 0.5)
    local g, s, cp = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local str
    if g > 0 then
        str = string.format("%d|cffffd700g|r %02d|cffc7c7cfs|r", g, s)
    elseif s > 0 then
        str = string.format("%d|cffc7c7cfs|r %02d|cffeda55fc|r", s, cp)
    else
        str = string.format("%d|cffeda55fc|r", cp)
    end
    return neg and ("|cffff4040-|r" .. str) or str
end

function ns.Duration(sec)
    sec = math.max(0, math.floor(sec))
    local h, m = math.floor(sec / 3600), math.floor(sec / 60) % 60
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm %02ds", m, sec % 60)
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
local defaults = {
    scale = 1.1,             -- size of the Tally window
    ledgerRange = "session", -- session | today | week | month | all
    ledgerAll = false,       -- ledger shows all characters
}

ns:On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    TallyDB = TallyDB or {}
    local db = TallyDB
    db.settings = db.settings or {}
    for k, v in pairs(defaults) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    db.ledger = db.ledger or {}
    -- clean out data from older versions that had crafting and AH features
    db.realms, db.chars, db.vendorBuy, db.overrides = nil, nil, nil, nil
    for _, k in ipairs({ "ahCut", "priceMode", "onlyProfitable", "hideIncomplete", "duration" }) do db.settings[k] = nil end
    ns.db = db
end)

ns:On("PLAYER_LOGIN", function()
    local realm = GetRealmName()
    local name = UnitName("player")
    ns.realmKey = realm .. "-" .. (UnitFactionGroup("player") or "?")
    ns.charKey = name .. "-" .. realm
    ns.char = { name = name, realmKey = ns.realmKey }
end)

-- What a looted item is worth: what a vendor pays for it
function ns:GetItemValue(id)
    local sell = select(11, ns.GetItemInfo(id))
    if sell == nil then ns.ItemName(id) return nil end -- not cached yet: ask the server
    if sell > 0 then return sell, "vendor" end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local RANGES = { session = "session", today = "today", week = "week", ["7d"] = "week",
    month = "month", ["30d"] = "month", all = "all" }

local function Help()
    ns.Print("/tally - open or close the ledger")
    ns.Print("/tally today | week | month | all | session - open the ledger on a time range")
    ns.Print("/tally reset - start a new session")
    ns.Print("/tally scale 1.1 - make the window bigger or smaller (1 = normal)")
    ns.Print("/tally debug - version and last error, for bug reports")
end

SLASH_TALLY1 = "/tally"
SlashCmdList.TALLY = function(msg)
    if not ns.db or not ns.charKey then return end
    msg = (msg or ""):lower()
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd, rest = cmd or "", rest or ""
    if cmd == "ledger" then cmd, rest = rest:match("^(%S*)%s*(.-)$") end -- old "/tally ledger week" still works

    if cmd == "" then
        ns:ToggleUI()
    elseif RANGES[cmd] then
        ns.db.settings.ledgerRange = RANGES[cmd]
        ns:ShowUI()
    elseif cmd == "reset" then
        ns:NewSession(true)
    elseif cmd == "scale" then
        local v = tonumber(rest)
        if v and v >= 0.7 and v <= 1.6 then
            ns.db.settings.scale = v
            ns:ApplyScale()
            ns.Print(("Scale set to %.2f"):format(v))
        else
            ns.Print("Usage: /tally scale 1.1   (0.7 to 1.6, 1 = normal size)")
        end
    elseif cmd == "debug" then
        local v = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version"))
            or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "?"
        ns.Print("Version " .. v .. "   Last error: " .. (ns.lastError or "none"))
    else
        Help()
    end
end
