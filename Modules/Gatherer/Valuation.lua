if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/Valuation.lua
-- Session value and the session summary format:
--   Market Value = items valued at their market price (not speculative)
--   Vendor       = items worth most at a vendor
--   Speculative  = items with a sale rate below the speculative threshold;
--                  separate line, not in Total and not in GPH
--   Raw Gold     = looted gold
--   Repair       = prorated repair cost (durability used x learned rate)
--   Total        = Market Value + Raw Gold + Vendor - Repair;  GPH = Total per hour
--   Realized     = actual gold delta of the character during the session
local _, ns = ...

local Valuation = {}
ns.Valuation = Valuation

local SEP = " \194\183 "
local RULE = "\226\148\128"   -- box drawing light horizontal

--- data = { items = { [key] = qty }, rawGold, repair, duration, realized }
-- Returns { market, vendor, speculative, rawGold, repair, total, gph, realized,
--           unpriced, items = { { key, quantity, value, bucket }, ... } sorted by value }
function Valuation.Compute(data)
    local Value = ns.API.Value
    local r = {
        market = 0, vendor = 0, speculative = 0, unpriced = 0,
        rawGold = data.rawGold or 0, repair = data.repair or 0, realized = data.realized or 0,
        duration = data.duration or 0, items = {},
    }
    for key, qty in pairs(data.items or {}) do
        local e = Value:Evaluate(key, { quantity = qty })
        local bucket
        if e.tier == "speculative" then
            bucket = "speculative"
            r.speculative = r.speculative + e.total
        elseif e.rule == "vendor" then
            bucket = "vendor"
            r.vendor = r.vendor + e.total
        elseif e.rule == "market" then
            bucket = "market"
            r.market = r.market + e.total
        else
            bucket = "none"
            r.unpriced = r.unpriced + 1
        end
        r.items[#r.items + 1] = { key = key, quantity = qty, value = e.total, bucket = bucket }
    end
    table.sort(r.items, function(a, b)
        if a.value == b.value then
            if a.quantity == b.quantity then return a.key < b.key end
            return a.quantity > b.quantity
        end
        return a.value > b.value
    end)
    r.total = r.market + r.rawGold + r.vendor - r.repair
    r.gph = Valuation.PerHour(r.total, r.duration)
    return r
end

function Valuation.PerHour(amount, duration)
    if not duration or duration <= 0 then return 0 end
    return math.floor(amount * 3600 / duration + 0.5)
end

--- "hh:mm:ss"
function Valuation.FormatDuration(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return ("%02d:%02d:%02d"):format(math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60)
end

--- Whole gold with thousands separators, e.g. "182,400g" (plain text, chat safe);
-- on WoW: Forever gold and silver, e.g. "12g 34s".
function Valuation.Gold(copper)
    copper = copper or 0
    local abs = math.abs(copper)
    if ns.API.Flavor.IsForever() then
        local gold, silver = math.floor(abs / 10000), math.floor(abs % 10000 / 100)
        local text = gold > 0 and (ns.API.Money.Group(gold) .. "g") or ""
        if silver > 0 then text = text .. (gold > 0 and " " or "") .. silver .. "s" end
        if text == "" then return "0g" end
        return (copper < 0 and "-" or "") .. text
    end
    local gold = math.floor(abs / 10000 + 0.5)
    return (copper < 0 and gold > 0 and "-" or "") .. ns.API.Money.Group(gold) .. "g"
end

--- Item display name (client cache), falling back to the key.
function Valuation.ItemName(key)
    local id = key and tonumber(key:match("^i:(%d+)"))
    local name = id and C_Item.GetItemInfo(id)
    return name or key
end

--- Summary lines in the session format: { { label, value }, ..., { rule = true }, ... }
-- summary = { farmName, duration, valuation }
function Valuation.Lines(summary)
    local L = ns.L
    local v = summary.valuation
    local names = {}
    for i = 1, #v.items do
        names[#names + 1] = Valuation.ItemName(v.items[i].key) .. " " .. v.items[i].quantity
    end
    local lines = {
        { L["Farm"], summary.farmName or L["Ad-hoc session"] },
        { L["Duration"], Valuation.FormatDuration(summary.duration) },
        { L["Items"], #names > 0 and table.concat(names, SEP) or "-" },
        { L["Market Value"], Valuation.Gold(v.market) },
        { L["Raw Gold"], Valuation.Gold(v.rawGold) },
        { L["Vendor"], Valuation.Gold(v.vendor) },
    }
    if v.repair ~= 0 then lines[#lines + 1] = { L["Repair"], Valuation.Gold(-v.repair) } end
    lines[#lines + 1] = { rule = true }
    lines[#lines + 1] = { L["Total"], Valuation.Gold(v.total) }
    lines[#lines + 1] = { L["GPH"], Valuation.Gold(v.gph) }
    if v.speculative > 0 then
        lines[#lines + 1] = { L["Speculative (not in total)"], Valuation.Gold(v.speculative) }
    end
    lines[#lines + 1] = { L["Realized"], Valuation.Gold(v.realized) }
    return lines
end

--- Plain text of the summary (one line per entry) for the window and chat.
function Valuation.Text(summary)
    local out = {}
    for _, line in ipairs(Valuation.Lines(summary)) do
        if line.rule then
            out[#out + 1] = RULE:rep(16)
        else
            out[#out + 1] = line[1] .. ": " .. line[2]
        end
    end
    return table.concat(out, "\n")
end
