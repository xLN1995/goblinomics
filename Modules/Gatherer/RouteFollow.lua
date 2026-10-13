if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/RouteFollow.lua
-- Following a stored route while farming (pure, the farm HUD draws it):
--   Project   a position relative to the player onto the radar, turned so the
--             player's facing points up
--   Nearest   the stop closest to the player: where the round is joined
--   Advance   reaching the next stop or one of the LOOKAHEAD after it (within its
--             cluster radius, at most STOP_REACH yards) moves on to the stop after that; passing the end of
--             the round counts a lap. The order is never planned again.
--   Speed     travel speed measured from the last seconds of movement, for the
--             time to the next stops; without a measurement the assumed one
--   Nodes     what is known about each node on this lap: "gathered" (mined by
--             the player), "seen" (the interact target showed it standing) or
--             "gone" (the player came within reach and it was not there); nodes
--             without a state are not checked yet. A new lap starts unchecked.
-- Positions are zone coordinates; ZoneYards turns them into yards.
--   state = { index, laps, reached, samples, speed, nodes = { [key] = state }, close }
local _, ns = ...

local Follow = {}
ns.RouteFollow = Follow

Follow.LOOKAHEAD = 5
Follow.STOP_REACH = 40     -- yards around a stop's centre that count as reached (large clusters too)
Follow.REACH = 8           -- yards: a standing node this close becomes the interact target
Follow.LEAVE = 25          -- yards: leaving a node's reach this far ends its check
Follow.MARK = 20           -- yards: a gather or interact target belongs to the nearest node this close
local SPEED_WINDOW = 3     -- seconds of samples
local MIN_SPEED = 3        -- yards per second: below this the player stands still

local sqrt, cos, sin = math.sqrt, math.cos, math.sin

--- Radar position (right, up) of a point dx yards east and dy yards south of the
-- player, for facing in radians (0 = north, counter-clockwise).
function Follow.Project(dx, dy, facing)
    local east, north = dx, -dy
    local c, s = cos(facing or 0), sin(facing or 0)
    return east * c + north * s, -east * s + north * c
end

--- Yards east and south from (px, py) to stop i.
function Follow.Offset(route, i, px, py, width, height)
    local s = route.stops[i]
    return (s.x - px) * width, (s.y - py) * height
end

function Follow.Distance(route, i, px, py, width, height)
    local dx, dy = Follow.Offset(route, i, px, py, width, height)
    return sqrt(dx * dx + dy * dy)
end

function Follow.Nearest(route, px, py, width, height)
    local best, bestD
    for i = 1, #route.stops do
        local d = Follow.Distance(route, i, px, py, width, height)
        if not bestD or d < bestD then best, bestD = i, d end
    end
    return best
end

--- Index of the stop k places after i on the round.
function Follow.After(route, i, k)
    return (i - 1 + k) % #route.stops + 1
end

--- Join the round at the nearest stop, or move on when the player reached the next
-- stop or one of the LOOKAHEAD after it. True when the next stop changed.
function Follow.Advance(state, route, px, py, width, height)
    local n = #route.stops
    if n == 0 then return false end
    if not state.index or state.index > n then
        state.index = Follow.Nearest(route, px, py, width, height)
        state.laps, state.reached = state.laps or 0, state.reached or 0
        return true
    end
    local radius = math.min(route.radius or ns.Route.RADIUS, Follow.STOP_REACH)
    for k = math.min(Follow.LOOKAHEAD, n - 1), 0, -1 do
        local i = Follow.After(route, state.index, k)
        if Follow.Distance(route, i, px, py, width, height) <= radius then
            Follow.Move(state, route, k + 1)
            return true
        end
    end
    return false
end

--- Move the next stop forward by steps (the skip key: 1).
function Follow.Move(state, route, steps)
    local n = #route.stops
    if n == 0 or not state.index then return end
    local unwrapped = state.index - 1 + steps
    local laps = math.floor(unwrapped / n)
    state.laps = (state.laps or 0) + laps
    if laps > 0 then state.nodes, state.close = {}, {} end   -- a new lap: nothing checked yet
    state.reached = (state.reached or 0) + steps
    state.index = unwrapped % n + 1
end

--- Record a position (yards) at time now; returns the travel speed in yards per second.
function Follow.Speed(state, now, x, y)
    local samples = state.samples or {}
    state.samples = samples
    samples[#samples + 1] = { t = now, x = x, y = y }
    while #samples > 2 and now - samples[1].t > SPEED_WINDOW do table.remove(samples, 1) end
    local first = samples[1]
    local dt = now - first.t
    if dt >= 0.5 then
        local dx, dy = x - first.x, y - first.y
        local v = sqrt(dx * dx + dy * dy) / dt
        if v >= MIN_SPEED then state.speed = state.speed and (state.speed * 0.7 + v * 0.3) or v end
    end
    return state.speed or ns.Route.FLIGHT_YPS
end

-- Nodes -------------------------------------------------------------------------------------------
--- Key of a node position.
function Follow.NodeKey(p) return ("%.4f:%.4f"):format(p.x, p.y) end

--- Nearest node to (px, py) within maxYards: index and distance, or nil.
function Follow.NearestNode(points, px, py, width, height, maxYards)
    local best, bestD
    for i, p in ipairs(points) do
        local dx, dy = (p.x - px) * width, (p.y - py) * height
        if math.abs(dx) <= maxYards and math.abs(dy) <= maxYards then
            local d = sqrt(dx * dx + dy * dy)
            if d <= maxYards and (not bestD or d < bestD) then best, bestD = i, d end
        end
    end
    return best, bestD
end

--- Mark the node nearest to the player: "gathered" always wins, "seen" only on an
-- unchecked or passed node.
function Follow.Mark(state, points, px, py, width, height, what)
    local i = Follow.NearestNode(points, px, py, width, height, Follow.MARK)
    if not i then return nil end
    state.nodes = state.nodes or {}
    local key = Follow.NodeKey(points[i])
    if what == "gathered" or state.nodes[key] ~= "gathered" then state.nodes[key] = what end
    return i
end

--- Nodes the player came within reach of and left again without seeing them: gone.
function Follow.Observe(state, points, px, py, width, height)
    state.nodes, state.close = state.nodes or {}, state.close or {}
    for _, p in ipairs(points) do
        local dx, dy = (p.x - px) * width, (p.y - py) * height
        local key
        if math.abs(dx) <= Follow.REACH and math.abs(dy) <= Follow.REACH and dx * dx + dy * dy <= Follow.REACH ^ 2 then
            key = Follow.NodeKey(p)
            state.close[key] = true
        end
    end
    for key in pairs(state.close) do
        local x, y = key:match("^([%d.]+):([%d.]+)$")
        local dx, dy = (tonumber(x) - px) * width, (tonumber(y) - py) * height
        if dx * dx + dy * dy > Follow.LEAVE ^ 2 then
            state.close[key] = nil
            if state.nodes[key] == nil then state.nodes[key] = "gone" end
        end
    end
end
