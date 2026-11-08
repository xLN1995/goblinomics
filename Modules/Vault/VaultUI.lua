if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Vault/VaultUI.lua
-- Vault tab (alt overview with freshness per location, one wealth figure with
-- the speculative part), the wealth tooltip and the "Vault" settings section.
-- A click on a character or the warband bank expands its items (Holdings.lua):
-- icon, link, quantity, where they lie and their value, the most valuable
-- first; hover shows the item tooltip with the split per location, shift-click
-- links it. The dashboard cards live in Cards.lua.
local _, ns = ...

local VUI = {}
ns.VaultUI = VUI

local API = ns.API
local L = API.L
local Money = API.Money
local Freshness = ns.Freshness
local LETTERS = { bags = "T", bank = "B", mail = "P", auctions = "A", equipment = "E" }

-- Display names of the locations (English text is the locale key).
local function LocationName(id)
    if id == "bags" then return L["Bags"] end
    if id == "bank" then return L["Bank"] end
    if id == "mail" then return L["Mail"] end
    if id == "auctions" then return L["Auctions"] end
    if id == "warband" then return L["Warband bank"] end
    return L["Equipment"]
end
local OWNER_TAB = "Goblinomics_Vault.Tab"
local ITEMS_SHOWN = 50   -- items per expanded row before "more items"

local vault
local tab = {}      -- widgets of the tab page
local expanded = {} -- ownerKey -> true (character key or "warband")
local showAll = {}  -- ownerKey -> true once "more items" was clicked
VUI.expanded, VUI.showAll = expanded, showAll

local function Fmt(copper)
    return Money.Format(copper or 0, { abbreviate = true })
end

local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    return c and c.colorStr or "ffffffff"
end

