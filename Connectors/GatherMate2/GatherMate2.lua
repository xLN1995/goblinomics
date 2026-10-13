if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Connectors/GatherMate2/GatherMate2.lua
-- GatherMate2 connector: the known gathering nodes of every zone as a node source
-- (API.Nodes) for Gatherer farms and routes. Read only, at runtime, through the
-- GatherMate2 addon object (GetNodesForZone, DecodeLoc, GetNameForNode,
-- GetIDForNode, nodeTextures); nothing is copied or written. New, deleted or
-- imported nodes (GatherMate2's AceEvent messages) mark the data as changed.
local ADDON_NAME = ...

local GM = _G.GatherMate2
if type(GM) ~= "table" or type(GM.GetNodesForZone) ~= "function" or type(GM.DecodeLoc) ~= "function" then return end
local API = Goblinomics and Goblinomics.API and Goblinomics.API.v1
if not API then return end

local Connector = API.RegisterModule(ADDON_NAME, {
    apiVersion = 1,
    name = "GatherMate2 Connector",
    description = function() return API.L["Gathering nodes from GatherMate2 for farms and routes."] end,
})

-- GatherMate2's node types (db_types) with our own labels
local LABELS = {
    ["Herb Gathering"] = function(L) return L["Herbalism"] end,
    ["Mining"] = function(L) return L["Mining"] end,
    ["Fishing"] = function(L) return L["Fishing"] end,
    ["Treasure"] = function(L) return L["Treasure"] end,
    ["Extract Gas"] = function(L) return L["Gas"] end,
    ["Archaeology"] = function(L) return L["Archaeology"] end,
    ["Logging"] = function(L) return L["Timber"] end,
}

local Source = { id = "gathermate2", name = "GatherMate2" }

function Source:Types()
    local out = {}
    for _, key in ipairs(type(GM.db_types) == "table" and GM.db_types or {}) do
        local label = LABELS[key]
        out[#out + 1] = { key = key, label = label and label(API.L) or key }
    end
    return out
end

--- Zones with at least one stored node. GatherMate2 keeps them in a base table per
-- type plus one table per storage addon (expansion); both are read, never changed.
function Source:Zones()
    local seen, out = {}, {}
    local function Add(storage)
        if type(storage) ~= "table" then return end
        for zone, nodes in pairs(storage) do
            if type(zone) == "number" and type(nodes) == "table" and next(nodes) and not seen[zone] then
                seen[zone] = true
                out[#out + 1] = zone
            end
        end
    end
    for _, db in pairs(type(GM.gmdbs) == "table" and GM.gmdbs or {}) do
        local raw = rawget(db, "__gm2_base_storage")
        if raw then
            Add(raw)
            for _, storage in pairs(rawget(db, "__gm2_storage_map") or {}) do Add(storage) end
        else
            Add(db)
        end
    end
    table.sort(out)
    return out
end

function Source:Nodes(uiMapID, nodeType)
    local out = {}
    if not (type(GM.gmdbs) == "table" and GM.gmdbs[nodeType]) then return out end
    for coord, id in GM:GetNodesForZone(uiMapID, nodeType, true) do
        if type(coord) == "number" and type(id) == "number" then
            local x, y = GM:DecodeLoc(coord)
            out[#out + 1] = { id = id, x = x, y = y }
        end
    end
    return out
end

function Source:NodeInfo(nodeType, id)
    local name = GM:GetNameForNode(nodeType, id)
    local textures = type(GM.nodeTextures) == "table" and GM.nodeTextures[nodeType]
    return name, textures and textures[id] or nil
end

function Source:Identify(name)
    for _, key in ipairs(type(GM.db_types) == "table" and GM.db_types or {}) do
        local ids = type(GM.nodeIDs) == "table" and GM.nodeIDs[key]
        local id = ids and ids[name]
        if id then return key, id end
    end
    return nil
end

local MESSAGES = { "GatherMate2NodeAdded", "GatherMate2NodeDeleted", "GatherMate2Cleanup", "GatherMate2DataImport" }
local listener = {}
local registered = false

function listener.OnMessage() API.Nodes:Changed() end

function Connector:OnEnable()
    API.Nodes:RegisterSource(Source)
    local AceEvent = LibStub and LibStub("AceEvent-3.0", true)
    if AceEvent and not registered then
        registered = true
        AceEvent:Embed(listener)
        for _, msg in ipairs(MESSAGES) do listener:RegisterMessage(msg, "OnMessage") end
    end
end

function Connector:OnDisable()
    API.Nodes:UnregisterSource(Source.id)
    if registered then
        registered = false
        listener:UnregisterAllMessages()
    end
end

-- for specs
Connector.source = Source
