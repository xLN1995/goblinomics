if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Flips/Backfill.lua
-- Once, on the first enable: the Ledger's history (AH purchase bookings, up to
-- its raw window, and the auction log, up to 180 days) replayed in time order
-- through the Engine. The log keeps only the gross amount of a sale, so the net
-- is the gross minus the auction house cut; the seller of a past sale is unknown.
local _, ns = ...

local Backfill = {}
ns.Backfill = Backfill

local API = ns.API
local Engine = ns.Engine

Backfill.CUT = 0.05

local module

-- buy before post before the outcome when times are equal
local ORDER = { buy = 1, post = 2, sale = 3, expired = 3, cancelled = 3 }

--- Purchases and auction events, oldest first.
function Backfill.Timeline()
    local list = {}
    for _, row in ipairs(API.Ledger:Query({ category = "AH" })) do
        if row.sub == "purchase" and row.itemKey and row.time and (row.quantity or 0) > 0 and (row.amount or 0) < 0 then
            list[#list + 1] = { time = row.time, kind = "buy", itemKey = row.itemKey, quantity = row.quantity,
                amount = -row.amount, char = row.char }
        end
    end
    for _, e in ipairs(API.Ledger:AuctionEvents()) do
        if e.itemKey and ORDER[e.kind] then list[#list + 1] = e end
    end
    table.sort(list, function(a, b)
        if a.time ~= b.time then return a.time < b.time end
        return ORDER[a.kind] < ORDER[b.kind]
    end)
    return list
end

function Backfill.Apply(e)
    if e.kind == "buy" then
        Engine.Purchase(e.itemKey, e.quantity, e.amount, e.time, e.char)
    elseif e.kind == "post" then
        Engine.Post(e.itemKey, e.quantity, e.time)
    elseif e.kind == "sale" then
        Engine.Sale(e.itemKey, e.quantity, e.amount, math.floor(e.amount * (1 - Backfill.CUT) + 0.5), e.time)
    else
        Engine.Ended(e.kind, e.itemKey, e.quantity, e.deposit, e.time)
    end
end

function Backfill.Run()
    local root = module.db.root
    if root.backfilled or not (API.Ledger and API.Ledger.AuctionEvents) then return end
    root.backfilled = time()
    local timeline = Backfill.Timeline()
    module:RunJob("backfill", function()
        for _, e in ipairs(timeline) do
            Backfill.Apply(e)
            API.Yield()
        end
    end)
end

function Backfill.Enable(m)
    module = m
    m:After(5, Backfill.Run)
end
