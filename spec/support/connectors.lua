-- Load connector addons into a booted core (the connector reads its API table then).
local M = {}

function M.tsm(data, valid)
    _G.TSM_API = {
        calls = {},
        GetCustomPriceValue = function(str, key)
            if type(key) ~= "string" or not key:match("^[ip]:%d+") then error("Invalid itemString") end
            table.insert(_G.TSM_API.calls, str .. "|" .. key)
            return data[str] and data[str][key]
        end,
        IsCustomPriceValid = function(str)
            if valid[str] then return true end
            return false, "Invalid price source"
        end,
        GetPriceSourceKeys = function(t)
            for _, k in ipairs({ "DBMarket", "DBRecent", "Destroy", "DBRegionSaleRate" }) do table.insert(t, k) end
            return t
        end,
    }
end

function M.auctionator(prices, disenchant, hasDB)
    local listeners = {}
    _G.Auctionator = {
        Database = hasDB ~= false and {} or nil,
        API = { v1 = {
            GetAuctionPriceByItemID = function(caller, id) assert(caller == "Goblinomics"); return prices["id:" .. id] end,
            GetAuctionPriceByItemLink = function(caller, link) assert(caller == "Goblinomics"); return prices[link] end,
            GetDisenchantPriceByItemLink = function(_, link) return disenchant[link] end,
            RegisterForDBUpdate = function(_, cb) table.insert(listeners, cb) end,
        } },
        FireUpdate = function() for _, cb in ipairs(listeners) do cb() end end,
    }
end

--- Fake GatherMate2: zones[uiMapID][type] = { { x, y, id } }; names[type][id] = name.
-- Its AceEvent messages go through a fake AceEvent-3.0 (M.sendMessage(msg)).
local handlers = {}
function M.gathermate(zones, names)
    local enc = function(x, y) return math.floor(x * 10000 + 0.5) * 1000000 + math.floor(y * 10000 + 0.5) * 100 end
    local gmdbs, nodeIDs, reverse = {}, {}, {}
    local types = { "Herb Gathering", "Mining", "Fishing", "Treasure", "Extract Gas", "Archaeology", "Logging" }
    for _, t in ipairs(types) do
        gmdbs[t] = setmetatable({ __gm2_base_storage = {}, __gm2_storage_map = { MN = {} } }, {
            __index = function(db, zone) return rawget(db, "__gm2_storage_map").MN[zone] end })
        nodeIDs[t], reverse[t] = {}, {}
    end
    for zone, byType in pairs(zones or {}) do
        for t, list in pairs(byType) do
            local nodes = {}
            for _, n in ipairs(list) do nodes[enc(n[1], n[2])] = n[3] end
            rawget(gmdbs[t], "__gm2_storage_map").MN[zone] = nodes
        end
    end
    for t, byID in pairs(names or {}) do
        for id, name in pairs(byID) do nodeIDs[t][name], reverse[t][id] = id, name end
    end
    _G.GatherMate2 = {
        db_types = types, gmdbs = gmdbs, nodeIDs = nodeIDs, reverseNodeIDs = reverse,
        nodeTextures = { Mining = { [1249] = "tin.tga" } },
        GetNodesForZone = function(_, zone, t) return pairs(gmdbs[t][zone] or {}) end,
        DecodeLoc = function(_, id) return math.floor(id / 1000000) / 10000, math.floor(id % 1000000 / 100) / 10000 end,
        GetNameForNode = function(self, t, id) return self.reverseNodeIDs[t][id] end,
    }
    local AceEvent = LibStub("AceEvent-3.0", true) or LibStub:NewLibrary("AceEvent-3.0", 1)
    function AceEvent.Embed(_, target)
        function target.RegisterMessage(obj, msg, method) handlers[msg] = function(...) obj[method](obj, msg, ...) end end
        function target.UnregisterAllMessages() for k in pairs(handlers) do handlers[k] = nil end end
        return target
    end
end

function M.sendMessage(msg, ...)
    if handlers[msg] then handlers[msg](...) end
end

--- Boot the core, load the given connector files, log in.
function M.boot(opts, files)
    local ns = load_core({ boot = true, money = opts.money or 1 })
    for _, f in ipairs(files) do
        load_addon_file(f.path, f.addon, {})
        WoWMock.fire("ADDON_LOADED", f.addon)
    end
    WoWMock.loggedIn = true
    WoWMock.fire("PLAYER_LOGIN")
    return ns
end

M.TSM = { path = "Connectors/TSM/TSM.lua", addon = "Goblinomics_Connector_TSM" }
M.AUC = { path = "Connectors/Auctionator/Auctionator.lua", addon = "Goblinomics_Connector_Auctionator" }
M.GM2 = { path = "Connectors/GatherMate2/GatherMate2.lua", addon = "Goblinomics_Connector_GatherMate2" }

function M.cleanup()
    _G.TSM_API = nil
    _G.Auctionator = nil
    _G.GatherMate2 = nil
end

return M
