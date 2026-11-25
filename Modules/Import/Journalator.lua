if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Import/Journalator.lua
-- Journalator reader. JOURNALATOR_ARCHIVE.stores.SometimesLocked["Logs-<ts>"] =
-- { timestamp, version, data }, data = EncodeForPrint(CompressDeflate(
-- LibSerialize)) of the sections. One store is
-- decoded per frame in a job. Every record names its character in
-- source = { character, realm, faction }.
-- Mapping:
--   Invoices        seller -> AH/sale (value - consignment + deposit, exact),
--                   buyer -> AH/purchase; both into the auction log
--   Posting         AH/deposit and an auction log post
--   Failures        auction log expired / cancelled
--   Vendoring       Vendor sell/buy (unit price x count; purchase and buyback are buys)
--   VendorRepairs   Repair
--   Questing        Quest/reward (reward money)
--   LootContainers  Loot/money
--   BasicMail*      Mail in/out (own characters: Transfer), postage separately
--   Trades          Other/trade (money in - out)
--   Fulfilling      Crafting/commission (tip - consortium cut)
--   CraftingOrdersPlaced  Crafting/fee (posting fee + tip)
--   Taxis, TrainingCosts  Other/taxi, Other/trainer
local _, ns = ...

local Journalator = {}
ns.Journalator = Journalator

local API = ns.API

function Journalator.Archive() return JOURNALATOR_ARCHIVE end

function Journalator.Available()
    local a = Journalator.Archive()
    return type(a) == "table" and type(a.stores) == "table" and LibStub ~= nil
        and LibStub("LibDeflate", true) ~= nil and LibStub("LibSerialize", true) ~= nil
end

