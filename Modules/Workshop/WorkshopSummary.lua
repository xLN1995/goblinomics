if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/WorkshopSummary.lua
-- "Overview" view of the Workshop, in cards: realized profit large with the
-- change against the previous period and the split into sold crafts / crafting
-- orders / salvage (no orders on WoW: Forever, see WorkshopUI.Sources), and the
-- open stock (items, cost, current market value);
-- profit per day as stacked bars; top recipes by profit and the best recipes by
-- concentration value per point, plus one line per profession. A click on a
-- recipe opens its details.
local _, ns = ...

local Summary = {}
ns.WorkshopSummary = Summary

local TOP = 5

local module

--- Days of the profit-per-day chart: the period, at least 14 and at most 90 days.
local function DaysFor(period)
    if type(period) ~= "number" then return 30 end
    return math.max(14, math.min(90, period))
end

--- Tooltip of a bar in the profit-per-day chart: the date, one line per source
-- and the total.
function Summary.ChartTooltip(bar)
    local L, UI = ns.L, ns.WorkshopUI
    local v, lines = bar.values, {}
    for _, s in ipairs(UI.Sources()) do
        lines[#lines + 1] = s.label .. ": " .. UI.Money(v[s.key], { color = true, sign = true })
    end
    lines[#lines + 1] = L["Total"] .. ": " .. UI.Money(bar.total, { color = true, sign = true })
    return ns.API.Format:Date(bar.day, "long"), lines
end

function Summary.Build(parent)
    local API, L, UI = ns.API, ns.L, ns.WorkshopUI
    local Theme, W = API.Theme, API.Widgets
    local C = Theme.colors
    local page = {}
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    page.frame = f

    local S = Theme.space

    -- realized profit and open stock
    local kpi = W.Card(f, L["Realized profit"])
    kpi:SetPoint("TOPLEFT", 0, 0)
    kpi:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    kpi:SetHeight(92)
    local body = kpi.body
    page.total = Theme.Text(body, "hero", C.gold)
    page.total:SetPoint("TOPLEFT", 0, 0)
    page.change = Theme.Text(body, "body", C.textDim)
    page.change:SetPoint("LEFT", page.total, "RIGHT", S.GAP, 0)
    page.split = Theme.Text(body, "small", C.textDim)
    page.split:SetPoint("BOTTOMLEFT", 0, 0)
    page.split:SetPoint("RIGHT", body, "RIGHT", -170, 0)
    page.split:SetWordWrap(false)
    local stockLabel = Theme.Text(body, "caption", C.textDim)
    stockLabel:SetPoint("TOPRIGHT", 0, 0)
    stockLabel:SetText(L["Open stock"]:upper())
    page.stockQty = Theme.Text(body, "title", C.text)
    page.stockQty:SetPoint("TOPRIGHT", 0, -14)
    page.stockQty:SetJustifyH("RIGHT")
    page.stockValue = Theme.Text(body, "small", C.textDim)
    page.stockValue:SetPoint("BOTTOMRIGHT", 0, 0)
    page.stockValue:SetJustifyH("RIGHT")

    -- profit per day
    local chartCard = W.Card(f, L["Profit per day"])
    chartCard:SetPoint("TOPLEFT", kpi, "BOTTOMLEFT", 0, -S.GAP)
    chartCard:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    chartCard:SetHeight(150)
    local sources = UI.Sources()
    local legend = Theme.Text(chartCard, "small", C.textDim)
    legend:SetPoint("TOPRIGHT", chartCard, "TOPRIGHT", -S.PAD, S.CARD_TITLE_Y)
    legend:SetJustifyH("RIGHT")
    local parts = {}
    for i, s in ipairs(sources) do parts[i] = s.code .. s.label .. "|r" end
    legend:SetText(table.concat(parts, "  "))
    page.legend = legend
    page.chart = W.BarChart(chartCard.body, {
        width = 420, height = 100, gap = 2, series = sources, tooltip = Summary.ChartTooltip,
    })
    page.chart:SetPoint("TOPLEFT", 0, 0)
    page.chart:SetPoint("BOTTOMRIGHT", 0, 0)
    page.chartEmpty = W.EmptyState(chartCard.body,
        API.Flavor.IsForever() and L["No sales in this period."] or L["No sales or orders in this period."])

    -- top recipes and concentration value
    local left = W.Card(f, L["Top recipes"])
    left:SetPoint("TOPLEFT", chartCard, "BOTTOMLEFT", 0, -S.GAP)
    left:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -S.GAP / 2, 0)
    local right = W.Card(f, "")
    right:SetPoint("TOPLEFT", chartCard, "BOTTOM", S.GAP / 2, -S.GAP)
    right:SetPoint("BOTTOMRIGHT", 0, 0)
    page.concentrationCard = right
    local function Rows(host, withBar)
        local rows = {}
        for i = 1, TOP do
            local y = -(i - 1) * (S.ROW_S + 2)
            local r = CreateFrame("Button", nil, host)
            r:SetPoint("TOPLEFT", 0, y)
            r:SetPoint("RIGHT", host, "RIGHT", 0, 0)
            r:SetHeight(S.ROW_S)
            if withBar then
                r.bar = r:CreateTexture(nil, "BACKGROUND")
                r.bar:SetColorTexture(unpack(C.accentSoft))
                r.bar:SetPoint("TOPLEFT", 0, 0)
                r.bar:SetHeight(S.ROW_S)
            end
            r.name = Theme.Text(r, "small", C.text)
            r.name:SetPoint("LEFT", 4, 0)
            r.name:SetPoint("RIGHT", r, "RIGHT", -76, 0)
            r.name:SetWordWrap(false)
            r.value = Theme.Text(r, "small", C.text)
            r.value:SetPoint("RIGHT", -2, 0)
            r.value:SetJustifyH("RIGHT")
            r:SetScript("OnClick", function(self) if self.recipe then UI.OpenRecipe(self.recipe) end end)
            rows[i] = r
        end
        return rows
    end
    page.top = Rows(left.body, true)
    page.conc = Rows(right.body, false)
    page.topEmpty = Theme.Text(left.body, "small", C.textDim)
    page.topEmpty:SetPoint("TOPLEFT", 4, -2)
    page.topEmpty:SetText(L["No sold crafts yet."])
    page.concEmpty = Theme.Text(right.body, "small", C.textDim)
    page.concEmpty:SetPoint("TOPLEFT", 4, -2)
    page.concEmpty:SetText(L["No concentrated crafts yet"])
    page.professions = Theme.Text(right.body, "caption", C.textDim)
    page.professions:SetPoint("TOPLEFT", 4, -TOP * (S.ROW_S + 2) - S.XS)
    page.professions:SetPoint("RIGHT", right.body, "RIGHT", 0, 0)
    page.professions:SetJustifyH("LEFT")
    page.leftFrame = left.body

    function page.Refresh(filter)
        local state = UI.state
        local cmp = ns.Stats.Compare(filter)
        local b = cmp.current
        page.total:SetText(UI.Money(b.total, { color = true, sign = true }))
        if cmp.change then
            local color = cmp.change >= 0 and "3fbf3f" or "d9463e"
            page.change:SetText(("|cff%s%+.0f%%|r %s"):format(color, cmp.change, L["vs. previous period"]))
        else
            page.change:SetText("")
        end
        page.split:SetText(UI.BreakdownText(b, "   "))
        local stock = ns.Stats.OpenStock(filter)
        page.stockQty:SetText(API.Lf("%d items", stock.qty))
        page.stockValue:SetText(API.Lf("cost %s, worth %s", UI.Money(stock.cost), UI.Money(stock.value)))

        local days = ns.Stats.Daily(DaysFor(state.period), filter)
        local bars, any = {}, false
        for i, d in ipairs(days) do
            bars[i] = { day = d.day, total = d.total, values = { sales = d.sales, orders = d.orders, salvage = d.salvage } }
            if d.total ~= 0 or d.sales ~= 0 or d.orders ~= 0 then any = true end
        end
        page.chart:SetData(bars)
        page.chartEmpty:SetShown(not any)
        page.chart:SetShown(any)

        local recipes = {}
        for _, r in ipairs(ns.Stats.Recipes(filter)) do
            if r.sold > 0 then recipes[#recipes + 1] = r end
        end
        local best = recipes[1] and math.max(1, recipes[1].profit) or 1
        local width = (page.leftFrame.GetWidth and page.leftFrame:GetWidth()) or 0
        if not width or width <= 0 then width = 200 end
        for i, row in ipairs(page.top) do
            local r = recipes[i]
            row.recipe = r and r.recipe
            row.name:SetText(r and (r.output and (UI.ItemLabel(r.output)) or r.name) or "")
            row.value:SetText(r and UI.Money(r.profit, { color = true, sign = true }) or "")
            row.bar:SetShown(r ~= nil and r.profit > 0)
            if r and r.profit > 0 then row.bar:SetWidth(math.max(2, width * r.profit / best)) end
        end
        page.topEmpty:SetShown(#recipes == 0)

        local days30 = module and module.db.settings.concentrationDays or 30
        page.concentrationCard:SetTitle(API.Lf("Concentration value (%d days)", days30))
        local conc = ns.Concentration.ByRecipe(nil, filter)
        for i, row in ipairs(page.conc) do
            local e = conc[i]
            row.recipe = e and e.recipe
            row.name:SetText(e and ((e.output and (UI.ItemLabel(e.output))) or e.name) or "")
            row.value:SetText(e and API.Lf("%s/pt", UI.Money(e.value)) or "")
        end
        page.concEmpty:SetShown(#conc == 0)
        local parts = {}
        for profession, c in pairs(ns.Concentration.ByProfession()) do
            if not filter.profession or filter.profession == profession then
                parts[#parts + 1] = ("%s %s"):format(profession, API.Lf("%s/pt", UI.Money(c.value)))
            end
        end
        table.sort(parts)
        page.professions:SetText(table.concat(parts, "   "))
    end

    return page
end

function Summary.Enable(m)
    module = m
end
