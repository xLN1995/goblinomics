if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/Farms.lua
-- Farm definitions (name, category, raid or dungeon from the Encounter Journal,
-- highlight threshold, expected highlights: items that always notify the player
-- when looted in a session of this farm; for gathering and fishing a zone, the
-- nodes farmed there, several at once, and the flight route over them) and their
-- statistics from the stored session summaries (runs, average and best GPH, last
-- run, nodes per hour and gold per node).
local _, ns = ...

local Farms = {}
ns.Farms = Farms

local HISTORY_MAX = 200   -- summaries kept per farm
local AD_HOC = "adhoc"    -- sessions started without a farm
Farms.AD_HOC = AD_HOC

local module

local function Root() return module.db.root end

--- { journalID, mapID, name, isRaid } from a spec value, or nil (false/invalid clears).
function Farms.CleanInstance(value)
    if type(value) ~= "table" or type(value.name) ~= "string" or strtrim(value.name) == "" then return nil end
    return {
        journalID = tonumber(value.journalID), mapID = tonumber(value.mapID),
        name = strtrim(value.name):sub(1, 100), isRaid = value.isRaid == true,
    }
end

--- Gathering and fishing farms can have a zone and nodes.
function Farms.HasNodes(category) return category == "gathering" or category == "fishing" end

