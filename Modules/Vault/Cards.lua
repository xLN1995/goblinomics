if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Vault/Cards.lua
-- Dashboard cards of the Vault (the net income card of the Ledger replaced the
-- raw gold delta, M7):
--   Wealth          full width on top: the wealth large with its
--                   change in the period, a bar split into gold, auctions,
--                   items and the speculative part, the history as an area
--   Gallywix        the Jealousmeter face and a cheeky line for the balance
--   Per character   raw gold per character and warband bank with the change
-- Start values come from the daily history (latest day before the period, else
-- the first known day inside it: then the card says "since <day>").
local _, ns = ...
local CODE = setmetatable({}, { __index = function(_, k) return ns.API.Theme.CODE[k] end })

local Cards = {}
ns.VaultCards = Cards

local API = ns.API
local L = API.L
local MAX_CHARS = 6

local vault

local function DayKey(t) return date("%Y-%m-%d", t) end

local function Current()
    return ns.Networth.Get()
end

--- History entry that marks the start of the period and whether it lies inside it.
-- field: only days that carry it count ("gold" and "chars" are recorded since
-- the one-wealth change, older days only have "wealth").
function Cards.StartEntry(context, field)
    local history = vault.db.root.history
    local fromKey = DayKey(context.from)
    local before, beforeKey, inside, insideKey
    for key, h in pairs(history) do
        if field and h[field] == nil then
            -- skip days without the value
        elseif key < fromKey then
            if not beforeKey or key > beforeKey then before, beforeKey = h, key end
        elseif not insideKey or key < insideKey then
            inside, insideKey = h, key
        end
    end
    if before then return before, beforeKey, false end
    return inside, insideKey, true
end

--- { gold, wealth, speculative, goldDelta, wealthDelta, startKey, partial }
function Cards.Deltas(context)
    local r = Current()
    if not r then return nil end
    local goldStart, key, partial = Cards.StartEntry(context, "gold")
    local wealthStart = Cards.StartEntry(context, "wealth")
    local d = { gold = r.gold, wealth = r.wealth, speculative = r.speculative, startKey = key, partial = partial }
    -- no day with gold yet: the period starts now
    d.goldDelta = goldStart and (r.gold - goldStart.gold) or 0
    if not goldStart then d.partial, d.startKey = true, DayKey(time()) end
    d.wealthDelta = wealthStart and (r.wealth - wealthStart.wealth) or 0
    return d
end