local function Rows(result)
    local rows = {}
    for charKey, c in pairs(result.chars) do
        local last = c.goldSeenAt
        for _, loc in pairs(c.locations) do
            if loc.seenAt and (not last or loc.seenAt > last) then last = loc.seenAt end
        end
        rows[#rows + 1] = { key = charKey, char = c, last = last }
    end
    table.sort(rows, function(a, b) return a.char.wealth > b.char.wealth end)
    if not API.Flavor.IsForever() then   -- no warband bank there
        rows[#rows + 1] = { key = "warband", warband = result.warband, last = result.warband.seenAt }
    end
    return rows
end
VUI.Rows = Rows

local function Pct(v) return API.Format:Percent(v) end

local function ItemLink(key)
    local id = tonumber(key:match("^i:(%d+)"))
    if not id then return nil end
    local name, link = C_Item.GetItemInfo(id)
    return link, name
end

--- Flat list rows: each owner row, followed by its items while it is expanded
-- (the ITEMS_SHOWN most valuable, then a "more" row), or a "loading" row while
-- its items are computed. get(ownerKey) returns the Holdings result or nil.
function VUI.BuildRows(owners, get)
    local out = {}
    for _, row in ipairs(owners) do
        row.kind = "owner"
        out[#out + 1] = row
        if expanded[row.key] then
            local h = get(row.key)
            if not h then
                out[#out + 1] = { kind = "loading", owner = row.key }
            elseif #h.items == 0 then
                out[#out + 1] = { kind = "empty", owner = row.key }
            else
                local limit = showAll[row.key] and #h.items or math.min(#h.items, ITEMS_SHOWN)
                for i = 1, limit do out[#out + 1] = { kind = "item", owner = row.key, entry = h.items[i] } end
                if limit < #h.items then
                    local rest = 0
                    for i = limit + 1, #h.items do rest = rest + h.items[i].value end
                    out[#out + 1] = { kind = "more", owner = row.key, count = #h.items - limit, value = rest }
                end
            end
        end
    end
    return out
end

local function LocationTooltip(owner, row)
    local W = API.Widgets
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if row.warband then
        local w = row.warband
        W.TooltipTitle(L["Warband bank"])
        W.TooltipPair(L["Status"], Freshness.Colorize(w.state, Freshness.Label(w.state)))
        W.TooltipPair(L["Seen by"], w.seenBy or "-")
        W.TooltipPair(L["Items"], Fmt(w.items))
    else
        W.TooltipTitle(row.char.name)
        for _, id in ipairs(ns.LOCATIONS) do
            local loc = row.char.locations[id]
            W.TooltipPair(LocationName(id) .. ": " .. Freshness.Colorize(loc.state, Freshness.Label(loc.state)),
                (loc.state == "never" and "-" or (Fmt(loc.value) .. "  " .. Freshness.Age(loc.seenAt))))
        end
    end
    GameTooltip:Show()
end

local columns   -- Widgets.Columns, built with the tab
local RefreshTab

local function ItemTooltip(owner, entry)
    local W = API.Widgets
    local link = ItemLink(entry.key)
    if link then
        W.ShowItemTooltip(owner, link)
    else
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        W.TooltipTitle(entry.key)
    end
    GameTooltip:AddLine(" ")
    for _, loc in ipairs(entry.locations) do
        local where = LocationName(loc.location)
        if loc.state == "stale" then where = where .. " " .. Freshness.Colorize("stale", "(" .. Freshness.Label("stale") .. ")") end
        W.TooltipPair(where, API.Money.Group(loc.quantity) .. "  " .. Fmt(loc.value))
    end
    GameTooltip:Show()
end

local function Toggle(ownerKey)
    if expanded[ownerKey] then
        expanded[ownerKey], showAll[ownerKey] = nil, nil
    else
        expanded[ownerKey] = true
        ns.Holdings.Run(ownerKey, function() RefreshTab() end)
    end
    RefreshTab()
end

local function OnRowClick(self)
    local d = self.data
    if d.kind == "owner" then
        Toggle(d.key)
    elseif d.kind == "more" then
        showAll[d.owner] = true
        RefreshTab()
    elseif d.kind == "item" then
        local link = ItemLink(d.entry.key)
        if link and IsModifiedClick and IsModifiedClick() and HandleModifiedItemClick then HandleModifiedItemClick(link) end
    end
end

local function OnRowEnter(self)
    local d = self.data
    if d.kind == "owner" then
        LocationTooltip(self, d)
    elseif d.kind == "item" then
        ItemTooltip(self, d.entry)
    end
end

local function ClearCells(cells)
    for _, key in ipairs({ "name", "gold", "items", "wealth", "locations", "seen" }) do cells[key]:SetText("") end
end

-- Item, "more", "loading" and "empty" rows below an expanded owner.
local function InitDetailRow(row, data)
    local Theme = API.Theme
    local C = Theme.colors
    local cells = row.cells
    ClearCells(cells)
    row.zebra:Hide()
    row.toggle:SetText("")
    if data.kind == "item" then
        local e = data.entry
        local id = tonumber(e.key:match("^i:(%d+)"))
        row.icon:SetTexture(id and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id) or 134400)
        row.icon:Show()
        API.ItemMarks:Update(row, e.key)
        row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        local link, name = ItemLink(e.key)
        row.label:SetText((link or name or e.key) .. "  " .. Theme.Colorize("x" .. API.Money.Group(e.quantity), C.textDim))
        local names, stale = {}, false
        for _, loc in ipairs(e.locations) do
            names[#names + 1] = LocationName(loc.location)
            if loc.state == "stale" then stale = true end
        end
        cells.locations:SetText(Theme.Colorize(table.concat(names, ", "), stale and C.textDim or C.text))
        cells.wealth:SetText(Theme.Colorize(Fmt(e.value), C.gold))
    else
        row.icon:Hide()
        API.ItemMarks:Update(row, nil)
        row.label:SetPoint("LEFT", 32, 0)
        local text
        if data.kind == "more" then
            text = API.Lf("%d more items (%s), click to show all", data.count, Fmt(data.value))
        elseif data.kind == "loading" then
            text = L["Calculating..."]
        else
            text = L["No items that count towards the wealth."]
        end
        row.label:SetText(Theme.Colorize(text, C.textDim))
    end
end

local function InitRow(row, data)
    local Theme = API.Theme
    local C = Theme.colors
    if not row.cells then
        columns:Cells(row)
        API.Widgets.RowBackground(row)
        row.toggle = Theme.Text(row, "body", C.textDim)
        row.toggle:SetPoint("LEFT", 2, 0)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 32, 0)
        API.ItemMarks:Attach(row, row.icon, 10)
        row.label = Theme.Text(row, "body", C.text)
        row.label:SetWordWrap(false)
        row:SetScript("OnClick", OnRowClick)
        row:SetScript("OnEnter", OnRowEnter)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    row.data = data
    local cells = row.cells
    row.label:ClearAllPoints()
    row.label:SetPoint("RIGHT", cells.gold, "LEFT", -Theme.space.SM, 0)
    if data.kind ~= "owner" then
        InitDetailRow(row, data)
        return
    end
    row.zebra:Show()
    row.icon:Hide()
    API.ItemMarks:Update(row, nil)
    row.toggle:SetText(expanded[data.key] and "-" or "+")
    row.label:SetPoint("LEFT", 14, 0)
    cells.name:SetText("")
    if data.warband then
        local w = data.warband
        row.label:SetText(Theme.Colorize(L["Warband bank"], C.gold))
        cells.gold:SetText(Fmt(w.gold))
        cells.items:SetText(Fmt(w.items + w.auctions))
        cells.wealth:SetText(Fmt(w.wealth))
        cells.locations:SetText(Freshness.Colorize(w.state, "W"))
    else
        local c = data.char
        row.label:SetText("|c" .. ClassColor(c.class) .. c.name .. "|r")
        cells.gold:SetText(Fmt(c.gold))
        cells.items:SetText(Fmt(c.items + c.auctions))
        cells.wealth:SetText(Fmt(c.wealth))
        local letters = {}
        for _, id in ipairs(ns.LOCATIONS) do
            local loc = c.locations[id]
            letters[#letters + 1] = Freshness.Colorize(loc.state, LETTERS[id])
        end
        cells.locations:SetText(table.concat(letters, " "))
    end
    cells.seen:SetText(Freshness.Age(data.last))
end

RefreshTab = function()
    local result = ns.Networth.Get()
    if not tab.list or not result then return end
    local Theme = API.Theme
    local speculative = API.Price:HasRole("saleRate")
        and ("  " .. Theme.Colorize("(" .. L["of which speculative"] .. " " .. Fmt(result.speculative) .. ")",
            Theme.colors.textDim)) or ""
    tab.summary:SetText(("%s %s%s   %s %s   %s %s   %s %s   %s"):format(
        L["Wealth"], Fmt(result.wealth), speculative,
        L["Gold"], Fmt(result.gold), L["Auctions"], Fmt(result.auctions), L["Items"], Fmt(result.items),
        Theme.Colorize(L["Confidence"] .. " " .. Pct(result.confidence), Theme.colors.textDim)))
    tab.list:SetData(VUI.BuildRows(Rows(result), ns.Holdings.Get))
end

-- New networth: the expanded rows compute their items again.
local function OnNetworth()
    for ownerKey in pairs(expanded) do ns.Holdings.Run(ownerKey, function() RefreshTab() end) end
    RefreshTab()
end

local function BuildTab(page)
    local W, Theme = API.Widgets, API.Theme
    local C, S = Theme.colors, Theme.space
    local goals = W.Button(page, L["Manage goals"], { auto = true,
        onClick = function() if ns.Goals then ns.Goals.OpenDialog() end end })
    goals:SetPoint("TOPRIGHT", -S.GUTTER, 0)
    local summary = Theme.Text(page, "body", C.text)
    summary:SetPoint("LEFT", page, "TOPLEFT", 0, -S.CONTROL_H / 2)
    summary:SetPoint("RIGHT", goals, "LEFT", -S.GAP, 0)
    summary:SetWordWrap(false)
    tab.summary = summary
    columns = W.Columns({
        { key = "name", label = L["Character"] },
        { key = "gold", label = L["Gold"], width = 90, align = "RIGHT" },
        { key = "items", label = L["Items"], width = 90, align = "RIGHT" },
        { key = "wealth", label = L["Wealth"], width = 90, align = "RIGHT" },
        { key = "locations", label = L["Locations"], width = 150, align = "CENTER" },
        { key = "seen", label = L["Seen"], width = 52, align = "RIGHT" },
    })
    local header = columns:Header(page)
    header:SetPoint("TOPLEFT", 0, S.CONTENT_TOP)
    header:SetPoint("RIGHT", page, "RIGHT", -S.GUTTER, 0)
    tab.list = W.ScrollList(page, { rowHeight = S.ROW, init = InitRow })
    tab.list.box:SetPoint("TOPLEFT", 0, S.CONTENT_TOP - S.HEADER_H - S.XS)
    tab.list.box:SetPoint("BOTTOMRIGHT", -S.GUTTER, 0)
    RefreshTab()
end

-- Dashboard tiles --------------------------------------------------------------
local function Line(left, right) API.Widgets.TooltipPair(left, right) end

local function Explain(text) API.Widgets.TooltipHint(text) end

-- Tooltip of the wealth tile: what the value contains, with the breakdown.
local TIPS = {
    ["vault.wealth"] = function(r, cfg)
        API.Widgets.TooltipTitle(L["Wealth"])
        Explain(L["Gold of all characters, the warband bank and mail, your active auctions and every item that can be sold (market price, vendor price for items that cannot go to the auction house). Bound and warbound items and equipped gear are not counted."])  -- luacheck: ignore 631
        GameTooltip:AddLine(" ")
        Line(L["Gold"], Fmt(r.gold))
        Line(L["Auctions"], Fmt(r.auctions))
        Line(L["Items"], Fmt(r.items))
        if API.Price:HasRole("saleRate") then   -- speculative needs a sale rate (TSM)
            GameTooltip:AddLine(" ")
            Explain(L["Speculative: items with a sale rate below %s; counted, but they rarely sell."]
                :format(Pct(cfg.speculativeThreshold)))
            Line(L["of which speculative"], Fmt(r.speculative))
        end
        if r.remote then
            GameTooltip:AddLine(" ")
            Line(L["Other accounts"], Fmt(r.remote.wealth))
        end
    end,
}

--- Wealth tooltip (used by the dashboard's gold card).
function VUI.WealthTooltip(owner)
    local r = ns.Networth.Get()
    if not r then return end
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMRIGHT")
    TIPS["vault.wealth"](r, API.Price:Config())
    GameTooltip:Show()
end

-- Settings ---------------------------------------------------------------------
local function BuildSettings(parent, y)
    local settings = vault.db.settings
    local form = API.Form.New(parent, y)
    form:Group(L["Jealousmeter"])
    form:Toggle({ label = L["Show the Jealousmeter window"],
        description = L["A small window with Gallywix' face next to the main window."],
        get = function() return settings.jealousmeter.window end,
        set = function(on)
            settings.jealousmeter.window = on
            ns.JealousmeterUI.ApplyWindowSetting()
        end })
    form:Toggle({ label = L["Lock the Jealousmeter window"], description = L["The window can no longer be moved."],
        get = function() return settings.jealousmeter.locked end,
        set = function(on) settings.jealousmeter.locked = on end })
    form:Sound({ label = L["Sound on level-up"], description = L["Plays when you reach a new Jealousmeter level."],
        get = function() return settings.jealousmeter.sound end,
        set = function(value) settings.jealousmeter.sound = value end, default = "kit:UI_EPICLOOT_TOAST" })
    form:Group(L["Data freshness"], L["Bank, mail and auctions are only seen when you open them."])
    form:Slider({ label = L["Fresh for (hours)"], description = L["A location counts as up to date for this long."],
        min = 1, max = 24,
        get = function() return settings.freshHours end,
        set = function(v)
            settings.freshHours = v
            ns.Networth.Schedule()
        end })
    form:Slider({ label = L["Aging up to (days)"], description = L["After this, a location counts as stale."],
        min = 1, max = 14,
        get = function() return settings.agingDays end,
        set = function(v)
            settings.agingDays = v
            ns.Networth.Schedule()
        end })
    return form:Finish()
end

function VUI.Enable(module)
    vault = module
    API.UI:RegisterTab({
        id = "vault", title = function() return L["Vault"] end, order = 10,
        build = BuildTab,
        onShow = function()
            OnNetworth()
            API.On("NETWORTH_UPDATED", OnNetworth, OWNER_TAB)
        end,
        onHide = function() API.Off("NETWORTH_UPDATED", OWNER_TAB) end,
    })
    API.UI:RegisterHeaderTooltipProvider("vault.freshness", function(tt)
        local r = ns.Networth.Get()
        if not r then return end
        local counts = { fresh = 0, aging = 0, stale = 0, never = 0 }
        for _, c in pairs(r.chars) do
            for _, loc in pairs(c.locations) do counts[loc.state] = counts[loc.state] + 1 end
        end
        tt:AddLine(" ")
        tt:AddDoubleLine(L["Data freshness"], Pct(r.confidence), API.Theme.colors.gold[1], API.Theme.colors.gold[2],
            API.Theme.colors.gold[3], 1, 1, 1)
        tt:AddLine(L["share of item value from fresh data"], 0.6, 0.6, 0.6, true)
        for _, state in ipairs({ "fresh", "aging", "stale", "never" }) do
            tt:AddDoubleLine(Freshness.Colorize(state, Freshness.Label(state)), tostring(counts[state]), 1, 1, 1, 1, 1, 1)
        end
    end)
    API.UI:RegisterSettings({ id = "vault", title = function() return L["Vault"] end, order = 20, build = BuildSettings,
        description = function() return L["Jealousmeter and how long scanned locations stay fresh."] end })
end