--- { { type, id } } from a spec value, without duplicates; nil when empty.
function Farms.CleanNodes(value)
    if type(value) ~= "table" then return nil end
    local out, seen = {}, {}
    for _, n in ipairs(value) do
        local t, id = type(n) == "table" and n.type, type(n) == "table" and tonumber(n.id)
        if type(t) == "string" and t ~= "" and id and not seen[t .. ":" .. id] then
            seen[t .. ":" .. id] = true
            out[#out + 1] = { type = t:sub(1, 40), id = id }
        end
    end
    return #out > 0 and out or nil
end

--- "type:id" key of a node.
function Farms.NodeKey(nodeType, id) return nodeType .. ":" .. id end

--- A route from the route computation, checked; nil when invalid.
function Farms.CleanRoute(value)
    if type(value) ~= "table" or type(value.stops) ~= "table" or #value.stops == 0 then return nil end
    local stops = {}
    for i = 1, math.min(#value.stops, ns.Route.MAX_STOPS) do
        local s = value.stops[i]
        local x, y, n = type(s) == "table" and tonumber(s.x), type(s) == "table" and tonumber(s.y), type(s) == "table" and tonumber(s.n)
        if not (x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1) then return nil end
        stops[i] = { x = x, y = y, n = math.max(1, math.floor(n or 1)) }
    end
    local zone = tonumber(value.zone)
    if not zone then return nil end
    return {
        zone = zone, radius = tonumber(value.radius) or ns.Route.RADIUS, nodes = tostring(value.nodes or ""),
        nodeCount = tonumber(value.nodeCount) or 0, stops = stops, clusters = tonumber(value.clusters) or 0,
        dropped = tonumber(value.dropped) or 0,
        length = tonumber(value.length) or 0, created = tonumber(value.created) or time(),
    }
end

--- "none", "ok", "stale" (zone or nodes changed since) or "grown" (more known nodes
-- now; still usable), plus the number of known nodes.
function Farms.RouteState(farm)
    local route = farm and farm.route
    if not route then return "none" end
    if route.zone ~= farm.zone or route.nodes ~= ns.Route.Signature(farm.nodes) then return "stale" end
    local known = #ns.Route.Points(farm.zone, farm.nodes)
    if known > route.nodeCount then return "grown", known end
    return "ok", known
end

local function Clean(spec, farm)
    farm = farm or {}
    if spec.name ~= nil then farm.name = strtrim(tostring(spec.name)) end
    if spec.category ~= nil then farm.category = tContains(ns.CATEGORIES, spec.category) and spec.category or "other" end
    if spec.expectedHighlights ~= nil then
        local items = {}
        for _, key in ipairs(spec.expectedHighlights) do
            if type(key) == "string" and not tContains(items, key) then items[#items + 1] = key end
        end
        farm.expectedHighlights = items
    end
    if spec.highlightThreshold ~= nil then
        local n = tonumber(spec.highlightThreshold)
        farm.highlightThreshold = (n and n > 0) and n or nil
    end
    if spec.instance ~= nil then
        farm.instance = Farms.CleanInstance(spec.instance)
    end
    if spec.zone ~= nil then
        local zone = tonumber(spec.zone)
        farm.zone = (zone and zone > 0) and zone or nil
    end
    if spec.nodes ~= nil then farm.nodes = Farms.CleanNodes(spec.nodes) end
    if spec.route ~= nil then farm.route = Farms.CleanRoute(spec.route) end
    if not Farms.HasNodes(farm.category) then farm.zone, farm.nodes, farm.route = nil, nil, nil end
    -- only raid and dungeon farms have an instance, and it must be of that kind
    local inst = farm.instance
    if inst and (not ns.IsInstanceCategory(farm.category) or inst.isRaid ~= (farm.category == "raid")) then
        farm.instance = nil
    end
    return farm
end

--- Create a farm; returns it, or nil and an error text.
function Farms.Create(spec)
    spec = spec or {}
    local name = spec.name and strtrim(tostring(spec.name)) or ""
    if name == "" then return nil, "name" end
    local root = Root()
    local id = "f" .. root.nextFarmId
    root.nextFarmId = root.nextFarmId + 1
    local farm = Clean(spec, { id = id, category = "other", expectedHighlights = {}, created = time() })
    root.farms[id] = farm
    ns.API.Emit("GATHERER_FARMS", { action = "create", id = id })
    return farm
end

function Farms.Update(id, spec)
    local farm = Root().farms[id]
    if not farm then return nil end
    if spec.name ~= nil and strtrim(tostring(spec.name)) == "" then return nil, "name" end
    Clean(spec, farm)
    ns.API.Emit("GATHERER_FARMS", { action = "update", id = id })
    return farm
end

function Farms.Delete(id)
    local root = Root()
    if not root.farms[id] then return false end
    root.farms[id] = nil
    root.history[id] = nil
    ns.API.Emit("GATHERER_FARMS", { action = "delete", id = id })
    return true
end

function Farms.Get(id) return Root().farms[id] end

--- Case-insensitive lookup by name.
function Farms.FindByName(name)
    if not name then return nil end
    local wanted = strtrim(name):lower()
    for _, farm in pairs(Root().farms) do
        if farm.name:lower() == wanted then return farm end
    end
    return nil
end

--- Farms sorted by name.
function Farms.List()
    local list = {}
    for _, farm in pairs(Root().farms) do list[#list + 1] = farm end
    table.sort(list, function(a, b)
        local an, bn = a.name:lower(), b.name:lower()
        if an == bn then return a.id < b.id end
        return an < bn
    end)
    return list
end

--- Store a finished session summary (newest first).
function Farms.AddSummary(summary)
    local root = Root()
    local id = summary.farmId or AD_HOC
    local list = root.history[id]
    if not list then
        list = {}
        root.history[id] = list
    end
    table.insert(list, 1, summary)
    for i = #list, HISTORY_MAX + 1, -1 do list[i] = nil end
end

--- Remove one stored summary (the same table) from a farm's history.
function Farms.DeleteSummary(id, summary)
    local list = Root().history[id or AD_HOC]
    if not list then return false end
    for i = 1, #list do
        if list[i] == summary then
            table.remove(list, i)
            ns.API.Emit("GATHERER_FARMS", { action = "history", id = id })
            return true
        end
    end
    return false
end

function Farms.History(id)
    return Root().history[id or AD_HOC] or {}
end

--- { runs, avgGPH, bestGPH, lastRun, totalDuration, total, nodes, nodeRuns, nodesPerHour,
-- goldPerNode } over the stored summaries. The node values come only from runs that
-- counted nodes.
function Farms.Stats(id)
    local list = Farms.History(id)
    local stats = { runs = #list, avgGPH = 0, bestGPH = 0, lastRun = nil, totalDuration = 0, total = 0,
        nodes = 0, nodeRuns = 0 }
    local nodeDuration, nodeTotal = 0, 0
    for i = 1, #list do
        local s = list[i]
        stats.totalDuration = stats.totalDuration + (s.duration or 0)
        stats.total = stats.total + (s.total or 0)
        local n = type(s.nodes) == "table" and s.nodes.total or 0
        if n > 0 then
            stats.nodes = stats.nodes + n
            stats.nodeRuns = stats.nodeRuns + 1
            nodeDuration = nodeDuration + (s.duration or 0)
            nodeTotal = nodeTotal + (s.total or 0)
        end
        if (s.gph or 0) > stats.bestGPH then stats.bestGPH = s.gph end
        if not stats.lastRun or (s.started or 0) > stats.lastRun then stats.lastRun = s.started end
    end
    -- average GPH over the total time, so short runs do not dominate
    if stats.totalDuration > 0 then
        stats.avgGPH = math.floor(stats.total * 3600 / stats.totalDuration + 0.5)
    end
    if stats.nodes > 0 then
        stats.goldPerNode = math.floor(nodeTotal / stats.nodes + 0.5)
        if nodeDuration > 0 then stats.nodesPerHour = math.floor(stats.nodes * 3600 / nodeDuration + 0.5) end
    end
    return stats
end

function Farms.Enable(m)
    module = m
end