--- Gold change per character and warband: { { key, name, class, delta, gold } } sorted by delta.
function Cards.CharDeltas(context)
    local r = Current()
    if not r then return {} end
    local start = Cards.StartEntry(context, "chars")
    local startChars = start and start.chars or {}
    local list = {}
    for key, c in pairs(r.chars) do
        local s = startChars[key]
        list[#list + 1] = { key = key, name = c.name, class = c.class, gold = c.gold, delta = s and (c.gold - s.gold) or nil }
    end
    if not ns.API.Flavor.IsForever() then   -- no warband bank there
        local wb = start and start.warband
        list[#list + 1] = { key = "warband", name = L["Warband bank"], gold = r.warband.gold,
            delta = wb and (r.warband.gold - wb.gold) or nil }
    end
    table.sort(list, function(a, b)
        if a.gold ~= b.gold then return a.gold > b.gold end
        return a.name < b.name
    end)
    return list
end

--- Wealth per day in the period (oldest first) and the day keys; today live.
function Cards.WealthSeries(context)
    local history = vault.db.root.history
    local values, keys = {}, {}
    for i = 0, context.days - 1 do
        local key = DayKey(context.from + i * 86400 + 3600)
        local h = history[key]
        if h and h.wealth then
            values[#values + 1], keys[#keys + 1] = h.wealth, key
        end
    end
    local r = Current()
    if r then
        local today = DayKey(time())
        if keys[#keys] == today then values[#values] = r.wealth
        else values[#values + 1], keys[#keys + 1] = r.wealth, today end
    end
    return values, keys
end

--- Parts of the wealth for the bar: { { key, amount, share } } (other accounts when linked).
function Cards.WealthParts(r)
    local withRate = API.Price:HasRole("saleRate")   -- speculative needs a sale rate (TSM)
    local spec = withRate and math.min(r.speculative or 0, r.items or 0) or 0
    local parts = {
        { key = "gold", amount = r.gold or 0 },
        { key = "auctions", amount = r.auctions or 0 },
        { key = "items", amount = (r.items or 0) - spec },
    }
    if withRate then parts[#parts + 1] = { key = "speculative", amount = spec } end
    local other = (r.wealth or 0) - (r.gold or 0) - (r.auctions or 0) - (r.items or 0)
    if other > 0 then parts[#parts + 1] = { key = "other", amount = other } end
    local total = math.max(1, r.wealth or 0)
    for _, p in ipairs(parts) do p.share = math.max(0, p.amount) / total end
    return parts
end

-- Gallywix ---------------------------------------------------------------------------
local MOODS = {
    ecstatic = { function() return L["Gallywix is green with envy. Greener than usual."] end,
        function() return L["Keep that up and Gallywix will want your autograph."] end,
        function() return L["Now that is what I call a hostile takeover!"] end },
    happy = { function() return L["Not bad, not bad. Gallywix raises an eyebrow."] end,
        function() return L["The coins are clinking nicely."] end,
        function() return L["Gallywix pretends not to notice. He noticed."] end },
    neutral = { function() return L["Nothing moves, nothing grows. Gallywix yawns."] end,
        function() return L["Steady as a goblin's grip on his wallet."] end,
        function() return L["Time is money, friend. Use it."] end },
    grumpy = { function() return L["Easy on the spending, friend."] end,
        function() return L["Gallywix smells an opportunity. For himself."] end,
        function() return L["That dent in your gold is hard to miss."] end },
    horrified = { function() return L["Gallywix is laughing. At you."] end,
        function() return L["Who let you near the auction house?"] end,
        function() return L["Your gold called. It wants to come back."] end },
}
Cards.MOODS = MOODS

--- Mood from the wealth change relative to the wealth at the start.
function Cards.Mood(d)
    if not d or not d.wealthDelta then return "neutral" end
    local base = math.max(1, (d.wealth or 0) - d.wealthDelta)
    local ratio = d.wealthDelta / base
    if ratio >= 0.10 then return "ecstatic" end
    if ratio >= 0.02 then return "happy" end
    if ratio > -0.02 then return "neutral" end
    if ratio > -0.10 then return "grumpy" end
    return "horrified"
end

--- One line of the mood; the same all day so it does not flicker.
function Cards.Comment(mood)
    local lines = MOODS[mood] or MOODS.neutral
    local day = math.floor(time() / 86400)
    return lines[day % #lines + 1]()
end

-- Cards ------------------------------------------------------------------------------
local function Fmt(copper, opts)
    opts = opts or {}
    opts.abbreviate = true
    return API.Money.Format(copper or 0, opts)
end

local function RegisterCards()
    local Theme = API.Theme
    local C = Theme.colors
    local PART_COLORS = {
        gold = C.gold, auctions = C.teal, items = C.accent,
        speculative = { C.accent[1], C.accent[2], C.accent[3], 0.40 }, other = C.blue,
    }
    local PART_NAMES = {
        gold = function() return L["Gold"] end, auctions = function() return L["Auctions"] end,
        items = function() return L["Items"] end, speculative = function() return L["speculative"] end,
        other = function() return L["Other accounts"] end,
    }
    API.UI:RegisterWidget({
        id = "vault.wealth", order = 5, size = "full", height = 124, events = { "NETWORTH_UPDATED" },
        title = function() return L["Wealth"] end,
        build = function(f)
            f.value = Theme.Text(f, "hero", C.gold)
            f.value:SetPoint("TOPLEFT", 12, -28)
            f.change = Theme.Text(f, "title", C.text)
            f.change:SetPoint("BOTTOMLEFT", f.value, "BOTTOMRIGHT", 12, 3)
            f.period = Theme.Text(f, 10, C.textDim)
            f.period:SetPoint("BOTTOMLEFT", f.change, "BOTTOMRIGHT", 6, 1)
            f.chart = API.Widgets.LineChart(f, { width = 300, height = 70, color = C.gold, fill = true,
                tooltip = function(i)
                    local key = f.keys and f.keys[i]
                    local v = f.values and f.values[i]
                    if not key then return "", {} end
                    return API.Format:Day(key, "long"), { L["Wealth"] .. ": " .. Fmt(v) }
                end })
            f.chart:SetPoint("TOPRIGHT", -12, -30)
            f.chart:SetPoint("BOTTOMRIGHT", -14, 14)
            f.bar = CreateFrame("Frame", nil, f)
            f.bar:SetPoint("TOPLEFT", 12, -66)
            f.bar:SetPoint("RIGHT", f.chart, "LEFT", -24, 0)
            f.bar:SetHeight(12)
            local track = f.bar:CreateTexture(nil, "BACKGROUND")
            track:SetAllPoints()
            track:SetColorTexture(1, 1, 1, 0.05)
            f.segments = {}
            f.legend = Theme.Text(f, 10, C.textDim)
            f.legend:SetPoint("TOPLEFT", f.bar, "BOTTOMLEFT", 0, -8)
            f.legend:SetPoint("RIGHT", f.bar, "RIGHT", 0, 0)
            f.legend:SetWordWrap(true)
            f.legend:SetJustifyV("TOP")
            f.value:EnableMouse(true)
            local hover = CreateFrame("Frame", nil, f)
            hover:SetPoint("TOPLEFT", f.value, "TOPLEFT")
            hover:SetPoint("BOTTOMRIGHT", f.period, "BOTTOMRIGHT")
            hover:EnableMouse(true)
            hover:SetScript("OnEnter", function(self) if ns.VaultUI then ns.VaultUI.WealthTooltip(self) end end)
            hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
            local function Fit(self)
                local w = (self.GetWidth and self:GetWidth()) or 0
                if not w or w <= 0 then w = 900 end
                self.chart:SetWidth(math.floor(math.max(160, math.min(420, w * 0.38))))
                if self.parts then self:LayoutBar() end
            end
            function f:LayoutBar()
                local width = (self.bar.GetWidth and self.bar:GetWidth()) or 0
                if not width or width <= 0 then width = 400 end
                local x = 0
                for i, p in ipairs(self.parts) do
                    local t = self.segments[i]
                    if not t then
                        t = self.bar:CreateTexture(nil, "ARTWORK")
                        self.segments[i] = t
                    end
                    local w = width * p.share
                    t:SetColorTexture(unpack(PART_COLORS[p.key]))
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", self.bar, "TOPLEFT", x, 0)
                    t:SetSize(math.max(0.1, w), 12)
                    t:SetShown(w >= 1)
                    x = x + w
                end
                for i = #self.parts + 1, #self.segments do self.segments[i]:Hide() end
            end
            f:HookScript("OnSizeChanged", Fit)
            f.bar:SetScript("OnSizeChanged", function() if f.parts then f:LayoutBar() end end)
            Fit(f)
        end,
        refresh = function(f, context)
            local r = Current()
            if not r then
                f.value:SetText("-")
                return
            end
            f.value:SetText(Fmt(r.wealth))
            local d = Cards.Deltas(context)
            f.change:SetText(d and Fmt(d.wealthDelta, { color = true, sign = true }) or "")
            f.period:SetText(context.days == 1 and L["today"] or API.Lf("in the last %d days", context.days))
            f.parts = Cards.WealthParts(r)
            f:LayoutBar()
            local legend = {}
            for _, p in ipairs(f.parts) do
                if p.amount > 0 then
                    local c = PART_COLORS[p.key]
                    legend[#legend + 1] = ("%s %s %s %s"):format(Theme.Colorize("\226\150\160", c),
                        PART_NAMES[p.key](), Fmt(p.amount), Theme.Colorize("(" .. API.Format:Percent(p.share) .. ")", C.textDim))
                end
            end
            f.legend:SetText(table.concat(legend, "    "))
            f.values, f.keys = Cards.WealthSeries(context)
            f.chart:SetData(f.values)
        end,
    })
    API.UI:RegisterWidget({
        id = "vault.gallywix", order = 11, size = "third", height = 120, events = { "NETWORTH_UPDATED" },
        build = function(f)
            f.face = f:CreateTexture(nil, "ARTWORK")
            f.face:SetSize(64, 64)
            f.face:SetPoint("LEFT", Theme.space.PAD, 0)
            f.text = Theme.Text(f, "small", C.text)
            f.text:SetPoint("LEFT", f.face, "RIGHT", Theme.space.PAD, 0)
            f.text:SetPoint("RIGHT", f, "RIGHT", -Theme.space.PAD, 0)
            f.text:SetJustifyV("MIDDLE")
        end,
        refresh = function(f, context)
            local level = ns.JealousmeterUI and select(2, ns.JealousmeterUI.Current()) or 0
            f.face:SetTexture(ns.Jealousmeter.Texture(level))
            f.text:SetText('"' .. Cards.Comment(Cards.Mood(Cards.Deltas(context))) .. '"')
        end,
    })
    API.UI:RegisterWidget({
        id = "vault.chars", order = 22, size = "third", height = 160, events = { "NETWORTH_UPDATED" },
        title = function() return L["Gold per character"] end,
        build = function(f)
            f.rows = {}
            for i = 1, MAX_CHARS + 1 do
                local y = -28 - (i - 1) * 18
                local row = {}
                row.bar = f:CreateTexture(nil, "BACKGROUND")
                row.bar:SetPoint("TOPLEFT", 12, y + 1)
                row.bar:SetHeight(16)
                row.name = Theme.Text(f, "small", C.text)
                row.name:SetPoint("TOPLEFT", 16, y - 1)
                row.name:SetPoint("RIGHT", f, "RIGHT", -154, 0)
                row.name:SetWordWrap(false)
                row.gold = Theme.Text(f, "small", C.text)
                row.gold:SetPoint("TOPRIGHT", f, "TOPRIGHT", -80, y - 1)
                row.gold:SetJustifyH("RIGHT")
                row.value = Theme.Text(f, "caption", C.text)
                row.value:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, y - 1)
                row.value:SetWidth(66)
                row.value:SetJustifyH("RIGHT")
                f.rows[i] = row
            end
            f.more = Theme.Text(f, "caption", C.textDim)
            f.more:SetPoint("BOTTOMLEFT", 12, 10)
        end,
        refresh = function(f, context)
            local list = Cards.CharDeltas(context)
            local maxAbs = 1
            for _, e in ipairs(list) do maxAbs = math.max(maxAbs, math.abs(e.delta or 0)) end
            local width = (f.GetWidth and f:GetWidth() or 0)
            if not width or width <= 0 then width = 200 end
            for i, row in ipairs(f.rows) do
                local e = list[i]
                if e then
                    local color = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
                    row.name:SetText(color and ("|c%s%s|r"):format(color.colorStr, e.name) or e.name)
                    row.gold:SetText(Fmt(e.gold))
                    row.value:SetText(e.delta and Fmt(e.delta, { color = true, sign = true }) or CODE.dim .. "-|r")
                    local d = e.delta or 0
                    row.bar:SetShown(d ~= 0)
                    row.bar:SetColorTexture(unpack(d >= 0 and C.accentSoft or C.lossSoft))
                    row.bar:SetWidth(math.max(2, (width - 24) * math.abs(d) / maxAbs))
                else
                    row.name:SetText("")
                    row.gold:SetText("")
                    row.value:SetText("")
                    row.bar:Hide()
                end
            end
            f.more:SetText(#list > #f.rows and API.Lf("%d more", #list - #f.rows) or "")
        end,
    })
end

function Cards.Enable(module)
    vault = module
    RegisterCards()
end
