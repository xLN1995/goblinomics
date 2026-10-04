if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Ledger/Store.lua
-- Transactions are compact arrays (memory budget) stored per day:
--   { time, charIndex, category, sub, amount, itemKey, quantity, tag, note, count, source }
-- (source: import id such as "tsm:1790000000" for imported bookings, M8)
-- (charIndex points into root.charIndex; root.chars belongs to the DB layer)
-- Consecutive bookings of the same character, category, sub-category and tag
-- without an item within 60 s are merged (never Other/unknown, which may still be
-- reclassified by a late confirmation) (amount summed, count increased), so
-- per-mob loot gold stays small. Days older than the retention window live on as
-- daily aggregates { [charIndex] = { ["cat|tag"] = {amount, count} } }.
local _, ns = ...

local Store = {}
ns.Store = Store

local API = ns.API
local T, CHAR, CAT, SUB, AMT, KEY, QTY, TAG, NOTE, COUNT, SRC = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
Store.F = { T = T, CHAR = CHAR, CAT = CAT, SUB = SUB, AMT = AMT, KEY = KEY, QTY = QTY, TAG = TAG, NOTE = NOTE, COUNT = COUNT,
    SRC = SRC }
Store.CATEGORIES = { "AH", "Vendor", "Repair", "Quest", "Loot", "Crafting", "Mail", "Other", "Transfer" }
Store.MERGE_WINDOW = 60

local ledger, root
local charIndexOf = {}
local changedPending = false

function Store.Enable(module)
    ledger, root = module, module.db.root
    for i, key in ipairs(root.charIndex) do charIndexOf[key] = i end
end

