-- Routes: clustering nodes into stops, the shortest round over the stops, building
-- and running the computation over several frames.
local C = require("spec.support.connectors")

-- small deterministic random numbers (Park-Miller)
local function Rng(seed)
    local state = seed
    return function()
        state = (state * 16807) % 2147483647
        return state / 2147483647
    end
end

local function RandomStops(n, seed, size)
    local rnd = Rng(seed)
    local out = {}
    for i = 1, n do out[i] = { x = rnd() * (size or 1000), y = rnd() * (size or 1000) } end
    return out
end

local function BruteForce(Route, stops)
    local n = #stops
    local best = math.huge
    local perm, used = { 1 }, { true }
    local function Walk(depth)
        if depth > n then
            best = math.min(best, Route.Length(stops, perm))
            return
        end
        for j = 2, n do
            if not used[j] then
                used[j], perm[depth] = true, j
                Walk(depth + 1)
                used[j], perm[depth] = false, nil
            end
        end
    end
    Walk(2)
    return best
end

local function Segments(stops, order)
    local segs = {}
    for i = 1, #order do segs[i] = { stops[order[i]], stops[order[i % #order + 1]] } end
    return segs
end

local function Cross(a, b, c, d)
    local function Orient(p, q, r) return (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) end
    local o1, o2 = Orient(a, b, c), Orient(a, b, d)
    local o3, o4 = Orient(c, d, a), Orient(c, d, b)
    return o1 * o2 < 0 and o3 * o4 < 0
end

local function IsPermutation(order, n)
    if #order ~= n then return false end
    local seen = {}
    for _, i in ipairs(order) do
        if seen[i] or i < 1 or i > n then return false end
        seen[i] = true
    end
    return true
end

