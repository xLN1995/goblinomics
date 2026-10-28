if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Flips/Store.lua
-- Account-wide purchase lots in root.lots, oldest first:
--   { id, key, char, time, qty, unit, state, remaining, posts,
--     sales = { { time, char, qty, gross, net, cost } },
--     ends = { { time, kind = "expired"|"cancelled", deposit } },
--     writeoff = { time, qty, kind } }
-- state: "candidate" (bought, not posted yet), "active" (posted at least once),
-- "closed" (nothing left), "ignored" (marked as no flip). Candidates older than
-- candidateDays take no part in the FIFO; Retention drops them.
local _, ns = ...

local Store = {}
ns.Store = Store

local module

local function Lots() return module.db.root.lots end

local function NextId()
    local root = module.db.root
    local id = root.nextId
    root.nextId = id + 1
    return id
end

--- Add a candidate lot (quantity > 0, unit price in copper); returns the lot.
function Store.Add(key, quantity, unit, t, char)
    if not key or not quantity or quantity <= 0 or not unit or unit < 0 then return nil end
    if Store.IsIgnoredKey(key) then return nil end
    local lot = { id = NextId(), key = key, char = char, time = t or time(), qty = quantity, unit = unit,
        state = "candidate", remaining = quantity, posts = 0, sales = {}, ends = {} }
    local lots = Lots()
    -- imported and backfilled purchases may be older than the newest lot
    local i = #lots
    while i > 0 and lots[i].time > lot.time do i = i - 1 end
    table.insert(lots, i + 1, lot)
    return lot
end

--- Whether a lot takes part in the FIFO at time t.
function Store.Open(lot, t)
    if lot.remaining <= 0 or lot.time > t then return false end
    if lot.state == "active" then return true end
    return lot.state == "candidate" and t - lot.time <= module.db.settings.candidateDays * 86400
end

--- Open lots of key at time t, oldest first (the tables themselves).
function Store.Matching(key, t)
    local list = {}
    if not key then return list end
    for _, lot in ipairs(Lots()) do
        if lot.key == key and Store.Open(lot, t) then list[#list + 1] = lot end
    end
    return list
end

function Store.Claims(key)
    return #Store.Matching(key, time()) > 0
end

--- Copies of the open lots of key, oldest first.
function Store.OpenLots(key)
    local list = {}
    for _, lot in ipairs(Store.Matching(key, time())) do
        local copy = {}
        for k, v in pairs(lot) do copy[k] = v end
        list[#list + 1] = copy
    end
    return list
end

function Store.ById(id)
    for _, lot in ipairs(Lots()) do
        if lot.id == id then return lot end
    end
    return nil
end

--- Mark a lot as no flip: it leaves the FIFO and the statistics.
function Store.Ignore(id)
    local lot = Store.ById(id)
    if lot then lot.state = "ignored" end
    return lot
end

--- Leave an item out for good: its lots become ignored, new purchases are not tracked.
function Store.IgnoreKey(key)
    local root = module.db.root
    root.ignoredKeys[key] = true
    for _, lot in ipairs(root.lots) do
        if lot.key == key then lot.state = "ignored" end
    end
end

function Store.IsIgnoredKey(key)
    return module.db.root.ignoredKeys[key] == true
end

--- Track an ignored item again (from now on; old lots stay ignored).
function Store.UnignoreKey(key)
    module.db.root.ignoredKeys[key] = nil
end

--- Write off what is left of a lot (vendored, used, lost): the cost counts as loss.
function Store.WriteOff(id, kind, t)
    local lot = Store.ById(id)
    if not lot or lot.remaining <= 0 or lot.state == "ignored" then return nil end
    lot.writeoff = { time = t or time(), qty = lot.remaining, kind = kind or "loss" }
    lot.remaining = 0
    lot.state = "closed"
    return lot
end

function Store.Enable(m)
    module = m
end
