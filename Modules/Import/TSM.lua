if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Import/TSM.lua
-- TSM Accounting reader. TradeSkillMasterDB keeps realm-wide CSV strings
-- "r@<Realm>@internalData@csv<Kind>" with a header line:
--   csvSales/csvBuys     itemString,stackSize,quantity,price,otherPlayer,player,time,source
--                        (price per item; auction sales already net of the 5 %
--                        cut, deposit not included; source Auction/Vendor/Trade)
--   csvIncome/csvExpense type,amount,otherPlayer,player,time
--   csvExpired/csvCancelled itemString,stackSize,quantity,player,time
-- Mapping: Auction -> AH sale (TSM price x quantity = net without the returned
-- deposit; checked against Journalator invoices, M8) or purchase plus the
-- auction log event (sales gross = net / 0.95 like the Ledger's own log); Vendor -> Vendor; Trade -> Other/trade;
-- Repair Bill -> Repair, Postage -> Mail/postage, Crafting Order -> Crafting,
-- Money Transfer -> Transfer between own characters, else Mail; expired and
-- cancelled auctions only go to the auction log.
local _, ns = ...

local TSM = {}
ns.TSM = TSM

local API = ns.API
local AH_CUT = 0.05
local KINDS = { "csvSales", "csvBuys", "csvIncome", "csvExpense", "csvExpired", "csvCancelled" }

--- The TSM database (replaceable in tests).
function TSM.DB() return TradeSkillMasterDB end

function TSM.Available() return type(TSM.DB()) == "table" end

--- Rows of a CSV string with header: { { field = value } }.
function TSM.ParseCSV(text)
    local rows, header = {}, nil
    for line in (text or ""):gmatch("[^\r\n]+") do
        local fields = {}
        for value in (line .. ","):gmatch("([^,]*),") do fields[#fields + 1] = value end
        if not header then
            header = fields
        else
            local row = {}
            for i, name in ipairs(header) do row[name] = fields[i] end
            rows[#rows + 1] = row
        end
    end
    return rows
end

--- { [realm] = { [kind] = csv } } from the database keys.
function TSM.Realms(db)
    local realms = {}
    for key, value in pairs(db or {}) do
        local realm, kind
        if type(key) == "string" then realm, kind = key:match("^r@(.-)@internalData@(csv%a+)$") end
        if realm and type(value) == "string" then
            realms[realm] = realms[realm] or {}
            realms[realm][kind] = value
        end
    end
    return realms
end

local function Money(v) return math.floor(tonumber(v) or 0) end

--- Batch { entries, events } and stats { count, from, to } of the whole database.
function TSM.Build(db)
    local own, byName = ns.Import.OwnCharacters(), ns.Import.OwnByName()
    local entries, events = {}, {}
    local stats = { count = 0 }
    local function Seen(t)
        stats.count = stats.count + 1
        stats.from = math.min(stats.from or t, t)
        stats.to = math.max(stats.to or t, t)
    end
    for realmName, kinds in pairs(TSM.Realms(db)) do
        local function Char(player)
            return player and player ~= "" and ns.Import.CharKey(player, realmName, byName) or nil
        end
        local function IsOwn(name)
            if not name or name == "" then return false end
            return own[ns.Import.CharKey(name, realmName, byName):lower()] ~= nil
        end
        local function Add(e)
            if e.char and e.time and e.amount and e.amount ~= 0 then entries[#entries + 1] = e end
        end
        for _, kind in ipairs(KINDS) do
            for _, r in ipairs(TSM.ParseCSV(kinds[kind])) do
                local t = tonumber(r.time)
                if t then
                    Seen(t)
                    local char = Char(r.player)
                    local key = r.itemString and API.ItemKey.FromLink(r.itemString) or nil
                    local qty = tonumber(r.quantity) or 1
                    if kind == "csvSales" or kind == "csvBuys" then
                        local gross = Money(r.price) * qty
                        local sale = kind == "csvSales"
                        if r.source == "Auction" then
                            Add({ time = t, char = char, category = "AH", sub = sale and "sale" or "purchase",
                                amount = sale and gross or -gross,
                                itemKey = key, quantity = qty, note = r.otherPlayer })
                            events[#events + 1] = { time = t, kind = sale and "sale" or "purchase", itemKey = key,
                                quantity = qty, amount = sale and math.floor(gross / (1 - AH_CUT) + 0.5) or gross }
                        elseif r.source == "Vendor" then
                            Add({ time = t, char = char, category = "Vendor", sub = sale and "sell" or "buy",
                                amount = sale and gross or -gross, itemKey = key, quantity = qty })
                        else
                            Add({ time = t, char = char, category = "Other", sub = "trade",
                                amount = sale and gross or -gross, itemKey = key, quantity = qty, note = r.otherPlayer })
                        end
                    elseif kind == "csvIncome" or kind == "csvExpense" then
                        local income = kind == "csvIncome"
                        local amount = Money(r.amount)
                        local e = { time = t, char = char, amount = income and amount or -amount, note = r.otherPlayer }
                        if r.type == "Repair Bill" then
                            e.category, e.sub = "Repair", "repair"
                        elseif r.type == "Postage" then
                            e.category, e.sub = "Mail", "postage"
                        elseif r.type == "Crafting Order" then
                            e.category, e.sub = "Crafting", income and "commission" or "fee"
                        elseif r.type == "Money Transfer" then
                            if IsOwn(r.otherPlayer) then
                                e.category, e.sub = "Transfer", "alt"
                            else
                                e.category, e.sub = "Mail", income and "in" or "out"
                            end
                        else
                            e.category, e.sub = "Other", "import"
                        end
                        Add(e)
                    else
                        events[#events + 1] = { time = t, kind = kind == "csvExpired" and "expired" or "cancelled",
                            itemKey = key, quantity = qty, amount = 0 }
                    end
                end
            end
        end
    end
    return { entries = entries, events = events }, stats
end

function TSM.Detect()
    local _, stats = TSM.Build(TSM.DB())
    return { available = true, count = stats.count, from = stats.from, to = stats.to }
end

function TSM.Read(callback)
    callback((TSM.Build(TSM.DB())))
end
