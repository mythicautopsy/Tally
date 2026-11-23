-- Tally: ledger - every copper in or out, sorted by where it came from.
-- Kept per session and as daily totals (forever), so you can look at any time range.
local ADDON, ns = ...

ns.INCOME = { "Looted gold", "Vendor sales", "AH sales", "Quest rewards", "Mail (other)", "Trade received", "Other income" }
ns.EXPENSE = { "Vendor purchases", "Repairs", "AH purchases", "AH deposits", "Training", "Flights", "Postage & COD", "Trade given", "Other spending" }

local LOG_MAX, HISTORY_MAX = 2000, 20
local lastMoney, loginAt
local open = {}        -- money-related windows open right now: key -> order opened
local pending = {}     -- short-lived hints set by hooks, e.g. "next money change is a repair"
local mailQueue = {}   -- category per mail you took money from
local saleQueue = {}   -- item name + count per AH sale mail you took money from
local buyHint          -- the item you just clicked buy on in the AH
ns.BIG = { ["AH purchases"] = "buy", ["AH sales"] = "sale" } -- categories with a 'biggest' box

---------------------------------------------------------------------------
-- Session storage
---------------------------------------------------------------------------
local function DayKey(t) return date("%Y-%m-%d", t or time()) end

local function Day(store, key)
    key = key or DayKey()
    local d = store.days[key]
    if not d then
        d = { income = {}, expense = {}, items = 0, listed = 0, played = 0 }
        store.days[key] = d
    end
    return d
end

local function AddInto(dst, src)
    for c, v in pairs(src.income or {}) do dst.income[c] = (dst.income[c] or 0) + v end
    for c, v in pairs(src.expense or {}) do dst.expense[c] = (dst.expense[c] or 0) + v end
    dst.items = dst.items + (src.items or 0)
    dst.listed = dst.listed + (src.listed or 0)
    dst.played = dst.played + (src.played or 0)
    for k, v in pairs(src.big or {}) do
        dst.big = dst.big or {}
        if not dst.big[k] or v.amount > dst.big[k].amount then dst.big[k] = v end
    end
end

