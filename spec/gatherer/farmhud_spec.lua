-- Full-screen farm HUD: following a route (radar projection, joining, moving on,
-- laps, speed) and when the HUD shows, hides and replaces the small session HUD.
local C = require("spec.support.connectors")

describe("Gatherer: farm HUD", function()
    after_each(function()
        assert.same({}, WoWMock.errors)
        C.cleanup()
    end)

    local pns, Follow

    -- a square of four stops, 100 x 100 yards apart, in a 1000 x 1000 yard zone
    local ROUTE = { zone = 2395, radius = 15, stops = {
        { x = 0.1, y = 0.1, n = 1 }, { x = 0.2, y = 0.1, n = 3 }, { x = 0.2, y = 0.2, n = 1 }, { x = 0.1, y = 0.2, n = 1 },
    } }

    before_each(function()
        C.gathermate({ [2395] = { Mining = { { 0.1, 0.1, 1249 }, { 0.2, 0.1, 1249 }, { 0.2, 0.2, 1249 }, { 0.1, 0.2, 1249 } } } },
            { Mining = { [1249] = "Umbral Tin" } })
        pns = select(2, load_gatherer({ before = function()
            load_addon_file(C.GM2.path, C.GM2.addon, {})
            WoWMock.fire("ADDON_LOADED", C.GM2.addon)
        end }))
        Follow = pns.RouteFollow
        WoWMock.maps[2395] = { name = "Eversong Woods", left = 0, top = 0, width = 1000, height = 1000 }
    end)

    describe("following", function()
        it("turns the radar so the facing points up", function()
            local x, y = Follow.Project(0, -100, 0)        -- 100 yd north, facing north
            assert.is_true(math.abs(x) < 1e-9 and math.abs(y - 100) < 1e-9)
            x, y = Follow.Project(-100, 0, math.pi / 2)    -- 100 yd west, facing west
            assert.is_true(math.abs(x) < 1e-9 and math.abs(y - 100) < 1e-9)
            x, y = Follow.Project(0, -100, math.pi / 2)    -- north is to the right when facing west
            assert.is_true(math.abs(x - 100) < 1e-9 and math.abs(y) < 1e-9)
        end)

        it("joins at the nearest stop and moves on in the round's direction", function()
            local state = {}
            assert.is_true(Follow.Advance(state, ROUTE, 0.19, 0.19, 1000, 1000))
            assert.equals(3, state.index)
            assert.is_false(Follow.Advance(state, ROUTE, 0.15, 0.15, 1000, 1000))
            assert.is_true(Follow.Advance(state, ROUTE, 0.2, 0.195, 1000, 1000))   -- 5 yd from stop 3
            assert.equals(4, state.index)
            Follow.Advance(state, ROUTE, 0.1, 0.2, 1000, 1000)
            assert.same({ 1, 1 }, { state.index, state.laps })                     -- past the end: a lap
        end)

        it("jumps ahead to a later stop within reach and skips by key", function()
            local route = { zone = 1, radius = 15, stops = {} }
            for i = 1, 10 do route.stops[i] = { x = i / 20, y = 0.5, n = 1 } end
            local state = { index = 1 }
            assert.is_true(Follow.Advance(state, route, 6 / 20, 0.5, 1000, 1000))   -- stop 6 = 5 after the next
            assert.equals(7, state.index)
            assert.is_false(Follow.Advance(state, route, 3 / 20, 0.5, 1000, 1000))  -- 6 places on: too far
            Follow.Move(state, route, 1)
            assert.equals(8, state.index)
            assert.equals(7, state.reached)
        end)

        it("keeps what is known about each node on this lap", function()
            local points = { { x = 0.1, y = 0.1 }, { x = 0.2, y = 0.1 }, { x = 0.3, y = 0.1 } }
            local state = {}
            -- passing node 1 within reach without seeing it: gone, once out of reach
            Follow.Observe(state, points, 0.105, 0.1, 1000, 1000)
            assert.is_nil(state.nodes[Follow.NodeKey(points[1])])
            Follow.Observe(state, points, 0.15, 0.1, 1000, 1000)
            assert.equals("gone", state.nodes[Follow.NodeKey(points[1])])
            -- node 2 shows as interact target: seen, also after leaving
            Follow.Observe(state, points, 0.205, 0.1, 1000, 1000)
            Follow.Mark(state, points, 0.205, 0.1, 1000, 1000, "seen")
            Follow.Observe(state, points, 0.26, 0.1, 1000, 1000)
            assert.equals("seen", state.nodes[Follow.NodeKey(points[2])])
            -- mining wins over seen; seen does not undo mined
            Follow.Mark(state, points, 0.2, 0.1, 1000, 1000, "gathered")
            Follow.Mark(state, points, 0.2, 0.1, 1000, 1000, "seen")
            assert.equals("gathered", state.nodes[Follow.NodeKey(points[2])])
            assert.is_nil(Follow.Mark(state, points, 0.5, 0.5, 1000, 1000, "seen"))   -- nothing near
            -- a new lap starts unchecked
            state.index = 4
            Follow.Move(state, ROUTE, 1)
            assert.same({}, state.nodes)
        end)

        it("measures the travel speed while moving", function()
            local state = {}
            assert.equals(pns.Route.FLIGHT_YPS, Follow.Speed(state, 0, 0, 0))
            Follow.Speed(state, 1, 40, 0)
            assert.equals(40, Follow.Speed(state, 2, 80, 0))
            assert.equals(40, Follow.Speed(state, 6, 80, 0))   -- standing still keeps the last speed
        end)
    end)

    describe("showing", function()
        local farm, Session, FarmHUD

        before_each(function()
            farm = pns.Farms.Create({ name = "Tin", category = "gathering", zone = 2395,
                nodes = { { type = "Mining", id = 1249 } }, route = ROUTE })
            Session, FarmHUD = pns.Session, pns.FarmHUD
            WoWMock.mapID = 2395
            WoWMock.mapPos = { 0.18, 0.1 }   -- 20 yd before stop 2
        end)

        local function hud() return _G.GoblinomicsGathererFarmHUD end
        -- one radar update (the mock does not run OnUpdate scripts by itself)
        local function tick()
            local f = hud()
            local fn = f and f:GetScript("OnUpdate")
            if fn then fn(f, 0.1) end
        end

        it("shows by hotkey in the farm's zone and replaces the small HUD", function()
            Session.Start(farm.id)
            assert.is_false(FarmHUD.IsShown())
            assert.is_true(pns.HUD.IsShown())
            Goblinomics.API.v1.Gatherer.ToggleFarmHUD()
            assert.is_true(FarmHUD.IsShown())
            assert.is_false(pns.HUD.IsShown())
            assert.equals(2, FarmHUD.State().index)            -- the nearest stop
            tick()
            local text = hud().panel.next[1]:GetText()
            assert.is_truthy(text:find("Stop 2: 20 yd"))
            assert.is_truthy(text:find("(3 nodes)", 1, true))
            assert.is_truthy(hud().panel.round:GetText():find("Stop 2/4"))
            -- the next three stops along the round, distances add up
            assert.is_truthy(hud().panel.next[2]:GetText():find("Stop 3: 120 yd"))
            assert.is_truthy(hud().panel.next[3]:GetText():find("Stop 4: 220 yd"))
            Goblinomics.API.v1.Gatherer.SkipStop()
            assert.equals(3, FarmHUD.State().index)
            Goblinomics.API.v1.Gatherer.ToggleFarmHUD()
            assert.is_false(FarmHUD.IsShown())
            assert.is_true(pns.HUD.IsShown())
        end)

        it("hides in combat, in instances and outside the zone and comes back", function()
            Session.Start(farm.id)
            FarmHUD.Toggle()
            assert.is_true(FarmHUD.IsShown())
            WoWMock.combat = true
            WoWMock.fire("PLAYER_REGEN_DISABLED")
            assert.is_false(FarmHUD.IsShown())
            WoWMock.combat = false
            WoWMock.fire("PLAYER_REGEN_ENABLED")
            assert.is_true(FarmHUD.IsShown())
            WoWMock.mapID = 2405
            tick()
            assert.is_false(FarmHUD.IsShown())
            WoWMock.mapID = 2395
            WoWMock.advance(1)
            assert.is_true(FarmHUD.IsShown())
            WoWMock.inInstance = true
            tick()
            assert.is_false(FarmHUD.IsShown())
        end)

        it("shows only in the farm's zone and its child maps, not in a neighbouring zone", function()
            WoWMock.maps[2395] = { name = "Eversong Woods", left = 0, top = 0, width = 1000, height = 1000 }
            WoWMock.maps[2437] = { name = "Zul'Aman", left = 0, top = 0, width = 1000, height = 1000 }
            WoWMock.maps[9001] = { name = "Cave", parent = 2395, left = 0, top = 0, width = 100, height = 100 }
            -- the client gives a position on the farm's map in the neighbouring zone, too
            WoWMock.mapPosAnywhere = true
            local route = { zone = 2395 }
            assert.is_not_nil(FarmHUD.Position(route))
            WoWMock.mapID = 2437
            assert.is_nil(FarmHUD.Position(route))
            WoWMock.mapID = 9001
            assert.is_not_nil(FarmHUD.Position(route))
            WoWMock.mapID, WoWMock.mapPos = 2395, { 1.2, 0.5 }
            assert.is_nil(FarmHUD.Position(route))
        end)

        it("shows by itself only when the setting is on, and never without a route", function()
            GoblinomicsGathererDB.settings.farmHudAuto = true
            Session.Start(farm.id)
            assert.is_true(FarmHUD.IsShown())
            Session.Stop()
            assert.is_false(FarmHUD.IsShown())
            local plain = pns.Farms.Create({ name = "Plain", category = "gathering" })
            Session.Start(plain.id)
            assert.is_false(FarmHUD.IsShown())
            assert.is_false(FarmHUD.Toggle())
            assert.is_true(pns.HUD.IsShown())
        end)

        it("switches with the button in the small session window and back from the side panel", function()
            Session.Start(farm.id)
            local small = _G.GoblinomicsGathererHUD
            assert.is_true(small.farmHud:IsShown())
            small.farmHud:GetScript("OnClick")(small.farmHud, "LeftButton")
            assert.is_true(FarmHUD.IsShown())
            assert.is_false(small:IsShown())
            local off = hud().panel.off
            off:GetScript("OnClick")(off, "LeftButton")
            assert.is_false(FarmHUD.IsShown())
            assert.is_true(small:IsShown())
            -- no route: no button
            Session.Stop()
            Session.Start(pns.Farms.Create({ name = "Plain", category = "gathering" }).id)
            assert.is_false(small.farmHud:IsShown())
        end)

        describe("with the minimap", function()
            local cluster, button

            before_each(function()
                cluster = CreateFrame("Frame", "MinimapCluster", UIParent)
                local mm = CreateFrame("Minimap", "Minimap", cluster)
                mm:SetPoint("TOPRIGHT", cluster, "TOPRIGHT", -10, -20)
                local zoom, alpha = 3, 1
                function mm.SetZoom(_, z) zoom = z end
                function mm.GetZoom() return zoom end
                function mm.SetAlpha(_, a) alpha = a end
                function mm.GetAlpha() return alpha end
                _G.Minimap = mm
                button = CreateFrame("Button", "SomeMinimapButton", mm)
                button:SetPoint("CENTER", Minimap, "BOTTOMLEFT", 5, 5)
                WoWMock.viewRadius = 233
            end)

            after_each(function() _G.Minimap = nil end)

            it("lends the minimap to the radar and gives it back as it was", function()
                Session.Start(farm.id)
                FarmHUD.Toggle()
                local f = hud()
                assert.is_true(pns.MinimapRadar.IsLent())
                assert.equals(f.radar, Minimap:GetParent())
                assert.same({ 0, 0, "1" }, { Minimap:GetZoom(), Minimap:GetAlpha(), WoWMock.cvars.rotateMinimap })
                assert.equals(233, f.yards)
                assert.is_false(f.player:IsShown())
                assert.is_true(button:GetParent() ~= Minimap)                  -- waits on the hidden stand-in
                Minimap:SetZoom(4)                                              -- someone zooms: kept at 0
                assert.equals(0, Minimap:GetZoom())
                -- a minimap addon puts it back at its place: anchored to the radar again
                Minimap:ClearAllPoints()
                Minimap:SetPoint("CENTER", UIParent, "CENTER", 967, 500)
                assert.same({ "CENTER", f.radar, "CENTER", 0, 0 }, { Minimap:GetPoint(1) })
                assert.equals(1, Minimap:GetNumPoints())
                FarmHUD.Toggle()
                assert.is_false(pns.MinimapRadar.IsLent())
                assert.equals(cluster, Minimap:GetParent())
                assert.same({ "TOPRIGHT", cluster, "TOPRIGHT", -10, -20 }, { Minimap:GetPoint(1) })
                assert.same({ 3, 1, "0" }, { Minimap:GetZoom(), Minimap:GetAlpha(), WoWMock.cvars.rotateMinimap })
                assert.equals(Minimap, button:GetParent())
                assert.same({ "CENTER", Minimap, "BOTTOMLEFT", 5, 5 }, { button:GetPoint(1) })
            end)

            it("gives the minimap back in combat, at logout and when switched off", function()
                Session.Start(farm.id)
                FarmHUD.Toggle()
                WoWMock.combat = true
                WoWMock.fire("PLAYER_REGEN_DISABLED")
                assert.is_false(pns.MinimapRadar.IsLent())
                WoWMock.combat = false
                WoWMock.fire("PLAYER_REGEN_ENABLED")
                assert.is_true(pns.MinimapRadar.IsLent())
                WoWMock.fire("PLAYER_LOGOUT")
                assert.equals("0", WoWMock.cvars.rotateMinimap)
                FarmHUD.Refresh()
                pns.Gatherer.db.settings.farmHudMinimap = false   -- the saved copy was replaced at logout
                FarmHUD.UseMinimap()
                assert.is_false(pns.MinimapRadar.IsLent())
                assert.equals(300, hud().yards)
                assert.is_true(hud().player:IsShown())
            end)
        end)

        it("stays off after a reload until switched on, then follows the stored route", function()
            Session.Start(farm.id)
            FarmHUD.Toggle()
            assert.is_true(FarmHUD.IsShown())
            WoWMock.fire("PLAYER_LOGOUT")
            local saved, now = GoblinomicsGathererDB, WoWMock.now
            pns = select(2, load_gatherer({ before = function()
                WoWMock.now = now + 5
                _G.GoblinomicsGathererDB = saved
                load_addon_file(C.GM2.path, C.GM2.addon, {})
                WoWMock.fire("ADDON_LOADED", C.GM2.addon)
            end }))
            WoWMock.mapID, WoWMock.mapPos = 2395, { 0.18, 0.1 }   -- the reload reset the mock world
            WoWMock.maps[2395] = { name = "Eversong Woods", left = 0, top = 0, width = 1000, height = 1000 }
            assert.is_false(pns.FarmHUD.IsShown())
            pns.FarmHUD.Toggle()
            assert.is_true(pns.FarmHUD.IsShown())
            assert.is_function(hud():GetScript("OnUpdate"))
            tick()
            assert.is_truthy(hud().panel.next[1]:GetText():find("Stop 2"))
        end)

        it("colours the nodes: yellow until mined or found empty, then grey", function()
            local C = Goblinomics.API.v1.Theme.colors
            assert.equals(C.gold, FarmHUD.NodeColor(nil))
            assert.equals(C.gold, FarmHUD.NodeColor("seen"))
            assert.equals(C.neutral, FarmHUD.NodeColor("gathered"))
            assert.equals(C.neutral, FarmHUD.NodeColor("gone"))
            Session.Start(farm.id)
            FarmHUD.Toggle()
            tick()
            -- the interact target shows the node at stop 2: seen
            WoWMock.mapPos = { 0.199, 0.1 }
            WoWMock.fire("PLAYER_SOFT_INTERACT_CHANGED", nil, "GameObject-0-1-2-3-4-0001")
            assert.equals("seen", FarmHUD.State().nodes["0.2000:0.1000"])
            -- mining it (the session counts a node): mined
            local s = Session.Active()
            s.nodes = { total = 1, by = { unknown = 1 } }
            tick()
            assert.equals("gathered", FarmHUD.State().nodes["0.2000:0.1000"])
        end)

        it("puts the side panel where the small session window stands, dragging either moves both", function()
            Session.Start(farm.id)
            local small = _G.GoblinomicsGathererHUD
            assert.same({ "TOPRIGHT", UIParent, "TOPRIGHT", -260, -200 }, { small:GetPoint(1) })
            FarmHUD.Toggle()
            local panel = hud().panel
            assert.same({ "TOPRIGHT", UIParent, "TOPRIGHT", -260, -200 }, { panel:GetPoint(1) })
            -- drag the panel: the small window follows
            panel:GetScript("OnDragStart")(panel)
            panel:ClearAllPoints()
            panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 300, -120)
            panel:GetScript("OnDragStop")(panel)
            FarmHUD.Toggle()
            assert.same({ "TOPLEFT", UIParent, "TOPLEFT", 300, -120 }, { small:GetPoint(1) })
            -- drag the small window: the panel follows
            small:ClearAllPoints()
            small:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 80)
            small:GetScript("OnDragStop")(small)
            FarmHUD.Toggle()
            assert.same({ "BOTTOM", UIParent, "BOTTOM", 0, 80 }, { panel:GetPoint(1) })
        end)

        it("switches the HUD with /gob farm hud and skips with /gob farm skip", function()
            Session.Start(farm.id)
            pns.Commands.Run("hud")
            assert.is_true(FarmHUD.IsShown())
            pns.Commands.Run("skip")
            assert.equals(3, FarmHUD.State().index)
            pns.Commands.Run("hud")
            assert.is_false(FarmHUD.IsShown())
        end)
    end)
end)
