if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Insights/InsightsUI.lua
-- Insights tab: a header bar with the tabs History, Cash
-- flow and Reports on the left and the filters period and character on the
-- right; below it the page in a scroll panel, built from cards like the
-- dashboard.
--   History    key figures against the previous period, wealth as an area
--              chart, income/expenses per day as bars with the net as a line,
--              top incomes and expenses with share bars
--   Cash flow  key figures and the Sankey diagram (Sankey.lua); always all
--              characters
--   Reports    day or week with back/forward: key figures against the previous
--              day/week, bars per hour or per day, top lists, the day's bookings
local _, ns = ...
local CODE = setmetatable({}, { __index = function(_, k) return ns.API.Theme.CODE[k] end })

local UI = {}
ns.InsightsUI = UI

local API = ns.API
local L = ns.L
local OWNER = "Goblinomics_Insights.Tab"
local TOP = 5
local SPACE = API.Theme.space
-- two header rows: the pages, then the filters (period left, character right); one row
-- overflowed into the character dropdown (in-game finding)
local FILTER_Y = -(SPACE.CONTROL_H + SPACE.SM)
local HEADER_H = 2 * SPACE.CONTROL_H + SPACE.SM
local GAP = SPACE.GAP
local PAD = SPACE.PAD
local TILE_H = 70
local ROW_H = SPACE.ROW
local MAX_BOOKINGS = 40

local tab = {}
local state = { page = "history", char = "all", reportKind = "day", reportOffset = 0 }
UI.state = state

local function Money(copper, opts)
    opts = opts or {}
    opts.abbreviate = true
    return API.Money.Format(math.floor((copper or 0) + 0.5), opts)
end

local function Days()
    return ns.Insights.db and ns.Insights.db.settings.days or 30
end

local function Char() return state.char ~= "all" and state.char or nil end

local function ShortDate(key) return API.Format:Day(key) end

local function LongDate(key) return API.Format:Day(key, "long") end

local function ItemName(itemKey)
    local id = tonumber(itemKey:match("^i:(%d+)"))
    local name, link
    if id then name, link = C_Item.GetItemInfo(id) end
    return link or name or itemKey, link, id
end

local function Weekday(t) return API.Format:Date(t, "weekday") end

local function Width(frame, fallback)
    local w = frame.GetWidth and frame:GetWidth()
    if not w or w <= 0 then return fallback or 640 end
    return w
end

-- Building blocks --------------------------------------------------------------------------
--- Card with background, 1 px border and an upper-case title; card.body is the inner area.
--- Card with a caption title (Widgets.Card, shared with the dashboard and the settings).
local function Card(parent, title)
    return API.Widgets.Card(parent, title)
end