local function Store()
    ns.db.ledger = ns.db.ledger or {}
    ns.db.ledger[ns.charKey] = ns.db.ledger[ns.charKey] or { history = {} }
    local st = ns.db.ledger[ns.charKey]
    st.name, st.realmKey = ns.char and ns.char.name, ns.realmKey
    st.history = st.history or {}
    if not st.days then
        -- first run with daily totals: build them from the sessions saved so far
        st.days = {}
        local old = {}
        for _, h in ipairs(st.history) do old[#old + 1] = h end
        if st.current then old[#old + 1] = st.current end
        for _, h in ipairs(old) do
            AddInto(Day(st, DayKey(h.start)), { income = h.income, expense = h.expense,
                items = h.itemValue, listed = h.listed, played = h.played })
        end
    end
    if not st.log then
        st.log = (st.current and st.current.log) or {}
        if st.current then st.current.log = nil end
    end
    return st
end

local function Blank()
    return { start = time(), played = 0, startMoney = GetMoney(), income = {}, expense = {}, items = {}, itemValue = 0, listed = 0 }
end

function ns:NewSession(announce)
    local store = Store()
    local cur = store.current
    if cur and (next(cur.income) or next(cur.expense) or next(cur.items)) then
        if cur == self.session then cur.played = self:SessionPlayed() end -- still running
        table.insert(store.history, 1, cur)
        while #store.history > HISTORY_MAX do table.remove(store.history) end
    end
    store.current = Blank()
    self.session = store.current
    loginAt = GetTime()
    lastMoney = GetMoney()
    if announce then ns.Print("New ledger session started.") end
    self:RequestRefresh()
end

function ns:SessionPlayed()
    local s = self.session
    if not s then return 0 end
    return (s.played or 0) + (GetTime() - (loginAt or GetTime()))
end

function ns:SessionTotals(s)
    s = s or self.session
    local inc, exp = 0, 0
    for _, v in pairs(s.income) do inc = inc + v end
    for _, v in pairs(s.expense) do exp = exp + v end
    return inc, exp, inc - exp, s.itemValue or 0
end

---------------------------------------------------------------------------
-- Work out what a money change was
---------------------------------------------------------------------------
local function SetPending(cat, sign)
    pending[sign] = { cat = cat, expires = GetTime() + 5 }
end

local function TakePending(sign)
    local p = pending[sign]
    pending[sign] = nil
    if p and p.expires >= GetTime() then return p.cat end
end

-- What each window means for a gain (+) or a loss (-). nil = "not this window".
local RULES = {
    trade    = function(gain) return gain and "Trade received" or "Trade given" end,
    mail     = function(gain)
        if gain then return table.remove(mailQueue, 1) or "Mail (other)" end
        return "Postage & COD"
    end,
    ah       = function(gain) if not gain then return "AH purchases" end end,
    merchant = function(gain)
        if gain then return "Vendor sales" end
        if InRepairMode and InRepairMode() then return "Repairs" end
        return "Vendor purchases"
    end,
    trainer  = function(gain) if not gain then return "Training" end end,
    taxi     = function(gain) if not gain then return "Flights" end end,
    loot     = function(gain) if gain then return "Looted gold" end end,
    quest    = function(gain) if gain then return "Quest rewards" end end,
}

local function Classify(delta)
    local gain = delta > 0
    local hint = TakePending(gain and 1 or -1)
    if hint then return hint end

    -- most recently opened window first
    local keys = {}
    for key in pairs(open) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return open[a] > open[b] end)
    for _, key in ipairs(keys) do
        local cat = RULES[key](gain)
        if cat then return cat end
    end
    return gain and "Other income" or "Other spending"
end

local function Log(text, amount, note, item)
    local log = Store().log
    table.insert(log, 1, { t = time(), text = text, amount = amount, note = note, item = item })
    while #log > LOG_MAX do table.remove(log) end
end

ns:On("PLAYER_MONEY", function()
    if not ns.session then return end
    local now = GetMoney()
    local delta = now - (lastMoney or now)
    lastMoney = now
    if delta == 0 then return end
    local cat = Classify(delta)
    local kind = delta > 0 and "income" or "expense"
    local amount = math.abs(delta)
    ns.session[kind][cat] = (ns.session[kind][cat] or 0) + amount
    local d = Day(Store())
    d[kind][cat] = (d[kind][cat] or 0) + amount

    -- which item was it? (AH sales and buys only)
    local item
    if cat == "AH sales" then
        local sale = table.remove(saleQueue, 1)
        if sale then item = sale.count and sale.count > 1 and (sale.count .. "x " .. sale.name) or sale.name end
    elseif cat == "AH purchases" and buyHint and GetTime() - buyHint.at < 15 then
        item = (buyHint.qty and buyHint.qty > 1 and (buyHint.qty .. "x ") or "") .. ns.ItemName(buyHint.id)
        buyHint = nil
    end
    local which = ns.BIG[cat]
    if which then
        local rec = { amount = amount, item = item, t = time() }
        for _, holder in ipairs({ ns.session, d }) do
            holder.big = holder.big or {}
            if not holder.big[which] or amount > holder.big[which].amount then holder.big[which] = rec end
        end
    end
    Log(cat, delta, nil, item)
    ns:RequestRefresh()
end)

---------------------------------------------------------------------------
-- Track which windows are open
---------------------------------------------------------------------------
local closedAt, seq = {}, 0
local function Track(showEvent, hideEvent, key)
    ns:On(showEvent, function()
        seq = seq + 1
        open[key] = seq
        closedAt[key] = nil
    end)
    ns:On(hideEvent, function()
        -- money events can land just after the window closes, so wait a moment
        local t = GetTime()
        closedAt[key] = t
        C_Timer.After(0.5, function()
            if closedAt[key] == t then open[key] = nil end
        end)
    end)
end
Track("MERCHANT_SHOW", "MERCHANT_CLOSED", "merchant")
Track("MAIL_SHOW", "MAIL_CLOSED", "mail")
Track("AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "ah")
Track("TRAINER_SHOW", "TRAINER_CLOSED", "trainer")
Track("TAXIMAP_OPENED", "TAXIMAP_CLOSED", "taxi")
Track("TRADE_SHOW", "TRADE_CLOSED", "trade")
Track("LOOT_OPENED", "LOOT_CLOSED", "loot")
Track("QUEST_COMPLETE", "QUEST_FINISHED", "quest")
ns:On("QUEST_TURNED_IN", function(_, _, money)
    if money and money > 0 then SetPending("Quest rewards", 1) end
end)
-- taxi: you're charged after the map closes
ns:On("TAXIMAP_CLOSED", function() SetPending("Flights", -1) end)

---------------------------------------------------------------------------
-- Hooks that tell us exactly what's about to happen
---------------------------------------------------------------------------
local function Hook(tbl, name, fn)
    if tbl and type(tbl[name]) == "function" then
        if tbl == _G then hooksecurefunc(name, fn) else hooksecurefunc(tbl, name, fn) end
    end
end

Hook(_G, "RepairAllItems", function() SetPending("Repairs", -1) end)

local function MailTaken(index)
    local invoiceType, itemName, count
    if GetInboxInvoiceInfo then
        local _
        invoiceType, itemName, _, _, _, _, _, _, _, _, count = GetInboxInvoiceInfo(index)
    end
    local _, _, _, _, money = GetInboxHeaderInfo(index)
    if money and money > 0 then
        local sale = invoiceType == "seller"
        table.insert(mailQueue, sale and "AH sales" or "Mail (other)")
        if sale then table.insert(saleQueue, { name = itemName or "item", count = count }) end
    end
end
Hook(_G, "TakeInboxMoney", MailTaken)
Hook(_G, "AutoLootMailItem", MailTaken)
ns:On("MAIL_CLOSED", function() C_Timer.After(1, function() wipe(mailQueue); wipe(saleQueue) end) end)

-- remember what you're buying on the AH, so the gold that leaves can be matched to an item
local lastSearched
ns:On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey) if type(itemKey) == "table" then lastSearched = itemKey.itemID end end)
ns:On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID) lastSearched = itemID end)
local function Buying(id, qty) if id then buyHint = { id = id, qty = qty, at = GetTime() } end end
Hook(C_AuctionHouse, "StartCommoditiesPurchase", function(id, qty) Buying(id, qty) end)
Hook(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(id, qty) Buying(id, qty) end)
Hook(C_AuctionHouse, "PlaceBid", function() Buying(lastSearched, 1) end)

