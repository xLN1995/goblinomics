if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Flips/Engine.lua
-- Live events into lots. Purchases come from the Ledger's AH/purchase bookings
-- (the same source as the Workshop's purchase lots), posts, sales, expired and
-- cancelled auctions from LEDGER_AH_EVENT. Every step takes its time and
-- character, so the backfill replays history through the same functions.
--   post      the oldest open lots of the item (FIFO, up to the posted quantity)
--             become flips: posts + 1
--   sale      FIFO over the open lots: cost = units x purchase price, gross and
--             net (after the cut) split by quantity; empty lots are closed
--   expired / cancelled
--             FIFO over the posted lots: an end with the lost deposit by quantity
-- Units without a lot (crafted, farmed, older stock) are no flip and ignored.
local _, ns = ...

local Engine = {}
ns.Engine = Engine

local Store = ns.Store

local module
local lastSale = nil   -- { key, matched } for the Ledger's sale tag

local function Round(x) return math.floor(x + 0.5) end

--- Take up to quantity from lots (oldest first): calls fn(lot, n) per lot, returns the total taken.
local function Each(lots, quantity, fn)
    local left = quantity
    for _, lot in ipairs(lots) do
        if left <= 0 then break end
        local n = math.min(lot.remaining, left)
        if n > 0 then
            fn(lot, n)
            left = left - n
        end
    end
    return quantity - left
end

function Engine.Purchase(key, quantity, total, t, char)
    if not quantity or quantity <= 0 or not total or total <= 0 then return nil end
    return Store.Add(key, quantity, total / quantity, t, char)
end

function Engine.Post(key, quantity, t)
    return Each(Store.Matching(key, t or time()), quantity or 1, function(lot)
        lot.state = "active"
        lot.posts = lot.posts + 1
    end)
end

--- Expired or cancelled auction (kind) with its lost deposit.
function Engine.Ended(kind, key, quantity, deposit, t)
    quantity = quantity or 1
    local posted = {}
    for _, lot in ipairs(Store.Matching(key, t or time())) do
        if lot.state == "active" then posted[#posted + 1] = lot end
    end
    t = t or time()
    return Each(posted, quantity, function(lot, n)
        lot.ends[#lot.ends + 1] = { time = t, kind = kind == "cancelled" and "cancelled" or "expired",
            deposit = Round((deposit or 0) * n / quantity) }
    end)
end

function Engine.Sale(key, quantity, gross, net, t, char)
    quantity = quantity or 1
    t = t or time()
    return Each(Store.Matching(key, t), quantity, function(lot, n)
        lot.state = "active"
        lot.remaining = lot.remaining - n
        lot.sales[#lot.sales + 1] = { time = t, char = char, qty = n, gross = Round((gross or 0) * n / quantity),
            net = Round((net or gross or 0) * n / quantity), cost = Round(n * lot.unit) }
        if lot.remaining <= 0 then lot.state = "closed" end
    end)
end

--- A Ledger booking: AH purchases with item and quantity become candidate lots.
function Engine.FromBooking(p)
    if not (p and p.category == "AH" and p.sub == "purchase" and p.itemKey) then return end
    if (p.quantity or 0) <= 0 or (p.amount or 0) >= 0 or p.imported then return end
    if Engine.Purchase(p.itemKey, p.quantity, -p.amount, p.time, p.char) then ns.Changed() end
end

function Engine.FromAuctionEvent(p)
    if not (p and p.itemKey) then return end
    local char = module.db.charKey
    local n = 0
    if p.kind == "post" then
        n = Engine.Post(p.itemKey, p.quantity)
    elseif p.kind == "sale" then
        n = Engine.Sale(p.itemKey, p.quantity, p.amount, p.net, time(), char)
        lastSale = { key = p.itemKey, matched = n }
    elseif p.kind == "expired" or p.kind == "cancelled" then
        n = Engine.Ended(p.kind, p.itemKey, p.quantity, p.deposit)
    end
    if n > 0 then ns.Changed() end
end

--- Ledger sale tag: "Flip" when the sale just logged was matched against lots.
function Engine.SaleTag(key)
    local s = lastSale
    lastSale = nil
    if module and module:IsEnabled() and s and s.key == key and s.matched > 0 then return "Flip" end
    return nil
end

function Engine.Enable(m)
    module = m
    m:On("LEDGER_TRANSACTION", function(_, p) if not p.merged then Engine.FromBooking(p) end end)
    m:On("LEDGER_TRANSACTION_ITEM", function(_, p) Engine.FromBooking(p) end)
    m:On("LEDGER_AH_EVENT", function(_, p) Engine.FromAuctionEvent(p) end)
    if not Engine.taggerRegistered and ns.API.Ledger and ns.API.Ledger.RegisterSaleTagger then
        ns.API.Ledger:RegisterSaleTagger(Engine.SaleTag)
        Engine.taggerRegistered = true
    end
end
