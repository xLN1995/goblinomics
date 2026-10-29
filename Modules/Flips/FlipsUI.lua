if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Flips/FlipsUI.lua
-- Main-window tab "Flips": one filter row (period, character, item search, "open
-- only"), four key figures (profit, ROI, sale rate, holding time), the profit per
-- day and a sortable item table with the open stock; a click on an item opens the
-- detail view (FlipsDetail) in place of the overview, shift-click links it.
-- Refreshed when the tab opens and on FLIPS_CHANGED.
local _, ns = ...

local UI = {}
ns.FlipsUI = UI

local API = ns.API
local L = API.L
local OWNER = "Goblinomics_Flips.Tab"
local ALL = "all"

local tab = {}
local state = { period = 30, char = ALL, search = "", openOnly = false, sort = "profit", reverse = false }
UI.state = state

local module

local function Money(copper, opts)
    opts = opts or {}
    opts.abbreviate = true
    return API.Money.Format(copper, opts)
end
UI.Money = Money

local function Percent(v, signed)
    if type(v) ~= "number" then return "-" end
    local text = API.Format:Percent(v, 0)
    if signed and v > 0 then text = "+" .. text end
    return text
end
UI.Percent = Percent

local function Hold(seconds)
    return type(seconds) == "number" and API.Format:Remaining(seconds) or "-"
end
UI.Hold = Hold

--- Link (or nil), name and icon of an item key.
function UI.Item(key)
    local str = API.ItemKey.ToItemString(key)
    local name, link = C_Item.GetItemInfo(str or key)
    local id = API.ItemKey.ToItemID(key)
    if not name and id and C_Item.GetItemNameByID then name = C_Item.GetItemNameByID(id) end
    local icon = id and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id) or 134400
    return link, name or key, icon
end

function UI.ShortName(charKey)
    return charKey and (charKey:match("^([^-]+)") or charKey) or "-"
end

--- Window of the period filter: { from, days } for Stats.
function UI.Window()
    return { from = API.Periods:From(state.period), char = state.char ~= ALL and state.char or nil }
end

local SORTS = {
    name = function(a, b) return select(2, UI.Item(a.key)):lower() < select(2, UI.Item(b.key)):lower() end,
    sold = function(a, b) return a.soldQty > b.soldQty end,
    revenue = function(a, b) return a.revenue > b.revenue end,
    profit = function(a, b) return a.profit > b.profit end,
    roi = function(a, b) return (a.roi or -math.huge) > (b.roi or -math.huge) end,
    rate = function(a, b) return (a.saleRate or -1) > (b.saleRate or -1) end,
    hold = function(a, b) return (a.holdTime or math.huge) < (b.holdTime or math.huge) end,
    open = function(a, b) return a.openCost > b.openCost end,
}

