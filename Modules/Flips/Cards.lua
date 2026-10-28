if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Flips/Cards.lua
-- Dashboard card "Flips" for the dashboard period: profit and ROI, the open stock
-- and the three items with the most profit. A click opens the Flips tab.
local _, ns = ...

local Cards = {}
ns.Cards = Cards

local API = ns.API
local L = API.L
local TOP = 3

--- { totals, top = { stats, ... } } for context = { days, from }.
function Cards.Summary(context)
    local summary = ns.Stats.Summary({ from = context.from })
    local open = 0
    for _, s in ipairs(ns.Stats.Summary({}).items) do
        if s.openQty > 0 then open = open + 1 end
    end
    local top = {}
    for _, s in ipairs(summary.items) do
        if s.soldQty > 0 then top[#top + 1] = s end
    end
    table.sort(top, function(a, b) return a.profit > b.profit end)
    for i = #top, TOP + 1, -1 do top[i] = nil end
    return { totals = summary.totals, openItems = open, top = top }
end

function Cards.Enable()
    local Theme = API.Theme
    local C = Theme.colors
    API.UI:RegisterWidget({
        id = "flips.summary", order = 43, size = "third", height = 140, events = { "FLIPS_CHANGED" },
        title = function() return L["Flips"] end,
        build = function(f)
            local function Line(y, label)
                local l = Theme.Text(f, "caption", C.textDim)
                l:SetPoint("TOPLEFT", 12, y)
                l:SetText(label:upper())
                local v = Theme.Text(f, "body", C.text)
                v:SetPoint("TOPLEFT", 90, y + 1)
                v:SetPoint("RIGHT", f, "RIGHT", -12, 0)
                v:SetWordWrap(false)
                return v
            end
            f.profit = Line(-30, L["Profit"])
            f.open = Line(-48, L["Open"])
            f.rows = {}
            for i = 1, TOP do
                local y = -72 - (i - 1) * 18
                local name = Theme.Text(f, "small", C.text)
                name:SetPoint("TOPLEFT", 12, y)
                name:SetPoint("RIGHT", f, "RIGHT", -90, 0)
                name:SetWordWrap(false)
                local value = Theme.Text(f, "small", C.text)
                value:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, y)
                value:SetJustifyH("RIGHT")
                f.rows[i] = { name = name, value = value }
            end
            f.empty = Theme.Text(f, "small", C.textDim)
            f.empty:SetPoint("TOPLEFT", 12, -72)
            f.empty:SetText(L["No flip sales in this period."])
            f:EnableMouse(true)
            f:SetScript("OnMouseUp", function() API.UI:Show("flips") end)
        end,
        refresh = function(f, context)
            local UI = ns.FlipsUI
            local s = Cards.Summary(context)
            local t = s.totals
            f.profit:SetText(UI.Money(t.profit, { color = true, sign = true }) .. "   "
                .. API.Theme.Colorize(L["ROI"] .. " " .. UI.Percent(t.roi, true), C.textDim))
            local openCost = ns.Stats.Summary({}).totals.openCost
            f.open:SetText(UI.Money(openCost) .. "   " .. API.Theme.Colorize(API.Lf("(%d items)", s.openItems), C.textDim))
            for i, row in ipairs(f.rows) do
                local e = s.top[i]
                row.name:SetShown(e ~= nil)
                row.value:SetShown(e ~= nil)
                if e then
                    row.name:SetText(select(2, UI.Item(e.key)))
                    row.value:SetText(UI.Money(e.profit, { color = true, sign = true }))
                end
            end
            f.empty:SetShown(#s.top == 0)
        end,
    })
end
