if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/Recompute.lua
-- One-off rebuild after the switch to purchase prices: replays the
-- Ledger's purchases and auction sales of the last 90 days together with the
-- stored craft records in time order, recomputes every craft's cost (purchase
-- lots, crafted intermediates, else the market price stored at the time of the
-- craft), and rebuilds the purchase lots, crafted lots, sale matches and the
-- own cost of crafting orders. Runs as a job after login, once per VERSION,
-- only when the Ledger module is loaded.
local _, ns = ...

local Recompute = {}
ns.Recompute = Recompute

local VERSION = 3   -- 2: salvage yields used in crafts (transfers); 3: sales repaired by the Ledger (schema 3)
local WINDOW_DAYS = 90
local ORDER = { purchase = 1, craft = 2, sale = 3 }

local module

local function RecomputeCraft(r)
    local consumed, returned, market = {}, {}, {}
    local hasReturns = false
    for _, g in ipairs(r.reagents or {}) do
        consumed[g[1]] = (consumed[g[1]] or 0) + g[2]
        market[g[1]] = g[4] or g[3]
        if g[7] then
            hasReturns = true
            if g[7] > 0 then returned[g[1]] = (returned[g[1]] or 0) + g[7] end
        end
    end
    local lines, cost, saved, incomplete = ns.Reagents.Cost(consumed, returned, { time = r.time, market = market })
    if not hasReturns then
        -- old records: only the value of the returns is known
        saved = r.saved or 0
        cost = cost - saved
    end
    r.reagents = ns.Reagents.Compact(lines)
    if r.costSource ~= "craftsim" then
        r.cost = cost
        r.saved = saved
        r.incomplete = incomplete or nil
    end
end

local function UpdateOrder(r)
    for _, o in ipairs(module.db.root.orders) do
        if o.craft == r.id and not o.manual then
            o.cost = r.cost or 0
            if o.status == "fulfilled" then o.profit = (o.commission or 0) + (o.rewards or 0) - o.cost end
        end
    end
end

--- Replay and rebuild; returns false without the Ledger.
function Recompute.Run(now)
    local ledger = ns.API.Ledger
    if not ledger then return false end
    local root = module.db.root
    now = now or time()
    local cutoff = now - WINDOW_DAYS * 86400
    local events = {}
    for _, row in ipairs(ledger:Query({ from = cutoff })) do
        if row.itemKey and (row.quantity or 0) > 0 then
            if (row.category == "AH" and row.sub == "purchase") or (row.category == "Vendor" and row.sub == "buy") then
                events[#events + 1] = { t = row.time, kind = "purchase", row = row }
            elseif row.category == "AH" and row.sub == "sale" then
                events[#events + 1] = { t = row.time, kind = "sale", row = row }
            end
        end
    end
    local craftIds = {}
    for _, r in ipairs(root.crafts) do
        events[#events + 1] = { t = r.time, kind = "craft", r = r, id = r.id }
        craftIds[r.id] = true
    end
    table.sort(events, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        if ORDER[a.kind] ~= ORDER[b.kind] then return ORDER[a.kind] < ORDER[b.kind] end
        return (a.id or 0) < (b.id or 0)
    end)

    -- keep what belongs to records that are no longer stored in detail
    root.purchases = {}
    local lots, matches = {}, {}
    for _, lot in ipairs(root.lots) do
        if not craftIds[lot.craft] then lots[#lots + 1] = lot end
    end
    for _, m in ipairs(root.matches) do
        if m.time < cutoff then matches[#matches + 1] = m end
    end
    local transfers = {}
    for _, tr in ipairs(root.transfers or {}) do
        if tr.time < cutoff then transfers[#transfers + 1] = tr end
    end
    root.lots, root.matches, root.transfers = lots, matches, transfers

    for i, e in ipairs(events) do
        if e.kind == "purchase" then
            ns.Purchases.FromBooking(e.row)
        elseif e.kind == "craft" then
            RecomputeCraft(e.r)
            if e.r.kind == "order" then
                UpdateOrder(e.r)
            else
                ns.Lots.Add(e.r)
            end
        else
            local row = e.row
            local matched = ns.Lots.Sell(row.itemKey, row.quantity, row.amount, row.time)
            if matched < row.quantity then ns.Purchases.Take(row.itemKey, row.quantity - matched, row.time) end
        end
        if i % 50 == 0 then ns.API.Yield() end
    end
    ns.Purchases.Prune(now)
    root.recomputed = VERSION
    ns.API.Emit("WORKSHOP_MATCH", { recomputed = true })
    return true
end

function Recompute.Needed()
    return (module.db.root.recomputed or 0) < VERSION and ns.API.Ledger ~= nil
end

function Recompute.Enable(m)
    module = m
    m:After(25, function()
        if Recompute.Needed() then m:RunJob("recompute", function() Recompute.Run() end) end
    end)
end
