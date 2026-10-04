if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Ledger/Repair.lua
-- One-time repair (schema 2): before the fix in the classifier, money of several
-- mails taken at once ("open all") arrived as one PLAYER_MONEY and was booked as
-- Mail/in from the context (no sender note). The auction log still recorded the
-- sales at that moment, so those bookings are split back: every logged sale
-- within the booking's time span that has no AH booking yet becomes an AH/sale
-- booking. The auction log keeps the gross price only; the net is estimated as
-- price minus the 5 % cut plus the deposit returned with the sale (deposit per
-- unit from the posting log). A small rest (rounding) is spread over the sales,
-- a larger one stays as Mail.
-- Schema 3: auction sales of items the addon had not seen posted were booked
-- without an item key and showed the buyer only. The logged sale at that moment
-- still has the item name; it resolves the key (posting log, else the client's
-- item cache), or at least goes into the note.
local _, ns = ...

local Repair = {}
ns.Repair = Repair

local T, CHAR, CAT, SUB, AMT, KEY, QTY, NOTE, COUNT = 1, 2, 3, 4, 5, 6, 7, 9, 10
local E_T, E_KIND, E_KEY, E_QTY, E_AMT, E_NAME = 1, 2, 3, 4, 5, 7
local SPAN = 65          -- merge window (60 s) plus slack
local ABSORB = 0.05      -- rest up to 5 % of the sales counts as deposits/rounding


--- Returns the number of split bookings.
function Repair.MergedMail(root)
    local events = root.ah and root.ah.events or {}
    local deposits = root.ah and root.ah.deposits or {}
    local function Net(e)
        local perUnit = e[E_KEY] and deposits[e[E_KEY]] or 0
        return math.floor(e[E_AMT] * 0.95) + math.floor(perUnit * (e[E_QTY] or 1) + 0.5)
    end
    local sales = {}
    for _, e in ipairs(events) do
        if e[E_KIND] == "sale" and (e[E_AMT] or 0) > 0 then sales[#sales + 1] = { e = e } end
    end
    if #sales == 0 then return 0 end
    -- sales that already have their booking
    for _, list in pairs(root.tx or {}) do
        for _, tx in ipairs(list) do
            if tx[CAT] == "AH" and tx[SUB] == "sale" then
                for _, s in ipairs(sales) do
                    if not s.used and math.abs(s.e[E_T] - tx[T]) <= 3 and s.e[E_KEY] == tx[KEY]
                        and (s.e[E_QTY] or 1) == (tx[QTY] or 1) then
                        s.used = true
                        break
                    end
                end
            end
        end
    end
    local split = 0
    for _, list in pairs(root.tx or {}) do
        local i = 1
        while i <= #list do
            local tx = list[i]
            local found = {}
            if tx[CAT] == "Mail" and tx[SUB] == "in" and tx[NOTE] == nil and (tx[AMT] or 0) > 0 then
                local sum = 0
                for _, s in ipairs(sales) do
                    local dt = tx[T] - s.e[E_T]
                    if not s.used and dt >= -3 and dt <= SPAN and sum + Net(s.e) <= tx[AMT] then
                        found[#found + 1] = s
                        sum = sum + Net(s.e)
                    end
                end
                if #found > 0 then
                    local rest = tx[AMT] - sum
                    local absorb = rest <= sum * ABSORB
                    local new = {}
                    local given = 0
                    for _, s in ipairs(found) do
                        s.used = true
                        local net = Net(s.e)
                        if absorb then net = math.floor(net * tx[AMT] / sum) end
                        given = given + net
                        new[#new + 1] = { s.e[E_T], tx[CHAR], "AH", "sale", net, s.e[E_KEY], s.e[E_QTY] }
                    end
                    if absorb then
                        new[1][AMT] = new[1][AMT] + (tx[AMT] - given)
                    else
                        tx[AMT] = rest
                        tx[COUNT] = nil
                        new[#new + 1] = tx
                    end
                    table.remove(list, i)
                    for k, n in ipairs(new) do table.insert(list, i + k - 1, n) end
                    i = i + #new - 1
                    split = split + 1
                end
            end
            i = i + 1
        end
    end
    return split
end

local function KeyOfName(root, name)
    local key = root.ah.names and root.ah.names[name]
    if key then return key end
    local link = C_Item and C_Item.GetItemInfo and select(2, C_Item.GetItemInfo(name))
    return link and ns.API.ItemKey.FromLink(link) or nil
end

--- Returns the number of repaired bookings (key or name added).
function Repair.SaleKeys(root)
    local events = root.ah and root.ah.events or {}
    local sales = {}
    for _, e in ipairs(events) do
        if e[E_KIND] == "sale" and not e[E_KEY] and e[E_NAME] then sales[#sales + 1] = { e = e } end
    end
    if #sales == 0 then return 0 end
    local repaired = 0
    for _, list in pairs(root.tx or {}) do
        for _, tx in ipairs(list) do
            if tx[CAT] == "AH" and tx[SUB] == "sale" and not tx[KEY] then
                local count = tx[COUNT] or 1
                local found = {}
                for _, s in ipairs(sales) do
                    local dt = tx[T] - s.e[E_T]
                    if #found < count and not s.used and dt >= -3 and dt <= (count > 1 and SPAN or 3)
                        and (count > 1 or (s.e[E_QTY] or 1) == (tx[QTY] or 1)) then
                        found[#found + 1] = s
                    end
                end
                local name = found[1] and found[1].e[E_NAME]
                for _, s in ipairs(found) do
                    if s.e[E_NAME] ~= name then name = nil end
                end
                if name and #found == count then
                    local key = KeyOfName(root, name)
                    local qty = 0
                    for _, s in ipairs(found) do
                        s.used = true
                        s.e[E_KEY] = key
                        qty = qty + (s.e[E_QTY] or 1)
                    end
                    if key then
                        tx[KEY], tx[QTY] = key, qty
                    else
                        tx[NOTE] = tx[NOTE] and (name .. " (" .. tx[NOTE] .. ")") or name
                    end
                    repaired = repaired + 1
                end
            end
        end
    end
    return repaired
end