function Store.CharIndex(charKey)
    local index = charIndexOf[charKey]
    if not index then
        root.charIndex[#root.charIndex + 1] = charKey
        index = #root.charIndex
        charIndexOf[charKey] = index
    end
    return index
end

function Store.CharKey(index)
    return root.charIndex[index]
end

local function Day(t)
    return date("%Y-%m-%d", t)
end
Store.Day = Day

local function Changed()
    if changedPending then return end
    changedPending = true
    ledger:After(0.5, function()
        changedPending = false
        API.Emit("LEDGER_CHANGED", {})
    end)
end

--- Decode a stored transaction into a table.
function Store.Decode(tx, day)
    return {
        time = tx[T], char = root.charIndex[tx[CHAR]], category = tx[CAT], sub = tx[SUB], amount = tx[AMT],
        itemKey = tx[KEY], quantity = tx[QTY], tag = tx[TAG], note = tx[NOTE], count = tx[COUNT] or 1,
        source = tx[SRC], day = day or Day(tx[T]), ref = tx,
    }
end

--- entry = { time, char, category, sub, amount, itemKey, quantity, tag, note }
-- Returns the stored transaction (possibly merged into the previous one).
function Store.Add(entry)
    local t = entry.time or time()
    local day = Day(t)
    local list = root.tx[day]
    if not list then
        list = {}
        root.tx[day] = list
    end
    local ci = Store.CharIndex(entry.char)
    local last = list[#list]
    local merged = false
    local tx
    if last and not entry.itemKey and not last[KEY] and not entry.source and not last[SRC]
        and entry.sub ~= "unknown" and last[CHAR] == ci and last[CAT] == entry.category
        and last[SUB] == entry.sub and last[TAG] == entry.tag and last[NOTE] == entry.note
        and t - last[T] <= Store.MERGE_WINDOW
        and (last[AMT] >= 0) == (entry.amount >= 0) then
        last[AMT] = last[AMT] + entry.amount
        last[COUNT] = (last[COUNT] or 1) + 1
        last[T] = t
        tx, merged = last, true
    else
        tx = { t, ci, entry.category, entry.sub, entry.amount, entry.itemKey, entry.quantity, entry.tag, entry.note,
            nil, entry.source }
        list[#list + 1] = tx
    end
    local payload = Store.Decode(tx, day)
    payload.merged = merged
    API.Emit("LEDGER_TRANSACTION", payload)
    Changed()
    return tx
end

--- Imported bookings (M8): inserted in time order into their days, never merged;
-- one LEDGER_TRANSACTION per booking with imported = true (Workshop takes AH
-- purchases as purchase lots) and one LEDGER_CHANGED. Returns the number added.
function Store.Import(entries)
    for _, entry in ipairs(entries) do
        local t = entry.time
        local day = Day(t)
        local list = root.tx[day]
        if not list then
            list = {}
            root.tx[day] = list
        end
        local tx = { t, Store.CharIndex(entry.char), entry.category, entry.sub, entry.amount, entry.itemKey,
            entry.quantity, entry.tag, entry.note, nil, entry.source }
        local pos = #list + 1
        while pos > 1 and list[pos - 1][T] > t do pos = pos - 1 end
        table.insert(list, pos, tx)
        local payload = Store.Decode(tx, day)
        payload.imported = true
        API.Emit("LEDGER_TRANSACTION", payload)
    end
    if #entries > 0 then Changed() end
    return #entries
end

--- Remove every booking of an import; returns the number removed (aggregated days keep their sums).
function Store.RemoveSource(source)
    local removed = 0
    for day, list in pairs(root.tx) do
        for i = #list, 1, -1 do
            if list[i][SRC] == source then
                table.remove(list, i)
                removed = removed + 1
            end
        end
        if #list == 0 then root.tx[day] = nil end
    end
    if removed > 0 then Changed() end
    return removed
end

--- Change category / sub-category / tag / item of a stored transaction.
function Store.Update(tx, fields)
    if fields.category then tx[CAT] = fields.category end
    if fields.sub then tx[SUB] = fields.sub end
    if fields.tag ~= nil then tx[TAG] = fields.tag ~= "" and fields.tag or nil end
    if fields.itemKey then tx[KEY], tx[QTY] = fields.itemKey, fields.quantity end
    if fields.note then tx[NOTE] = fields.note end
    Changed()
    -- items are attached after the money (vendor purchases): tell listeners
    if fields.itemKey then API.Emit("LEDGER_TRANSACTION_ITEM", Store.Decode(tx)) end
end

local function Matches(row, filter)
    if filter.char and row.char ~= filter.char then return false end
    if filter.category and row.category ~= filter.category then return false end
    if filter.tag and row.tag ~= filter.tag then return false end
    if filter.from and row.time and row.time < filter.from then return false end
    if filter.search and filter.search ~= "" then
        local hay = ((row.note or "") .. " " .. (row.tag or "") .. " " .. (row.itemName or "")):lower()
        if not hay:find(filter.search:lower(), 1, true) then return false end
    end
    return true
end

local function ItemName(key)
    if not key then return nil end
    local query = API.ItemKey.ToItemString(key) or key
    local name = C_Item.GetItemInfo(query)
    return name
end
Store.ItemName = ItemName

--- Rows matching filter = { from (epoch), char, category, tag, search }, newest first.
-- Aggregated days contribute rows with aggregated = true (per char, category, tag).
function Store.Query(filter)
    filter = filter or {}
    local fromDay = filter.from and Day(filter.from) or nil
    local rows = {}
    for day, list in pairs(root.tx) do
        if not fromDay or day >= fromDay then
            for i = 1, #list do
                local row = Store.Decode(list[i], day)
                row.itemName = ItemName(row.itemKey)
                if Matches(row, filter) then rows[#rows + 1] = row end
            end
        end
    end
    for day, byChar in pairs(root.daily) do
        if not fromDay or day >= fromDay then
            for ci, cells in pairs(byChar) do
                for cell, sum in pairs(cells) do
                    local category, tag = cell:match("^([^|]*)|(.*)$")
                    local row = {
                        day = day, char = root.charIndex[ci], category = category, tag = tag ~= "" and tag or nil,
                        amount = sum.amount, count = sum.count, aggregated = true,
                    }
                    local f = filter.from and { char = filter.char, category = filter.category, tag = filter.tag,
                        search = filter.search } or filter
                    if Matches(row, f) then rows[#rows + 1] = row end
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.day ~= b.day then return a.day > b.day end
        return (a.time or 0) > (b.time or 0)
    end)
    return rows
end

--- income, expense, net over rows; transfers are neutral and excluded.
function Store.Totals(rows)
    local income, expense = 0, 0
    for i = 1, #rows do
        local r = rows[i]
        if r.category ~= "Transfer" then
            if r.amount >= 0 then income = income + r.amount else expense = expense + r.amount end
        end
    end
    return income, expense, income + expense
end

--- All tags used so far (sorted).
function Store.Tags()
    local seen, list = {}, {}
    for _, txs in pairs(root.tx) do
        for i = 1, #txs do
            local tag = txs[i][TAG]
            if tag and not seen[tag] then seen[tag] = true; list[#list + 1] = tag end
        end
    end
    for _, byChar in pairs(root.daily) do
        for _, cells in pairs(byChar) do
            for cell in pairs(cells) do
                local tag = cell:match("|(.+)$")
                if tag and not seen[tag] then seen[tag] = true; list[#list + 1] = tag end
            end
        end
    end
    table.sort(list)
    return list
end
