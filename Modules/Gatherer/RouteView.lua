if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/RouteView.lua
-- Route preview from the farm editor: the zone map (its art tiles), the chosen
-- nodes while the route is computed, then the stops (clusters larger, with their
-- node count) and the round as lines from the start. Below it the facts (nodes,
-- clusters, single stops, length, lap time), the progress of the computation and
-- Discard / Recalculate / Apply. Apply hands the route to the editor's form; the
-- editor's Save stores it with the farm. An up-to-date route is shown without
-- computing it again.
local _, ns = ...

local RouteView = {}
ns.RouteView = RouteView

local WIDTH, HEIGHT = 640, 560
local MAP_H = 400
local DOT, CLUSTER_DOT = 7, 12   -- soft dots: a little larger than solid ones

local dialog
local form, onApply
local result, cancel

-- Pools ------------------------------------------------------------------------------------------
local function Pool(create)
    local pool = { items = {}, used = 0 }
    function pool:Next()
        self.used = self.used + 1
        local item = self.items[self.used]
        if not item then
            item = create()
            self.items[self.used] = item
        end
        item:Show()
        return item
    end
    function pool:Reset()
        for i = 1, #self.items do self.items[i]:Hide() end
        self.used = 0
    end
    return pool
end

-- Map ---------------------------------------------------------------------------------------------
--- Canvas size for the zone: the art layer's aspect within WIDTH x MAP_H.
local function CanvasSize(zone)
    local layers = C_Map.GetMapArtLayers and C_Map.GetMapArtLayers(zone)
    local layer = layers and layers[1]
    local maxW = WIDTH - 2 * ns.API.Theme.space.DIALOG_PAD
    local aspect = (layer and layer.layerHeight > 0) and (layer.layerWidth / layer.layerHeight) or 1.5
    local w = math.min(maxW, MAP_H * aspect)
    return math.floor(w), math.floor(w / aspect), layer
end

--- Tile placement of a zone's map art: { { texture, x, y, w, h } } in canvas pixels.
function RouteView.Tiles(zone, canvasW)
    local layers = C_Map.GetMapArtLayers and C_Map.GetMapArtLayers(zone)
    local layer = layers and layers[1]
    if not layer or not C_Map.GetMapArtLayerTextures then return {} end
    local textures = C_Map.GetMapArtLayerTextures(zone, 1) or {}
    local cols = math.ceil(layer.layerWidth / layer.tileWidth)
    local rows = math.ceil(layer.layerHeight / layer.tileHeight)
    local scale = canvasW / layer.layerWidth
    local out = {}
    for r = 0, rows - 1 do
        for c = 0, cols - 1 do
            local tex = textures[r * cols + c + 1]
            if tex then
                out[#out + 1] = { texture = tex, x = c * layer.tileWidth * scale, y = r * layer.tileHeight * scale,
                    w = layer.tileWidth * scale, h = layer.tileHeight * scale }
            end
        end
    end
    return out
end

local function Build()
    local API, L = ns.API, ns.L
    local W, Theme = API.Widgets, API.Theme
    local C, S = Theme.colors, Theme.space
    local d
    d = W.Dialog({ name = "GoblinomicsGathererRouteView", width = WIDTH, height = HEIGHT,
        onClose = function() if cancel then cancel() end end,
        buttons = {
            { text = L["Discard"], onClick = function() d:Hide() end },
            { text = L["Recalculate"], onClick = function() RouteView.Compute() end },
            { text = L["Apply"], primary = true, onClick = function() RouteView.Apply() end },
        } })
    d.discard, d.recalc, d.apply = d.buttons[1], d.buttons[2], d.buttons[3]
    d.canvas = CreateFrame("Frame", nil, d.body)
    d.canvas:SetClipsChildren(true)
    Theme.Fill(d.canvas, C.panel)
    d.tiles = Pool(function()
        local t = d.canvas:CreateTexture(nil, "BACKGROUND", nil, 1)
        return t
    end)
    d.overlay = CreateFrame("Frame", nil, d.canvas)
    d.overlay:SetAllPoints(d.canvas)   -- a child frame: drawn above the map tiles
    d.lines = Pool(function()
        local line = Theme.SmoothLine(d.overlay:CreateLine(nil, "ARTWORK"))
        line:SetThickness(3)
        Theme.Tint(line, C.accent)
        return line
    end)
    d.dots = Pool(function() return Theme.SmoothDot(d.overlay:CreateTexture(nil, "OVERLAY")) end)
    d.labels = Pool(function()
        local fs = Theme.Text(d.overlay, 10, C.text)
        return fs
    end)
    d.hits = Pool(function()
        local hit = CreateFrame("Frame", nil, d.overlay)
        hit:SetSize(12, 12)
        hit:EnableMouse(true)
        hit:SetScript("OnEnter", function(self)
            if self.stop then W.ShowTooltip(self, API.Lf("Stop %d", self.index), self.lines) end
        end)
        hit:SetScript("OnLeave", W.HideTooltip)
        return hit
    end)
    d.facts = Theme.Text(d.body, "body", C.text)
    d.facts:SetJustifyH("LEFT")
    d.lap = Theme.Text(d.body, "body", C.textDim)
    d.lap:SetJustifyH("LEFT")
    d.progress = W.ProgressBar(d.body, WIDTH - 2 * S.DIALOG_PAD, 14)
    d.error = Theme.Text(d.body, "small", C.loss)
    d.error:SetJustifyH("LEFT")
    return d
