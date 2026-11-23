-- Tally: the ledger window
local ADDON, ns = ...
local Money = ns.Money

local FRAME_W, FRAME_H = 900, 580

local ui = {}
ns.ui = ui

---------------------------------------------------------------------------
-- Small widgets
---------------------------------------------------------------------------
local function Button(parent, text, w)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 100, 22)
    b:SetText(text)
    return b
end

local function Check(parent, label, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetText(label)
    cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false); ns:RequestRefresh() end)
    return cb
end

-- Scrolling list of "left text ... right text" lines with optional bars
local function TextList(parent, width, name)
    local sf = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(width, 1)
    sf:SetScrollChild(content)
    local pool = {}
    local list = { frame = sf }
    function list:SetLines(lines)
        for i, line in ipairs(lines) do
            local row = pool[i]
            if not row then
                row = CreateFrame("Frame", nil, content)
                row:SetSize(width, 16)
                row:SetPoint("TOPLEFT", 0, -(i - 1) * 16)
                row.bar = row:CreateTexture(nil, "BACKGROUND")
                row.bar:SetPoint("LEFT", 0, 0)
                row.bar:SetHeight(14)
                row.l = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.l:SetPoint("LEFT", 4, 0)
                row.l:SetJustifyH("LEFT")
                row.r = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.r:SetPoint("RIGHT", -4, 0)
                row.r:SetJustifyH("RIGHT")
                pool[i] = row
            end
            row.l:SetFontObject(line.header and "GameFontNormal" or "GameFontHighlightSmall")
            row.l:SetText(line.l or "")
            row.r:SetText(line.r or "")
            if line.bar and line.bar > 0 then
                local c = line.barColor or { 0.2, 0.8, 0.2 }
                row.bar:SetColorTexture(c[1], c[2], c[3], 0.25)
                row.bar:SetWidth(math.max(1, width * math.min(line.bar, 1)))
                row.bar:Show()
            else
                row.bar:Hide()
            end
            row:Show()
        end
        for i = #lines + 1, #pool do pool[i]:Hide() end
        content:SetHeight(math.max(1, #lines * 16))
    end
    return list
end

---------------------------------------------------------------------------

-- Ledger tab
---------------------------------------------------------------------------
local ledgerView = "recent"

-- one fixed colour per category, so a category always looks the same
local COLORS = {
    ["Looted gold"] = { 0.95, 0.79, 0.30 }, ["Vendor sales"] = { 0.95, 0.60, 0.29 },
    ["AH sales"] = { 0.34, 0.80, 0.95 },    ["Quest rewards"] = { 0.44, 0.81, 0.59 },
    ["Mail (other)"] = { 0.73, 0.42, 0.85 }, ["Trade received"] = { 0.18, 0.83, 0.75 },
    ["Other income"] = { 0.61, 0.64, 0.69 },
    ["Vendor purchases"] = { 0.95, 0.60, 0.29 }, ["Repairs"] = { 0.92, 0.34, 0.34 },
    ["AH purchases"] = { 0.34, 0.80, 0.95 },     ["AH deposits"] = { 0.18, 0.50, 0.93 },
    ["Training"] = { 0.44, 0.81, 0.59 },          ["Flights"] = { 0.73, 0.42, 0.85 },
    ["Postage & COD"] = { 0.95, 0.79, 0.30 },     ["Trade given"] = { 0.18, 0.83, 0.75 },
    ["Other spending"] = { 0.61, 0.64, 0.69 },
    ["Listed on AH"] = { 0.55, 0.75, 1.00 },
}
local EMPTY = { 0.25, 0.22, 0.18 }

local function Signed(c)
    if c >= 0 then return "|cff40ff40+|r" .. Money(c) end
    return Money(c)
end

local function Hex(c)
    return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

-- Crisp category chart: one stacked bar for the overall split, then a row per category
-- with a bar sized to its share. Plain rectangles only, so it stays sharp at any UI scale.
local function Snap(tex)
    if tex.SetSnapToPixelGrid then tex:SetSnapToPixelGrid(true) end
    if tex.SetTexelSnappingBias then tex:SetTexelSnappingBias(0) end
    return tex
end

local CHART_ROW = 22
local function CategoryChart(parent, width, title)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width, 44 + 10 * CHART_ROW)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 0, 0)
    f.title:SetText(title)
    f.total = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.total:SetPoint("TOPRIGHT", 0, 0)

    f.track = Snap(f:CreateTexture(nil, "BACKGROUND"))
    f.track:SetPoint("TOPLEFT", 0, -20)
    f.track:SetSize(width, 14)
    f.track:SetColorTexture(EMPTY[1], EMPTY[2], EMPTY[3], 0.6)

    f.none = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.none:SetPoint("TOPLEFT", 4, -46)
    f.none:SetText("Nothing in this range yet")

    f.segs, f.rows = {}, {}

    -- slices = { {cat, amount}, ... } largest first
    function f:SetData(slices, total)
        self.total:SetText(Money(total))
        self.none:SetShown(#slices == 0)

        -- stacked bar in whole pixels: every category gets at least 1px,
        -- and the biggest one absorbs the rounding so the bar fills exactly
        local widths, used = {}, 0
        for i, sl in ipairs(slices) do
            widths[i] = math.max(1, math.floor(width * sl[2] / total + 0.5))
            used = used + widths[i]
        end
        if #slices > 0 then widths[1] = math.max(1, widths[1] + (width - used)) end
        local x = 0
        for i, sl in ipairs(slices) do
            local seg = self.segs[i]
            if not seg then
                seg = Snap(self:CreateTexture(nil, "ARTWORK"))
                self.segs[i] = seg
            end
            local c = COLORS[sl[1]] or EMPTY
            seg:ClearAllPoints()
            seg:SetPoint("TOPLEFT", self.track, "TOPLEFT", x, 0)
            seg:SetSize(widths[i], 14)
            seg:SetColorTexture(c[1], c[2], c[3], 1)
            seg:Show()
            x = x + widths[i]
        end
        for i = #slices + 1, #self.segs do self.segs[i]:Hide() end

        -- one row per category
        for i, sl in ipairs(slices) do
            local row = self.rows[i]
            if not row then
                row = CreateFrame("Frame", nil, self)
                row:SetSize(width, CHART_ROW - 2)
                row:SetPoint("TOPLEFT", 0, -44 - (i - 1) * CHART_ROW)
                row.bar = Snap(row:CreateTexture(nil, "BACKGROUND"))
                row.bar:SetPoint("TOPLEFT", 0, 0)
                row.bar:SetHeight(CHART_ROW - 2)
                row.sw = Snap(row:CreateTexture(nil, "ARTWORK"))
                row.sw:SetSize(4, CHART_ROW - 2)
                row.sw:SetPoint("LEFT", 0, 0)
                row.l = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.l:SetPoint("LEFT", 10, 0)
                row.r = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.r:SetPoint("RIGHT", -4, 0)
                self.rows[i] = row
            end
            local c = COLORS[sl[1]] or EMPTY
            local share = total > 0 and sl[2] / total or 0
            row.bar:SetWidth(math.max(1, math.floor(width * share + 0.5)))
            row.bar:SetColorTexture(c[1], c[2], c[3], 0.28)
            row.sw:SetColorTexture(c[1], c[2], c[3], 1)
            row.l:SetText(sl[1])
            row.r:SetText(Money(sl[2]) .. ("  |cff888888%d%%|r"):format(ns.Pct(share)))
            row:Show()
        end
        for i = #slices + 1, #self.rows do self.rows[i]:Hide() end
    end
    return f
end

local function Slices(order, data)
    local list, total = {}, 0
    for _, cat in ipairs(order) do
        local v = data[cat] or 0
        if v > 0 then list[#list + 1] = { cat, v }; total = total + v end
    end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    return list, total
end

local function RefreshLedger()
    if not ns.session then return end
    local set = ns.db.settings
    local range = set.ledgerRange or "session"
    local all = set.ledgerAll and range ~= "session"
    local agg = ns:RangeData(range, all)
    local inc, exp, net = ns:Totals(agg)
    local items = agg.items
    local hours = math.max(agg.played / 3600, 1 / 60)

    local st = ui.stats
    st.time:SetText(ns.Duration(agg.played))
    st.net:SetText(Signed(net) .. (net >= 0 and "  |cff40ff40profit|r" or "  |cffff4040loss|r"))
    st.gph:SetText(agg.played > 0 and Signed(net / hours) or Money(nil))
    st.items:SetText(Money(items))
    st.gold:SetText(Money(GetMoney()))
    st.total:SetText(Signed(net + items))
    for _, which in ipairs({ "buy", "sale" }) do
        local rec = agg.big and agg.big[which]
        ui.statBoxes[which].rec = rec
        if rec then
            st[which]:SetText(Money(rec.amount) .. (rec.item and ("  |cffaaaaaa" .. rec.item .. "|r") or ""))
        else
            st[which]:SetText(Money(nil))
        end
    end

    local incS, incT = Slices(ns.INCOME, agg.income)
    local expS, expT = Slices(ns.EXPENSE, agg.expense)
    ui.incChart:SetData(incS, incT)
    ui.expChart:SetData(expS, expT)

    local timeFmt = (range == "session" or range == "today") and "%H:%M" or "%d %b %H:%M"
    local R = {}
    if ledgerView == "recent" then
        R[#R + 1] = { l = "Transactions", header = true }
        local log = ns:RangeLog(range, all)
        for _, e in ipairs(log) do
            local c = COLORS[e.text] or EMPTY
            local left = date(timeFmt, e.t) .. "  " .. Hex(c) .. e.text .. "|r"
                .. (e.item and ("  " .. e.item) or "") .. (e.who and (" |cff888888" .. e.who .. "|r") or "")
            R[#R + 1] = { l = left, r = e.note and ("|cff888888" .. e.note .. "|r") or Signed(e.amount) }
        end
        if #log == 0 then R[#R + 1] = { l = "|cff888888No money has moved in this range.|r" } end
    elseif ledgerView == "items" then
        local s = ns.session
        R[#R + 1] = { l = "Looted items (this session)", r = Money(s.itemValue or 0), header = true }
        local list = {}
        for id, e in pairs(s.items) do list[#list + 1] = { id = id, count = e.count, value = e.value } end
        table.sort(list, function(a, b) return a.value > b.value end)
        for _, e in ipairs(list) do
            R[#R + 1] = { l = ("%dx %s"):format(e.count, ns.ItemName(e.id)), r = Money(e.value),
                bar = (s.itemValue or 0) > 0 and e.value / s.itemValue or 0, barColor = { 0.3, 0.6, 1 } }
        end
        if #list == 0 then R[#R + 1] = { l = "|cff888888Nothing looted yet.|r" } end
        R[#R + 1] = { l = " " }
        R[#R + 1] = { l = "|cff888888Valued at what a vendor pays.|r" }
    elseif range == "session" then
        R[#R + 1] = { l = "Past sessions", header = true }
        local store = ns.db.ledger[ns.charKey]
        for _, h in ipairs(store.history) do
            local hi, he, hn = ns:SessionTotals(h)
            R[#R + 1] = { l = date("%d %b %H:%M", h.start) .. "  |cff888888" .. ns.Duration(h.played or 0) .. "|r", r = Signed(hn) }
            R[#R + 1] = { l = "  |cff888888in " .. Money(hi) .. "  out " .. Money(he) .. "|r" }
        end
        if #store.history == 0 then R[#R + 1] = { l = "|cff888888No past sessions yet.|r" } end
    else
        R[#R + 1] = { l = "By day", header = true }
        local days = ns:RangeDays(range, all)
        for _, d in ipairs(days) do
            R[#R + 1] = { l = d.key .. "  |cff888888" .. ns.Duration(d.played) .. "|r", r = Signed(d.net) }
            R[#R + 1] = { l = "  |cff888888in " .. Money(d.income) .. "  out " .. Money(d.expense) .. "|r" }
        end
        if #days == 0 then R[#R + 1] = { l = "|cff888888Nothing recorded in this range yet.|r" } end
    end
    ui.detail:SetLines(R)
    for k, b in pairs(ui.viewBtns) do b:SetEnabled(k ~= ledgerView) end
    ui.viewBtns.history:SetText(range == "session" and "Past sessions" or "By day")
    for k, b in pairs(ui.rangeBtns) do b:SetEnabled(k ~= range) end
    ui.allChars:SetChecked(set.ledgerAll and true or false)
    ui.allChars:SetEnabled(range ~= "session")
end

local function CreateLedgerPanel(parent)
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints()

    -- time range buttons (top right, level with the tabs)
    ui.rangeBtns = {}
    local prevR
    for i = #ns.RANGES, 1, -1 do
        local r = ns.RANGES[i]
        local b = Button(p, r[2], r[1] == "session" and 90 or 64)
        if prevR then b:SetPoint("RIGHT", prevR, "LEFT", -2, 0) else b:SetPoint("TOPRIGHT", -12, -28) end
        b:SetScript("OnClick", function() ns.db.settings.ledgerRange = r[1]; RefreshLedger() end)
        ui.rangeBtns[r[1]] = b
        prevR = b
    end

    -- summary: two rows of four boxes
    ui.stats, ui.statBoxes = {}, {}
    local labels = {
        { "time", "Time played" }, { "net", "Net cash" }, { "gph", "Gold per hour" }, { "total", "Net incl. items" },
        { "items", "Looted items (est.)" }, { "gold", "Gold on hand" }, { "buy", "Biggest AH buy" }, { "sale", "Biggest AH sale" },
    }
    local bw = (FRAME_W - 32) / 4
    for i, v in ipairs(labels) do
        local col, line = (i - 1) % 4, math.floor((i - 1) / 4)
        local b = CreateFrame("Frame", nil, p)
        b:SetPoint("TOPLEFT", 16 + col * bw, -58 - line * 44)
        b:SetSize(bw - 6, 40)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.04)
        local lab = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        lab:SetPoint("TOPLEFT", 8, -6)
        lab:SetText(v[2])
        local val = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        val:SetPoint("BOTTOMLEFT", 8, 6)
        val:SetWidth(bw - 20)
        val:SetJustifyH("LEFT")
        val:SetWordWrap(false)
        ui.stats[v[1]] = val
        ui.statBoxes[v[1]] = b
        if v[1] == "buy" or v[1] == "sale" then
            b:EnableMouse(true)
            b:SetScript("OnEnter", function(self)
                local rec = self.rec
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:AddLine(v[2])
                if rec then
                    GameTooltip:AddLine(rec.item or "Item not recorded", 1, 1, 1)
                    GameTooltip:AddDoubleLine("Amount", Money(rec.amount), 0.7, 0.7, 0.7, 1, 1, 1)
                    GameTooltip:AddDoubleLine("When", date("%d %b %H:%M", rec.t), 0.7, 0.7, 0.7, 1, 1, 1)
                else
                    GameTooltip:AddLine("Nothing in this range yet", 0.7, 0.7, 0.7)
                end
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", GameTooltip_Hide)
        end
    end

    -- income and expenses: stacked bar + a bar per category
    local colW = 240
    ui.incChart = CategoryChart(p, colW - 10, "|cff40ff40Income|r")
    ui.incChart:SetPoint("TOPLEFT", 21, -156)
    ui.expChart = CategoryChart(p, colW - 10, "|cffff6060Expenses|r")
    ui.expChart:SetPoint("TOPLEFT", 21 + colW + 10, -156)

    -- transactions / looted items / history
    local listX = 16 + colW * 2 + 30
    local listW = FRAME_W - listX - 30
    ui.detail = TextList(p, listW, "TallyLedgerScroll")
    ui.detail.frame:SetPoint("TOPLEFT", listX, -152)
    ui.detail.frame:SetPoint("BOTTOMRIGHT", -30, 44)

    ui.viewBtns = {}
    local views = { { "recent", "Transactions" }, { "items", "Looted items" }, { "history", "Past sessions" } }
    local prev
    for _, v in ipairs(views) do
        local b = Button(p, v[2], 110)
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -4, 0) else b:SetPoint("BOTTOMRIGHT", -12, 12) end
        b:SetScript("OnClick", function() ledgerView = v[1]; RefreshLedger() end)
        ui.viewBtns[v[1]] = b
        prev = b
    end

    local reset = Button(p, "New session", 110)
    reset:SetPoint("BOTTOMLEFT", 12, 12)
    reset:SetScript("OnClick", function() ns:NewSession(true) end)

    ui.allChars = Check(p, "All characters", function() return ns.db.settings.ledgerAll end,
        function(v) ns.db.settings.ledgerAll = v end)
    ui.allChars:SetPoint("LEFT", reset, "RIGHT", 10, 0)

    -- keep the clock and gold/hour ticking (every second for a session, every 5s otherwise)
    local t = 0
    p:SetScript("OnUpdate", function(_, dt)
        t = t + dt
        local every = (ns.db.settings.ledgerRange or "session") == "session" and 1 or 5
        if t > every then t = 0; RefreshLedger() end
    end)
    return p
end

---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Main window
---------------------------------------------------------------------------
local function CreateMain()
    local f = CreateFrame("Frame", "TallyMainFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(FRAME_W, FRAME_H)
    f:SetScale(ns.db.settings.scale or 1)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "TallyMainFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -5)
    title:SetText("Tally")
    local heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", 16, -32)
    heading:SetText("Gold ledger")

    ui.ledger = CreateLedgerPanel(f)
    ui.frame = f
    f:SetScript("OnShow", function() ns:Refresh() end)
    f:Hide()
end

function ns:ToggleUI()
    if not ui.frame then CreateMain() end
    ui.frame:SetShown(not ui.frame:IsShown())
    if ui.frame:IsShown() then ns:Refresh() end
end

function ns:ShowUI()
    if not ui.frame then CreateMain() end
    ui.frame:Show()
    ns:Refresh()
end

function ns:ApplyScale()
    if ui.frame then ui.frame:SetScale(ns.db.settings.scale or 1) end
end

function ns:Refresh()
    if not (ui.frame and ui.frame:IsShown()) then return end
    RefreshLedger()
end

local queued = false
function ns:RequestRefresh()
    if queued then return end
    queued = true
    C_Timer.After(0.3, function() queued = false; ns:Refresh() end)
end

ns:On("GET_ITEM_INFO_RECEIVED", function() ns:RequestRefresh() end)
