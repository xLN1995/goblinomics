if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/Salvage.lua
-- Salvage (milling, prospecting, crushing, shatter, disenchanting): per salvaged item the
-- operations, items used and their cost, and on a cash basis what the yield
-- brought in: revenue of sold yields plus the cost share of yields used in
-- crafts; profit = that minus all costs of the operations (unsold yields make
-- it negative until they are sold). The value of the unsold yield at market
-- price is shown for orientation.
local _, ns = ...

local Salvage = {}
ns.Salvage = Salvage

local module

--- Rows per salvaged item: { input, operations, used, cost, yield, gain, outputs = { [key] = qty },
--   revenue, soldCost, profit } sorted by gain. filter = { from, profession, char }
-- One row per base item: disenchanted gear of the same item with other bonus IDs
-- or stats counts together (input is the base key then).
function Salvage.Rows(filter)
    filter = filter or {}
    local rows, byInput, craftToRow = {}, {}, {}
    for _, r in ipairs(module.db.root.crafts) do
        if r.kind == "salvage" and (not filter.from or r.time >= filter.from) and (not filter.to or r.time < filter.to)
            and (not filter.profession or filter.profession == r.profession)
            and (not filter.char or filter.char == r.char) then
            local input = ns.API.ItemKey.Base(r.input)
            local key = input or ("recipe:" .. r.recipe)
            local row = byInput[key]
            if not row then
                row = { input = input, name = r.name, profession = r.profession, method = r.method,
                    operations = 0, used = 0, cost = 0,
                    yield = 0, outputs = {}, revenue = 0, soldCost = 0, transferred = 0, openValue = 0 }
                byInput[key] = row
                rows[#rows + 1] = row
            end
            row.operations = row.operations + r.crafts
            for _, g in ipairs(r.reagents) do
                if g[1] == r.input then row.used = row.used + g[2] end
            end
            row.cost = row.cost + (r.cost or 0)
            row.yield = row.yield + (r.yield or 0)
            for _, o in ipairs(r.outputs) do row.outputs[o[1]] = (row.outputs[o[1]] or 0) + o[2] end
            craftToRow[r.id] = row
        end
    end
    for _, m in ipairs(module.db.root.matches) do
        local row = craftToRow[m.craft]
        if row then
            row.revenue = row.revenue + m.revenue
            row.soldCost = row.soldCost + m.cost
        end
    end
    for _, tr in ipairs(module.db.root.transfers or {}) do
        local row = craftToRow[tr.craft]
        if row then row.transferred = row.transferred + tr.cost end
    end
    for _, lot in ipairs(module.db.root.lots) do
        local row = craftToRow[lot.craft]
        if row then row.openValue = row.openValue + lot.qty * (ns.Reagents.UnitPrice(lot.key) or 0) end
    end
    for _, row in ipairs(rows) do
        row.gain = row.yield - row.cost
        -- cash basis: all costs of the operations against what the yield brought in so far
        row.profit = row.revenue + row.transferred - row.cost
    end
    table.sort(rows, function(a, b)
        if a.profit ~= b.profit then return a.profit > b.profit end
        return a.cost > b.cost
    end)
    return rows
end

function Salvage.Enable(m)
    module = m
end