--- Items of the summary that pass search and "open only", sorted.
function UI.Apply(summary)
    local items = {}
    local search = strtrim(state.search or ""):lower()
    for _, s in ipairs(summary.items) do
        local ok = not state.openOnly or s.openQty > 0
        if ok and search ~= "" then ok = select(2, UI.Item(s.key)):lower():find(search, 1, true) ~= nil end
        if ok then items[#items + 1] = s end
    end
    local sort = SORTS[state.sort] or SORTS.profit
    if state.reverse then
        local base = sort
        sort = function(a, b) return base(b, a) end
    end
    table.sort(items, function(a, b)
        if sort(a, b) then return true end
        if sort(b, a) then return false end
        return a.key < b.key
    end)
    return items
end

function UI.SortBy(key)
    if state.sort == key then
        state.reverse = not state.reverse
    else
        state.sort, state.reverse = key, false
    end
    UI.Refresh()
end

--- Characters that bought flips: { { value, label } }.
function UI.CharacterChoices()
    local seen, list = {}, {}
    for _, lot in ipairs(module.db.root.lots) do
        if lot.char and not seen[lot.char] then
            seen[lot.char] = true
            list[#list + 1] = { value = lot.char, label = UI.ShortName(lot.char) }
        end
    end
    table.sort(list, function(a, b) return a.label < b.label end)
    table.insert(list, 1, { value = ALL, label = L["All characters"] })
    return list
end

-- Building blocks ------------------------------------------------------------------------
--- Key figure tile: label, value, note.
local function Tile(parent, label)
    local Theme = API.Theme
    local C, S = Theme.colors, Theme.space
    local t = API.Widgets.Card(parent)
    t.label = Theme.Text(t, "caption", C.textDim)
    t.label:SetPoint("TOPLEFT", S.PAD, -10)
    t.label:SetText(label:upper())
    t.value = Theme.Text(t, "value", C.text)
    t.value:SetPoint("TOPLEFT", S.PAD, -24)
    t.value:SetPoint("RIGHT", t, "RIGHT", -S.PAD, 0)
    t.value:SetWordWrap(false)
    t.note = Theme.Text(t, "caption", C.textDim)
    t.note:SetPoint("TOPLEFT", S.PAD, -46)
    t.note:SetPoint("RIGHT", t, "RIGHT", -S.PAD, 0)
    t.note:SetWordWrap(false)
    return t
end
UI.TILE_H = 64

--- n tiles side by side with equal width, re-arranged on size changes.
local function TileRow(parent, labels)
    local gap = API.Theme.space.GAP
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(UI.TILE_H)
    row.tiles = {}
    for i, label in ipairs(labels) do row.tiles[i] = Tile(row, label) end
    function row:Arrange()
        local width = self:GetWidth()
        if not width or width <= 0 then return end
        local n = #self.tiles
        local w = (width - gap * (n - 1)) / n
        for i, t in ipairs(self.tiles) do
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", self, "TOPLEFT", (i - 1) * (w + gap), 0)
            t:SetSize(w, UI.TILE_H)
        end
    end
    row:SetScript("OnSizeChanged", row.Arrange)
    return row
end
UI.TileRow = TileRow

-- Item table -------------------------------------------------------------------------------
local columns   -- Widgets.Columns: item (flex), sold, revenue, profit, ROI, rate, hold, open

local function InitRow(row, s)
    local Theme = API.Theme
    local C = Theme.colors
    if not row.cols then
        row.cols = columns:Cells(row, "body")
        row.cols.item:SetText("")
        row.cols.sold:SetTextColor(unpack(C.textDim))
        row.cols.open:SetTextColor(unpack(C.textDim))
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", Theme.space.SM, 0)
        row.name = Theme.Text(row, "body", C.text)
        row.name:SetWordWrap(false)
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", row.cols.sold, "LEFT", -Theme.space.SM, 0)
        API.Widgets.RowBackground(row)
        row:SetScript("OnClick", function(self)
            local link = UI.Item(self.data.key)
            if link and IsModifiedClick and IsModifiedClick() and HandleModifiedItemClick then
                HandleModifiedItemClick(link)
                return
            end
            UI.ShowDetail(self.data.key)
        end)
        row:SetScript("OnEnter", function(self)
            local link = UI.Item(self.data.key)
            if link then API.Widgets.ShowItemTooltip(self, link) end
        end)
        row:SetScript("OnLeave", API.Widgets.HideTooltip)
    end
    row.data = s
    local link, name, icon = UI.Item(s.key)
    row.icon:SetTexture(icon)
    row.name:SetText(link or name)
    local c = row.cols
    c.sold:SetText(API.Money.Group(s.soldQty))
    c.revenue:SetText(Money(s.revenue))
    c.profit:SetText(Money(s.profit, { color = true }))
    c.roi:SetText(Percent(s.roi, true))
    c.rate:SetText(Percent(s.saleRate))
    c.hold:SetText(Hold(s.holdTime))
    c.open:SetText(s.openQty > 0 and (API.Money.Group(s.openQty) .. " / " .. Money(s.openCost)) or "-")
end

-- Refresh ------------------------------------------------------------------------------------
local function SetTiles(t)
    local tiles = tab.tiles
    tiles[1].value:SetText(Money(t.profit, { color = true }))
    tiles[1].note:SetText(API.Lf("%d sold", t.soldQty))
    tiles[2].value:SetText(Percent(t.roi, true))
    tiles[2].note:SetText(API.Lf("on %s", Money(t.cost + t.writeoff)))
    tiles[3].value:SetText(Percent(t.saleRate))
    tiles[3].note:SetText(API.Lf("%d of %d auctions", t.sold, t.sold + t.expired + t.cancelled))
    tiles[4].value:SetText(Hold(t.holdTime))
    tiles[4].note:SetText(L["Purchase to sale"])
end

local function RefreshChart()
    local window = UI.Window()
    local days = type(state.period) == "number" and state.period or 365
    local data = ns.Stats.Daily(days, window)
    tab.dayData = data
    local points = {}
    for i, d in ipairs(data) do points[i] = { values = { profit = d.profit } } end
    tab.chart:SetData(points)
end

function UI.Refresh()
    if not tab.list then return end
    if tab.detailKey then
        ns.FlipsDetail.Refresh(tab.detailKey)
        return
    end
    local summary = ns.Stats.Summary(UI.Window())
    local items = UI.Apply(summary)
    SetTiles(summary.totals)
    RefreshChart()
    columns:RefreshHeader()
    tab.list:SetData(items)
    local profit, open = 0, 0
    for _, s in ipairs(items) do profit, open = profit + s.profit, open + s.openCost end
    tab.total:SetText(API.Lf("Sum: %s  (open: %s)", Money(profit, { color = true }), Money(open)))
    tab.empty:Set(#summary.items == 0
        and L["No flips yet. Buy an item on the auction house and post it again."]
        or L["No items match the filter."])
    tab.empty:SetShown(#items == 0)
end

function UI.ShowDetail(key)
    tab.detailKey = key
    tab.overview:Hide()
    tab.detail:Show()
    ns.FlipsDetail.Refresh(key)
end

function UI.ShowOverview()
    tab.detailKey = nil
    tab.detail:Hide()
    tab.overview:Show()
    UI.Refresh()
end

-- Build ------------------------------------------------------------------------------------
local function BuildFilters(page)
    local W = API.Widgets
    local S = API.Theme.space
    tab.period = API.Periods:Control(page, function() return state.period end, function(value)
        state.period = value
        UI.Refresh()
    end, true)
    tab.period:SetPoint("TOPLEFT", 0, 0)
    tab.charFilter = W.Dropdown(page, UI.CharacterChoices, function() return state.char end, function(v)
        state.char = v
        UI.Refresh()
    end, { size = "M", tooltip = L["Character"] })
    tab.charFilter:SetPoint("TOPRIGHT", page, "TOPRIGHT", -S.GUTTER, 0)
    tab.openOnly = W.Checkbox(page, L["Open only"], function() return state.openOnly end, function(on)
        state.openOnly = on
        UI.Refresh()
    end, { width = 110, tooltip = L["Only items with unsold stock."] })
    tab.openOnly:SetPoint("RIGHT", tab.charFilter, "LEFT", -S.GAP, 0)
    tab.search = W.EditBox(page, {
        width = 120,
        get = function() return state.search end,
        set = function(text) state.search = text; UI.Refresh(); return true end,
        tooltip = L["Search item"],
    })
    -- the search takes the room between the period and the right-hand controls
    tab.search:SetPoint("LEFT", tab.period, "RIGHT", S.GAP, 0)
    tab.search:SetPoint("RIGHT", tab.openOnly, "LEFT", -S.GAP, 0)
    tab.search:HookScript("OnTextChanged", function(self, userInput)
        if userInput then state.search = self:GetText(); UI.Refresh() end
    end)
end

local CHART_H = 150

local function BuildOverview(parent)
    local W, Theme, Charts = API.Widgets, API.Theme, API.Charts
    local C, S = Theme.colors, Theme.space
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    tab.overview = f

    local kpi = TileRow(f, { L["Profit"], L["ROI"], L["Sale rate"], L["Holding time"] })
    kpi:SetPoint("TOPLEFT", 0, 0)
    kpi:SetPoint("TOPRIGHT", 0, 0)
    tab.tiles = kpi.tiles

    local card = W.Card(f, L["Profit per day"])
    card:SetPoint("TOPLEFT", 0, -(UI.TILE_H + S.GAP))
    card:SetPoint("TOPRIGHT", 0, -(UI.TILE_H + S.GAP))
    card:SetHeight(CHART_H)
    tab.chart = Charts.TimeChart(card.body, { height = CHART_H - 40, empty = L["No flip sales in this period."],
        series = { { kind = "bars", key = "profit", color = C.gold } },
        label = function(i) return tab.dayData[i] and API.Format:Day(tab.dayData[i].day) or "" end,
        tooltip = function(i)
            local d = tab.dayData[i]
            return API.Format:Day(d.day, "full"), {
                L["Revenue"] .. ": " .. Money(d.revenue),
                L["Cost"] .. ": " .. Money(d.cost),
                L["Profit"] .. ": " .. Money(d.profit, { color = true, sign = true }) }
        end })
    tab.chart:SetAllPoints(card.body)

    columns = W.Columns({
        { key = "item", label = L["Item"], sortable = true },
        { key = "sold", label = L["Sold"], width = 56, align = "RIGHT", sortable = true },
        { key = "revenue", label = L["Revenue"], width = 76, align = "RIGHT", sortable = true },
        { key = "profit", label = L["Profit"], width = 76, align = "RIGHT", sortable = true },
        { key = "roi", label = L["ROI"], width = 52, align = "RIGHT", sortable = true },
        { key = "rate", label = L["Rate"], width = 48, align = "RIGHT", sortable = true },
        { key = "hold", label = L["Hold"], width = 60, align = "RIGHT", sortable = true },
        { key = "open", label = L["Open"], width = 110, align = "RIGHT", sortable = true },
    }, {
        onSort = function(key) UI.SortBy(key == "item" and "name" or key) end,
        sortKey = function() return state.sort == "name" and "item" or state.sort end,
        sortDesc = function()
            local desc = state.sort ~= "name" and state.sort ~= "hold"
            if state.reverse then desc = not desc end
            return desc
        end,
    })
    local top = -(UI.TILE_H + S.GAP + CHART_H + S.GAP)
    local header = columns:Header(f)
    header:SetPoint("TOPLEFT", 0, top)
    header:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    tab.total = Theme.Text(f, "body", C.text)
    tab.total:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -S.SM, 2)
    tab.total:SetJustifyH("RIGHT")
    tab.list = W.ScrollList(f, { rowHeight = S.ROW, init = InitRow })
    tab.list.box:SetPoint("TOPLEFT", 0, top - S.HEADER_H - S.XS)
    tab.list.box:SetPoint("BOTTOMRIGHT", -S.GUTTER, S.ROW)
    tab.empty = W.EmptyState(tab.list.box, L["No flips yet. Buy an item on the auction house and post it again."])
end

local function BuildTab(page)
    local S = API.Theme.space
    BuildFilters(page)
    local content = CreateFrame("Frame", nil, page)
    content:SetPoint("TOPLEFT", 0, -(S.CONTROL_H + S.GAP))
    content:SetPoint("BOTTOMRIGHT", -S.GUTTER, 0)
    BuildOverview(content)
    tab.detail = ns.FlipsDetail.Build(content)
    tab.detail:Hide()
    UI.Refresh()
end

-- Settings ---------------------------------------------------------------------------------
local function BuildSettings(parent, y)
    local settings = module.db.settings
    local form = API.Form.New(parent, y)
    form:Group(L["Detection"])
    form:Number({ label = L["Candidate for (days)"], min = 1,
        description = L["A purchase that is not posted within this time is no flip."],
        get = function() return settings.candidateDays end,
        set = function(n) settings.candidateDays = n; ns.Changed() end })
    form:Number({ label = L["Keep flip details (days)"], min = 7,
        description = L["Older finished flips are kept as totals per item and day."],
        get = function() return settings.retentionDays end,
        set = function(n) settings.retentionDays = n end })
    form:Group(L["Auction house"])
    form:Toggle({ label = L["Flip hints at the auction house"],
        description = L["Cost basis and break-even when posting, your flip record when buying."],
        get = function() return settings.auctionHints end,
        set = function(on) settings.auctionHints = on; API.Emit("FLIPS_HINTS", {}) end })
    form:Note(L["Flips needs the Ledger module: it reports purchases and auction house sales."])
    return form:Finish()
end

function UI.Enable(m)
    module = m
    API.UI:RegisterTab({
        id = "flips", title = function() return L["Flips"] end, order = 25,
        build = BuildTab,
        onShow = function()
            UI.Refresh()
            API.On("FLIPS_CHANGED", UI.Refresh, OWNER)
        end,
        onHide = function() API.Off("FLIPS_CHANGED", OWNER) end,
    })
    API.UI:RegisterSettings({ id = "flips", title = function() return L["Flips"] end, order = 35,
        build = BuildSettings,
        description = function() return L["Detection of flips, retention and the auction house hints."] end })
end
