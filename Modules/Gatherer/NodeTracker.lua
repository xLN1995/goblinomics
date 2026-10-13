if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/NodeTracker.lua
-- Counts the gathering nodes of a running session. A loot window whose source is a
-- game object (GetLootSourceInfo) is one node; the same object counts once within
-- REPEAT seconds. The name of the last spell target (UNIT_SPELLCAST_SENT, e.g.
-- "Umbral Tin") tells the node through the node source (API.Nodes:Identify);
-- without one, or for an unknown name, it counts as "unknown". Fishing loot is no node.
--   session.nodes = { total, by = { ["Mining:1249"] = n } }
-- The items of a node's loot window are learned per node in root.nodeLoot[key]
-- [itemKey] = quantity; the farm editor proposes them as expected highlights.
local _, ns = ...

local Tracker = {}
ns.NodeTracker = Tracker

local REPEAT = 60          -- seconds an object counts only once
local TARGET_WINDOW = 10   -- seconds between the cast and its loot window
local LOOT_GRACE = 2       -- loot chat lines arriving after the window closed
Tracker.UNKNOWN = "unknown"

local module
local target = nil         -- { name, time } of the last spell target
local seen = {}            -- object guid -> time counted
local current = nil        -- { key, open, closedAt } of the last node loot window

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

local function OnCastSent(_, unit, name)
    if unit ~= "player" or IsSecret(name) or type(name) ~= "string" or name == "" then return end
    target = { name = name, time = GetTime() }
end

--- Node key of the last spell target, or UNKNOWN.
function Tracker.Identify(now)
    if target and now - target.time <= TARGET_WINDOW then
        local nodeType, id = ns.API.Nodes:Identify(target.name)
        if nodeType and id then return ns.Farms.NodeKey(nodeType, id) end
    end
    return Tracker.UNKNOWN
end

--- Count a node in the session.
function Tracker.Count(s, key)
    s.nodes = s.nodes or { total = 0, by = {} }
    s.nodes.total = s.nodes.total + 1
    s.nodes.by[key] = (s.nodes.by[key] or 0) + 1
end

local function OnLootReady()
    local s = ns.Session.Active()
    if not s or not s.runningSince or (IsFishingLoot and IsFishingLoot()) then return end
    if GetNumLootItems() < 1 then return end
    local guid = GetLootSourceInfo(1)
    if IsSecret(guid) or type(guid) ~= "string" or not guid:match("^GameObject") then return end
    local now = GetTime()
    for g, at in pairs(seen) do if now - at > REPEAT then seen[g] = nil end end
    if seen[guid] then return end
    seen[guid] = now
    local key = Tracker.Identify(now)
    target = nil
    Tracker.Count(s, key)
    current = { key = key, open = true }
    ns.API.Emit("GATHERER_SESSION", { action = "update", session = s })
end

local function OnLootClosed()
    if current and current.open then
        current.open = false
        current.closedAt = GetTime()
    end
end

--- Called by the session for every farmed item: learn what a known node gives.
function Tracker.OnLoot(p)
    if not current or current.key == Tracker.UNKNOWN or not (p.source and p.source.kind == "object") then return end
    if not current.open and GetTime() - (current.closedAt or 0) > LOOT_GRACE then return end
    local root = module.db.root
    root.nodeLoot = root.nodeLoot or {}
    local byItem = root.nodeLoot[current.key] or {}
    root.nodeLoot[current.key] = byItem
    byItem[p.itemKey] = (byItem[p.itemKey] or 0) + (p.quantity or 1)
end

--- What the given nodes ({ { type, id } }) gave so far: { [itemKey] = quantity }.
function Tracker.Loot(nodes)
    local totals = {}
    local loot = module and module.db.root.nodeLoot or {}
    for _, n in ipairs(nodes or {}) do
        for key, qty in pairs(loot[ns.Farms.NodeKey(n.type, n.id)] or {}) do totals[key] = (totals[key] or 0) + qty end
    end
    return totals
end

--- "48 nodes (122/h, 2.5k per node)" for a session or summary with counted nodes, or nil.
function Tracker.Text(nodes, duration, total)
    local n = type(nodes) == "table" and nodes.total or 0
    if n <= 0 then return nil end
    local API = ns.API
    local parts = {}
    if (duration or 0) > 0 then parts[#parts + 1] = API.Lf("%d/h", math.floor(n * 3600 / duration + 0.5)) end
    if total and total > 0 then
        parts[#parts + 1] = API.Lf("%s per node", API.Money.Format(math.floor(total / n + 0.5), { abbreviate = true }))
    end
    local text = API.Lf("%d nodes", n)
    return #parts > 0 and (text .. " (" .. table.concat(parts, ", ") .. ")") or text
end

--- Name and icon of a node key ("Mining:1249"), from the node source.
function Tracker.NodeInfo(key)
    if key == Tracker.UNKNOWN then return ns.L["Unknown node"], nil end
    local nodeType, id = key:match("^(.+):(%d+)$")
    local name, icon = ns.API.Nodes:Info(nodeType, tonumber(id))
    return name or key, icon
end

function Tracker.Enable(m)
    module = m
    m:RegisterEvent("UNIT_SPELLCAST_SENT", OnCastSent)
    m:RegisterEvent("LOOT_READY", OnLootReady)
    m:RegisterEvent("LOOT_CLOSED", OnLootClosed)
end

function Tracker.Disable()
    target, current = nil, nil
    wipe(seen)
end