end

local function Place(frame, x, y, w, h)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", dialog.canvas, "TOPLEFT", x, -y)
    frame:SetSize(w, h)
end

--- Lay out the canvas for the zone and draw its map tiles.
local function DrawMap(zone)
    local S = ns.API.Theme.space
    local w, h = CanvasSize(zone)
    dialog.canvasW, dialog.canvasH = w, h
    dialog.canvas:ClearAllPoints()
    dialog.canvas:SetPoint("TOP", dialog.body, "TOP", 0, 0)
    dialog.canvas:SetSize(w, h)
    dialog.tiles:Reset()
    for _, t in ipairs(RouteView.Tiles(zone, w)) do
        local tex = dialog.tiles:Next()
        tex:SetTexture(t.texture)
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", dialog.canvas, "TOPLEFT", t.x, -t.y)
        tex:SetSize(t.w, t.h)
    end
    local y = -(MAP_H + S.SM)
    dialog.facts:ClearAllPoints()
    dialog.facts:SetPoint("TOPLEFT", dialog.body, "TOPLEFT", 0, y)
    dialog.lap:ClearAllPoints()
    dialog.lap:SetPoint("TOPLEFT", dialog.body, "TOPLEFT", 0, y - 18)
    dialog.progress:ClearAllPoints()
    dialog.progress:SetPoint("TOPLEFT", dialog.body, "TOPLEFT", 0, y - 40)
    dialog.error:ClearAllPoints()
    dialog.error:SetPoint("TOPLEFT", dialog.body, "TOPLEFT", 0, y - 40)
end

local function ClearOverlay()
    dialog.lines:Reset()
    dialog.dots:Reset()
    dialog.labels:Reset()
    dialog.hits:Reset()
end

--- The chosen nodes as small dots while the route is computed.
local function DrawNodes(points)
    local C = ns.API.Theme.colors
    ClearOverlay()
    for _, p in ipairs(points) do
        local dot = dialog.dots:Next()
        ns.API.Theme.Tint(dot, C.textDim, 0.9)
        Place(dot, p.x * dialog.canvasW, p.y * dialog.canvasH, 4, 4)
    end
end

