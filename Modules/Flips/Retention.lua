if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Flips/Retention.lua
-- After login: candidates that were not posted within candidateDays
-- are dropped (no flip), ignored lots after retentionDays. Closed lots whose last
-- activity is older than retentionDays fold into aggregates[day][key][char] with
-- the sums Stats reads (Stats.SUMS), every part on its own day; totals stay the same.
-- One pass without yielding: live purchases must not land in the replaced list.
local _, ns = ...

local Retention = {}
ns.Retention = Retention

local module

local function Day(t) return date("%Y-%m-%d", t) end

local function LastActivity(lot)
    local last = lot.time
    for _, s in ipairs(lot.sales) do last = math.max(last, s.time) end
    for _, e in ipairs(lot.ends) do last = math.max(last, e.time) end
    if lot.writeoff then last = math.max(last, lot.writeoff.time) end
    return last
end

local function Fold(root, lot)
    local char = lot.char or "?"
    local function Cell(t)
        local day = Day(t)
        local byKey = root.aggregates[day] or {}
        root.aggregates[day] = byKey
        local byChar = byKey[lot.key] or {}
        byKey[lot.key] = byChar
        local a = byChar[char] or {}
        byChar[char] = a
        return a
    end
    local function Add(a, field, v) a[field] = (a[field] or 0) + v end
    local a = Cell(lot.time)
    Add(a, "bought", lot.qty)
    Add(a, "spent", lot.qty * lot.unit)
    for _, s in ipairs(lot.sales) do
        a = Cell(s.time)
        Add(a, "sold", 1)
        Add(a, "soldQty", s.qty)
        Add(a, "gross", s.gross)
        Add(a, "revenue", s.net)
        Add(a, "cost", s.cost)
        Add(a, "holdSum", s.qty * (s.time - lot.time))
    end
    for _, e in ipairs(lot.ends) do
        a = Cell(e.time)
        Add(a, e.kind == "cancelled" and "cancelled" or "expired", 1)
        Add(a, "depositLost", e.deposit or 0)
    end
    local w = lot.writeoff
    if w then
        a = Cell(w.time)
        Add(a, "writeoffQty", w.qty)
        Add(a, "writeoff", math.floor(w.qty * lot.unit + 0.5))
    end
end

function Retention.Run(now)
    local root = module.db.root
    local settings = module.db.settings
    now = now or time()
    local candidateCutoff = now - settings.candidateDays * 86400
    local cutoff = now - settings.retentionDays * 86400
    local kept = {}
    for _, lot in ipairs(root.lots) do
        if lot.state == "candidate" then
            if lot.time >= candidateCutoff then kept[#kept + 1] = lot end
        elseif lot.state == "ignored" then
            if lot.time >= cutoff then kept[#kept + 1] = lot end
        elseif lot.state == "closed" and LastActivity(lot) < cutoff then
            Fold(root, lot)
        else
            kept[#kept + 1] = lot
        end
    end
    root.lots = kept
end

function Retention.Enable(m)
    module = m
    m:After(10, function() Retention.Run() end)
end