local function Deposit() SetPending("AH deposits", -1) end
Hook(C_AuctionHouse, "PostItem", Deposit)
Hook(C_AuctionHouse, "PostCommodity", Deposit)
Hook(C_AuctionHouse, "ConfirmPostItem", Deposit)
Hook(C_AuctionHouse, "ConfirmPostCommodity", Deposit)
Hook(_G, "PostAuction", Deposit)
Hook(_G, "StartAuction", Deposit)

---------------------------------------------------------------------------
-- Items you loot (valued at your scanned AH price, or vendor price)
---------------------------------------------------------------------------
local function ToPattern(fmt)
    if not fmt then return end
    fmt = fmt:gsub("%%%d?%$?s", "\001")
    fmt = fmt:gsub("%%%d?%$?d", "\002")
    fmt = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    fmt = fmt:gsub("\001", "(.+)")
    fmt = fmt:gsub("\002", "(%%d+)")
    return "^" .. fmt .. "$"
end
local LOOT_MULTI = ToPattern(LOOT_ITEM_SELF_MULTIPLE)
local LOOT_SINGLE = ToPattern(LOOT_ITEM_SELF)

ns:On("CHAT_MSG_LOOT", function(msg)
    if not ns.session or not msg then return end
    local link, count = msg:match(LOOT_MULTI or "^$")
    if not link then
        link = msg:match(LOOT_SINGLE or "^$")
        count = 1
    end
    local id = ns.IDFromLink(link)
    if not id then return end
    count = tonumber(count) or 1
    local unit = ns:GetItemValue(id) or 0
    local items = ns.session.items
    local e = items[id] or { count = 0, value = 0 }
    e.count = e.count + count
    e.value = e.value + unit * count
    items[id] = e
    ns.session.itemValue = (ns.session.itemValue or 0) + unit * count
    local d = Day(Store())
    d.items = d.items + unit * count
    ns:RequestRefresh()
end)

