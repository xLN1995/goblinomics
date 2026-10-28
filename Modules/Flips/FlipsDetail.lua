if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Flips/FlipsDetail.lua
-- Detail view of one item in the Flips tab (in place of the overview): back
-- button, item and "Ignore item" in one row; left the balance for the period and
-- the market comparison, right the purchase and sale prices per day; below every
-- lot with its actions (not a flip, write off) in a context menu.
local _, ns = ...

local D = {}
ns.FlipsDetail = D

local API = ns.API
local L = API.L

local view = {}
local LINES_H = 5 * 16

--- Break-even sale price per unit: the cost basis plus the auction house cut.
function D.BreakEven(unit)
    if not unit then return nil end
    return math.ceil(unit / (1 - ns.Backfill.CUT))
end

--- Average purchase price of the open stock (nil without open stock).
function D.CostBasis(key)
    local qty, cost = 0, 0
    for _, lot in ipairs(ns.Store.OpenLots(key)) do
        qty = qty + lot.remaining
        cost = cost + lot.remaining * lot.unit
    end
    return qty > 0 and cost / qty or nil, qty
end

--- Label/value lines in a card body; returns { set(i, label, value) }.
local function Lines(parent, n)
    local Theme = API.Theme
    local C = Theme.colors
    local lines = {}
    for i = 1, n do
        local y = -(i - 1) * 16
        local label = Theme.Text(parent, "small", C.textDim)
        label:SetPoint("TOPLEFT", 0, y)
        local value = Theme.Text(parent, "small", C.text)
        value:SetPoint("TOPRIGHT", 0, y)
        value:SetJustifyH("RIGHT")
        lines[i] = { label = label, value = value }
    end
    function lines.Set(i, label, value)
        lines[i].label:SetText(label)
        lines[i].value:SetText(value)
    end
    return lines
end

local function StateText(lot)
    if lot.state == "ignored" then return L["no flip"] end
    if lot.state == "closed" then return L["done"] end
    if lot.state == "candidate" then return lot.open and L["bought"] or L["expired"] end
    return L["open"]
end

local function LotMenu(owner, lot)
    if not MenuUtil then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateButton(L["Not a flip"], function()
            ns.Store.Ignore(lot.id)
            ns.Changed()
        end)
        if lot.remaining > 0 and lot.state ~= "ignored" then
            root:CreateButton(L["Write off the rest"], function()
                API.Widgets.Confirm({
                    title = L["Write off"],
                    text = API.Lf("Book the %d unsold items as a loss of %s?", lot.remaining,
                        ns.FlipsUI.Money(lot.remaining * lot.unit)),
                    confirmText = L["Write off"],
                    onConfirm = function()
                        ns.Store.WriteOff(lot.id, "loss")
                        ns.Changed()
                    end,
                })
            end)
        end
    end)
end

local columns   -- lot table: bought (flex), qty, unit, sold, open, posts, profit, state, menu

local function InitRow(row, lot)
    local Theme = API.Theme
    local C = Theme.colors
    local Money = ns.FlipsUI.Money
    if not row.cols then
        row.cols = columns:Cells(row, "body")
        row.cols.unit:SetTextColor(unpack(C.textDim))
        row.cols.state:SetTextColor(unpack(C.textDim))
        API.Widgets.RowBackground(row)
        row.menu = API.Widgets.Button(row, "...", { width = 24, height = Theme.space.SMALL_H,
            onClick = function(self) LotMenu(self, self:GetParent().data) end })
        row.menu:SetPoint("RIGHT", row, "RIGHT", -Theme.space.SM, 0)
    end
    row.data = lot
    local c = row.cols
    c.bought:SetText(API.Format:Date(lot.time, "stamp") .. "  " .. ns.FlipsUI.ShortName(lot.char))
    c.qty:SetText(API.Money.Group(lot.qty))
    c.unit:SetText(Money(lot.unit))
    c.sold:SetText(lot.soldQty > 0 and API.Money.Group(lot.soldQty) or "-")
    c.open:SetText(lot.remaining > 0 and lot.state ~= "ignored" and API.Money.Group(lot.remaining) or "-")
    c.posts:SetText(tostring(lot.posts))
    c.profit:SetText(lot.state == "ignored" and "-" or Money(lot.profit, { color = true }))
    c.state:SetText(StateText(lot))
    row.menu:SetShown(lot.state ~= "ignored")
end

