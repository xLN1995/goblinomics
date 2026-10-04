if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Ledger/Ledger.lua
-- Ledger: every gold movement booked exactly once into a category (AH, Vendor,
-- Repair, Quest, Loot, Crafting, Mail, Other; neutral Transfer), mail and trade
-- tags, the auction house log, retention and the ledger table. This file registers
-- the module and wires the parts together; the other files share the namespace.
local ADDON_NAME, ns = ...

local API = Goblinomics and Goblinomics.API and Goblinomics.API.v1
if not API then return end
ns.API = API
ns.L = API.L

local Ledger = API.RegisterModule(ADDON_NAME, {
    apiVersion = 1,
    name = "Ledger",
    description = function() return API.L["Books every gold movement into categories and logs the auction house."] end,
    order = 20,
    db = {
        sv = "GoblinomicsLedgerDB",
        version = 3,
        migrations = {
            -- schema 2: auction sales that "open all" booked as Mail (Repair.lua)
            [2] = function(root) if ns.Repair then ns.Repair.MergedMail(root) end end,
            -- schema 3: auction sales without an item key (Repair.lua)
            [3] = function(root) if ns.Repair then ns.Repair.SaleKeys(root) end end,
        },
        defaults = {
            mailRules = {},
            retentionDays = 90,
        },
        charDefaults = {},
    },
})
ns.Ledger = Ledger

--- Localised display name of a category id.
function ns.CategoryName(category)
    local L = ns.L
    if category == "AH" then return L["Auction House"] end
    if category == "Vendor" then return L["Vendor"] end
    if category == "Repair" then return L["Repair"] end
    if category == "Quest" then return L["Quest"] end
    if category == "Loot" then return L["Loot"] end
    if category == "Crafting" then return L["Crafting"] end
    if category == "Mail" then return L["Mail"] end
    if category == "Transfer" then return L["Transfer"] end
    return L["Other"]
end

--- Display label of a booking: category, for "Other" with its kind (Taxi, Trade, ...).
function ns.BookingLabel(category, sub)
    local L = ns.L
    local name = ns.CategoryName(category)
    if category == "AH" and (sub == "bid" or sub == "refund") then
        return name .. " \194\183 " .. (sub == "bid" and L["Bid"] or L["Refund"])
    end
    if category ~= "Other" or not sub then return name end
    local kind
    if sub == "taxi" then kind = L["Taxi"]
    elseif sub == "trade" then kind = L["Trade"]
    elseif sub == "trainer" then kind = L["Trainer"]
    elseif sub == "transmog" then kind = L["Transmog"]
    elseif sub == "barber" then kind = L["Barber"]
    elseif sub == "upgrade" then kind = L["Upgrade"]
    elseif sub == "guildbank" then kind = L["Guild bank"]
    elseif sub == "restricted" then kind = L["Instance"]
    end
    return kind and (name .. " \194\183 " .. kind) or name
end

local PARTS = { "Store", "Monitors", "Classifier", "AuctionLog", "Retention", "TradePopup", "LedgerUI", "LedgerCards" }

function Ledger:OnInit()
    local root = self.db.root
    for _, key in ipairs({ "charIndex", "tx", "daily", "tradePartners" }) do
        if type(root[key]) ~= "table" then root[key] = {} end
    end
    if type(root.ah) ~= "table" then root.ah = {} end
    if type(root.ah.events) ~= "table" then root.ah.events = {} end
    if type(root.ah.names) ~= "table" then root.ah.names = {} end
    if type(root.ah.deposits) ~= "table" then root.ah.deposits = {} end
    if type(root.ah.open) ~= "table" then root.ah.open = {} end
end

-- Public, read-only: other modules (Workshop) read the bookings.
API.Ledger = {
    --- Decoded bookings { time, char, category, sub, amount, itemKey, quantity, ... }
    Query = function(_, filter) return ns.Store and ns.Store.Query(filter or {}) or {} end,
    --- Daily aggregates (older than the raw window) from a day key on:
    -- { { day, char, category, tag, amount, count } }
    Aggregates = function(_, fromKey)
        local root = ns.Ledger.db and ns.Ledger.db.root
        local list = {}
        for day, byChar in pairs(root and root.daily or {}) do
            if not fromKey or day >= fromKey then
                for ci, cells in pairs(byChar) do
                    for cell, sum in pairs(cells) do
                        local category, tag = cell:match("^([^|]*)|(.*)$")
                        list[#list + 1] = { day = day, char = root.charIndex[ci], category = category,
                            tag = tag ~= "" and tag or nil, amount = sum.amount, count = sum.count }
                    end
                end
            end
        end
        return list
    end,
    --- Import bookings and auction log events from another addon (M8), without
    -- duplicates: batch = { source, entries = { { time, char, category, sub, amount,
    -- itemKey, quantity, tag, note } }, events = { { time, kind, itemKey, quantity,
    -- amount, deposit, name } } }. dryRun only counts. Returns the counts (Dedup.Import).
    Import = function(_, batch, dryRun)
        if not (ns.Ledger.db and ns.Dedup) then return nil end
        return ns.Dedup.Import(ns.Ledger.db.root, batch, dryRun)
    end,
    --- Auction house statistics of an item for the last `days` days (nil = all time), or nil:
    -- { posted, sold, soldQuantity, expired, cancelled, revenue, depositLost, saleRate,
    --   averagePrice, lastSale, purchases, purchasedQuantity, spent, averagePurchasePrice }
    AuctionStats = function(_, itemKey, days)
        local s = ns.AuctionLog and ns.AuctionLog.Stats(itemKey, days)
        if not s then return nil end
        local copy = {}
        for k, v in pairs(s) do copy[k] = v end
        return copy
    end,
    --- Remove everything an import added: bookings, auction log events.
    RemoveImport = function(_, source)
        if not ns.Ledger.db then return 0, 0 end
        return ns.Store.RemoveSource(source), ns.AuctionLog.RemoveSource(source)
    end,
}

function Ledger:OnEnable()
    for _, part in ipairs(PARTS) do
        if ns[part] and ns[part].Enable then ns[part].Enable(self) end
    end
end

function Ledger:OnDisable()
    for i = #PARTS, 1, -1 do
        local part = ns[PARTS[i]]
        if part and part.Disable then part.Disable(self) end
    end
end
