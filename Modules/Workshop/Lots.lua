if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/Lots.lua
-- Crafted items as FIFO lots { id, key, qty, unit, time, craft, recipe, quality, char }
-- (unit = cost per item; several outputs, e.g. salvage, share the cost by their
-- market value). Auction house sales (LEDGER_AH_EVENT "sale", net proceeds)
-- consume the oldest lots of the same item key (else of the same item with
-- other bonus IDs), account-wide; each consumed
-- part becomes a match { time, craft, recipe, key, quality, qty, revenue, cost }.
-- Sales of items that were not crafted are ignored. Lots older than lotDays are
-- no longer open stock but still match a late sale.
local _, ns = ...

local Lots = {}
ns.Lots = Lots

local module

local function Root() return module.db.root end

--- Create the lots of a craft record.
function Lots.Add(record)
    local outputs = record.outputs or {}
    if #outputs == 0 then return end
    local values, sum = {}, 0
    for i, o in ipairs(outputs) do
        values[i] = (ns.Reagents.UnitPrice(o[1]) or 0) * o[2]
        sum = sum + values[i]
    end
    for i, o in ipairs(outputs) do
        local share = sum > 0 and values[i] / sum or 1 / #outputs
        local lot = { id = ns.NextId(), key = o[1], qty = o[2], unit = (record.cost or 0) * share / o[2],
            time = record.time, craft = record.id, recipe = record.recipe, quality = o[3], char = record.char,
            kind = record.kind }
        table.insert(Root().lots, lot)
    end
end

--- Consume lots for a sale; returns the matched quantity.
function Lots.Sell(key, quantity, net, t)
    if not key or not quantity or quantity <= 0 then return 0 end
    local lots = Root().lots
    local netUnit = (net or 0) / quantity
    local remaining = quantity
    local matched = 0
    local function Take(same)
        for _, lot in ipairs(lots) do
            if remaining <= 0 then break end
            if lot.qty > 0 and same(lot) then
                local take = math.min(lot.qty, remaining)
                lot.qty = lot.qty - take
                remaining = remaining - take
                matched = matched + take
                table.insert(Root().matches, { time = t or time(), craft = lot.craft, recipe = lot.recipe, key = key,
                    quality = lot.quality, qty = take, revenue = netUnit * take, cost = lot.unit * take,
                    char = lot.char, kind = lot.kind })
            end
        end
    end
    Take(function(lot) return lot.key == key end)
    -- then the same item with other bonus IDs: the link of a crafted item in the
    -- bags can differ from the craft result's link
    local base = ns.API.ItemKey.Base(key)
    if remaining > 0 and base then
        Take(function(lot) return ns.API.ItemKey.Base(lot.key) == base end)
    end
    for i = #lots, 1, -1 do
        if lots[i].qty <= 0 then table.remove(lots, i) end
    end
    if matched > 0 then ns.API.Emit("WORKSHOP_MATCH", { key = key, quantity = matched }) end
    return matched
end

--- A crafted item used as a reagent: take up to `quantity` from the oldest lots
-- of key crafted before t; returns taken quantity and their cost. The item
-- leaves the open stock; its cost flows into the new craft.
function Lots.TakeReagent(key, quantity, t)
    t = t or time()
    local lots = Root().lots
    local taken, cost = 0, 0
    for _, lot in ipairs(lots) do
        if taken >= quantity then break end
        if lot.key == key and lot.qty > 0 and lot.time <= t then
            local n = math.min(lot.qty, quantity - taken)
            lot.qty = lot.qty - n
            taken = taken + n
            cost = cost + n * lot.unit
            -- salvage yields used in a craft: the salvage gets their cost share back
            if lot.kind == "salvage" then
                local transfers = Root().transfers
                transfers[#transfers + 1] = { time = t, craft = lot.craft, recipe = lot.recipe, key = key, qty = n,
                    cost = n * lot.unit, char = lot.char }
            end
        end
    end
    for i = #lots, 1, -1 do
        if lots[i].qty <= 0 then table.remove(lots, i) end
    end
    return taken, cost
end

--- Lots still counted as open stock (younger than lotDays).
function Lots.Open()
    local cutoff = time() - module.db.settings.lotDays * 86400
    local open = {}
    for _, lot in ipairs(Root().lots) do
        if lot.time >= cutoff then open[#open + 1] = lot end
    end
    return open
end

local function OnAuctionEvent(_, p)
    if p.kind ~= "sale" then return end
    local quantity = p.quantity or 1
    local matched = Lots.Sell(p.itemKey, quantity, p.net or p.amount)
    -- resold bought reagents leave the purchase lots
    if matched < quantity and ns.Purchases then ns.Purchases.Take(p.itemKey, quantity - matched) end
end

function Lots.Enable(m)
    module = m
    m:On("LEDGER_AH_EVENT", OnAuctionEvent)
end
