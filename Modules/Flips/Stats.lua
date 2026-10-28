if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Flips/Stats.lua
-- Statistics per item and in total for a window (days, nil = all time) and an
-- optional character (the buyer of the lot). Sales, ends and write-offs count in
-- the window of their own time, purchases in the window of the purchase:
--   profit   = net revenue - cost of the sold units - lost deposits - write-offs
--   roi      = profit / (cost of the sold units + written-off cost)
--   saleRate = sold auctions / (sold + expired + cancelled auctions)
--   holdTime = average seconds from purchase to sale, by quantity
-- open stock (quantity, cost) is always the current one. Ignored lots never count;
-- folded aggregates (Retention) count by their day.
local _, ns = ...

local Stats = {}
ns.Stats = Stats

local module

local function New()
    return { bought = 0, spent = 0, soldQty = 0, gross = 0, revenue = 0, cost = 0, depositLost = 0,
        writeoffQty = 0, writeoff = 0, sold = 0, expired = 0, cancelled = 0, holdSum = 0, openQty = 0, openCost = 0 }
end

local function Finish(s)
    s.profit = s.revenue - s.cost - s.depositLost - s.writeoff
    local invested = s.cost + s.writeoff
    s.roi = invested > 0 and s.profit / invested or nil
    local attempts = s.sold + s.expired + s.cancelled
    s.saleRate = attempts > 0 and s.sold / attempts or nil
    s.holdTime = s.soldQty > 0 and s.holdSum / s.soldQty or nil
    return s
end

local function Day(t) return date("%Y-%m-%d", t) end

local function Cutoff(days, now)
    return days and ((now or time()) - days * 86400) or nil
end

--- Add one lot to s (sales, ends and write-offs from cutoff on).
local function AddLot(s, lot, cutoff, now)
    if lot.state == "ignored" then return end
    local inWindow = function(t) return not cutoff or t >= cutoff end
    if inWindow(lot.time) and lot.state ~= "candidate" then
        s.bought = s.bought + lot.qty
        s.spent = s.spent + lot.qty * lot.unit
    end
    for _, sale in ipairs(lot.sales) do
        if inWindow(sale.time) then
            s.sold = s.sold + 1
            s.soldQty = s.soldQty + sale.qty
            s.gross = s.gross + sale.gross
            s.revenue = s.revenue + sale.net
            s.cost = s.cost + sale.cost
            s.holdSum = s.holdSum + sale.qty * (sale.time - lot.time)
            if not s.lastSale or sale.time > s.lastSale then s.lastSale = sale.time end
        end
    end
    for _, e in ipairs(lot.ends) do
        if inWindow(e.time) then
            if e.kind == "cancelled" then s.cancelled = s.cancelled + 1 else s.expired = s.expired + 1 end
            s.depositLost = s.depositLost + (e.deposit or 0)
        end
    end
    local w = lot.writeoff
    if w and inWindow(w.time) then
        s.writeoffQty = s.writeoffQty + w.qty
        s.writeoff = s.writeoff + math.floor(w.qty * lot.unit + 0.5)
    end
    if ns.Store.Open(lot, now) and lot.state == "active" then
        s.openQty = s.openQty + lot.remaining
        s.openCost = s.openCost + math.floor(lot.remaining * lot.unit + 0.5)
    end
end

local SUMS = { "bought", "spent", "soldQty", "gross", "revenue", "cost", "depositLost", "writeoffQty", "writeoff",
    "sold", "expired", "cancelled", "holdSum" }

local function AddAggregate(s, a)
    for _, f in ipairs(SUMS) do s[f] = s[f] + (a[f] or 0) end
end
Stats.SUMS = SUMS

--- { key -> stats } for filter = { days, char }.
function Stats.ByItem(filter)
    filter = filter or {}
    local now = time()
    local cutoff = Cutoff(filter.days, now)
    local map = {}
    local function For(key)
        local s = map[key]
        if not s then
            s = New()
            s.key = key
            map[key] = s
        end
        return s
    end
    local root = module.db.root
    for _, lot in ipairs(root.lots) do
        if not filter.char or lot.char == filter.char then AddLot(For(lot.key), lot, cutoff, now) end
    end
    local fromDay = cutoff and Day(cutoff) or nil
    for day, byKey in pairs(root.aggregates) do
        if not fromDay or day >= fromDay then
            for key, byChar in pairs(byKey) do
                for char, a in pairs(byChar) do
                    if not filter.char or char == filter.char then AddAggregate(For(key), a) end
                end
            end
        end
    end
    for _, s in pairs(map) do Finish(s) end
    return map
end

--- Statistics of one item, or nil without flips.
function Stats.Item(key, days)
    local s = Stats.ByItem({ days = days })[key]
    if not s or (s.bought == 0 and s.soldQty == 0 and s.openQty == 0) then return nil end
    return s
end

--- Totals over all items plus the item list: { totals, items = { stats, ... } }.
function Stats.Summary(filter)
    local totals = New()
    local items = {}
    for _, s in pairs(Stats.ByItem(filter)) do
        if s.bought > 0 or s.soldQty > 0 or s.openQty > 0 or s.writeoffQty > 0 then
            items[#items + 1] = s
            AddAggregate(totals, s)
            totals.openQty = totals.openQty + s.openQty
            totals.openCost = totals.openCost + s.openCost
        end
    end
    totals.items = #items
    return { totals = Finish(totals), items = items }
end

--- Profit per day for the last `days` days, oldest first: { { day, profit, revenue, cost } }.
function Stats.Daily(days, filter)
    filter = filter or {}
    local now = time()
    local cutoff = Cutoff(days or 30, now)
    local byDay = {}
    local function Bucket(t)
        local d = Day(t)
        local b = byDay[d]
        if not b then
            b = { day = d, profit = 0, revenue = 0, cost = 0 }
            byDay[d] = b
        end
        return b
    end
    for _, lot in ipairs(module.db.root.lots) do
        if lot.state ~= "ignored" and (not filter.char or lot.char == filter.char) then
            for _, sale in ipairs(lot.sales) do
                if sale.time >= cutoff then
                    local b = Bucket(sale.time)
                    b.revenue = b.revenue + sale.net
                    b.cost = b.cost + sale.cost
                    b.profit = b.profit + sale.net - sale.cost
                end
            end
            for _, e in ipairs(lot.ends) do
                if e.time >= cutoff then
                    local b = Bucket(e.time)
                    b.profit = b.profit - (e.deposit or 0)
                end
            end
            local w = lot.writeoff
            if w and w.time >= cutoff then
                local b = Bucket(w.time)
                local loss = math.floor(w.qty * lot.unit + 0.5)
                b.cost = b.cost + loss
                b.profit = b.profit - loss
            end
        end
    end
    local fromDay = Day(cutoff)
    for day, byKey in pairs(module.db.root.aggregates) do
        if day >= fromDay then
            for _, byChar in pairs(byKey) do
                for char, a in pairs(byChar) do
                    if not filter.char or char == filter.char then
                        local b = byDay[day] or { day = day, profit = 0, revenue = 0, cost = 0 }
                        byDay[day] = b
                        b.revenue = b.revenue + (a.revenue or 0)
                        b.cost = b.cost + (a.cost or 0) + (a.writeoff or 0)
                        b.profit = b.profit + (a.revenue or 0) - (a.cost or 0) - (a.depositLost or 0) - (a.writeoff or 0)
                    end
                end
            end
        end
    end
    local list = {}
    for _, b in pairs(byDay) do list[#list + 1] = b end
    table.sort(list, function(a, b) return a.day < b.day end)
    return list
end

function Stats.Enable(m)
    module = m
end
