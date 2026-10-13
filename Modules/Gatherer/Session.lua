if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/Session.lua
-- The session tracker. Sessions start manually only (HUD, tab, /gob farm).
-- Captured while running:
--   items     LOOT_RECEIVED except crafted items and items that arrive through a
--             merchant, mail, auction, trade, bank or crafting window
--   raw gold  positive MONEY_DELTA with loot context (loot window open or closed
--             within the recent window, loot chat marker, restricted replay or the
--             reconciliation right after it); a loot
--             chat line up to 5 s after the money moves an unexplained gain to loot
--   realized  every character money change except warband transfers
--   repair    durability points used x copper per point (learned at a merchant)
--   nodes     gathering nodes (NodeTracker), in total and per node
-- Duration excludes pauses. With auto-pause the idle minutes before the pause do
-- not count either. The session lives in db.char.active and survives /reload; at
-- logout it pauses and resumes on the next login within RESUME_GRACE seconds.
local _, ns = ...

local Session = {}
ns.Session = Session

local RECLASSIFY_WINDOW = 5
local RESUME_GRACE = 300
local SLOTS_FIRST, SLOTS_LAST = 1, 19
-- windows through which items or gold arrive that were not farmed
local NOT_FARMED = { "merchant", "mail", "auction", "trade", "bank", "warbank", "guildbank", "craft", "craftingOrder" }
local NOT_LOOT_MONEY = { "merchant", "mail", "auction", "trade", "bank", "warbank", "guildbank", "craftingOrder",
    "quest", "taxi", "trainer", "transmog", "barber", "upgrade" }

local module
local unexplained = {}   -- { amount, time } positive gains without loot context
local autoPauseToken = 0

local function Emit(action)
    ns.API.Emit("GATHERER_SESSION", { action = action, session = Session.Active() })
end

function Session.Active()
    return module and module.db.char and module.db.char.active or nil
end

function Session.IsRunning()
    local s = Session.Active()
    return s ~= nil and s.runningSince ~= nil
end

--- Seconds without pauses.
function Session.Duration(s)
    s = s or Session.Active()
    if not s then return 0 end
    local d = s.accumulated or 0
    if s.runningSince then d = d + math.max(0, time() - s.runningSince) end
    return d
end

-- Durability -----------------------------------------------------------------
--- Missing durability points over all equipped items.
function Session.MissingDurability()
    local missing = 0
    for slot = SLOTS_FIRST, SLOTS_LAST do
        local current, maximum = GetInventoryItemDurability(slot)
        if current and maximum and maximum > current then
            missing = missing + (maximum - current)
        end
    end
    return missing
end

function Session.RepairRate()
    return module.db.char.repairRate
end

--- Prorated repair cost of the session in copper.
function Session.RepairCost(s)
    s = s or Session.Active()
    local rate = Session.RepairRate()
    if not s or not rate then return 0 end
    return math.floor((s.durabilityUsed or 0) * rate + 0.5)
end

local function LearnRepairRate()
    local cost = GetRepairAllCost()
    local missing = Session.MissingDurability()
    if type(cost) == "number" and cost > 0 and missing > 0 then
        module.db.char.repairRate = cost / missing
    end
end

local function OnDurability()
    local s = Session.Active()
    if not s then return end
    local missing = Session.MissingDurability()
    local last = s.missing or missing
    if s.runningSince and missing > last then
        s.durabilityUsed = (s.durabilityUsed or 0) + (missing - last)
    end
    s.missing = missing
end

-- Auto-pause -----------------------------------------------------------------
local function Activity()
    local s = Session.Active()
    if s then s.lastActivity = time() end
end

