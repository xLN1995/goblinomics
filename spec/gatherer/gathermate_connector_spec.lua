-- Gathering nodes: the core registry (API.Nodes) and the GatherMate2 connector.
local C = require("spec.support.connectors")

describe("Nodes: GatherMate2 connector", function()
    after_each(function()
        assert.same({}, WoWMock.errors)
        C.cleanup()
    end)

    local ns

    local ZONES = {
        [2395] = {
            Mining = { { 0.10, 0.20, 1249 }, { 0.11, 0.21, 1249 }, { 0.50, 0.50, 1250 } },
            ["Herb Gathering"] = { { 0.30, 0.40, 1481 } },
        },
        [2405] = { Mining = { { 0.5, 0.5, 1245 } } },
    }
    local NAMES = {
        Mining = { [1249] = "Umbral Tin", [1250] = "Umbral Tin Seam", [1245] = "Brilliant Silver" },
        ["Herb Gathering"] = { [1481] = "Argentleaf" },
    }

    before_each(function()
        C.gathermate(ZONES, NAMES)
        ns = C.boot({}, { C.GM2 })
        WoWMock.flush()
    end)

    it("registers GatherMate2 as the node source and lists types and zones", function()
        local API = ns.API
        assert.is_true(API.Nodes:Available())
        local types = API.Nodes:Types()
        assert.equals("Herb Gathering", types[1].key)
        assert.equals("Herbalism", types[1].label)
        assert.equals("Timber", types[7].label)
        assert.same({ 2395, 2405 }, API.Nodes:Zones())
    end)

    it("reads the nodes of a zone with their position, name and icon", function()
        local API = ns.API
        local list = API.Nodes:List(2395, "Mining")
        assert.equals(3, #list)
        local found
        for _, n in ipairs(list) do if n.id == 1250 then found = n end end
        assert.equals(0.5, found.x)
        assert.equals(0.5, found.y)
        assert.same({ "Umbral Tin", "tin.tga" }, { API.Nodes:Info("Mining", 1249) })
        assert.same({}, API.Nodes:List(2395, "Fishing"))
        assert.same({}, API.Nodes:List(2395, "Unknown"))
    end)

    it("groups a zone's nodes by type with their count", function()
        local catalog = ns.API.Nodes:Catalog(2395)
        assert.equals(2, #catalog)
        assert.equals("Herb Gathering", catalog[1].type)
        assert.equals("Mining", catalog[2].type)
        assert.same({ id = 1249, name = "Umbral Tin", icon = "tin.tga", count = 2 }, catalog[2].nodes[1])
        assert.equals(1, catalog[2].nodes[2].count)
    end)

    it("tells a zone's expansion from its ore and herb nodes", function()
        assert.equals(11, ns.API.Nodes:ZoneExpansion(2395))
        assert.is_nil(ns.API.Nodes:ZoneExpansion(9999))
    end)

    it("identifies a node by its localized name", function()
        assert.same({ "Mining", 1250 }, { ns.API.Nodes:Identify("Umbral Tin Seam") })
        assert.same({ "Herb Gathering", 1481 }, { ns.API.Nodes:Identify("Argentleaf") })
        assert.is_nil(ns.API.Nodes:Identify("Copper Vein"))
        assert.is_nil(ns.API.Nodes:Identify(""))
    end)

    it("emits NODES_CHANGED once when GatherMate2 learns several nodes", function()
        local count = 0
        ns.API.On("NODES_CHANGED", function() count = count + 1 end, "spec")
        C.sendMessage("GatherMate2NodeAdded", 2395, "Mining", 123, "Umbral Tin")
        C.sendMessage("GatherMate2NodeAdded", 2395, "Mining", 456, "Umbral Tin")
        WoWMock.advance(2)
        WoWMock.flush()
        assert.equals(1, count)
    end)

    it("measures a zone in yards from two world positions", function()
        WoWMock.maps[2395] = { name = "Eversong Woods", left = 1000, top = 5000, width = 4000, height = 2600 }
        assert.same({ 4000, 2600 }, { ns.API.Nodes:ZoneYards(2395) })
        assert.is_nil(ns.API.Nodes:ZoneYards(1))
        assert.equals("Eversong Woods", ns.API.Nodes:ZoneName(2395))
        WoWMock.mapID = 2395
        assert.equals(2395, ns.API.Nodes:CurrentZone())
    end)
end)

describe("Nodes: without a source", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    it("answers with empty lists", function()
        local ns = load_core({ boot = true })
        assert.is_false(ns.API.Nodes:Available())
        assert.same({}, ns.API.Nodes:Catalog(2395))
        assert.is_nil(ns.API.Nodes:Identify("Umbral Tin"))
    end)
end)
