if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Insights/Data.lua
-- Evaluations for Insights, cached per (from, character) until the ledger, the
-- networth or the workshop changes. Transfers are neutral except in the cash
-- flow, where deposits to and withdrawals from the warband bank are shown.
local _, ns = ...

local Data = {}
ns.Data = Data

local API = ns.API
local cache = {}

local function DayKey(t) return date("%Y-%m-%d", t) end

function Data.Invalidate() wipe(cache) end

local function DayStart(t)
    local d = date("*t", t)
    return time({ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 })
end
Data.DayStart = DayStart

--- Start of the period of `days` days ending today.
function Data.From(days)
    return DayStart(DayStart(time()) - (days - 1) * 86400 + 3600)
end

local function CategoryName(category)
    local L = ns.L
    local names = { AH = L["Auction House"], Vendor = L["Vendor"], Repair = L["Repair"], Quest = L["Quest"],
        Loot = L["Loot"], Crafting = L["Crafting"], Mail = L["Mail"], Transfer = L["Transfer"] }
    return names[category] or L["Other"]
end
Data.CategoryName = CategoryName

local function Label(category, tag)
    if tag and tag ~= "" then return tag end
    return CategoryName(category)
end

--- All bookings of the period (raw and aggregated), optionally of one character:
-- { { day, char, category, tag, amount, itemKey, quantity } }
function Data.Bookings(from, char)
    local key = "b|" .. from .. "|" .. (char or "")
    if cache[key] then return cache[key] end
    local list = {}
    if API.Ledger then
        local fromKey = DayKey(from)
        for _, r in ipairs(API.Ledger:Query({ from = from })) do
            if not char or r.char == char then
                list[#list + 1] = { day = r.day, time = r.time, char = r.char, category = r.category, tag = r.tag,
                    amount = r.amount, itemKey = r.itemKey, quantity = r.quantity, sub = r.sub }
            end
        end
        if API.Ledger.Aggregates then
            for _, a in ipairs(API.Ledger:Aggregates(fromKey)) do
                if not char or a.char == char then list[#list + 1] = a end
            end
        end
    end
    cache[key] = list
    return list
end

--- Income and expenses (without transfers) between two times: { income, expense, net }.
function Data.Totals(from, to, char)
    local key = "t|" .. from .. "|" .. to .. "|" .. (char or "")
    if cache[key] then return cache[key] end
    local fromKey, toKey = DayKey(from), DayKey(to)
    local t = { income = 0, expense = 0 }
    for _, b in ipairs(Data.Bookings(from, char)) do
        if b.day >= fromKey and b.day < toKey and b.category ~= "Transfer" then
            if b.amount >= 0 then t.income = t.income + b.amount else t.expense = t.expense + b.amount end
        end
    end
    t.net = t.income + t.expense
    cache[key] = t
    return t
end

--- Latest recorded wealth on or before a day key (nil when none).
function Data.WealthAt(dayKey)
    if not API.Vault then return nil end
    local best, bestKey
    for key, h in pairs(API.Vault:History()) do
        if key <= dayKey and h.wealth and (not bestKey or key > bestKey) then best, bestKey = h.wealth, key end
    end
    return best
end

--- Key figures of the last `days` days and of the same number of days before:
-- { income, expense, net, wealth, wealthChange, prev = { income, expense, net, wealthChange } }
function Data.Period(days, char)
    local from = Data.From(days)
    local to = DayStart(DayStart(time()) + 86400 + 3600)
    local prevFrom = DayStart(from - days * 86400 + 3600)
    local cur, prev = Data.Totals(from, to, char), Data.Totals(prevFrom, from, char)
    local p = { income = cur.income, expense = cur.expense, net = cur.net,
        prev = { income = prev.income, expense = prev.expense, net = prev.net } }
    local current = API.Vault and API.Vault:Current()
    if current then
        p.wealth = current.wealth
        local atStart = Data.WealthAt(DayKey(from - 3600))
        local atPrevStart = Data.WealthAt(DayKey(prevFrom - 3600))
        if atStart then p.wealthChange = current.wealth - atStart end
        if atStart and atPrevStart then p.prev.wealthChange = atStart - atPrevStart end
    end
    return p
end

--- Change against the previous value in percent (nil when there is nothing to compare).
function Data.Change(value, previous)
    if not value or not previous or previous == 0 then return nil end
    return (value - previous) / math.abs(previous) * 100
end

--- Per hour of one day (from = day start): { { hour, income, expense, net } } x 24.
function Data.Hours(from, char)
    local list = {}
    for h = 0, 23 do list[h + 1] = { hour = h, income = 0, expense = 0, net = 0 } end
    local key = DayKey(from + 3600)
    for _, b in ipairs(Data.Bookings(from, char)) do
        if b.day == key and b.time and b.category ~= "Transfer" then
            local e = list[tonumber(date("%H", b.time)) + 1]
            if b.amount >= 0 then e.income = e.income + b.amount else e.expense = e.expense + b.amount end
            e.net = e.income + e.expense
        end
    end
    return list
end

--- Bookings of one day (from = day start), newest first.
function Data.DayBookings(from, char)
    local list = {}
    local key = DayKey(from + 3600)
    for _, b in ipairs(Data.Bookings(from, char)) do
        if b.day == key and b.time then list[#list + 1] = b end
    end
    table.sort(list, function(a, b) return a.time > b.time end)
    return list
end

--- Label of a booking (tag or category).
function Data.Label(b) return Label(b.category, b.tag) end

--- Per day (oldest first): { { key, time, income, expense, net } }
function Data.Days(days, char)
    local from = Data.From(days)
    local byDay = {}
    for _, b in ipairs(Data.Bookings(from, char)) do
        if b.category ~= "Transfer" then
            local d = byDay[b.day]
            if not d then
                d = { income = 0, expense = 0 }
                byDay[b.day] = d
            end
            if b.amount >= 0 then d.income = d.income + b.amount else d.expense = d.expense + b.amount end
        end
    end
    local list = {}
    for i = 0, days - 1 do
        local t = from + i * 86400 + 3600
        local key = DayKey(t)
        local d = byDay[key] or { income = 0, expense = 0 }
        list[#list + 1] = { key = key, time = t, income = d.income, expense = d.expense, net = d.income + d.expense }
    end
    return list
end

--- Wealth per day from the Vault history (oldest first, gaps skipped); with a
-- character only the days that recorded it (per character since M7).
function Data.Wealth(days, char)
    local list = {}
    if not API.Vault then return list end
    local history = API.Vault:History()
    local from = Data.From(days)
    for i = 0, days - 1 do
        local t = from + i * 86400 + 3600
        local h = history[DayKey(t)]
        if h and char then h = h.chars and h.chars[char] end
        if h and h.wealth then list[#list + 1] = { key = DayKey(t), time = t, wealth = h.wealth, gold = h.gold } end
    end
    local current = API.Vault:Current()
    if current and char then current = current.chars and current.chars[char] end
    if current then
        local today = DayKey(time())
        if list[#list] and list[#list].key == today then
            list[#list].wealth, list[#list].gold = current.wealth, current.gold
        else
            list[#list + 1] = { key = today, time = time(), wealth = current.wealth, gold = current.gold }
        end
    end
    return list
end

--- Top incomes and expenses by source (tag or category; AH and vendor by item):
-- incomes, expenses = { { label, amount, itemKey } } sorted by size
function Data.Top(days, char, n)
    local incomes, expenses = {}, {}
    for _, b in ipairs(Data.Bookings(Data.From(days), char)) do
        if b.category ~= "Transfer" then
            local byItem = b.itemKey and (b.category == "AH" or b.category == "Vendor")
            local label = byItem and b.itemKey or Label(b.category, b.tag)
            local map = b.amount >= 0 and incomes or expenses
            local e = map[label]
            if not e then
                e = { label = label, amount = 0, itemKey = byItem and b.itemKey or nil }
                map[label] = e
            end
            e.amount = e.amount + b.amount
        end
    end
    local function Sorted(map, desc)
        local list = {}
        for _, e in pairs(map) do list[#list + 1] = e end
        table.sort(list, function(a, b)
            if a.amount ~= b.amount then
                if desc then return a.amount > b.amount end
                return a.amount < b.amount
            end
            return a.label < b.label
        end)
        for i = #list, (n or 5) + 1, -1 do list[i] = nil end
        return list
    end
    return Sorted(incomes, true), Sorted(expenses, false)
end

--- Cash flow of the period:
-- { sources = { {label, amount} }, chars = { {label, char, income, outgo} },
--   sinks = { {label, amount} }, links = { {from, to, amount} } }
-- sources: income by category/tag and withdrawals from the warband bank;
-- sinks: expenses by category, deposits to the warband bank and "kept".
function Data.Flow(days)
    local L = ns.L
    local from = Data.From(days)
    local sources, sinks, chars, links = {}, {}, {}, {}
    local function Add(map, label, amount)
        map[label] = (map[label] or 0) + amount
    end
    local function Link(fromLabel, toLabel, amount)
        local key = fromLabel .. ">" .. toLabel
        local l = links[key]
        if not l then
            l = { from = fromLabel, to = toLabel, amount = 0 }
            links[key] = l
        end
        l.amount = l.amount + amount
    end
    local WARBAND = L["Warband bank"]
    local KEPT = L["Kept"]
    -- older data books both sides of a warband transfer as "warbank": equal
    -- opposite amounts of one character on one day cancel out
    local bookings, pairsSeen = {}, {}
    for _, b in ipairs(Data.Bookings(from, nil)) do
        if b.category == "Transfer" and b.sub ~= "warband" then
            local key = (b.char or "") .. "|" .. b.day .. "|" .. math.abs(b.amount)
            local other = pairsSeen[key]
            if other and other.amount == -b.amount then
                other.cancelled = true
                pairsSeen[key] = nil
            else
                pairsSeen[key] = b
                bookings[#bookings + 1] = b
            end
        elseif not (b.category == "Transfer" and b.sub == "warband") then
            bookings[#bookings + 1] = b
        end
    end
    for _, b in ipairs(bookings) do if not b.cancelled then
        local charLabel = b.char and (b.char:match("^([^%-]+)") or b.char) or "?"
        local c = chars[charLabel]
        if not c then
            c = { label = charLabel, char = b.char, income = 0, outgo = 0 }
            chars[charLabel] = c
        end
        if b.category == "Transfer" then
            if b.sub == "warbank" or b.sub == nil then
                if b.amount < 0 then
                    Add(sinks, WARBAND, -b.amount); Link(charLabel, WARBAND, -b.amount)
                    c.outgo = c.outgo - b.amount
                elseif b.amount > 0 then
                    Add(sources, WARBAND, b.amount); Link(WARBAND, charLabel, b.amount)
                    c.income = c.income + b.amount
                end
            end
        elseif b.amount >= 0 then
            local label = Label(b.category, b.tag)
            Add(sources, label, b.amount); Link(label, charLabel, b.amount)
            c.income = c.income + b.amount
        else
            local label = CategoryName(b.category)
            Add(sinks, label, -b.amount); Link(charLabel, label, -b.amount)
            c.outgo = c.outgo - b.amount
        end
    end end
    for label, c in pairs(chars) do
        local kept = c.income - c.outgo
        if kept > 0 then
            Add(sinks, KEPT, kept); Link(label, KEPT, kept)
            c.outgo = c.outgo + kept
        end
    end
    local function Sorted(map)
        local list = {}
        for label, amount in pairs(map) do list[#list + 1] = { label = label, amount = amount } end
        table.sort(list, function(a, b) return a.amount > b.amount end)
        return list
    end
    local charList = {}
    for _, c in pairs(chars) do
        if c.income > 0 or c.outgo > 0 then charList[#charList + 1] = c end
    end
    table.sort(charList, function(a, b) return math.max(a.income, a.outgo) > math.max(b.income, b.outgo) end)
    local linkList = {}
    for _, l in pairs(links) do linkList[#linkList + 1] = l end
    return { sources = Sorted(sources), chars = charList, sinks = Sorted(sinks), links = linkList }
end

--- Report for a day (offset 0 = today) or a week (Monday to Sunday, offset 0 = this week),
-- optionally of one character. r.previous holds the key figures one period
-- earlier; r.days the 7 days of a week, r.hours the 24 hours of a day.
function Data.Report(kind, offset, char, noPrevious)
    local now = time()
    local from, to
    if kind == "week" then
        local weekday = (tonumber(date("%w", now)) + 6) % 7
        from = DayStart(DayStart(now) - weekday * 86400 + 3600) - (offset or 0) * 7 * 86400
        from = DayStart(from + 3600)
        to = DayStart(from + 7 * 86400 + 3600)
    else
        from = DayStart(DayStart(now) - (offset or 0) * 86400 + 3600)
        to = DayStart(from + 86400 + 3600)
    end
    local r = { kind = kind, from = from, to = to, income = 0, expense = 0, incomes = {}, expenses = {} }
    local fromKey, toKey = DayKey(from), DayKey(to)
    local incomes, expenses = {}, {}
    for _, b in ipairs(Data.Bookings(from, char)) do
        if b.day >= fromKey and b.day < toKey and b.category ~= "Transfer" then
            local label = Label(b.category, b.tag)
            if b.amount >= 0 then
                r.income = r.income + b.amount
                incomes[label] = (incomes[label] or 0) + b.amount
            else
                r.expense = r.expense + b.amount
                expenses[label] = (expenses[label] or 0) + b.amount
            end
        end
    end
    for label, amount in pairs(incomes) do r.incomes[#r.incomes + 1] = { label = label, amount = amount } end
    for label, amount in pairs(expenses) do r.expenses[#r.expenses + 1] = { label = label, amount = amount } end
    table.sort(r.incomes, function(a, b) return a.amount > b.amount end)
    table.sort(r.expenses, function(a, b) return a.amount < b.amount end)
    r.net = r.income + r.expense
    -- wealth is recorded for all characters together
    if API.Vault and not char then
        local history = API.Vault:History()
        local before = history[DayKey(from - 3600)]
        local last = history[DayKey(to - 3600)]
        if to > now and API.Vault:Current() then last = API.Vault:Current() end
        if before and last and before.wealth and last.wealth then r.wealthChange = last.wealth - before.wealth end
    end
    if API.Workshop then
        local b = API.Workshop:Breakdown({ from = from, to = to, char = char })
        r.crafting = b and b.total
    end
    if API.Flips then
        local f = API.Flips:Summary({ from = from, to = to, char = char })
        r.flips = f and f.totals.items > 0 and f.totals.profit or nil
    end
    if API.Gatherer then
        local sessions, total = 0, 0
        for _, s in ipairs(API.Gatherer:Summaries(from)) do
            if (s.started or 0) < to and (not char or s.char == char) then
                sessions, total = sessions + 1, total + (s.total or 0)
            end
        end
        r.sessions, r.farmed = sessions, total
    end
    if kind == "week" then
        local byDay = {}
        for _, b in ipairs(Data.Bookings(from, char)) do
            if b.day >= fromKey and b.day < toKey and b.category ~= "Transfer" then
                local d = byDay[b.day] or { income = 0, expense = 0 }
                byDay[b.day] = d
                if b.amount >= 0 then d.income = d.income + b.amount else d.expense = d.expense + b.amount end
            end
        end
        r.days = {}
        for i = 0, 6 do
            local t = from + i * 86400 + 3600
            local d = byDay[DayKey(t)] or { income = 0, expense = 0 }
            r.days[i + 1] = { key = DayKey(t), time = t, income = d.income, expense = d.expense, net = d.income + d.expense }
        end
    else
        r.hours = Data.Hours(from, char)
        r.bookings = Data.DayBookings(from, char)
    end
    if not noPrevious then r.previous = Data.Report(kind, (offset or 0) + 1, char, true) end
    return r
end

function Data.Enable(module)
    for _, event in ipairs({ "LEDGER_CHANGED", "NETWORTH_UPDATED", "WORKSHOP_MATCH", "WORKSHOP_ORDER", "FLIPS_CHANGED" }) do
        module:On(event, Data.Invalidate)
    end
end