local function ScheduleAutoPause()
    autoPauseToken = autoPauseToken + 1
    local minutes = module.db.settings.autoPauseMinutes or 0
    local s = Session.Active()
    if minutes <= 0 or not s or not s.runningSince then return end
    local token = autoPauseToken
    local limit = minutes * 60
    local wait = math.max(1, (s.lastActivity or time()) + limit - time())
    module:After(wait, function()
        if token ~= autoPauseToken then return end
        local cur = Session.Active()
        if not cur or not cur.runningSince then return end
        local idleSince = cur.lastActivity or cur.runningSince
        if time() - idleSince >= limit then
            -- the idle minutes do not count
            cur.accumulated = (cur.accumulated or 0) + math.max(0, idleSince - cur.runningSince)
            cur.runningSince = nil
            cur.autoPaused = true
            Emit("pause")
        else
            ScheduleAutoPause()
        end
    end)
end
Session.ScheduleAutoPause = ScheduleAutoPause

-- Lifecycle ------------------------------------------------------------------
--- Start a session for a farm id (nil = ad-hoc). Returns the session or nil, "active".
function Session.Start(farmId)
    if Session.Active() then return nil, "active" end
    local farm = farmId and ns.Farms.Get(farmId) or nil
    local now = time()
    local s = {
        farmId = farm and farm.id or nil, started = now, accumulated = 0, runningSince = now,
        items = {}, links = {}, rawGold = 0, realized = 0, durabilityUsed = 0,
        missing = Session.MissingDurability(), lastActivity = now,
    }
    module.db.char.active = s
    wipe(unexplained)
    ScheduleAutoPause()
    Emit("start")
    return s
end

function Session.Pause()
    local s = Session.Active()
    if not s or not s.runningSince then return false end
    s.accumulated = Session.Duration(s)
    s.runningSince = nil
    s.autoPaused = nil
    autoPauseToken = autoPauseToken + 1
    Emit("pause")
    return true
end

function Session.Resume()
    local s = Session.Active()
    if not s or s.runningSince then return false end
    s.runningSince = time()
    s.lastActivity = s.runningSince
    s.autoPaused = nil
    s.missing = Session.MissingDurability()
    ScheduleAutoPause()
    Emit("resume")
    return true
end

--- Value of the active (or given) session right now.
function Session.Evaluate(s)
    s = s or Session.Active()
    if not s then return nil end
    return ns.Valuation.Compute({
        items = s.items, rawGold = s.rawGold, realized = s.realized,
        repair = Session.RepairCost(s), duration = Session.Duration(s),
    })
end

--- Stop the active session, store its summary in the farm history and return it.
function Session.Stop()
    local s = Session.Active()
    if not s then return nil end
    local v = Session.Evaluate(s)
    local farm = s.farmId and ns.Farms.Get(s.farmId) or nil
    local items, links, values = {}, {}, {}
    for key, qty in pairs(s.items) do items[key] = qty end
    for key, link in pairs(s.links or {}) do links[key] = link end
    for _, item in ipairs(v.items) do values[item.key] = item.value end
    local summary = {
        farmId = farm and farm.id or nil, farmName = farm and farm.name or nil,
        char = module.db.charKey, started = s.started, duration = Session.Duration(s),
        items = items, links = links, values = values, market = v.market, vendor = v.vendor, speculative = v.speculative,
        rawGold = v.rawGold, repair = v.repair, total = v.total, gph = v.gph, realized = v.realized,
        repairKnown = Session.RepairRate() ~= nil,
        nodes = s.nodes and s.nodes.total > 0 and CopyTable(s.nodes) or nil,
    }
    ns.Farms.AddSummary(summary)
    module.db.char.active = nil
    autoPauseToken = autoPauseToken + 1
    wipe(unexplained)
    ns.API.Emit("GATHERER_SESSION", { action = "stop", summary = summary })
    return summary
end

--- Rebuild the valuation of a stored summary (for the summary window).
function Session.SummaryValuation(summary)
    local v = ns.Valuation.Compute({ items = summary.items, rawGold = summary.rawGold,
        realized = summary.realized, repair = summary.repair, duration = summary.duration })
    -- stored totals keep the value at the time of the stop
    v.market, v.vendor, v.speculative = summary.market, summary.vendor, summary.speculative
    v.total, v.gph = summary.total, summary.gph
    if summary.values then
        for _, item in ipairs(v.items) do item.value = summary.values[item.key] or item.value end
        table.sort(v.items, function(a, b)
            if a.value == b.value then return a.key < b.key end
            return a.value > b.value
        end)
    end
    return v
