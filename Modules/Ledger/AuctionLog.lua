if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Ledger/AuctionLog.lua
-- Auction house log (Journalator parity): posts, sales, purchases, expired and
-- cancelled auctions with the lost deposits. Events are small arrays
--   { time, kind, itemKey, quantity, amount, deposit, name }
-- (imported events carry their import id as 8th field, M8).
-- Statistics per item: posted, sold, expired, cancelled, revenue, average sale
-- price per unit, lost deposits and the sale rate
--   sold auctions / (sold + expired + cancelled auctions)
-- for all time or a window in days.
-- Invoices only name the item. Open postings per name { key, remaining, unit,
-- time } resolve the key: the oldest posting with the same unit price wins, else
-- the oldest one with that name. This keeps qualities with the same name apart
-- (reagent qualities, crafted gear). Items posted elsewhere resolve through the
-- client's item cache by name. Expired and cancelled auctions consume
-- postings too. Sales emit LEDGER_AH_EVENT with net proceeds and unit price.
local _, ns = ...

local AuctionLog = {}
ns.AuctionLog = AuctionLog

local API = ns.API
local T, KIND, KEY, QTY, AMT, DEP, NAME, SRC = 1, 2, 3, 4, 5, 6, 7, 8
AuctionLog.F = { T = T, KIND = KIND, KEY = KEY, QTY = QTY, AMT = AMT, DEP = DEP, NAME = NAME, SRC = SRC }

local root
local windowCache = {}   -- days -> { key -> stats }
local OPEN_DAYS = 31     -- mails with sales stay 30 days

local function Invalidate()
    for k in pairs(windowCache) do windowCache[k] = nil end
end

local function Add(kind, key, quantity, amount, deposit, name, net)
    local events = root.ah.events
    events[#events + 1] = { time(), kind, key, quantity or 1, amount or 0, deposit or 0, name }
    Invalidate()
    local q = quantity or 1
    API.Emit("LEDGER_AH_EVENT", { kind = kind, itemKey = key, quantity = quantity, amount = amount,
        net = net or amount, unitPrice = (amount and q > 0) and amount / q or nil })
end

-- Open postings -----------------------------------------------------------------------
local function OpenList(name)
    local list = root.ah.open[name]
    if not list then
        list = {}
        root.ah.open[name] = list
    end
    return list
end

--- Take `quantity` from open postings; pick(entry) chooses the first candidates.
local function Consume(list, quantity, pick)
    local key
    local remaining = quantity
    for pass = 1, 2 do
        for i = 1, #list do
            local e = list[i]
            if remaining > 0 and e.remaining > 0 and (pass == 2 or pick(e)) and (not key or e.key == key) then
                key = key or e.key
                local used = math.min(remaining, e.remaining)
                e.remaining = e.remaining - used
                remaining = remaining - used
            end
        end
        if key then break end
    end
    for i = #list, 1, -1 do
        if list[i].remaining <= 0 then table.remove(list, i) end
    end
    return key
end

--- Key of a sold item from its invoice: open postings, then the last posted key.
function AuctionLog.KeyForSale(name, quantity, amount)
    if not name then return nil end
    local list = root.ah.open[name]
    local unit = (amount and quantity and quantity > 0) and amount / quantity or nil
    local key = list and Consume(list, quantity or 1, function(e)
        return unit ~= nil and e.unit ~= nil and math.abs(e.unit - unit) <= 1
    end)
    key = key or root.ah.names[name]
    if key then return key end
    -- not posted through this addon: the client may still know the item by name
    local link = select(2, C_Item.GetItemInfo(name))
    return link and API.ItemKey.FromLink(link) or nil
end

local function ConsumeKey(key, quantity)
    if not key then return end
    for _, list in pairs(root.ah.open) do
        for _, e in ipairs(list) do
            if e.key == key then
                Consume(list, quantity or 1, function(x) return x.key == key end)
                return
            end
        end
    end
end

local function PruneOpen()
    local cutoff = time() - OPEN_DAYS * 86400
    for name, list in pairs(root.ah.open) do
        for i = #list, 1, -1 do
            if list[i].time < cutoff then table.remove(list, i) end
        end
        if #list == 0 then root.ah.open[name] = nil end
    end
end

local function NameOf(link, key)
    local name = link and C_Item.GetItemInfo(link)
    if name then return name end
    local id = API.ItemKey.ToItemID(key)
    return id and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id) or nil
end

function AuctionLog.KeyForName(name)
    return name and root.ah.names[name] or nil
end