--- n frames side by side with equal width, re-arranged on size changes.
local function Row(parent, n)
    local row = CreateFrame("Frame", nil, parent)
    row.cells = {}
    function row:Arrange()
        local w = (Width(self) - GAP * (n - 1)) / n
        for i, cell in ipairs(self.cells) do
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", self, "TOPLEFT", (i - 1) * (w + GAP), 0)
            cell:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", (i - 1) * (w + GAP), 0)
            cell:SetWidth(w)
        end
    end
    function row:Add(cell)
        self.cells[#self.cells + 1] = cell
        cell:SetParent(self)
        if #self.cells == n then self:Arrange() end
        return cell
    end
    row:SetScript("OnSizeChanged", row.Arrange)
    return row
end

--- Key figure tile: label, value, comparison line.
local function Tile(parent, label)
    local Theme = API.Theme
    local C = Theme.colors
    local t = Card(parent)
    t.label = Theme.Text(t, 10, C.textDim)
    t.label:SetPoint("TOPLEFT", PAD, -10)
    t.label:SetText(label:upper())
    t.value = Theme.Text(t, "value", C.text)
    t.value:SetPoint("TOPLEFT", PAD, -26)
    t.value:SetPoint("RIGHT", t, "RIGHT", -PAD, 0)
    t.value:SetWordWrap(false)
    t.note = Theme.Text(t, 10, C.textDim)
    t.note:SetPoint("TOPLEFT", PAD, -50)
    t.note:SetPoint("RIGHT", t, "RIGHT", -PAD, 0)
    t.note:SetWordWrap(false)
    --- change in percent; goodWhenUp colours an increase green (else red)
    function t:SetChange(pct, goodWhenUp, suffix)
        if not pct then
            self.note:SetText(CODE.dim .. L["no comparison"] .. "|r")
            return
        end
        local up = pct >= 0
        local good = (up and goodWhenUp) or (not up and not goodWhenUp)
        local text = (up and "+" or "-") .. API.Format:Percent(math.abs(pct) / 100)
        local color = math.abs(pct) < 0.5 and "999999" or (good and API.Money.GAIN_COLOR or API.Money.LOSS_COLOR)
        self.note:SetText("|cff" .. color .. text .. "|r " .. CODE.dim .. suffix .. "|r")
    end
    return t
end

--- Key figure row: Wealth (or custom first tile), income, expenses, net.
local function KpiRow(parent, labels)
    local row = Row(parent, #labels)
    row.tiles = {}
    for i, label in ipairs(labels) do row.tiles[i] = row:Add(Tile(row, label)) end
    return row
end

--- Fill income/expense/net tiles from totals and previous totals.
local function SetMoneyTiles(tiles, cur, prev, suffix)
    local Change = ns.Data.Change
    tiles.income.value:SetText(Money(cur.income, { color = true }))
    tiles.income:SetChange(prev and Change(cur.income, prev.income), true, suffix)
    tiles.expense.value:SetText(Money(cur.expense, { color = true }))
    tiles.expense:SetChange(prev and Change(-cur.expense, -prev.expense), false, suffix)
    tiles.net.value:SetText(Money(cur.net, { color = true, sign = true }))
    tiles.net:SetChange(prev and Change(cur.net, prev.net), true, suffix)
end

--- Top list with icon, name, share bar, percent and amount.
local function TopList(parent, n, color)
    local Theme = API.Theme
    local C = Theme.colors
    local list = { rows = {} }
    for i = 1, n do
        local r = CreateFrame("Button", nil, parent)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * (ROW_H + 4))
        r:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
        r:SetHeight(ROW_H)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16)
        r.icon:SetPoint("TOPLEFT", 0, -1)
        r.dot = r:CreateTexture(nil, "ARTWORK")
        r.dot:SetSize(8, 8)
        r.dot:SetPoint("CENTER", r.icon, "CENTER")
        r.dot:SetColorTexture(color[1], color[2], color[3], 0.9)
        r.name = Theme.Text(r, 11, C.text)
        r.name:SetPoint("TOPLEFT", 22, -2)
        r.name:SetPoint("RIGHT", r, "RIGHT", -120, 0)
        r.name:SetWordWrap(false)
        r.value = Theme.Text(r, 11, C.text)
        r.value:SetPoint("TOPRIGHT", 0, -2)
        r.value:SetJustifyH("RIGHT")
        r.pct = Theme.Text(r, 10, C.textDim)
        r.pct:SetPoint("TOPRIGHT", -78, -3)
        r.pct:SetJustifyH("RIGHT")
        r.track = r:CreateTexture(nil, "BACKGROUND")
        r.track:SetColorTexture(1, 1, 1, 0.05)
        r.track:SetPoint("BOTTOMLEFT", 22, 1)
        r.track:SetPoint("BOTTOMRIGHT", 0, 1)
        r.track:SetHeight(3)
        r.bar = r:CreateTexture(nil, "ARTWORK")
        r.bar:SetColorTexture(color[1], color[2], color[3], 0.8)
        r.bar:SetPoint("BOTTOMLEFT", 22, 1)
        r.bar:SetHeight(3)
        local hl = r:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.04)
        r.share = 0
        r:SetScript("OnSizeChanged", function(self, w)
            if w and w > 22 then self.bar:SetWidth(math.max(1, (w - 22) * self.share)) end
        end)
        r:SetScript("OnEnter", function(self)
            if self.link then API.Widgets.ShowItemTooltip(self, self.link) end
        end)
        r:SetScript("OnLeave", API.Widgets.HideTooltip)
        list.rows[i] = r
    end
    list.empty = Theme.Text(parent, 11, C.textDim)
    list.empty:SetPoint("TOPLEFT", 0, -2)
    list.empty:SetText(L["Nothing in this period."])
    function list:SetData(entries)
        local total = 0
        for _, e in ipairs(entries) do total = total + math.abs(e.amount) end
        local width = Width(parent, 280) - 22
        for i, r in ipairs(self.rows) do
            local e = entries[i]
            r:SetShown(e ~= nil)
            if e then
                local share = total > 0 and math.abs(e.amount) / total or 0
                local name, link, id = e.label, nil, nil
                if e.itemKey then name, link, id = ItemName(e.itemKey) end
                r.link = link
                r.name:SetText(name .. (e.itemKey and API.ItemMarks:Inline(e.itemKey) or ""))
                r.value:SetText(Money(math.abs(e.amount)))
                r.pct:SetText(API.Format:Percent(share))
                r.share = share
                r.bar:SetWidth(math.max(1, width * share))
                local icon = id and C_Item.GetItemIconByID(id)
                r.icon:SetTexture(icon)
                r.icon:SetShown(icon ~= nil)
                r.dot:SetShown(icon == nil)
            end
        end
        self.empty:SetShown(#entries == 0)
    end
    list.height = n * (ROW_H + 4)
    return list
end

--- Vertical stack of blocks in the scroll content; heights may be functions,
-- visible() hides a block (and closes its gap).
local function Stack(parent)
    local stack = { items = {} }
    function stack:Add(frame, height, visible)
        frame:SetParent(parent)
        self.items[#self.items + 1] = { frame = frame, height = height, visible = visible }
        return frame
    end
    function stack:Layout()
        local y = 0
        for _, item in ipairs(self.items) do
            local on = not item.visible or item.visible()
            item.frame:SetShown(on)
            if on then
                local h = type(item.height) == "function" and item.height() or item.height
                item.frame:ClearAllPoints()
                item.frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -y)
                item.frame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -y)
                item.frame:SetHeight(h)
                y = y + h + GAP
            end
        end
        return math.max(0, y - GAP)
    end
    return stack
