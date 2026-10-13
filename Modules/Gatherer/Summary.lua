if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/Summary.lua
-- Session summary window, also opened from the history in the Gatherer tab.
-- Layout: farm and session facts on top, the earned gold (Total) large with the
-- GPH beside it, a compact breakdown (Market Value, Raw Gold, Vendor, Repair,
-- Speculative, Realized), then every item as a link with icon, quantity and
-- value, sorted by value. Hovering a row shows the item tooltip; shift-click
-- links the item in chat. "Copy" opens the plain-text session format.
local _, ns = ...
local CODE = setmetatable({}, { __index = function(_, k) return ns.API.Theme.CODE[k] end })

local Summary = {}
ns.Summary = Summary

local WIDTH, HEIGHT = 480, 540
local ROW_H = 22

local window

local function Money(copper)
    -- whole gold with coin icon; small amounts keep silver and copper
    local API = ns.API
    if math.abs(copper or 0) >= 10000 then
        local gold = math.floor(math.abs(copper) / 10000 + 0.5) * 10000
        return API.Money.Format(copper < 0 and -gold or gold)
    end
    return API.Money.Format(copper or 0)
end

local function ItemLink(summary, key)
    if summary.links and summary.links[key] then return summary.links[key] end
    local id = tonumber(key:match("^i:(%d+)"))
    if not id then return nil end
    local _, link = C_Item.GetItemInfo(id)
    return link
end

local function InitItemRow(row, data)
    if not row.name then
        local Theme = ns.API.Theme
        local C = Theme.colors
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 2, 0)
        ns.API.ItemMarks:Attach(row, row.icon, 11)
        row.name = Theme.Text(row, "body", C.text)
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", -150, 0)
        row.name:SetWordWrap(false)
        row.qty = Theme.Text(row, "body", C.textDim)
        row.qty:SetPoint("RIGHT", -100, 0)
        row.qty:SetWidth(46)
        row.qty:SetJustifyH("RIGHT")
        row.value = Theme.Text(row, "body", C.gold)
        row.value:SetPoint("RIGHT", -4, 0)
        row.value:SetWidth(92)
        row.value:SetJustifyH("RIGHT")
        ns.API.Widgets.RowBackground(row)
        row:SetScript("OnEnter", function(self)
            if self.data.link then ns.API.Widgets.ShowItemTooltip(self, self.data.link) end
        end)
        row:SetScript("OnLeave", ns.API.Widgets.HideTooltip)
        row:SetScript("OnClick", function(self)
            if self.data.link and HandleModifiedItemClick then HandleModifiedItemClick(self.data.link) end
        end)
    end
    row.data = data
    row.zebra:SetShown(data.index % 2 == 0)
    local id = tonumber(data.key:match("^i:(%d+)"))
    row.icon:SetTexture(id and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id) or 134400)
    ns.API.ItemMarks:Update(row, data.key)
    row.name:SetText(data.link or ns.Valuation.ItemName(data.key))
    row.qty:SetText("x" .. data.quantity)
    local speculative = data.bucket == "speculative"
    row.value:SetText(data.value > 0 and ((speculative and CODE.dim or "") .. Money(data.value)
        .. (speculative and "|r" or "")) or CODE.dim .. "-|r")
end

local function Pair(parent, x, y)
    local Theme = ns.API.Theme
    local C = Theme.colors
    local label = Theme.Text(parent, "small", C.textDim)
    label:SetPoint("TOPLEFT", x, y)
    local value = Theme.Text(parent, "body", C.text)
    value:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + 206, y)
    value:SetJustifyH("RIGHT")
    return { label = label, value = value }
end

