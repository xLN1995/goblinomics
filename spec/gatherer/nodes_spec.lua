-- Gatherer with gathering nodes: farms with zone and nodes, nodes counted per
-- session, what a node gives, node statistics and the farm editor's node list.
local fake = require("spec.support.sources")
local C = require("spec.support.connectors")

local ORE = "|cffffffff|Hitem:236951::::::::80:::::|h[Umbral Tin Ore]|h|r"
local GEM = "|cffffffff|Hitem:236960::::::::80:::::|h[Voidglass]|h|r"

describe("Gatherer: gathering nodes", function()
    after_each(function()
        assert.same({}, WoWMock.errors)
        C.cleanup()
    end)

    local ns, pns, Session

    local function lootLine(link, qty)
        WoWMock.fire("CHAT_MSG_LOOT", "You receive loot: " .. link .. "x" .. qty .. ".", nil, nil, nil, nil, nil, nil,
            nil, nil, nil, nil, WoWMock.player.guid)
    end

    --- Gather one node: cast on its name, open its loot window, loot, close.
    local function gather(name, guid, loot)
        WoWMock.fire("UNIT_SPELLCAST_SENT", "player", name, "cast", 471013)
        WoWMock.loot = {}
        for i, l in ipairs(loot) do WoWMock.loot[i] = { link = l[1], sources = { guid, l[2] } } end
        WoWMock.fire("LOOT_READY")
        for _, l in ipairs(loot) do lootLine(l[1], l[2]) end
        WoWMock.fire("LOOT_CLOSED")
    end

    local function boot(withSource)
        if withSource then
            C.gathermate({ [2395] = { Mining = { { 0.1, 0.2, 1249 }, { 0.3, 0.3, 1249 }, { 0.5, 0.5, 1250 } },
                ["Herb Gathering"] = { { 0.4, 0.4, 1481 } } } },
                { Mining = { [1249] = "Umbral Tin", [1250] = "Umbral Tin Seam" }, ["Herb Gathering"] = { [1481] = "Argentleaf" } })
        end
        ns, pns = load_gatherer({ before = function()
            if withSource then
                load_addon_file(C.GM2.path, C.GM2.addon, {})
                WoWMock.fire("ADDON_LOADED", C.GM2.addon)
            end
        end })
        Session = pns.Session
        ns.Price.RegisterSource(fake("tsm", 10, { market = { ["i:236951"] = 1000, ["i:236960"] = 50000 } }))
    end

    describe("with GatherMate2", function()
        before_each(function() boot(true) end)

        it("keeps zone and nodes only for gathering and fishing farms", function()
            local farm = pns.Farms.Create({ name = "Tin", category = "gathering", zone = 2395,
                nodes = { { type = "Mining", id = 1249 }, { type = "Mining", id = 1249 }, { type = "Mining", id = "1250" },
                    { type = "", id = 1 }, "junk" } })
            assert.equals(2395, farm.zone)
            assert.same({ { type = "Mining", id = 1249 }, { type = "Mining", id = 1250 } }, farm.nodes)
            pns.Farms.Update(farm.id, { category = "raid" })
            assert.is_nil(farm.zone)
            assert.is_nil(farm.nodes)
        end)

        it("counts each node once per type and learns what it gives", function()
            Session.Start(nil)
            gather("Umbral Tin", "GameObject-0-1-2-3-4-0001", { { ORE, 3 } })
            gather("Umbral Tin", "GameObject-0-1-2-3-4-0001", { { ORE, 1 } })   -- the same object again
            gather("Umbral Tin Seam", "GameObject-0-1-2-3-4-0002", { { ORE, 5 }, { GEM, 1 } })
            gather("Copper Vein", "GameObject-0-1-2-3-4-0003", { { ORE, 1 } })
            -- a creature's loot window is no node
            WoWMock.loot = { { link = ORE, sources = { "Creature-0-1-2-3-4-0004", 1 } } }
            WoWMock.fire("LOOT_READY")
            WoWMock.fire("LOOT_CLOSED")
            local nodes = Session.Active().nodes
            assert.equals(3, nodes.total)
            assert.same({ ["Mining:1249"] = 1, ["Mining:1250"] = 1, unknown = 1 }, nodes.by)
            assert.same({ ["i:236951"] = 4 }, GoblinomicsGathererDB.nodeLoot["Mining:1249"])
            assert.same({ ["i:236951"] = 5, ["i:236960"] = 1 }, GoblinomicsGathererDB.nodeLoot["Mining:1250"])
            assert.is_nil(GoblinomicsGathererDB.nodeLoot.unknown)
            assert.same({ ["i:236951"] = 9, ["i:236960"] = 1 },
                pns.NodeTracker.Loot({ { type = "Mining", id = 1249 }, { type = "Mining", id = 1250 } }))
            assert.same({ "Umbral Tin Seam", nil }, { pns.NodeTracker.NodeInfo("Mining:1250") })
        end)

        it("does not count nodes while paused or for fishing loot", function()
            Session.Start(nil)
            Session.Pause()
            gather("Umbral Tin", "GameObject-0-1-2-3-4-0001", { { ORE, 1 } })
            Session.Resume()
            WoWMock.fishing = true
            gather("Umbral Tin", "GameObject-0-1-2-3-4-0005", { { ORE, 1 } })
            assert.is_nil(Session.Active().nodes)
        end)

        it("stores the nodes with the summary and averages them per farm", function()
            local farm = pns.Farms.Create({ name = "Tin", category = "gathering" })
            Session.Start(farm.id)
            gather("Umbral Tin", "GameObject-0-1-2-3-4-0001", { { ORE, 10 } })
            gather("Umbral Tin", "GameObject-0-1-2-3-4-0002", { { ORE, 10 } })
            WoWMock.advance(1800)
            local summary = Session.Stop()
            assert.same({ total = 2, by = { ["Mining:1249"] = 2 } }, summary.nodes)
            local stats = pns.Farms.Stats(farm.id)
            assert.equals(2, stats.nodes)
            assert.equals(1, stats.nodeRuns)
            assert.equals(4, stats.nodesPerHour)
            assert.equals(math.floor(summary.total / 2 + 0.5), stats.goldPerNode)
            assert.equals("2 nodes (4/h, " .. ns.API.Money.Format(stats.goldPerNode, { abbreviate = true })
                .. " per node)", pns.NodeTracker.Text(summary.nodes, summary.duration, summary.total))
            -- a run without nodes leaves the node values alone
            Session.Start(farm.id)
            WoWMock.advance(600)
            Session.Stop()
            assert.equals(4, pns.Farms.Stats(farm.id).nodesPerHour)
        end)

        it("exports and imports zone and nodes with the farm", function()
            local farm = pns.Farms.Create({ name = "Tin", category = "gathering", zone = 2395,
                nodes = { { type = "Mining", id = 1249 } } })
            local kind, created = pns.Strings.Import(pns.Strings.ExportFarms({ farm.id }))
            assert.equals("farms", kind)
            assert.equals(2395, created[1].zone)
            assert.same({ { type = "Mining", id = 1249 } }, created[1].nodes)
        end)

        it("lists the zone's nodes in the farm editor and saves the chosen ones", function()
            WoWMock.mapID = 2395
            WoWMock.maps[2395] = { name = "Eversong Woods", left = 0, top = 0, width = 4000, height = 3000 }
            pns.FarmEditor.Open(nil)
            local form = pns.FarmEditor.Form()
            assert.is_nil(form.zone)   -- where the player stands plays no part
            form.zone = 2395
            pns.FarmEditor.RefreshNodes()
            assert.is_true(pns.FarmEditor.ShowsNodes())
            local rows = _G.GoblinomicsGathererFarmEditor.nodeRows
            assert.equals("type", rows[1].kind)
            assert.equals("Herbalism", rows[1].label)
            assert.same({ "node", "Umbral Tin", 2 }, { rows[4].kind, rows[4].name, rows[4].count })
            form.name = "Tin"
            form.nodes[1] = { type = "Mining", id = 1249 }
            assert.is_true(pns.FarmEditor.Save())
            local farm = pns.Farms.FindByName("Tin")
            assert.equals(2395, farm.zone)
            assert.same({ { type = "Mining", id = 1249 } }, farm.nodes)
            -- open/fishing farms only; a dungeon farm has no node list
            pns.FarmEditor.Open(farm)
            pns.FarmEditor.Form().category = "dungeon"
            assert.is_false(pns.FarmEditor.ShowsNodes())
        end)

        it("offers the zones in a submenu per expansion, not the player's zone", function()
            _G.EXPANSION_NAME11 = "Midnight"
            WoWMock.mapID = 2405
            WoWMock.maps[2395] = { name = "Eversong Woods", left = 0, top = 0, width = 1, height = 1 }
            WoWMock.maps[2405] = { name = "Voidstorm", left = 0, top = 0, width = 1, height = 1 }
            local list = pns.FarmEditor.ZoneChoices()
            assert.equals(1, #list)
            assert.equals("Midnight", list[1].label)
            assert.same({ { value = 2395, label = "Eversong Woods" } }, list[1].children)
            _G.EXPANSION_NAME11 = nil
        end)

        it("adds only the rare finds of the chosen nodes as highlights", function()
            GoblinomicsGathererDB.nodeLoot = { ["Mining:1249"] = { ["i:236951"] = 95, ["i:236960"] = 5 } }
            pns.FarmEditor.Open(nil)
            local form = pns.FarmEditor.Form()
            form.nodes[1] = { type = "Mining", id = 1249 }
            pns.FarmEditor.AddFromNodes()
            assert.same({ "i:236960" }, form.expectedHighlights)
        end)
    end)

    describe("without a node source", function()
        before_each(function() boot(false) end)

        it("counts nodes as unknown and shows the hint instead of the node list", function()
            Session.Start(nil)
            gather("Umbral Tin", "GameObject-0-1-2-3-4-0001", { { ORE, 1 } })
            assert.same({ total = 1, by = { unknown = 1 } }, Session.Active().nodes)
            assert.is_nil(GoblinomicsGathererDB.nodeLoot)
            pns.FarmEditor.Open(nil)
            assert.is_false(pns.FarmEditor.ShowsNodes())
            assert.is_nil(pns.FarmEditor.Form().zone)
        end)
    end)
end)
