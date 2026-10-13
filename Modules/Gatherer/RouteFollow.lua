if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/RouteFollow.lua
-- Following a stored route while farming (pure, the farm HUD draws it):
--   Project   a position relative to the player onto the radar, turned so the
--             player's facing points up
--   Nearest   the stop closest to the player: where the round is joined
--   Advance   reaching the next stop or one of the LOOKAHEAD after it (within the
--             route's radius) moves on to the stop after that; passing the end of
--             the round counts a lap. The order is never planned again.
--   Speed     travel speed measured from the last seconds of movement, for the
--             time to the next stops; without a measurement the assumed one
-- Positions are zone coordinates; ZoneYards turns them into yards.
--   state = { index, laps, reached, samples, speed }
local _, ns = ...

local Follow = {}
ns.RouteFollow = Follow

Follow.LOOKAHEAD = 5
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
    local radius = route.radius or ns.Route.RADIUS
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
    state.laps = (state.laps or 0) + math.floor(unwrapped / n)
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