end

local function NewPage(parent)
    local p = { frame = CreateFrame("Frame", nil, parent) }
    p.frame:SetPoint("TOPLEFT")
    p.frame:SetPoint("TOPRIGHT")
    p.stack = Stack(p.frame)
    return p
end

-- History --------------------------------------------------------------------------------
local function BuildHistory(parent)
    local Charts = API.Charts
    local C = API.Theme.colors
    local p = NewPage(parent)
    local kpi = p.stack:Add(KpiRow(p.frame, { L["Wealth"], L["Income"], L["Expenses"], L["Net"] }), TILE_H)
    p.tiles = { wealth = kpi.tiles[1], income = kpi.tiles[2], expense = kpi.tiles[3], net = kpi.tiles[4] }

    local wealthCard = p.stack:Add(Card(p.frame, L["Wealth"]), 220)
    p.wealth = Charts.TimeChart(wealthCard.body, { height = 180, empty = L["No data in this period yet."],
        series = { { kind = "area", key = "wealth", color = C.gold } },
        label = function(i) return p.wealthData[i] and ShortDate(p.wealthData[i].key) or "" end,
        tooltip = function(i)
            local e = p.wealthData[i]
            local before = p.wealthData[i - 1]
            local lines = { L["Wealth"] .. ": " .. Money(e.wealth) }
            if e.gold then lines[#lines + 1] = L["Gold"] .. ": " .. Money(e.gold) end
            if before then lines[#lines + 1] = L["Change"] .. ": " .. Money(e.wealth - before.wealth, { color = true, sign = true }) end
            return LongDate(e.key), lines
        end })
    p.wealth:SetAllPoints(wealthCard.body)

    local barsCard = p.stack:Add(Card(p.frame, L["Income and expenses per day"]), 200)
    p.bars = Charts.TimeChart(barsCard.body, { height = 160, empty = L["No bookings in this period."],
        series = { { kind = "bars", key = "income", color = C.accent }, { kind = "bars", key = "expense", color = C.loss },
            { kind = "line", key = "net", color = C.gold } },
        label = function(i) return p.dayData[i] and ShortDate(p.dayData[i].key) or "" end,
        tooltip = function(i)
            local d = p.dayData[i]
            return LongDate(d.key), { L["Income"] .. ": " .. Money(d.income, { color = true }),
                L["Expenses"] .. ": " .. Money(d.expense, { color = true }),
                L["Net"] .. ": " .. Money(d.net, { color = true, sign = true }) }
        end })
    p.bars:SetAllPoints(barsCard.body)

    local tops = p.stack:Add(Row(p.frame, 2), 28 + TOP * (ROW_H + 4) + 10)
    local inCard = tops:Add(Card(tops, L["Top incomes"]))
    local outCard = tops:Add(Card(tops, L["Top expenses"]))
    p.incomes = TopList(inCard.body, TOP, C.accent)
    p.expenses = TopList(outCard.body, TOP, C.loss)

    function p.Refresh()
        local days, char = Days(), Char()
        local period = ns.Data.Period(days, char)
        local suffix = L["vs. previous period"]
        p.tiles.wealth.value:SetText(period.wealth and Money(period.wealth) or "-")
        if period.wealthChange then
            p.tiles.wealth.note:SetText(Money(period.wealthChange, { color = true, sign = true })
                .. " " .. CODE.dim .. L["in this period"] .. "|r")
        else
            p.tiles.wealth.note:SetText(CODE.dim .. L["no comparison"] .. "|r")
        end
        SetMoneyTiles(p.tiles, period, period.prev, suffix)
        p.wealthData = ns.Data.Wealth(days, char)
        local points = {}
        for i, e in ipairs(p.wealthData) do points[i] = { values = { wealth = e.wealth } } end
        p.wealth:SetData(points)
        p.dayData = ns.Data.Days(days, char)
        local bars = {}
        for i, d in ipairs(p.dayData) do bars[i] = { values = { income = d.income, expense = d.expense, net = d.net } } end
        p.bars:SetData(bars)
        local incomes, expenses = ns.Data.Top(days, char, TOP)
        p.incomes:SetData(incomes)
        p.expenses:SetData(expenses)
        p.period = period
        return p.stack:Layout()
    end
    return p
end

-- Cash flow ------------------------------------------------------------------------------
local SANKEY_H = 380

local function BuildFlow(parent)
    local p = NewPage(parent)
    local kpi = p.stack:Add(KpiRow(p.frame, { L["Income"], L["Expenses"], L["Net"] }), TILE_H)
    p.tiles = { income = kpi.tiles[1], expense = kpi.tiles[2], net = kpi.tiles[3] }
    local card = p.stack:Add(Card(p.frame, L["Where the gold came from and where it went"]),
        function() return (p.sankey.needed or SANKEY_H) + 40 end)
    p.sankey = ns.Sankey.Create(card.body, SANKEY_H)
    p.sankey:SetAllPoints(card.body)
    function p.Refresh()
        local days = Days()
        local period = ns.Data.Period(days)
        SetMoneyTiles(p.tiles, period, period.prev, L["vs. previous period"])
        local flow = ns.Data.Flow(days)
        p.flow = flow
        p.sankey:SetData(flow)
        return p.stack:Layout()
    end
    return p
end

-- Reports --------------------------------------------------------------------------------
local function BuildReports(parent)
    local W, Theme, Charts = API.Widgets, API.Theme, API.Charts
    local C = Theme.colors
    local p = NewPage(parent)

    local head = p.stack:Add(Card(p.frame), 48)
    p.kind = W.Segmented(head, { { value = "day", label = L["Day"] }, { value = "week", label = L["Week"] } },
        function() return state.reportKind end, function(v)
            state.reportKind, state.reportOffset = v, 0
            UI.Refresh()
        end, { min = 60 })
    p.kind:SetPoint("LEFT", PAD, 0)
    p.prev = W.IconButton(head, "prev", { size = SPACE.CONTROL_H, onClick = function()
        state.reportOffset = state.reportOffset + 1
        UI.Refresh()
    end })
    p.prev:SetPoint("LEFT", p.kind, "RIGHT", 2 * SPACE.GAP, 0)
    p.next = W.IconButton(head, "next", { size = SPACE.CONTROL_H, onClick = function()
        state.reportOffset = math.max(0, state.reportOffset - 1)
        UI.Refresh()
    end })
    p.next:SetPoint("LEFT", p.prev, "RIGHT", SPACE.XS, 0)
    p.title = Theme.Text(head, "title", C.text)
    p.title:SetPoint("LEFT", p.next, "RIGHT", SPACE.PAD, 0)
    p.today = W.Button(head, L["Today"], { auto = true, onClick = function()
        state.reportOffset = 0
        UI.Refresh()
    end })
    p.today:SetPoint("RIGHT", -PAD, 0)

    local row1 = p.stack:Add(KpiRow(p.frame, { L["Income"], L["Expenses"], L["Net"] }), TILE_H)
    local row2 = p.stack:Add(KpiRow(p.frame, { L["Wealth change"], L["Crafting profit"], L["Flip profit"], L["Farming"] }),
        TILE_H)
    p.tiles = { income = row1.tiles[1], expense = row1.tiles[2], net = row1.tiles[3],
        wealth = row2.tiles[1], crafting = row2.tiles[2], flips = row2.tiles[3], farming = row2.tiles[4] }

    p.chartCard = p.stack:Add(Card(p.frame, ""), 200)
    p.chart = Charts.TimeChart(p.chartCard.body, { height = 160, empty = L["No bookings in this period."],
        series = { { kind = "bars", key = "income", color = C.accent }, { kind = "bars", key = "expense", color = C.loss },
            { kind = "line", key = "net", color = C.gold } },
        label = function(i)
            local e = p.chartData[i]
            if not e then return "" end
            return e.hour and ("%02d"):format(e.hour) or API.Format:Date(e.time, "weekdayShort")
        end,
        tooltip = function(i)
            local e = p.chartData[i]
            local title = e.hour and ("%02d:00 - %02d:59"):format(e.hour, e.hour) or (Weekday(e.time) .. ", " .. LongDate(e.key))
            return title, { L["Income"] .. ": " .. Money(e.income, { color = true }),
                L["Expenses"] .. ": " .. Money(e.expense, { color = true }),
                L["Net"] .. ": " .. Money(e.net, { color = true, sign = true }) }
        end })
    p.chart:SetAllPoints(p.chartCard.body)

    local tops = p.stack:Add(Row(p.frame, 2), 28 + TOP * (ROW_H + 4) + 10)
    local inCard = tops:Add(Card(tops, L["Top incomes"]))
    local outCard = tops:Add(Card(tops, L["Top expenses"]))
    p.incomes = TopList(inCard.body, TOP, C.accent)
    p.expenses = TopList(outCard.body, TOP, C.loss)

    -- the booking list only belongs to a day
    p.bookingsCard = p.stack:Add(Card(p.frame, L["Bookings"]), function()
        return 28 + math.max(1, p.bookingCount or 0) * 20 + 12
    end, function() return state.reportKind == "day" end)
    p.rows = {}
    local body = p.bookingsCard.body
    for i = 1, MAX_BOOKINGS do
        local r = {}
        local y = -(i - 1) * 20
        r.time = Theme.Text(body, 11, C.textDim)
        r.time:SetPoint("TOPLEFT", 0, y)
        r.char = Theme.Text(body, 11, C.text)
        r.char:SetPoint("TOPLEFT", 50, y)
        r.char:SetWidth(100)
        r.char:SetWordWrap(false)
        r.label = Theme.Text(body, 11, C.text)
        r.label:SetPoint("TOPLEFT", 156, y)
        r.label:SetPoint("RIGHT", body, "RIGHT", -100, 0)
        r.label:SetWordWrap(false)
        r.value = Theme.Text(body, 11, C.text)
        r.value:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, y)
        r.value:SetJustifyH("RIGHT")
        p.rows[i] = r
    end
    p.noBookings = Theme.Text(body, 11, C.textDim)
    p.noBookings:SetPoint("TOPLEFT", 0, 0)
    p.noBookings:SetText(L["No bookings in this period."])

    local function FillBookings(list)
        local shown = 0
        for i, r in ipairs(p.rows) do
            local b = list and list[i]
            local on = b ~= nil
            for _, fs in pairs(r) do fs:SetShown(on) end
            if on then
                shown = i
                r.time:SetText(date("%H:%M", b.time))
                r.char:SetText(b.char and (b.char:match("^([^%-]+)") or b.char) or "-")
                local text = ns.Data.Label(b)
                if b.itemKey then text = text .. ": " .. ItemName(b.itemKey) .. ((b.quantity or 1) > 1 and (" x" .. b.quantity) or "") end
                r.label:SetText(text)
                r.value:SetText(Money(b.amount, { color = true, sign = true }))
            end
        end
        p.noBookings:SetShown(list ~= nil and #list == 0)
        p.bookingCount = shown
    end

    function p.Refresh()
        local r = ns.Data.Report(state.reportKind, state.reportOffset, Char())
        p.report = r
        local isDay = state.reportKind == "day"
        p.kind:Refresh()
        p.title:SetText(isDay and (Weekday(r.from) .. ", " .. ns.API.Format:Date(r.from, "long"))
            or (ns.API.Format:Date(r.from) .. " - " .. ns.API.Format:Date(r.to - 3600, "long")))
        for _, b in ipairs({ p.next, p.today }) do b:SetEnabled(state.reportOffset > 0) end
        local suffix = isDay and L["vs. previous day"] or L["vs. previous week"]
        local prev = r.previous
        SetMoneyTiles(p.tiles, r, prev, suffix)
        local Change = ns.Data.Change
        p.tiles.wealth.value:SetText(r.wealthChange and Money(r.wealthChange, { color = true, sign = true }) or "-")
        if Char() then
            p.tiles.wealth.note:SetText(CODE.dim .. L["all characters only"] .. "|r")
        else
            p.tiles.wealth:SetChange(prev and Change(r.wealthChange, prev.wealthChange), true, suffix)
        end
        p.tiles.crafting.value:SetText(r.crafting and Money(r.crafting, { color = true, sign = true }) or "-")
        p.tiles.crafting:SetChange(prev and Change(r.crafting, prev.crafting), true, suffix)
        p.tiles.flips.value:SetText(r.flips and Money(r.flips, { color = true, sign = true }) or "-")
        p.tiles.flips:SetChange(prev and Change(r.flips, prev.flips), true, suffix)
        p.tiles.farming.value:SetText(r.sessions and r.sessions > 0 and Money(r.farmed) or "-")
        p.tiles.farming.note:SetText(CODE.dim .. API.Lf("%d sessions", r.sessions or 0) .. "|r")
        p.chartData = isDay and r.hours or r.days
        p.chartCard.title:SetText((isDay and L["Income and expenses per hour"] or L["Income and expenses per day"]):upper())
        local bars = {}
        for i, e in ipairs(p.chartData) do bars[i] = { values = { income = e.income, expense = e.expense, net = e.net } } end
        p.chart:SetData(bars)
        p.incomes:SetData(r.incomes)
        p.expenses:SetData(r.expenses)
        FillBookings(isDay and r.bookings or nil)
        return p.stack:Layout()
    end
    return p
end

-- Tab --------------------------------------------------------------------------------------
local BUILDERS = { history = BuildHistory, flow = BuildFlow, reports = BuildReports }

function UI.Refresh()
    if not tab.content then return end
    tab.tabs:Refresh()
    tab.char:SetShown(state.page ~= "flow")
    tab.allChars:SetShown(state.page == "flow")
    tab.pages = tab.pages or {}
    local page = tab.pages[state.page]
    if not page then
        page = BUILDERS[state.page](tab.content)
        tab.pages[state.page] = page
    end
    for id, pg in pairs(tab.pages) do pg.frame:SetShown(id == state.page) end
    local start = debugprofilestop()
    local height = page.Refresh() or 0
    page.frame:SetHeight(math.max(1, height))
    tab.scroll:Update(height)
    tab.lastRefreshMs = debugprofilestop() - start
end

function UI.Page(id) return tab.pages and tab.pages[id] end

local function CharChoices()
    local list = { { value = "all", label = L["All characters"] } }
    if API.Vault and API.Vault:Current() then
        local chars = {}
        for key, c in pairs(API.Vault:Current().chars) do chars[#chars + 1] = { value = key, label = c.name or key } end
        table.sort(chars, function(a, b) return a.label < b.label end)
        for _, c in ipairs(chars) do list[#list + 1] = c end
    end
    return list
end

local function Build(page)
    local W, Theme = API.Widgets, API.Theme
    local C = Theme.colors
    local header = CreateFrame("Frame", nil, page)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:SetHeight(HEADER_H)
    tab.header = header
    tab.tabs = W.Segmented(header, { { value = "history", label = L["History"] }, { value = "flow", label = L["Cash flow"] },
        { value = "reports", label = L["Reports"] } }, function() return state.page end, function(v)
            state.page = v
            UI.Refresh()
        end, { min = 80 })
    tab.tabs:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0)
    local period = API.Periods:Control(header, Days, function(d)
        ns.Insights.db.settings.days = d
        UI.Refresh()
    end)
    period:SetPoint("TOPLEFT", header, "TOPLEFT", 0, FILTER_Y)
    tab.period = period
    tab.char = W.Dropdown(header, CharChoices, function() return state.char end, function(v)
        state.char = v
        UI.Refresh()
    end, { size = "M" })
    tab.char:SetPoint("TOPRIGHT", header, "TOPRIGHT", -SPACE.GUTTER, FILTER_Y)
    tab.allChars = Theme.Text(header, "small", C.textDim)
    tab.allChars:SetPoint("RIGHT", tab.char, "RIGHT", -SPACE.SM, 0)
    tab.allChars:SetText(L["All characters"])

    tab.scroll = W.ScrollPanel(page)
    tab.scroll.box:SetPoint("TOPLEFT", 0, -(HEADER_H + GAP))
    tab.scroll.box:SetPoint("BOTTOMRIGHT", -SPACE.GUTTER, 0)
    tab.content = tab.scroll.content
    UI.Refresh()
end

-- Registered at load time: the core's placeholder tab is replaced before the page is built.
API.UI:RegisterTab({
    id = "insights", title = function() return L["Insights"] end, order = 1, module = "Goblinomics_Insights",
    build = Build,
    onShow = function()
        UI.Refresh()
        for _, event in ipairs({ "LEDGER_CHANGED", "NETWORTH_UPDATED" }) do
            API.On(event, function() if tab.content then UI.Refresh() end end, OWNER)
        end
    end,
    onHide = function()
        API.Off("LEDGER_CHANGED", OWNER)
        API.Off("NETWORTH_UPDATED", OWNER)
    end,
})