function AuctionLog.Post(key, quantity, deposit, link, unitPrice)
    if not key then return end
    local name = NameOf(link or API.ItemKey.ToItemString(key), key)
    if name then
        root.ah.names[name] = key
        local list = OpenList(name)
        list[#list + 1] = { key = key, remaining = quantity or 1, unit = unitPrice, time = time() }
    end
    if deposit and quantity and quantity > 0 then
        root.ah.deposits[key] = deposit / quantity
    end
    Add("post", key, quantity, 0, deposit, name)
end

function AuctionLog.Sale(key, name, quantity, amount, net)
    Add("sale", key, quantity, amount, 0, name, net)
end

--- Imported events (M8): e = { time, kind, itemKey, quantity, amount, deposit, name }.
function AuctionLog.Import(list, source)
    local events = root.ah.events
    for _, e in ipairs(list) do
        events[#events + 1] = { e.time, e.kind, e.itemKey, e.quantity or 1, e.amount or 0, e.deposit or 0, e.name, source }
        if e.itemKey and e.name and not root.ah.names[e.name] then root.ah.names[e.name] = e.itemKey end
    end
    Invalidate()
    return #list
end

--- Remove the events of an import; returns the number removed.
function AuctionLog.RemoveSource(source)
    local kept, removed = {}, 0
    for _, e in ipairs(root.ah.events) do
        if e[SRC] == source then removed = removed + 1 else kept[#kept + 1] = e end
    end
    root.ah.events = kept
    Invalidate()
    return removed
end

function AuctionLog.Purchase(key, quantity, amount)
    Add("purchase", key, quantity, amount, 0)
end

local function LostDeposit(key, quantity)
    local perUnit = key and root.ah.deposits[key]
    return perUnit and math.floor(perUnit * (quantity or 1) + 0.5) or 0
end

function AuctionLog.Expired(key, quantity)
    ConsumeKey(key, quantity)
    Add("expired", key, quantity, 0, LostDeposit(key, quantity))
end

function AuctionLog.Cancel(key, quantity)
    ConsumeKey(key, quantity)
    Add("cancelled", key, quantity, 0, LostDeposit(key, quantity))
end

local function NewStats()
    return { posted = 0, sold = 0, soldQuantity = 0, expired = 0, cancelled = 0, revenue = 0, depositLost = 0,
        purchases = 0, purchasedQuantity = 0, spent = 0 }
end

local function Finish(s)
    local attempts = s.sold + s.expired + s.cancelled
    s.saleRate = attempts > 0 and s.sold / attempts or nil
    s.averagePrice = s.soldQuantity > 0 and s.revenue / s.soldQuantity or nil
    s.averagePurchasePrice = s.purchasedQuantity > 0 and s.spent / s.purchasedQuantity or nil
    return s
end

local function Build(days)
    local cutoff = days and (time() - days * 86400) or nil
    local map = {}
    for _, e in ipairs(root.ah.events) do
        local key = e[KEY] or (e[NAME] and root.ah.names[e[NAME]])
        if key and (not cutoff or e[T] >= cutoff) then
            local s = map[key]
            if not s then s = NewStats(); map[key] = s end
            local kind = e[KIND]
            if kind == "post" then
                s.posted = s.posted + 1
            elseif kind == "sale" then
                s.sold = s.sold + 1
                s.soldQuantity = s.soldQuantity + (e[QTY] or 1)
                s.revenue = s.revenue + (e[AMT] or 0)
                if not s.lastSale or e[T] > s.lastSale then s.lastSale = e[T] end
            elseif kind == "expired" then
                s.expired = s.expired + 1
                s.depositLost = s.depositLost + (e[DEP] or 0)
            elseif kind == "cancelled" then
                s.cancelled = s.cancelled + 1
                s.depositLost = s.depositLost + (e[DEP] or 0)
            elseif kind == "purchase" then
                s.purchases = s.purchases + 1
                s.purchasedQuantity = s.purchasedQuantity + (e[QTY] or 1)
                s.spent = s.spent + (e[AMT] or 0)
            end
        end
    end
    for _, s in pairs(map) do Finish(s) end
    return map
end

--- Statistics of an item for the last `days` days (nil = all time); nil without events.
function AuctionLog.Stats(key, days)
    local cacheKey = days or "all"
    local map = windowCache[cacheKey]
    if not map then
        map = Build(days)
        windowCache[cacheKey] = map
    end
    return map[key]
end

--- Drop events older than `days` (Retention).
function AuctionLog.Prune(days)
    local cutoff = time() - days * 86400
    local kept = {}
    for _, e in ipairs(root.ah.events) do
        if e[T] >= cutoff then kept[#kept + 1] = e end
    end
    root.ah.events = kept
    PruneOpen()
    Invalidate()
end

function AuctionLog.Enable(module)
    root = module.db.root
    if type(root.ah.open) ~= "table" then root.ah.open = {} end
    PruneOpen()
    Invalidate()
end