local function Build()
    local API = ns.API
    local W, Theme = API.Widgets, API.Theme
    local C, S = Theme.colors, Theme.space
    local L = ns.L
    local f
    f = W.Dialog({ name = "GoblinomicsGathererSummary", title = L["Session summary"], width = WIDTH, height = HEIGHT,
        buttons = {
            { text = L["Copy as text"], onClick = function()
                ns.TextDialog.ShowCopy({ title = L["Session summary"], text = f.text })
            end },
            { text = L["Close"], primary = true, onClick = function() f:Hide() end },
        } })
    local body = f.body
    f.facts = Theme.Text(body, "small", C.textDim)
    f.facts:SetPoint("TOPLEFT")
    f.facts:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    f.facts:SetWordWrap(false)

    -- earned gold, large, in a card with a gold bar
    local hero = W.Card(body)
    hero:SetPoint("TOPLEFT", 0, -20)
    hero:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    hero:SetHeight(64)
    local accent = hero:CreateTexture(nil, "ARTWORK")
    accent:SetColorTexture(unpack(C.gold))
    accent:SetPoint("TOPLEFT")
    accent:SetPoint("BOTTOMLEFT")
    accent:SetWidth(3)
    f.totalLabel = Theme.Text(hero, "caption", C.textDim)
    f.totalLabel:SetPoint("TOPLEFT", S.PAD, S.CARD_TITLE_Y)
    f.totalLabel:SetText(L["Earned"]:upper())
    f.total = Theme.Text(hero, "hero", C.gold)
    f.total:SetPoint("BOTTOMLEFT", S.PAD, 9)
    f.gphLabel = Theme.Text(hero, "caption", C.textDim)
    f.gphLabel:SetPoint("TOPRIGHT", -S.PAD, S.CARD_TITLE_Y)
    f.gphLabel:SetJustifyH("RIGHT")
    f.gphLabel:SetText(L["Gold per hour"]:upper())
    f.gph = Theme.Text(hero, "page", C.text)
    f.gph:SetPoint("BOTTOMRIGHT", -S.PAD, 11)
    f.gph:SetJustifyH("RIGHT")

    -- breakdown, two columns
    f.pairs = {}
    for i = 1, 6 do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        f.pairs[i] = Pair(body, col * 228, -96 - row * 18)
    end

    -- items
    local columns = W.Columns({
        { key = "item", label = L["Items"] },
        { key = "qty", label = L["Qty"], width = 46, align = "RIGHT" },
        { key = "value", label = L["Value"], width = 92, align = "RIGHT" },
    })
    local header = columns:Header(body)
    header:SetPoint("TOPLEFT", 0, -156)
    header:SetPoint("RIGHT", body, "RIGHT", -S.GUTTER, 0)
    f.itemsTitle = header.cells[1].label
    f.items = W.ScrollList(body, { rowHeight = ROW_H, init = InitItemRow })
    f.items.box:SetPoint("TOPLEFT", 0, -156 - S.HEADER_H - S.XS)
    f.items.box:SetPoint("BOTTOMRIGHT", -S.GUTTER, 30)
    f.noItems = W.EmptyState(f.items.box, L["No loot in this session."])

    f.note = Theme.Text(body, "caption", C.textDim)
    f.note:SetPoint("BOTTOMLEFT", 0, 0)
    f.note:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    f.note:SetJustifyV("BOTTOM")
    return f
end

--- Valuation, item rows (sorted by value) and plain text of a stored summary.
function Summary.Build(summary)
    local v = ns.Session.SummaryValuation(summary)
    local rows = {}
    for i, item in ipairs(v.items) do
        rows[i] = { index = i, key = item.key, quantity = item.quantity, value = item.value, bucket = item.bucket,
            link = ItemLink(summary, item.key) }
    end
    local text = ns.Valuation.Text({ farmName = summary.farmName, duration = summary.duration, valuation = v })
    return v, rows, text
end

function Summary.Show(summary)
    window = window or Build()
    local L = ns.L
    local API = ns.API
    local v, rows, text = Summary.Build(summary)
    window.text = text
    window:SetTitle(L["Session summary"] .. ": " .. (summary.farmName or L["Ad-hoc session"]))
    local facts = { ns.Valuation.FormatDuration(summary.duration) }
    if summary.char then facts[#facts + 1] = summary.char:match("^([^%-]+)") or summary.char end
    if summary.started then
        facts[#facts + 1] = API.Format:Date(summary.started, "longStamp")
    end
    local nodes = ns.NodeTracker.Text(summary.nodes, summary.duration, v.total)
    if nodes then facts[#facts + 1] = nodes end
    window.facts:SetText(table.concat(facts, "  \194\183  "))
    window.total:SetText(Money(v.total))
    window.gph:SetText(API.Lf("%s per hour", Money(v.gph)))

    local pairs_ = {
        { L["Market Value"], Money(v.market) },
        { L["Repair"], v.repair ~= 0 and (CODE.bad .. Money(-v.repair) .. "|r") or Money(0) },
        { L["Raw Gold"], Money(v.rawGold) },
        { L["Speculative"], CODE.dim .. Money(v.speculative) .. "|r" },
        { L["Vendor"], Money(v.vendor) },
        { L["Realized"], API.Money.Format(v.realized, { color = true, sign = true }) },
    }
    if not API.Price:HasRole("saleRate") then table.remove(pairs_, 4) end   -- speculative needs TSM
    for i = 1, #window.pairs do
        local p = pairs_[i]
        window.pairs[i].label:SetText(p and p[1] or "")
        window.pairs[i].value:SetText(p and p[2] or "")
    end
    window.itemsTitle:SetText(API.Lf("Items (%d)", #rows):upper())
    window.items:SetData(rows)
    window.noItems:SetShown(#rows == 0)

    local notes = {}
    if v.speculative > 0 then notes[#notes + 1] = L["Speculative items are not included in the earned gold."] end
    if summary.repairKnown == false then
        notes[#notes + 1] = L["Repair unknown: visit a merchant with damaged gear once to learn the repair rate."]
    end
    window.note:SetText(table.concat(notes, " "))
    window:Show()
end

function Summary.Hide()
    if window then window:Hide() end
end