--- Stops and the round.
local function DrawRoute(route)
    local API, L = ns.API, ns.L
    local C = API.Theme.colors
    ClearOverlay()
    local w, h = dialog.canvasW, dialog.canvasH
    local stops = route.stops
    local n = #stops
    local width, height = API.Nodes:ZoneYards(route.zone)
    for i, s in ipairs(stops) do
        local nxt = stops[i % n + 1]
        if n > 1 then
            local line = dialog.lines:Next()
            line:SetStartPoint("TOPLEFT", dialog.canvas, s.x * w, -s.y * h)
            line:SetEndPoint("TOPLEFT", dialog.canvas, nxt.x * w, -nxt.y * h)
        end
        local dot = dialog.dots:Next()
        local size = s.n > 1 and CLUSTER_DOT or DOT
        local color = i == 1 and C.accent or (s.n > 1 and C.gold or C.text)
        API.Theme.Tint(dot, color, 1)
        Place(dot, s.x * w, s.y * h, size, size)
        if s.n > 1 or i == 1 then
            local fs = dialog.labels:Next()
            fs:SetText(i == 1 and (L["Start"] .. (s.n > 1 and (" (" .. s.n .. ")") or "")) or tostring(s.n))
            fs:ClearAllPoints()
            fs:SetPoint("BOTTOMLEFT", dialog.canvas, "TOPLEFT", s.x * w + size / 2 + 1, -s.y * h + 1)
        end
        local hit = dialog.hits:Next()
        Place(hit, s.x * w, s.y * h, 12, 12)
        hit.stop, hit.index = s, i
        local lines = { API.Lf("%d nodes", s.n) }
        if width and n > 1 then
            local dx, dy = (nxt.x - s.x) * width, (nxt.y - s.y) * height
            lines[#lines + 1] = API.Lf("%s yd to the next stop", API.Format:Number(math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)))
        end
        hit.lines = lines
    end
end

local function ShowFacts(route)
    local API = ns.API
    local L = ns.L
    if not route then
        dialog.facts:SetText("")
        dialog.lap:SetText("")
        return
    end
    local singles = #route.stops - route.clusters
    local facts = API.Lf("%d nodes: %d clusters and %d single stops", route.nodeCount, route.clusters, singles)
    if (route.dropped or 0) > 0 then facts = facts .. "  " .. API.Lf("(%d far off, left out)", route.dropped) end
    dialog.facts:SetText(facts)
    dialog.lap:SetText(ns.FarmEditor.RouteText(route) .. "  " .. ns.API.Theme.CODE.dim
        .. L["(lap time at an assumed flight speed)"] .. "|r")
end

local function OnProgress(phase, share)
    local L = ns.L
    dialog.progress:SetValue(share)
    dialog.progress:SetLabels(phase == "cluster" and L["Grouping nodes"] or L["Optimizing the route"],
        ("%d%%"):format(math.floor(share * 100 + 0.5)))
end

local function OnDone(route, err)
    local L = ns.L
    cancel = nil
    dialog.progress:Hide()
    dialog.recalc:SetEnabled(true)
    if not route then
        dialog.error:SetText(err == "size" and L["The size of this zone is unknown, no route possible."]
            or L["No known nodes for this choice."])
        dialog.error:Show()
        return
    end
    result = route
    DrawRoute(route)
    ShowFacts(route)
    dialog.apply:SetEnabled(true)
end

--- Compute the route for the form's zone and nodes (again).
function RouteView.Compute()
    if not (dialog and form and form.zone) then return end
    if cancel then cancel() end
    result = nil
    dialog.apply:SetEnabled(false)
    dialog.recalc:SetEnabled(false)
    dialog.error:Hide()
    ShowFacts(nil)
    DrawNodes(ns.Route.Points(form.zone, form.nodes))
    dialog.progress:SetMinMaxValues(0, 1)
    OnProgress("cluster", 0)
    dialog.progress:Show()
    cancel = ns.Route.Run(form.zone, form.nodes, OnProgress, OnDone)
end

--- Hand the computed route to the editor.
function RouteView.Apply()
    if not result then return end
    form.route = result
    dialog:Hide()
    if onApply then onApply() end
end

--- Open for the editor's form; apply() refreshes the editor afterwards.
function RouteView.Open(editorForm, apply)
    dialog = dialog or Build()
    form, onApply = editorForm, apply
    local L = ns.L
    dialog:SetTitle(L["Route"] .. ": " .. ((form.name and form.name ~= "") and form.name or L["New farm"]))
    DrawMap(form.zone)
    dialog:Show()
    local state = ns.Farms.RouteState({ zone = form.zone, nodes = form.nodes, route = form.route })
    if form.route and (state == "ok" or state == "grown") then
        result = form.route
        dialog.progress:Hide()
        dialog.error:Hide()
        DrawRoute(result)
        ShowFacts(result)
        dialog.apply:SetEnabled(true)
        dialog.recalc:SetEnabled(true)
    else
        RouteView.Compute()
    end
end

function RouteView.Result() return result end

function RouteView.Disable()
    if cancel then cancel() end
    if dialog then dialog:Hide() end
end
