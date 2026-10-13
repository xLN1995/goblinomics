if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/Route.lua
-- Flight route over the known nodes of a farm (a covering salesman problem: every
-- node within sight of the round, not every node visited):
--   Cluster   nodes within the cover radius of a common centre are one stop (densest
--             first, a grid finds the neighbours); a lone node is a stop. The radius
--             is half the minimap's view radius, so a stop's nodes show on the
--             minimap well before it is reached.
--   Prune     stops whose detour per node costs more than OUTLIER times the round's
--             average are left out (lone nodes far off); stops whose nodes the line
--             from the stop before to the one after passes within the radius anyway
--             are dropped (shortcut); a last 2-opt pass trades small detours for
--             fewer sharp turns (turn penalty, only within TURN_SLACK yards)
--   Optimize  up to 8 stops exact; otherwise nearest neighbour from up to 12 starts,
--             each improved with 2-opt (neighbour lists, don't-look bits) and
--             Or-opt (move 1-3 stops, also reversed) until nothing improves; the
--             shortest round wins, rotated to start in the west
--   Run       the work in a coroutine with a large budget per frame (the player may
--             notice it while it runs), paused in combat, with progress
-- Distances are in yards: zone coordinates times the zone size (API.Nodes:ZoneYards).
-- The stored route keeps zone coordinates in round order.
local _, ns = ...

local Route = {}
ns.Route = Route

Route.RADIUS = 15         -- yards around a stop (fallback; routes use the cover radius)
Route.VIEW_RADIUS = 333.33 -- yards the minimap shows around the player at zoom 0 outdoors
Route.OUTLIER = 2.5       -- a stop's detour per node above this times the average: left out
local TURN_WEIGHT = 0.25  -- yards per radian of turning, times the cover radius
local TURN_SLACK = 15     -- yards a smoother turn may add per change
local SMOOTH_WINDOW = 80  -- stops a smoothing reversal may span
Route.FLIGHT_YPS = 30     -- assumed travel speed for the lap time
Route.MAX_STOPS = 2000
local BUDGET_MS = 40
local NEIGHBOURS = 12
local STARTS = 12
local EXACT = 8
local EPS = 1e-7

local sqrt, floor, huge = math.sqrt, math.floor, math.huge

local function NoYield() end

-- Clustering ------------------------------------------------------------------------------------
--- Stops from points { { x, y } } in yards: { { x, y, n, members = { index } } }.
function Route.Cluster(points, radius, yield)
    radius = radius or Route.RADIUS
    yield = yield or NoYield
    local r2 = radius * radius
    local n = #points
    local grid, alive = {}, {}
    local function Cell(x, y) return floor(x / radius) .. ":" .. floor(y / radius) end
    for i = 1, n do
        local key = Cell(points[i].x, points[i].y)
        grid[key] = grid[key] or {}
        table.insert(grid[key], i)
        alive[i] = true
    end
    -- alive points within radius of (x, y)
    local function Near(x, y)
        local out = {}
        local cx, cy = floor(x / radius), floor(y / radius)
        for gx = cx - 1, cx + 1 do
            for gy = cy - 1, cy + 1 do
                for _, j in ipairs(grid[gx .. ":" .. gy] or {}) do
                    local p = points[j]
                    local dx, dy = p.x - x, p.y - y
                    if alive[j] and dx * dx + dy * dy <= r2 then out[#out + 1] = j end
                end
            end
        end
        return out
    end
    local function Centre(members)
        local sx, sy = 0, 0
        for _, j in ipairs(members) do sx, sy = sx + points[j].x, sy + points[j].y end
        return sx / #members, sy / #members
    end
    -- densest first
    local order, count = {}, {}
    for i = 1, n do
        order[i] = i
        count[i] = #Near(points[i].x, points[i].y)
        if i % 200 == 0 then yield() end
    end
    table.sort(order, function(a, b)
        if count[a] ~= count[b] then return count[a] > count[b] end
        return a < b
    end)
    local stops = {}
    for k, i in ipairs(order) do
        if alive[i] then
            local p = points[i]
            local members = Near(p.x, p.y)
            local cx, cy = p.x, p.y
            if #members >= 2 then
                -- move the centre into the middle of its members, twice
                for _ = 1, 2 do
                    local mx, my = Centre(members)
                    local again = Near(mx, my)
                    if #again < 2 then break end
                    cx, cy, members = mx, my, again
                end
            else
                members = { i }
            end
            for _, j in ipairs(members) do alive[j] = false end
            stops[#stops + 1] = { x = cx, y = cy, n = #members, members = members }
        end
        if k % 200 == 0 then yield() end
    end
    return stops
end

-- Tour helpers ----------------------------------------------------------------------------------
local function Dist(stops, a, b)
    local dx, dy = stops[a].x - stops[b].x, stops[a].y - stops[b].y
    return sqrt(dx * dx + dy * dy)
end

--- Length of the closed round over stops in the given order (default: as listed).
function Route.Length(stops, order)
    local n = order and #order or #stops
    if n < 2 then return 0 end
    local total = 0
    for i = 1, n do
        local a = order and order[i] or i
        local b = order and order[i % n + 1] or (i % n + 1)
        total = total + Dist(stops, a, b)
    end
    return total
end

--- The NEIGHBOURS nearest stops of every stop, nearest first (scan in x order).
local function NeighbourLists(stops, yield)
    local n = #stops
    local byX = {}
    for i = 1, n do byX[i] = i end
    table.sort(byX, function(a, b)
        if stops[a].x ~= stops[b].x then return stops[a].x < stops[b].x end
        return a < b
    end)
    local rank = {}
    for r, i in ipairs(byX) do rank[i] = r end
    local k = math.min(NEIGHBOURS, n - 1)
    local lists = {}
    for i = 1, n do
        local best, bestD = {}, {}
        -- keep the k nearest, sorted by distance
        local function Offer(j)
            local d = Dist(stops, i, j)
            local pos
            if #best < k then
                pos = #best + 1
            elseif d < bestD[k] then
                pos = k
            else
                return
            end
            while pos > 1 and bestD[pos - 1] > d do
                best[pos], bestD[pos] = best[pos - 1], bestD[pos - 1]
                pos = pos - 1
            end
            best[pos], bestD[pos] = j, d
        end
        local x = stops[i].x
        local lo, hi = rank[i] - 1, rank[i] + 1
        while lo >= 1 or hi <= n do
            local limit = #best == k and bestD[k] or huge
            local goLo = lo >= 1 and x - stops[byX[lo]].x <= limit
            local goHi = hi <= n and stops[byX[hi]].x - x <= limit
            if not goLo and not goHi then break end
            if goLo then
                Offer(byX[lo])
                lo = lo - 1
            end
            if goHi then
                Offer(byX[hi])
                hi = hi + 1
            end
        end
        lists[i] = best
        if i % 100 == 0 then yield() end
    end
    return lists
end

local function NearestNeighbourTour(stops, start, yield)
    local n = #stops
    local used, tour = { [start] = true }, { start }
    local cur = start
    for step = 2, n do
        local best, bestD = nil, huge
        for j = 1, n do
            if not used[j] then
                local d = Dist(stops, cur, j)
                if d < bestD then best, bestD = j, d end
            end
        end
        used[best] = true
        tour[step] = best
        cur = best
        if step % 50 == 0 then yield() end
    end
    return tour
end

-- 2-opt with neighbour lists and don't-look bits on an array tour.
local function TwoOpt(stops, tour, lists, yield)
    local n = #tour
    local pos = {}
    for i = 1, n do pos[tour[i]] = i end
    local function Succ(c) return tour[pos[c] % n + 1] end
    local function Pred(c) return tour[(pos[c] - 2) % n + 1] end
    -- reverse the tour between positions i and j (cyclic), the shorter side
    local function Reverse(i, j)
        local len = (j - i) % n + 1
        if 2 * len > n then
            i, j = j % n + 1, (i - 2) % n + 1
            len = n - len
        end
        for _ = 1, floor(len / 2) do
            local a, b = tour[i], tour[j]
            tour[i], tour[j] = b, a
            pos[b], pos[a] = i, j
            i = i % n + 1
            j = (j - 2) % n + 1
        end
    end
    local active, queue, head = {}, {}, 1
    for i = 1, n do
        active[tour[i]] = true
        queue[i] = tour[i]
    end
    local function Push(c)
        if not active[c] then
            active[c] = true
            queue[#queue + 1] = c
        end
    end
    local improved, steps = false, 0
    while head <= #queue do
        local a = queue[head]
        queue[head] = nil
        head = head + 1
        active[a] = false
        local found = false
        for dir = 1, 2 do
            local b = dir == 1 and Succ(a) or Pred(a)
            local dab = Dist(stops, a, b)
            for _, c in ipairs(lists[a]) do
                local dac = Dist(stops, a, c)
                if dac >= dab then break end
                local d = dir == 1 and Succ(c) or Pred(c)
                if c ~= b and d ~= a then
                    local delta = dac + Dist(stops, b, d) - dab - Dist(stops, c, d)
                    if delta < -EPS then
                        if dir == 1 then Reverse(pos[b], pos[c]) else Reverse(pos[c], pos[b]) end
                        Push(a); Push(b); Push(c); Push(d)
                        found, improved = true, true
                        break
                    end
                end
            end
            if found then break end
        end
        steps = steps + 1
        if steps % 100 == 0 then yield() end
    end
    return improved
end

-- Or-opt on a linked tour: move a segment of 1-3 stops between two neighbouring stops
-- elsewhere, in either direction, when that shortens the round. Every stop is
-- tried once and again after a move near it. Returns the new tour or nil.
local function OrOpt(stops, tour, lists, yield)
    local n = #tour
    if n < 5 then return nil end
    local nextOf, prevOf = {}, {}
    for i = 1, n do
        nextOf[tour[i]] = tour[i % n + 1]
        prevOf[tour[i]] = tour[(i - 2) % n + 1]
    end
    local active, queue, head = {}, {}, 1
    for i = 1, n do
        active[tour[i]] = true
        queue[i] = tour[i]
    end
    local function Push(c)
        if not active[c] then
            active[c] = true
            queue[#queue + 1] = c
        end
    end
    local improved, steps = false, 0
    local seg = {}
    while head <= #queue do
        local first = queue[head]
        queue[head] = nil
        head = head + 1
        active[first] = false
        for len = 1, 3 do
            -- the segment first .. last, forward
            local last = first
            seg[1] = first
            for k = 2, len do
                last = nextOf[last]
                seg[k] = last
            end
            for k = len + 1, 3 do seg[k] = nil end
            local p, nx = prevOf[first], nextOf[last]
            if p == last or nx == first or p == nx then break end
            local gain = Dist(stops, p, first) + Dist(stops, last, nx) - Dist(stops, p, nx)
            if gain > EPS then
                local bestCost, bestC, bestRev = gain - EPS, nil, false
                for e = 1, 2 do
                    local endpoint = e == 1 and first or last
                    for _, c in ipairs(lists[endpoint]) do
                        local cs = nextOf[c]
                        if c ~= p and c ~= seg[1] and c ~= seg[2] and c ~= seg[3]
                            and cs ~= seg[1] and cs ~= seg[2] and cs ~= seg[3] then
                            local base = Dist(stops, c, cs)
                            local fwd = Dist(stops, c, first) + Dist(stops, last, cs) - base
                            local rev = Dist(stops, c, last) + Dist(stops, first, cs) - base
                            if fwd < bestCost then bestCost, bestC, bestRev = fwd, c, false end
                            if rev < bestCost then bestCost, bestC, bestRev = rev, c, true end
                        end
                    end
                end
                if bestC then
                    local c, cs = bestC, nextOf[bestC]
                    nextOf[p], prevOf[nx] = nx, p
                    if bestRev then
                        for k = 1, len do
                            local v = seg[k]
                            nextOf[v], prevOf[v] = prevOf[v], nextOf[v]
                        end
                        nextOf[c], prevOf[last] = last, c
                        nextOf[first], prevOf[cs] = cs, first
                    else
                        nextOf[c], prevOf[first] = first, c
                        nextOf[last], prevOf[cs] = cs, last
                    end
                    Push(p); Push(nx); Push(c); Push(cs); Push(first); Push(last)
                    improved = true
                    break
                end
            end
        end
        steps = steps + 1
        if steps % 100 == 0 then yield() end
    end
    if not improved then return nil end
    local out, cur = {}, tour[1]
    for i = 1, n do
        out[i] = cur
        cur = nextOf[cur]
    end
    return out
end

-- Every permutation for a few stops (stop 1 fixed).
local function Exact(stops)
    local n = #stops
    local best, bestLen = nil, huge
    local perm, used = { 1 }, { true }
    local function Walk(depth, length)
        if length >= bestLen then return end
        if depth > n then
            local total = length + Dist(stops, perm[n], perm[1])
            if total < bestLen - EPS then
                bestLen = total
                best = { unpack(perm) }
            end
            return
        end
        for j = 2, n do
            if not used[j] then
                used[j] = true
                perm[depth] = j
                Walk(depth + 1, length + Dist(stops, perm[depth - 1], j))
                used[j] = false
            end
        end
    end
    Walk(2, 0)
    return best
end

--- Rotate a tour to start at its westernmost stop (smallest x, then y).
local function Rotate(stops, tour)
    local start = 1
    for i = 2, #tour do
        local a, b = stops[tour[i]], stops[tour[start]]
        if a.x < b.x or (a.x == b.x and a.y < b.y) then start = i end
    end
    local out = {}
    for k = 0, #tour - 1 do out[#out + 1] = tour[(start + k - 1) % #tour + 1] end
    return out
end

--- The shortest round found over stops { { x, y } } (yards): an order of indices.
-- progress(phase, done, total) reports "starts" and "optimize".
function Route.Optimize(stops, yield, progress)
    yield, progress = yield or NoYield, progress or NoYield
    local n = #stops
    if n <= 3 then
        local order = {}
        for i = 1, n do order[i] = i end
        return order
    end
    if n <= EXACT then return Rotate(stops, Exact(stops)) end
    local lists = NeighbourLists(stops, yield)
    -- start stops spread over the zone: first, west, east, north, south, then evenly
    local starts, seen = {}, {}
    local function AddStart(i) if i and not seen[i] then seen[i] = true; starts[#starts + 1] = i end end
    local west, east, north, south = 1, 1, 1, 1
    for i = 2, n do
        if stops[i].x < stops[west].x then west = i end
        if stops[i].x > stops[east].x then east = i end
        if stops[i].y < stops[north].y then north = i end
        if stops[i].y > stops[south].y then south = i end
    end
    for _, i in ipairs({ 1, west, east, north, south }) do AddStart(i) end
    -- more starts spread over the list (points come sorted from west to east)
    for k = 1, STARTS do AddStart(1 + floor((k - 0.5) * n / STARTS)) end
    local best, bestLen = nil, huge
    for k = 1, math.min(STARTS, #starts) do
        progress("optimize", k - 1, #starts)
        local tour = NearestNeighbourTour(stops, starts[k], yield)
        repeat
            local changed = TwoOpt(stops, tour, lists, yield)
            local moved = OrOpt(stops, tour, lists, yield)
            if moved then
                tour = moved
                changed = true
            end
        until not changed
        local len = Route.Length(stops, tour)
        if len < bestLen - EPS then best, bestLen = tour, len end
    end
    progress("optimize", #starts, #starts)
    return Rotate(stops, best)
end

-- Pruning and smoothing --------------------------------------------------------------------------
--- Half the minimap's view radius (fully zoomed out, outdoors).
function Route.CoverRadius()
    local r = C_Minimap and C_Minimap.GetViewRadius and Minimap and Minimap:GetZoom() == 0
        and C_Minimap.GetViewRadius()
    if type(r) ~= "number" or (issecretvalue and issecretvalue(r)) or r <= 0 then r = Route.VIEW_RADIUS end
    return r / 2
end

local function SegmentDistance(p, a, b)
    local dx, dy = b.x - a.x, b.y - a.y
    local len2 = dx * dx + dy * dy
    local t = len2 > 0 and math.max(0, math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) or 0
    local ex, ey = a.x + t * dx - p.x, a.y + t * dy - p.y
    return sqrt(ex * ex + ey * ey)
end

--- Leave out stops whose detour per node is far above the round's average. Returns
-- the new tour and the number of nodes left out.
function Route.PruneOutliers(stops, tour, factor)
    factor = factor or Route.OUTLIER
    local dropped = 0
    while #tour > 3 do
        local n, total = #tour, 0
        for _, i in ipairs(tour) do total = total + stops[i].n end
        local average = Route.Length(stops, tour) / math.max(1, total)
        local worst, worstCost
        for k = 1, n do
            local p, w, q = tour[(k - 2) % n + 1], tour[k], tour[k % n + 1]
            local detour = Dist(stops, p, w) + Dist(stops, w, q) - Dist(stops, p, q)
            local cost = detour / stops[w].n
            if not worstCost or cost > worstCost then worst, worstCost = k, cost end
        end
        if worstCost <= factor * average then break end
        dropped = dropped + stops[tour[worst]].n
        table.remove(tour, worst)
    end
    return tour, dropped
end

--- Drop stops whose nodes the line from the stop before to the stop after passes
-- within the radius anyway; their nodes count for the nearer neighbour.
function Route.Shortcut(stops, tour, points, radius)
    local changed = true
    while changed and #tour > 3 do
        changed = false
        local n = #tour
        for k = 1, n do
            local p, w, q = tour[(k - 2) % n + 1], tour[k], tour[k % n + 1]
            local covered = true
            for _, j in ipairs(stops[w].members or {}) do
                if SegmentDistance(points[j], stops[p], stops[q]) > radius then covered = false break end
            end
            if covered then
                local to = Dist(stops, w, p) <= Dist(stops, w, q) and p or q
                stops[to].n = stops[to].n + stops[w].n
                stops[to].members = stops[to].members or {}
                for _, j in ipairs(stops[w].members or {}) do table.insert(stops[to].members, j) end
                table.remove(tour, k)
                changed = true
                break
            end
        end
    end
    return tour
end

local function Turn(stops, u, v, w)
    local ax, ay = stops[v].x - stops[u].x, stops[v].y - stops[u].y
    local bx, by = stops[w].x - stops[v].x, stops[w].y - stops[v].y
    local la, lb = sqrt(ax * ax + ay * ay), sqrt(bx * bx + by * by)
    if la == 0 or lb == 0 then return 0 end
    return math.acos(math.max(-1, math.min(1, (ax * bx + ay * by) / (la * lb))))
end

--- 2-opt with length plus a turn penalty: a reversal that removes sharp turns is
-- taken when it adds at most TURN_SLACK yards. True when anything changed.
function Route.Smooth(stops, tour, radius, yield)
    yield = yield or NoYield
    local n = #tour
    if n < 6 then return false end
    local weight = TURN_WEIGHT * radius
    local function At(k) return tour[(k - 1) % n + 1] end
    -- turning over the window i-1 .. j+2 (the only turns a reversal of i+1..j changes)
    local function Turns(i, j)
        local sum = 0
        for _, k in ipairs({ i, i + 1, j, j + 1 }) do sum = sum + Turn(stops, At(k - 1), At(k), At(k + 1)) end
        return sum
    end
    local function Reverse(lo, hi)
        while lo < hi do
            local a, b = (lo - 1) % n + 1, (hi - 1) % n + 1
            tour[a], tour[b] = tour[b], tour[a]
            lo, hi = lo + 1, hi - 1
        end
    end
    local changedAny, changed, passes = false, true, 0
    while changed and passes < 20 do
        changed, passes = false, passes + 1
        for i = 1, n - 3 do
            -- long rounds: only reversals within a window, so the pass stays fast
            for j = i + 2, math.min(n - 1, i + n - 3, i + SMOOTH_WINDOW) do
                local a, b, c, d = At(i), At(i + 1), At(j), At(j + 1)
                local dLen = Dist(stops, a, c) + Dist(stops, b, d) - Dist(stops, a, b) - Dist(stops, c, d)
                if dLen <= TURN_SLACK then
                    local before = Turns(i, j)
                    Reverse(i + 1, j)
                    local after = Turns(i, j)
                    if dLen + weight * (after - before) < -EPS then
                        changed, changedAny = true, true
                    else
                        Reverse(i + 1, j)
                    end
                end
            end
            if i % 10 == 0 then yield() end
        end
    end
    return changedAny
end

-- Building a route ------------------------------------------------------------------------------
--- "Mining:1249,Mining:1250": the chosen nodes, sorted.
function Route.Signature(nodes)
    local keys = {}
    for _, n in ipairs(nodes or {}) do keys[#keys + 1] = ns.Farms.NodeKey(n.type, n.id) end
    table.sort(keys)
    return table.concat(keys, ",")
end

--- Positions of the chosen nodes in a zone: { { x, y } } in zone coordinates.
function Route.Points(zone, nodes)
    local wanted, types = {}, {}
    for _, n in ipairs(nodes or {}) do
        wanted[ns.Farms.NodeKey(n.type, n.id)] = true
        types[n.type] = true
    end
    local out = {}
    for nodeType in pairs(types) do
        for _, p in ipairs(ns.API.Nodes:List(zone, nodeType)) do
            if wanted[ns.Farms.NodeKey(nodeType, p.id)] then out[#out + 1] = { x = p.x, y = p.y } end
        end
    end
    table.sort(out, function(a, b)
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end)
    return out
end

local function Round4(v) return floor(v * 10000 + 0.5) / 10000 end

--- The whole computation for a zone and nodes (inside a coroutine or directly):
-- a route table, or nil and "nodes" / "size".
function Route.Build(zone, nodes, yield, progress)
    yield, progress = yield or NoYield, progress or NoYield
    local width, height = ns.API.Nodes:ZoneYards(zone)
    if not width then return nil, "size" end
    local points = Route.Points(zone, nodes)
    if #points == 0 then return nil, "nodes" end
    progress("cluster", 0, 1)
    local yards = {}
    for i, p in ipairs(points) do yards[i] = { x = p.x * width, y = p.y * height } end
    local radius = Route.CoverRadius()
    local stops = Route.Cluster(yards, radius, yield)
    if #stops > Route.MAX_STOPS then return nil, "size" end
    progress("cluster", 1, 1)
    local order = Route.Optimize(stops, yield, progress)
    local dropped
    order, dropped = Route.PruneOutliers(stops, order)
    order = Route.Shortcut(stops, order, yards, radius)
    -- the remaining stops once more as the shortest round, then smoothed
    local kept = {}
    for i, idx in ipairs(order) do kept[i] = stops[idx] end
    stops = kept
    order = Route.Optimize(stops, yield, progress)
    Route.Smooth(stops, order, radius, yield)
    local out, clusters = {}, 0
    for i, idx in ipairs(order) do
        local s = stops[idx]
        out[i] = { x = Round4(s.x / width), y = Round4(s.y / height), n = s.n }
        if s.n > 1 then clusters = clusters + 1 end
    end
    return {
        zone = zone, radius = floor(radius + 0.5), nodes = Route.Signature(nodes), nodeCount = #points,
        dropped = dropped, stops = out, clusters = clusters, length = floor(Route.Length(stops, order) + 0.5),
        created = time(),
    }
end

--- Seconds for one lap at the assumed speed.
function Route.LapSeconds(route)
    return route and route.length and floor(route.length / Route.FLIGHT_YPS + 0.5) or 0
end

-- Runner ----------------------------------------------------------------------------------------
local generation = 0

--- Compute a route over several frames: onProgress(phase, share 0..1), onDone(route, err).
-- Returns a cancel function. Pauses in combat.
function Route.Run(zone, nodes, onProgress, onDone)
    generation = generation + 1
    local mine = generation
    local deadline = 0
    local function Yield()
        if debugprofilestop() >= deadline then coroutine.yield() end
    end
    local function Progress(phase, done, total)
        if onProgress then onProgress(phase, total > 0 and done / total or 0) end
    end
    local co = coroutine.create(function() return Route.Build(zone, nodes, Yield, Progress) end)
    local function Step()
        if mine ~= generation then return end
        if InCombatLockdown() then
            C_Timer.After(1, Step)
            return
        end
        deadline = debugprofilestop() + BUDGET_MS
        local ok, route, err = coroutine.resume(co)
        if not ok then
            geterrorhandler()(route)
            if onDone then onDone(nil, "error") end
        elseif coroutine.status(co) == "dead" then
            if onDone then onDone(route, err) end
        else
            C_Timer.After(0, Step)
        end
    end
    C_Timer.After(0, Step)
    return function() if mine == generation then generation = generation + 1 end end
end

function Route.Cancel() generation = generation + 1 end