describe("Gatherer: routes", function()
    after_each(function()
        assert.same({}, WoWMock.errors)
        C.cleanup()
    end)

    local Route

    before_each(function()
        local _, pns = load_gatherer()
        Route = pns.Route
    end)

    describe("clustering", function()
        it("joins two nodes close together into one stop and keeps a lone node apart", function()
            local stops = Route.Cluster({ { x = 0, y = 0 }, { x = 10, y = 0 }, { x = 50, y = 0 } }, 15)
            assert.equals(2, #stops)
            table.sort(stops, function(a, b) return a.x < b.x end)
            assert.same({ 5, 0, 2 }, { stops[1].x, stops[1].y, stops[1].n })
            assert.same({ 50, 0, 1 }, { stops[2].x, stops[2].y, stops[2].n })
        end)

        it("makes one stop of a dense group", function()
            local stops = Route.Cluster({ { x = 100, y = 100 }, { x = 105, y = 102 }, { x = 98, y = 95 },
                { x = 103, y = 108 }, { x = 96, y = 104 } }, 15)
            assert.equals(1, #stops)
            assert.equals(5, stops[1].n)
        end)

        it("never puts a node more than the radius away from its stop", function()
            local points = RandomStops(400, 7, 600)
            local stops = Route.Cluster(points, 15)
            local covered = 0
            for _, s in ipairs(stops) do
                covered = covered + s.n
                for _, j in ipairs(s.members) do
                    local dx, dy = points[j].x - s.x, points[j].y - s.y
                    assert.is_true(math.sqrt(dx * dx + dy * dy) <= 15 + 1e-9)
                end
            end
            assert.equals(400, covered)
            assert.is_true(#stops < 400)
        end)
    end)

    describe("optimizing", function()
        it("finds the shortest round for a few stops", function()
            for seed = 1, 5 do
                local stops = RandomStops(8, seed)
                local order = Route.Optimize(stops)
                assert.is_true(IsPermutation(order, 8))
                assert.is_true(math.abs(Route.Length(stops, order) - BruteForce(Route, stops)) < 1e-6)
            end
        end)

        it("comes close to the shortest round for nine stops", function()
            for seed = 11, 15 do
                local stops = RandomStops(9, seed)
                local order = Route.Optimize(stops)
                assert.is_true(IsPermutation(order, 9))
                assert.is_true(Route.Length(stops, order) <= BruteForce(Route, stops) * 1.02)
            end
        end)

        it("leaves no crossing lines on a large round and beats the plain nearest neighbour", function()
            local stops = RandomStops(150, 42)
            local order = Route.Optimize(stops)
            assert.is_true(IsPermutation(order, 150))
            local segs = Segments(stops, order)
            for i = 1, #segs do
                for j = i + 2, #segs do
                    if not (i == 1 and j == #segs) then
                        assert.is_false(Cross(segs[i][1], segs[i][2], segs[j][1], segs[j][2]))
                    end
                end
            end
            -- plain nearest neighbour from the first stop
            local used, nn, cur = { [1] = true }, { 1 }, 1
            for _ = 2, #stops do
                local best, bestD
                for j = 1, #stops do
                    if not used[j] then
                        local d = (stops[cur].x - stops[j].x) ^ 2 + (stops[cur].y - stops[j].y) ^ 2
                        if not bestD or d < bestD then best, bestD = j, d end
                    end
                end
                used[best], cur = true, best
                nn[#nn + 1] = best
            end
            assert.is_true(Route.Length(stops, order) < Route.Length(stops, nn))
        end)

        it("gives the same round for the same stops, starting in the west", function()
            local stops = RandomStops(60, 3)
            local a, b = Route.Optimize(stops), Route.Optimize(stops)
            assert.same(a, b)
            for i = 1, #stops do assert.is_true(stops[a[1]].x <= stops[i].x) end
        end)

        it("handles one to three stops", function()
            assert.same({}, Route.Optimize({}))
            assert.same({ 1 }, Route.Optimize({ { x = 1, y = 1 } }))
            assert.same({ 1, 2, 3 }, Route.Optimize(RandomStops(3, 1)))
        end)
    end)

    describe("building", function()
        local pns

        before_each(function()
            local zone = {}
            local rnd = Rng(99)
            for i = 1, 120 do zone[i] = { rnd(), rnd(), i % 3 == 0 and 1250 or 1249 } end
            zone[121] = { 0.5, 0.5, 1245 }
            C.gathermate({ [2395] = { Mining = zone } }, { Mining = { [1249] = "Umbral Tin", [1250] = "Umbral Tin Seam",
                [1245] = "Brilliant Silver" } })
            pns = select(2, load_gatherer({ before = function()
                load_addon_file(C.GM2.path, C.GM2.addon, {})
                WoWMock.fire("ADDON_LOADED", C.GM2.addon)
            end }))
            Route = pns.Route
            WoWMock.maps[2395] = { name = "Eversong Woods", left = 0, top = 0, width = 4000, height = 3000 }
        end)

        it("builds a route over the chosen nodes of a zone", function()
            local nodes = { { type = "Mining", id = 1250 }, { type = "Mining", id = 1249 } }
            local route = Route.Build(2395, nodes)
            assert.equals(2395, route.zone)
            assert.equals(15, route.radius)
            assert.equals("Mining:1249,Mining:1250", route.nodes)
            assert.equals(120, route.nodeCount)
            local total = 0
            for _, s in ipairs(route.stops) do
                total = total + s.n
                assert.is_true(s.x >= 0 and s.x <= 1 and s.y >= 0 and s.y <= 1)
            end
            assert.equals(120, total)
            assert.is_true(route.length > 0)
            assert.equals(math.floor(route.length / 30 + 0.5), Route.LapSeconds(route))
            assert.same({ nil, "nodes" }, { Route.Build(2395, { { type = "Mining", id = 9 } }) })
            assert.same({ nil, "size" }, { Route.Build(1, nodes) })
        end)

        it("runs over several frames with progress and can be cancelled", function()
            local nodes = { { type = "Mining", id = 1249 } }
            local phases, result = {}, nil
            WoWMock.profileStep = 50   -- every clock read uses up the frame budget
            Route.Run(2395, nodes, function(phase) phases[phase] = true end, function(route) result = route end)
            local frames = 0
            while not result and frames < 10000 do
                WoWMock.advance(0)   -- one frame
                frames = frames + 1
            end
            WoWMock.profileStep = 0.01
            assert.same({}, WoWMock.errors)
            assert.is_table(result)
            assert.is_true(frames > 1)
            assert.same({ cluster = true, optimize = true }, phases)
            assert.same(Route.Build(2395, nodes).stops, result.stops)

            local done = false
            local cancel = Route.Run(2395, nodes, nil, function() done = true end)
            cancel()
            for _ = 1, 50 do WoWMock.advance(0); WoWMock.flush() end
            assert.is_false(done)
        end)

        local function finish()
            for _ = 1, 10000 do
                if not pns.RouteView.Result() then WoWMock.advance(0) else return end
            end
        end

        it("keeps a route with the farm and tells when it is out of date or more nodes are known", function()
            local nodes = { { type = "Mining", id = 1249 } }
            local route = Route.Build(2395, nodes)
            local farm = pns.Farms.Create({ name = "Tin", category = "gathering", zone = 2395, nodes = nodes, route = route })
            assert.equals(#route.stops, #farm.route.stops)
            assert.equals("ok", (pns.Farms.RouteState(farm)))
            pns.Farms.Update(farm.id, { nodes = { { type = "Mining", id = 1250 } } })
            assert.equals("stale", (pns.Farms.RouteState(farm)))
            pns.Farms.Update(farm.id, { nodes = nodes })
            farm.route.nodeCount = farm.route.nodeCount - 5
            assert.same({ "grown", 80 }, { pns.Farms.RouteState(farm) })
            -- invalid routes are dropped, false clears, and strings leave the route out
            assert.is_nil(pns.Farms.CleanRoute({ zone = 1, stops = { { x = 2, y = 0 } } }))
            local kind, created = pns.Strings.Import(pns.Strings.ExportFarms({ farm.id }))
            assert.equals("farms", kind)
            assert.is_nil(created[1].route)
            pns.Farms.Update(farm.id, { route = false })
            assert.is_nil(farm.route)
        end)

        it("places the zone's map tiles in rows", function()
            WoWMock.mapArt[2395] = { layer = { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 },
                textures = { 11, 12, 13, 14, 21, 22, 23, 24, 31, 32, 33, 34 } }
            local tiles = pns.RouteView.Tiles(2395, 501)
            assert.equals(12, #tiles)
            assert.same({ 22, 128, 128, 128, 128 }, { tiles[6].texture, tiles[6].x, tiles[6].y, tiles[6].w, tiles[6].h })
            assert.same({}, pns.RouteView.Tiles(1, 500))
        end)

        it("creates the route from the farm editor and saves it with the farm", function()
            WoWMock.mapID = 2395
            pns.FarmEditor.Open(nil)
            local form = pns.FarmEditor.Form()
            form.name = "Tin"
            local d = _G.GoblinomicsGathererFarmEditor
            assert.equals("Create route...", d.routeButton.label:GetText())
            form.nodes[1] = { type = "Mining", id = 1249 }
            pns.FarmEditor.RefreshRoute()
            assert.is_truthy(d.routeStatus:GetText():find("No route yet"))
            pns.RouteView.Open(form, pns.FarmEditor.RefreshRoute)
            finish()
            local view = _G.GoblinomicsGathererRouteView
            assert.is_truthy(view.facts:GetText():find("80 nodes"))
            pns.RouteView.Apply()
            assert.is_false(view:IsShown())
            assert.is_truthy(d.routeStatus:GetText():find("stops"))
            assert.equals("Recalculate...", d.routeButton.label:GetText())
            assert.is_true(pns.FarmEditor.Save())
            local farm = pns.Farms.FindByName("Tin")
            assert.equals("Mining:1249", farm.route.nodes)
            -- an up-to-date route opens without computing again
            pns.FarmEditor.Open(farm)
            pns.RouteView.Open(pns.FarmEditor.Form(), pns.FarmEditor.RefreshRoute)
            assert.equals(farm.route, pns.RouteView.Result())
            -- another node makes it out of date
            table.insert(pns.FarmEditor.Form().nodes, { type = "Mining", id = 1250 })
            pns.FarmEditor.RefreshRoute()
            assert.is_truthy(d.routeStatus:GetText():find("Out of date"))
        end)

        it("waits while in combat", function()
            local result
            WoWMock.combat = true
            Route.Run(2395, { { type = "Mining", id = 1245 } }, nil, function(route) result = route end)
            WoWMock.advance(0); WoWMock.flush()
            assert.is_nil(result)
            WoWMock.combat = false
            for _ = 1, 5 do WoWMock.advance(1); WoWMock.flush() end
            assert.equals(1, #result.stops)
        end)
    end)
end)