---------------------------------------------------------------------------
-- Session lifecycle: new session on real login, keep it across /reload
---------------------------------------------------------------------------
-- time played per day, counted in 30s steps while you're logged in
local ticking = false
local function StartClock()
    if ticking then return end
    ticking = true
    local function tick()
        local d = Day(Store())
        d.played = d.played + 30
    end
    if C_Timer.NewTicker then
        C_Timer.NewTicker(30, tick)
    else
        local function loop() tick(); C_Timer.After(30, loop) end
        C_Timer.After(30, loop)
    end
end

ns:On("PLAYER_ENTERING_WORLD", function(isInitialLogin, isReloadingUi)
    if ns.session then lastMoney = GetMoney() return end -- zoning
    StartClock()
    local store = Store()
    if isInitialLogin or not store.current then
        ns:NewSession(false)
    else
        ns.session = store.current
        loginAt = GetTime()
        lastMoney = GetMoney()
    end
end)

ns:On("PLAYER_LOGOUT", function()
    if ns.session then
        ns.session.played = ns:SessionPlayed()
        loginAt = GetTime()
    end
end)

---------------------------------------------------------------------------
-- Time ranges: This session / Today / 7 days / 30 days / All time
---------------------------------------------------------------------------
ns.RANGES = { { "session", "This session" }, { "today", "Today" }, { "week", "7 days" }, { "month", "30 days" }, { "all", "All time" } }
local RANGE_DAYS = { today = 1, week = 7, month = 30 }

-- start of the range as a timestamp (midnight N-1 days ago)
function ns:RangeStart(range)
    if range == "session" then return self.session and self.session.start or time() end
    local n = RANGE_DAYS[range]
    if not n then return 0 end
    local t = date("*t", time())
    t.hour, t.min, t.sec = 0, 0, 0
    return time(t) - (n - 1) * 86400
end

local function Stores(allChars)
    if not allChars then return { Store() } end
    Store() -- make sure this character's ledger exists
    local list = {}
    for _, st in pairs(ns.db.ledger) do
        if st.days then list[#list + 1] = st end
    end
    return list
end

-- Totals for a range: { income = {cat = copper}, expense = {...}, items, listed, played }
function ns:RangeData(range, allChars)
    local agg = { income = {}, expense = {}, items = 0, listed = 0, played = 0 }
    if range == "session" then
        local s = self.session
        if s then AddInto(agg, { income = s.income, expense = s.expense, items = s.itemValue,
            listed = s.listed, played = self:SessionPlayed(), big = s.big }) end
        return agg
    end
    local from = RANGE_DAYS[range] and DayKey(self:RangeStart(range)) or ""
    for _, st in ipairs(Stores(allChars)) do
        for key, d in pairs(st.days) do
            if key >= from then AddInto(agg, d) end
        end
    end
    return agg
end

function ns:Totals(agg)
    local inc, exp = 0, 0
    for _, v in pairs(agg.income) do inc = inc + v end
    for _, v in pairs(agg.expense) do exp = exp + v end
    return inc, exp, inc - exp
end

-- Transactions in a range, newest first
function ns:RangeLog(range, allChars, max)
    local from = self:RangeStart(range)
    local out = {}
    for _, st in ipairs(Stores(range ~= "session" and allChars)) do
        for _, e in ipairs(st.log or {}) do
            if e.t < from then break end -- logs are newest first
            out[#out + 1] = { t = e.t, text = e.text, amount = e.amount, note = e.note, who = allChars and st.name or nil }
        end
    end
    table.sort(out, function(a, b) return a.t > b.t end)
    while #out > (max or 300) do table.remove(out) end
    return out
end

-- One line per day in a range, newest first: { key, income, expense, net, played }
function ns:RangeDays(range, allChars)
    local from = RANGE_DAYS[range] and DayKey(self:RangeStart(range)) or ""
    local byDay = {}
    for _, st in ipairs(Stores(allChars)) do
        for key, d in pairs(st.days) do
            if key >= from then
                local a = byDay[key] or { income = {}, expense = {}, items = 0, listed = 0, played = 0 }
                AddInto(a, d)
                byDay[key] = a
            end
        end
    end
    local list = {}
    for key, a in pairs(byDay) do
        local inc, exp, net = ns:Totals(a)
        list[#list + 1] = { key = key, income = inc, expense = exp, net = net, played = a.played }
    end
    table.sort(list, function(a, b) return a.key > b.key end)
    return list
end