--- Encoded log stores: { { name, data } } sorted by name.
function Journalator.Stores(archive)
    local list = {}
    for _, group in pairs(archive and archive.stores or {}) do
        for name, store in pairs(group) do
            if type(name) == "string" and name:match("^Logs%-") and type(store) == "table" and type(store.data) == "string" then
                list[#list + 1] = { name = name, data = store.data }
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

--- Decoded sections of one store, or nil.
function Journalator.Decode(data)
    local LD, LS = LibStub("LibDeflate"), LibStub("LibSerialize")
    local compressed = LD:DecodeForPrint(data)
    local raw = compressed and LD:DecompressDeflate(compressed)
    if not raw then return nil end
    local ok, sections = LS:Deserialize(raw)
    return ok and type(sections) == "table" and sections or nil
end

--- Add the bookings and auction events of decoded sections to a batch.
function Journalator.Map(sections, batch, stats)
    local own, byName = ns.Import.OwnCharacters(), ns.Import.OwnByName()
    local entries, events = batch.entries, batch.events
    local function CharOf(e)
        local s = e.source
        if type(s) ~= "table" or not s.character then return nil end
        return ns.Import.CharKey(s.character, s.realm, byName)
    end
    local function IsOwn(name, e)
        if not name or name == "" then return false end
        local key = ns.Import.CharKey(name, type(e.source) == "table" and e.source.realm or "", byName)
        return own[key:lower()] ~= nil
    end
    local function Key(e) return e.itemLink and API.ItemKey.FromLink(e.itemLink) or nil end
    local function Add(e, fields)
        local t = tonumber(e.time)
        if not t then return end
        stats.count = stats.count + 1
        stats.from = math.min(stats.from or t, t)
        stats.to = math.max(stats.to or t, t)
        fields.time, fields.char = t, CharOf(e)
        if fields.char and fields.amount and fields.amount ~= 0 then entries[#entries + 1] = fields end
    end
    local function Event(e, fields)
        fields.time = tonumber(e.time)
        if fields.time then events[#events + 1] = fields end
    end
    local function Each(name, fn)
        for _, e in ipairs(sections[name] or {}) do if type(e) == "table" then fn(e) end end
    end

    Each("Invoices", function(e)
        local key, count = Key(e), e.count or 1
        if e.invoiceType == "seller" then
            Add(e, { category = "AH", sub = "sale", amount = (e.value or 0) - (e.consignment or 0) + (e.deposit or 0),
                itemKey = key, quantity = count, note = e.playerName })
            Event(e, { kind = "sale", itemKey = key, name = e.itemName, quantity = count, amount = e.value or 0 })
        elseif e.invoiceType == "buyer" then
            Add(e, { category = "AH", sub = "purchase", amount = -(e.value or 0), itemKey = key, quantity = count,
                note = e.playerName })
            Event(e, { kind = "purchase", itemKey = key, name = e.itemName, quantity = count, amount = e.value or 0 })
        end
    end)
    Each("Posting", function(e)
        local key = Key(e)
        Add(e, { category = "AH", sub = "deposit", amount = -(e.deposit or 0), itemKey = key, quantity = e.count })
        Event(e, { kind = "post", itemKey = key, name = e.itemName, quantity = e.count, amount = 0, deposit = e.deposit })
    end)
    Each("Failures", function(e)
        stats.count = stats.count + 1
        Event(e, { kind = e.failedType == "cancelled" and "cancelled" or "expired", itemKey = Key(e), name = e.itemName,
            quantity = e.count, amount = 0 })
    end)
    Each("Vendoring", function(e)
        -- Journalator: vendorType "sell", "purchase" or "buyback"; the unit price is
        -- price / stack size and can be fractional
        local amount = math.floor((e.unitPrice or 0) * (e.count or 1) + 0.5)
        local sell = e.vendorType == "sell"
        Add(e, { category = "Vendor", sub = sell and "sell" or "buy",
            amount = sell and amount or -amount, itemKey = Key(e), quantity = e.count })
    end)
    Each("VendorRepairs", function(e) Add(e, { category = "Repair", sub = "repair", amount = -(e.money or 0) }) end)
    Each("Questing", function(e)
        Add(e, { category = "Quest", sub = "reward", amount = e.rewardMoney or 0, note = e.questName })
    end)
    Each("LootContainers", function(e) Add(e, { category = "Loot", sub = "money", amount = e.money or 0 }) end)
    Each("BasicMailReceived", function(e)
        local mine = IsOwn(e.sender, e)
        Add(e, { category = mine and "Transfer" or "Mail", sub = mine and "alt" or "in", amount = e.money or 0,
            note = e.sender })
    end)
    Each("BasicMailSent", function(e)
        local mine = IsOwn(e.recipient, e)
        Add(e, { category = mine and "Transfer" or "Mail", sub = mine and "alt" or "out", amount = -(e.money or 0),
            note = e.recipient })
        Add(e, { category = "Mail", sub = "postage", amount = -(e.sendCost or 0), note = e.recipient })
    end)
    Each("Trades", function(e)
        Add(e, { category = "Other", sub = "trade", amount = (e.moneyIn or 0) - (e.moneyOut or 0), note = e.player })
    end)
    Each("Fulfilling", function(e)
        Add(e, { category = "Crafting", sub = "commission", amount = (e.tipAmount or 0) - (e.consortiumCut or 0),
            note = e.playerName })
    end)
    Each("CraftingOrdersPlaced", function(e)
        Add(e, { category = "Crafting", sub = "fee", amount = -((e.postingFee or 0) + (e.tipAmount or 0)),
            note = e.playerName })
    end)
    Each("Taxis", function(e) Add(e, { category = "Other", sub = "taxi", amount = -(e.money or 0) }) end)
    Each("TrainingCosts", function(e) Add(e, { category = "Other", sub = "trainer", amount = -(e.money or 0) }) end)
end

--- Decode all stores in a job (one per frame); callback(batch, stats).
function Journalator.Build(callback)
    local stores = Journalator.Stores(Journalator.Archive())
    local batch, stats = { entries = {}, events = {} }, { count = 0 }
    ns.Import:RunJob("journalator", function()
        for _, store in ipairs(stores) do
            local sections = Journalator.Decode(store.data)
            if sections then Journalator.Map(sections, batch, stats) end
            API.Yield()
        end
    end, function() callback(batch, stats) end)
end

function Journalator.Detect()
    -- counting needs the decoded stores; the settings page asks for a preview instead
    local stores = Journalator.Stores(Journalator.Archive())
    return { available = true, stores = #stores }
end

function Journalator.Read(callback)
    Journalator.Build(function(batch) callback(batch) end)
end