function D.Build(parent)
    local W, Theme, Charts = API.Widgets, API.Theme, API.Charts
    local C, S = Theme.colors, Theme.space
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)

    local back = W.Button(f, "< " .. L["Back"], { auto = true, onClick = function() ns.FlipsUI.ShowOverview() end })
    back:SetPoint("TOPLEFT", 0, 0)
    view.ignore = W.Button(f, L["Ignore item"], { auto = true, onClick = function()
        local key = view.key
        API.Widgets.Confirm({
            title = L["Ignore item"],
            text = L["Purchases of this item will no longer count as flips. Its lots leave the statistics."],
            confirmText = L["Ignore item"],
            onConfirm = function()
                ns.Store.IgnoreKey(key)
                ns.Changed()
                ns.FlipsUI.ShowOverview()
            end,
        })
    end })
    view.ignore:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    view.icon = f:CreateTexture(nil, "ARTWORK")
    view.icon:SetSize(20, 20)
    view.icon:SetPoint("LEFT", back, "RIGHT", S.GAP, 0)
    view.name = Theme.Text(f, "title", C.text)
    view.name:SetPoint("LEFT", view.icon, "RIGHT", S.SM, 0)
    view.name:SetPoint("RIGHT", view.ignore, "LEFT", -S.GAP, 0)
    view.name:SetWordWrap(false)

    local top = -(S.CONTROL_H + S.GAP)
    local cardH = S.CARD_BODY_Y * -1 + LINES_H + S.PAD
    view.balanceCard = W.Card(f, L["Balance"])
    view.balanceCard:SetPoint("TOPLEFT", 0, top)
    view.balanceCard:SetSize(S.MASTER_W, cardH)
    view.balance = Lines(view.balanceCard.body, 5)
    local market = W.Card(f, L["Market"])
    market:SetPoint("TOPLEFT", 0, top - cardH - S.GAP)
    market:SetSize(S.MASTER_W, cardH - 16)
    view.market = Lines(market.body, 4)

    local chartCard = W.Card(f, L["Prices per unit"])
    chartCard:SetPoint("TOPLEFT", S.MASTER_W + S.GAP, top)
    chartCard:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    chartCard:SetHeight(2 * cardH - 16 + S.GAP)
    view.chart = Charts.TimeChart(chartCard.body, { height = 2 * cardH - 56 + S.GAP,
        empty = L["No purchases or sales in this period."],
        series = { { kind = "line", key = "buy", color = C.accent }, { kind = "line", key = "sell", color = C.gold } },
        format = function(copper) return API.Money.Format(copper, { abbreviate = true }) end,
        label = function(i) return view.prices[i] and API.Format:Day(view.prices[i].day) or "" end,
        tooltip = function(i)
            local d = view.prices[i]
            local lines = {}
            if d.buy then lines[#lines + 1] = L["Bought at"] .. ": " .. API.Money.Format(math.floor(d.buy + 0.5)) end
            if d.sell then lines[#lines + 1] = L["Sold at"] .. ": " .. API.Money.Format(math.floor(d.sell + 0.5)) end
            return API.Format:Day(d.day, "full"), lines
        end })
    view.chart:SetAllPoints(chartCard.body)

    columns = W.Columns({
        { key = "bought", label = L["Lots"] },
        { key = "qty", label = L["Qty"], width = 50, align = "RIGHT" },
        { key = "unit", label = L["Cost basis"], width = 76, align = "RIGHT" },
        { key = "sold", label = L["Sold"], width = 50, align = "RIGHT" },
        { key = "open", label = L["Open"], width = 46, align = "RIGHT" },
        { key = "posts", label = L["Posts"], width = 40, align = "RIGHT" },
        { key = "profit", label = L["Profit"], width = 76, align = "RIGHT" },
        { key = "state", label = L["Status"], width = 56 },
        { key = "menu", label = "", width = 24 },
    })
    local listTop = top - (2 * cardH - 16 + S.GAP) - S.GAP
    local header = columns:Header(f)
    header:SetPoint("TOPLEFT", 0, listTop)
    header:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    view.list = W.ScrollList(f, { rowHeight = S.ROW, init = InitRow })
    view.list.box:SetPoint("TOPLEFT", 0, listTop - S.HEADER_H - S.XS)
    view.list.box:SetPoint("BOTTOMRIGHT", -S.GUTTER, 0)
    view.frame = f
    return f
end

function D.Refresh(key)
    if not view.frame then return end
    view.key = key
    local UI = ns.FlipsUI
    local Money = UI.Money
    local link, name, icon = UI.Item(key)
    view.icon:SetTexture(icon)
    view.name:SetText(link or name)
    local window = UI.Window()
    local s = ns.Stats.ByItem(window)[key]
    view.balanceCard:SetTitle(L["Balance"] .. " (" .. API.Periods:Label(UI.state.period) .. ")")
    local b = view.balance
    b.Set(1, L["Profit"], s and Money(s.profit, { color = true }) or "-")
    b.Set(2, L["ROI"], s and UI.Percent(s.roi, true) or "-")
    b.Set(3, L["Sale rate"], s and UI.Percent(s.saleRate) or "-")
    b.Set(4, L["Holding time"], s and UI.Hold(s.holdTime) or "-")
    b.Set(5, L["Lost deposits"], s and Money(s.depositLost) or "-")
    local marketValue = API.Price:Get(key, "market")
    local basis = D.CostBasis(key)
    local m = view.market
    m.Set(1, L["Market value"], marketValue and Money(marketValue) or "-")
    m.Set(2, L["Your cost basis"], basis and Money(basis) or "-")
    m.Set(3, L["Average sale"], s and s.soldQty > 0 and Money(s.gross / s.soldQty) or "-")
    m.Set(4, L["Break-even"], basis and Money(D.BreakEven(basis)) or "-")
    view.prices = ns.Stats.Prices(key, window.from)
    local points = {}
    for i, d in ipairs(view.prices) do points[i] = { values = { buy = d.buy, sell = d.sell } } end
    view.chart:SetData(points)
    view.list:SetData(ns.Stats.Lots(key))
end
