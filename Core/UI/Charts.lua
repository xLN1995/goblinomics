if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/UI/Charts.lua
-- Time charts of UI kit v1 (Insights, M7 redesign): a plot area with a value
-- axis (gold, abbreviated), date labels and horizontal grid lines. Series:
--   area   line with a gradient fill down to the bottom of the plot, drawn as
--          vertical stripes (textures cannot be polygons)
--   bars   positive values up, negative values down from the zero line;
--          several bar series stack per sign
--   line   line with points (e.g. net over the bars)
-- One hover area over the plot shows a crosshair at the nearest day, a marker
-- on every line and the tooltip. Layout functions are pure and tested; frames
-- come from pools and are only touched on data or size changes.
local _, ns = ...

local Charts = {}
ns.Charts = Charts
local Theme = ns.Theme
local Widgets = ns.Widgets
local C = Theme.colors

local MARGIN = { left = 52, right = 10, top = 8, bottom = 18 }
local MAX_STRIPES = 300

--- Value axis with 1-2-5 steps: { min, max, step, ticks = { v, ... } }.
-- Sign changes always get a grid line at 0 (0 is a multiple of the step).
function Charts.NiceScale(min, max, count)
    count = count or 4
    if min == nil or max == nil then min, max = 0, 0 end
    if min == max then
        local pad = math.abs(max) > 0 and math.abs(max) * 0.1 or 1
        local wasPositive = min >= 0
        min, max = min - pad, max + pad
        if wasPositive and min < 0 then min = 0 end
    end
    local rough = (max - min) / count
    local mag = 10 ^ math.floor(math.log(rough) / math.log(10))
    local norm = rough / mag
    local step = (norm <= 1 and 1 or norm <= 2 and 2 or norm <= 5 and 5 or 10) * mag
    local lo = math.floor(min / step + 1e-9) * step
    local hi = math.ceil(max / step - 1e-9) * step
    if hi <= lo then hi = lo + step end
    local ticks = {}
    for i = 0, math.floor((hi - lo) / step + 0.5) do ticks[#ticks + 1] = lo + i * step end
    return { min = lo, max = hi, step = step, ticks = ticks }
end

--- Indices that get a date label: all when they fit, else first, last and evenly between.
function Charts.DateTicks(n, maxLabels)
    local list = {}
    if n <= 0 then return list end
    maxLabels = math.max(2, maxLabels or 6)
    if n <= maxLabels then
        for i = 1, n do list[i] = i end
        return list
    end
    local last
    for k = 0, maxLabels - 1 do
        local i = math.floor(1 + k * (n - 1) / (maxLabels - 1) + 0.5)
        if i ~= last then list[#list + 1] = i end
        last = i
    end
    return list
end

--- Short gold label for the value axis: "950", "12K", "2.5K", "1.2M" (copper in).
function Charts.AxisLabel(copper)
    local g = copper / 10000
    local a = math.abs(g)
    local text
    if a >= 1000000 then
        text = ("%.1fM"):format(g / 1000000)
    elseif a >= 10000 then
        text = ("%.0fK"):format(g / 1000)
    elseif a >= 1000 then
        text = ("%.1fK"):format(g / 1000)
    else
        text = ("%d"):format(math.floor(g + 0.5))
    end
    text = text:gsub("%.0([KM])$", "%1")
    return ns.Format and ns.Format.Number and (text:gsub("%.", ns.Format.Decimal())) or text
end

--- Pure layout. data = { { values = { [key] = n } } }, series = { { kind, key } }.
-- Returns { scale, xs = { x }, slot, bars = { { x, width, segments = { { key, y, height } } } },
--   lines = { [key] = { { x, y } } }, zero, empty } with y from the bottom of the plot.
function Charts.Layout(data, series, width, height)
    local n = #data
    local layout = { xs = {}, bars = {}, lines = {}, empty = true }
    local hasBars = false
    local lo, hi = math.huge, -math.huge
    for _, s in ipairs(series) do if s.kind == "bars" then hasBars = true end end
    for _, d in ipairs(data) do
        local pos, neg = 0, 0
        for _, s in ipairs(series) do
            local v = d.values[s.key]
            if v then
                if v ~= 0 then layout.empty = false end
                if s.kind == "bars" then
                    if v > 0 then pos = pos + v else neg = neg + v end
                else
                    if v < lo then lo = v end
                    if v > hi then hi = v end
                end
            end
        end
        if hasBars then
            if neg < lo then lo = neg end
            if pos > hi then hi = pos end
        end
    end
    if lo == math.huge then lo, hi = 0, 0 end
    if hasBars then lo, hi = math.min(lo, 0), math.max(hi, 0) end
    local scale = Charts.NiceScale(lo, hi)
    layout.scale = scale
    local range = scale.max - scale.min
    local function Y(v) return (v - scale.min) / range * height end
    layout.zero = (scale.min <= 0 and scale.max >= 0) and Y(0) or nil
    -- x: slot centres with bars (bars need room at the edges), else edge to edge
    local slot = n > 0 and width / n or width
    layout.slot = slot
    for i = 1, n do
        if hasBars then
            layout.xs[i] = (i - 0.5) * slot
        else
            layout.xs[i] = n > 1 and (i - 1) / (n - 1) * width or width / 2
        end
    end
    local barWidth = math.max(1, math.floor(slot * (slot >= 6 and 0.7 or 1)))
    for i, d in ipairs(data) do
        if hasBars then
            local entry = { x = math.floor(layout.xs[i] - barWidth / 2 + 0.5), width = barWidth, segments = {} }
            local up, down = Y(0), Y(0)
            for _, s in ipairs(series) do
                local v = s.kind == "bars" and d.values[s.key] or nil
                if v and v > 0 then
                    local top = up + v / range * height
                    entry.segments[#entry.segments + 1] = { key = s.key, y = up, height = top - up }
                    up = top
                elseif v and v < 0 then
                    local bottom = down + v / range * height
                    entry.segments[#entry.segments + 1] = { key = s.key, y = bottom, height = down - bottom }
                    down = bottom
                end
            end
            layout.bars[i] = entry
        end
        for _, s in ipairs(series) do
            if s.kind ~= "bars" then
                local v = d.values[s.key]
                local list = layout.lines[s.key] or {}
                layout.lines[s.key] = list
                if v then list[#list + 1] = { x = layout.xs[i], y = Y(v), index = i } end
            end
        end
    end
    return layout
end

--- Vertical stripes under a line: { { x, width, height, left, right } } every `stripe`
-- px between the first and the last point: height at the stripe centre, left and
-- right at its edges (the drawing shears the top edge from left to right).
function Charts.AreaStripes(points, stripe)
    local list = {}
    if #points < 2 then return list end
    local x0, x1 = points[1].x, points[#points].x
    local seg = 1
    local x = x0
    while x < x1 do
        local w = math.min(stripe, x1 - x)
        local mid = x + w / 2
        while seg < #points - 1 and points[seg + 1].x < mid do seg = seg + 1 end
        local a, b = points[seg], points[seg + 1]
        local t = b.x > a.x and (mid - a.x) / (b.x - a.x) or 0
        local tEnd = b.x > a.x and math.min(1, (x + w - a.x) / (b.x - a.x)) or 0
        local tStart = b.x > a.x and math.max(0, (x - a.x) / (b.x - a.x)) or 0
        list[#list + 1] = { x = x, width = w, height = math.max(0, a.y + (b.y - a.y) * t),
            left = math.max(0, a.y + (b.y - a.y) * tStart), right = math.max(0, a.y + (b.y - a.y) * tEnd) }
        x = x + w
    end
    return list
end

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
    function pool:Reset() self.used = 0 end
    function pool:HideRest()
        for i = self.used + 1, #self.items do self.items[i]:Hide() end
    end
    return pool
end

--- opts = { height, series = { { kind = "area"|"bars"|"line", key, color } },
--   label(i) -> date text, tooltip(i) -> title, lines, empty = text, format(copper) -> axis text }.
-- :SetData(data) with data = { { values = { [key] = n } } } (oldest first).
function Charts.TimeChart(parent, opts)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(opts.height or 160)
    local plot = CreateFrame("Frame", nil, f)
    plot:SetPoint("TOPLEFT", MARGIN.left, -MARGIN.top)
    plot:SetPoint("BOTTOMRIGHT", -MARGIN.right, MARGIN.bottom)
    f.plot = plot
    local colors = {}
    for _, s in ipairs(opts.series) do colors[s.key] = s.color or C.accent end
    local format = opts.format or Charts.AxisLabel

    local grid = Pool(function()
        local t = plot:CreateTexture(nil, "BACKGROUND")
        t:SetHeight(1)
        return t
    end)
    local yLabels = Pool(function()
        local fs = Theme.Text(f, 9, C.textDim)
        fs:SetJustifyH("RIGHT")
        return fs
    end)
    local xLabels = Pool(function() return Theme.Text(f, 9, C.textDim) end)
    local stripes = Pool(function()
        local t = Theme.Unsnap(plot:CreateTexture(nil, "BORDER"))
        t:SetTexture(Theme.WHITE)
        return t
    end)
    local bars = Pool(function() return plot:CreateTexture(nil, "ARTWORK") end)
    local segments = Pool(function()
        local l = Theme.SmoothLine(plot:CreateLine(nil, "OVERLAY"))
        l:SetThickness(3)
        return l
    end)
    local points = Pool(function()
        local t = Theme.SmoothDot(plot:CreateTexture(nil, "OVERLAY"))
        t:SetSize(7, 7)
        return t
    end)
    local empty = Widgets.EmptyState(plot, opts.empty)

    -- crosshair
    local cross = plot:CreateTexture(nil, "OVERLAY")
    cross:SetWidth(1)
    cross:SetColorTexture(1, 1, 1, 0.35)
    cross:Hide()
    local band = plot:CreateTexture(nil, "BACKGROUND")
    band:SetColorTexture(1, 1, 1, 0.05)
    band:Hide()
    local markers = {}

    local function Size()
        local w = (plot.GetWidth and plot:GetWidth()) or 0
        if not w or w <= 0 then w = (opts.width or 400) - MARGIN.left - MARGIN.right end
        local h = (plot.GetHeight and plot:GetHeight()) or 0
        if not h or h <= 0 then h = (opts.height or 160) - MARGIN.top - MARGIN.bottom end
        return w, h
    end

    local function Layout()
        local width, height = Size()
        local data = f.data or {}
        local layout = Charts.Layout(data, opts.series, width, height)
        f.layout = layout
        for _, p in ipairs({ grid, yLabels, xLabels, stripes, bars, segments, points }) do p:Reset() end
        local empties = layout.empty or #data == 0
        empty:SetShown(empties and opts.empty ~= nil)
        if not empties then
            local s = layout.scale
            for _, v in ipairs(s.ticks) do
                local y = (v - s.min) / (s.max - s.min) * height
                local line = grid:Next()
                line:SetColorTexture(unpack(v == 0 and C.borderHover or C.border))
                line:ClearAllPoints()
                line:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y)
                line:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, y)
                local label = yLabels:Next()
                label:ClearAllPoints()
                label:SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, y)
                label:SetText(format(v))
            end
            if opts.label then
                local ticks = Charts.DateTicks(#data, math.floor(width / 64))
                for k, i in ipairs(ticks) do
                    local label = xLabels:Next()
                    label:ClearAllPoints()
                    local x = layout.xs[i]
                    local anchor = (k == 1 and #ticks > 1 and x < 20) and "TOPLEFT"
                        or (k == #ticks and #ticks > 1 and x > width - 20) and "TOPRIGHT" or "TOP"
                    label:SetPoint(anchor, plot, "BOTTOMLEFT", x, -4)
                    label:SetText(opts.label(i))
                end
            end
            for _, sr in ipairs(opts.series) do
                local c = colors[sr.key]
                local list = layout.lines[sr.key]
                if sr.kind == "area" and list then
                    local stripe = math.max(3, math.ceil(width / MAX_STRIPES))
                    for _, st in ipairs(Charts.AreaStripes(list, stripe)) do
                        local t = stripes:Next()
                        t:SetGradient("VERTICAL", CreateColor(c[1], c[2], c[3], 0.02), CreateColor(c[1], c[2], c[3], 0.30))
                        t:ClearAllPoints()
                        t:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", st.x, 0)
                        t:SetSize(st.width, math.max(1, st.left))
                        t:SetVertexOffset(3, 0, st.right - st.left)   -- upper right follows the line: no steps
                    end
                end
            end
            for _, entry in ipairs(layout.bars) do
                for _, seg in ipairs(entry.segments) do
                    local t = bars:Next()
                    t:SetColorTexture(unpack(colors[seg.key]))
                    t:ClearAllPoints()
                    t:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", entry.x, seg.y)
                    t:SetSize(entry.width, math.max(1, seg.height))
                end
            end
            for _, sr in ipairs(opts.series) do
                local list = layout.lines[sr.key]
                if sr.kind ~= "bars" and list then
                    local c = colors[sr.key]
                    for i = 2, #list do
                        local l = segments:Next()
                        Theme.Tint(l, c)
                        l:SetStartPoint("BOTTOMLEFT", plot, list[i - 1].x, list[i - 1].y)
                        l:SetEndPoint("BOTTOMLEFT", plot, list[i].x, list[i].y)
                    end
                    if sr.kind == "line" or #list == 1 then
                        for _, p in ipairs(list) do
                            local t = points:Next()
                            Theme.Tint(t, c)
                            t:ClearAllPoints()
                            t:SetPoint("CENTER", plot, "BOTTOMLEFT", p.x, p.y)
                        end
                    end
                end
            end
        end
        for _, p in ipairs({ grid, yLabels, xLabels, stripes, bars, segments, points }) do p:HideRest() end
    end

    local function HideCrosshair()
        cross:Hide()
        band:Hide()
        for _, m in pairs(markers) do m:Hide() end
        f.hoverIndex = nil
        Widgets.HideTooltip()
    end

    local function ShowCrosshair(i, owner)
        local layout = f.layout
        local _, height = Size()
        local x = layout.xs[i]
        cross:ClearAllPoints()
        cross:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", math.floor(x), 0)
        cross:SetHeight(height)
        cross:Show()
        if #layout.bars > 0 then
            band:ClearAllPoints()
            band:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x - layout.slot / 2, 0)
            band:SetSize(layout.slot, height)
            band:Show()
        end
        for _, sr in ipairs(opts.series) do
            if sr.kind ~= "bars" then
                local m = markers[sr.key]
                if not m then
                    m = plot:CreateTexture(nil, "OVERLAY", nil, 7)
                    m:SetSize(8, 8)
                    m:SetColorTexture(unpack(colors[sr.key]))
                    markers[sr.key] = m
                end
                local hit
                for _, p in ipairs(layout.lines[sr.key] or {}) do if p.index == i then hit = p end end
                m:SetShown(hit ~= nil)
                if hit then
                    m:ClearAllPoints()
                    m:SetPoint("CENTER", plot, "BOTTOMLEFT", hit.x, hit.y)
                end
            end
        end
        if opts.tooltip then
            local title, lines = opts.tooltip(i)
            Widgets.ShowTooltip(owner, title, lines, "ANCHOR_CURSOR")
        end
    end

    Widgets.HoverOverlay(plot, function(x, _, owner)
        local layout = f.layout
        if not layout or layout.empty or #layout.xs == 0 then return end
        local pts = {}
        for i, px in ipairs(layout.xs) do pts[i] = { x = px } end
        local i = Widgets.NearestIndex(pts, x)
        if i == f.hoverIndex then return end
        f.hoverIndex = i
        ShowCrosshair(i, owner)
    end, HideCrosshair)

    f:SetScript("OnSizeChanged", Layout)
    plot:SetScript("OnSizeChanged", Layout)
    function f:SetData(data)
        self.data = data
        HideCrosshair()
        Layout()
    end
    function f:Hover(i) ShowCrosshair(i, plot.overlay) end
    return f
end

ns.API.Charts = Charts