end

-- Capture --------------------------------------------------------------------
local function AnyWindow(ctx, keys)
    local recent = ctx.recent or {}
    for i = 1, #keys do
        if ctx[keys[i]] or recent[keys[i]] then return true end
    end
    return false
end

local function OnLoot(_, p)
    local s = Session.Active()
    if not s or not s.runningSince then return end
    if p.source and (p.source.kind == "craft" or p.source.kind == "disenchant") then return end
    local ctx = p.context or {}
    if not p.restricted and AnyWindow(ctx, NOT_FARMED) then return end
    s.items[p.itemKey] = (s.items[p.itemKey] or 0) + p.quantity
    s.links[p.itemKey] = s.links[p.itemKey] or p.link
    Activity()
    if ns.NodeTracker then ns.NodeTracker.OnLoot(p) end
    if ns.Highlights and ns.Highlights.OnLoot then ns.Highlights.OnLoot(p) end
    Emit("update")
end

local function IsLootMoney(p)
    -- replayed or reconciled after the restricted mode (boss encounter): loot
    if p.restricted or p.reconciled then return true end
    local ctx = p.context or {}
    local marks = ctx.marks or {}
    if marks.questReward then return false end
    for i = 1, #NOT_LOOT_MONEY do
        if ctx[NOT_LOOT_MONEY[i]] then return false end
    end
    local recent = ctx.recent or {}
    if ctx.loot or marks.lootMoney or recent.loot then return true end
    return false
end

local function OnMoney(_, p)
    local s = Session.Active()
    if not s or not s.runningSince or p.scope ~= "player" then return end
    s.realized = s.realized + p.amount
    if p.amount > 0 then
        if IsLootMoney(p) then
            s.rawGold = s.rawGold + p.amount
            Activity()
        else
            unexplained[#unexplained + 1] = { amount = p.amount, time = GetTime() }
            if #unexplained > 10 then table.remove(unexplained, 1) end
        end
    end
    Emit("update")
end

-- The loot chat line can arrive after the money (autoloot): move the most recent
-- unexplained gain to raw gold.
local function OnMoneyChat(_, msg)
    if ns.API.IsRestricted() or (issecretvalue and issecretvalue(msg)) then return end
    local s = Session.Active()
    if not s or not s.runningSince then return end
    local now = GetTime()
    for i = #unexplained, 1, -1 do
        local entry = unexplained[i]
        table.remove(unexplained, i)
        if now - entry.time <= RECLASSIFY_WINDOW then
            s.rawGold = s.rawGold + entry.amount
            Activity()
            Emit("update")
            return
        end
    end
end

local function OnContext(_, p)
    if p.key == "merchant" and p.active then LearnRepairRate() end
end

function Session.OnLogout()
    local s = Session.Active()
    if s and s.runningSince then
        s.accumulated = Session.Duration(s)
        s.runningSince = nil
        s.resumeAt = time()
    end
end

function Session.Enable(m)
    module = m
    local s = Session.Active()
    if s then
        s.missing = Session.MissingDurability()
        if s.resumeAt and time() - s.resumeAt <= RESUME_GRACE then
            s.runningSince = time()
            s.lastActivity = s.runningSince
        end
        s.resumeAt = nil
        ScheduleAutoPause()
    end
    m:On("LOOT_RECEIVED", OnLoot)
    m:On("MONEY_DELTA", OnMoney)
    m:On("CONTEXT_CHANGED", OnContext)
    m:RegisterEvent("UPDATE_INVENTORY_DURABILITY", OnDurability)
    m:RegisterEvent("CHAT_MSG_MONEY", OnMoneyChat)
end

function Session.Disable()
    autoPauseToken = autoPauseToken + 1
    wipe(unexplained)
end
