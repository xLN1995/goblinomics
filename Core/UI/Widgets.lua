if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/UI/Widgets.lua
-- Widget constructors of UI kit v1. Every constructor creates frames only when
-- called; nothing here runs at load. Dropdown menus use Blizzard's MenuUtil,
-- lists use ScrollBox; the confirm dialog never uses StaticPopup.
local _, ns = ...

local Widgets = {}
ns.Widgets = Widgets
local Theme = ns.Theme
local C = Theme.colors

-------------------------------------------------------------------------------
-- Tooltip (GameTooltip, so item tooltips keep TSM/Auctionator lines)
-------------------------------------------------------------------------------
function Widgets.ShowTooltip(owner, title, lines, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetText(title, C.gold[1], C.gold[2], C.gold[3])
    for i = 1, #(lines or {}) do
        GameTooltip:AddLine(lines[i], C.textDim[1], C.textDim[2], C.textDim[3], true)
    end
    GameTooltip:Show()
end

function Widgets.ShowItemTooltip(owner, link, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
end

function Widgets.HideTooltip()
    GameTooltip:Hide()
end

local function AttachTooltip(frame, title, lines)
    if not title then return end
    frame:HookScript("OnEnter", function(self) Widgets.ShowTooltip(self, title, lines) end)
    frame:HookScript("OnLeave", Widgets.HideTooltip)
end

-------------------------------------------------------------------------------
-- Chevron (drawn with two lines: dropdown arrows, sort marks, prev/next)
-------------------------------------------------------------------------------
local CHEVRON = {
    down = { { -1, 0.5 }, { 0, -0.5 }, { 1, 0.5 } },
    up = { { -1, -0.5 }, { 0, 0.5 }, { 1, -0.5 } },
    left = { { 0.5, 1 }, { -0.5, 0 }, { 0.5, -1 } },
    right = { { -0.5, 1 }, { 0.5, 0 }, { -0.5, -1 } },
}

--- A small chevron frame of `size` px pointing down/up/left/right; :SetColor(c), :SetDirection(d).
function Widgets.Chevron(parent, direction, size)
    size = size or 8
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.lines = { Theme.SmoothLine(f:CreateLine(nil, "OVERLAY")), Theme.SmoothLine(f:CreateLine(nil, "OVERLAY")) }
    local color = C.textDim
    function f:SetColor(c)
        color = c
        for _, l in ipairs(self.lines) do Theme.Tint(l, c) end
    end
    function f:SetDirection(d)
        local p = CHEVRON[d] or CHEVRON.down
        local h = size / 2
        for i, l in ipairs(self.lines) do
            l:SetThickness(2.5)
            l:SetStartPoint("CENTER", self, p[i][1] * h, p[i][2] * h)
            l:SetEndPoint("CENTER", self, p[i + 1][1] * h, p[i + 1][2] * h)
        end
    end
    f:SetDirection(direction)
    f:SetColor(color)
    return f
end

-------------------------------------------------------------------------------
-- Button
-------------------------------------------------------------------------------
--- Width of a button that fits its text (minimum `min`, default 80).
function Widgets.FitWidth(label, min)
    local w = label.GetStringWidth and label:GetStringWidth()
    if type(w) ~= "number" or w <= 0 then return nil end
    return math.max(min or 80, math.ceil(w) + 24)
end

--- Flat button. opts = { width, height, auto (width from the text, min width), dimOff (unselected
-- label dimmed, segmented buttons), onClick(self, mouseButton), tooltip, tooltipLines }.
-- :SetEnabled(on) greys the button out; :SetSelected(on) marks it.
function Widgets.Button(parent, text, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(opts.width or 120, opts.height or Theme.space.CONTROL_H)
    b.bg = Theme.Fill(b, C.button)
    b.border = Theme.Border(b)
    b.label = Theme.Text(b, "body", C.text)
    b.label:SetPoint("CENTER")
    b.label:SetText(text or "")
    b.dimOff = opts.dimOff
    if opts.auto then
        local w = Widgets.FitWidth(b.label, opts.min)
        if w then b:SetWidth(w) end
    end
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnEnter", function(self)
        if self.selected or self.disabled then return end
        self.bg:SetColorTexture(unpack(C.buttonHover))
        self.border:SetColor(unpack(C.borderHover))
    end)
    b:SetScript("OnLeave", function(self)
        if self.selected or self.disabled then return end
        self.bg:SetColorTexture(unpack(C.button))
        self.border:SetColor(unpack(C.border))
    end)
    b:SetScript("OnClick", function(self, mouseButton)
        if opts.onClick then opts.onClick(self, mouseButton) end
    end)
    function b:SetText(t)
        self.label:SetText(t)
        if opts.auto then
            local w = Widgets.FitWidth(self.label, opts.min)
            if w then self:SetWidth(w) end
        end
    end
    function b:SetSelected(on)
        self.selected = on
        self.bg:SetColorTexture(unpack(on and C.accentSoft or C.button))
        self.border:SetColor(unpack(on and C.accent or C.border))
        self.label:SetTextColor(unpack((on or not self.dimOff) and C.text or C.textDim))
    end
    local nativeEnable = b.SetEnabled
    function b:SetEnabled(on)
        on = on and true or false
        if nativeEnable then nativeEnable(self, on) end
        self.disabled = not on
        self:SetAlpha(on and 1 or 0.45)
        self.label:SetTextColor(unpack(on and ((self.selected or not self.dimOff) and C.text or C.textDim) or C.textDim))
    end
    AttachTooltip(b, opts.tooltip, opts.tooltipLines)
    return b
end

-------------------------------------------------------------------------------
-- Checkbox (toggle style)
-------------------------------------------------------------------------------
--- Toggle with label. get() -> boolean, set(boolean).
function Widgets.Checkbox(parent, text, get, set, opts)
    opts = opts or {}
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(opts.width or 300, 22)
    local track = CreateFrame("Frame", nil, f)
    track:SetSize(32, 16)
    track:SetPoint("LEFT")
    f.track = Theme.Fill(track, C.track)
    local knob = track:CreateTexture(nil, "ARTWORK")
    knob:SetSize(12, 12)
    knob:SetColorTexture(1, 1, 1, 0.9)
    f.knob = knob
    f.label = Theme.Text(f, 12, C.text)
    f.label:SetPoint("LEFT", track, "RIGHT", 8, 0)
    f.label:SetText(text)
    function f:Refresh()
        local on = get() and true or false
        knob:ClearAllPoints()
        knob:SetPoint(on and "RIGHT" or "LEFT", track, on and "RIGHT" or "LEFT", on and -2 or 2, 0)
        self.track:SetColorTexture(unpack(on and C.accent or C.track))
    end
    f:SetScript("OnClick", function(self)
        set(not get())
        self:Refresh()
    end)
    AttachTooltip(f, opts.tooltip, opts.tooltipLines)
    f:Refresh()
    return f
end

-------------------------------------------------------------------------------
-- Dropdown (MenuUtil radio menu)
-------------------------------------------------------------------------------
--- choices() -> { {value, label, children = { ... }}, ... }; get() -> value; set(value).
-- opts = { width, size = "S"|"M"|"L", placeholder (shown for nil or opts.emptyValue),
-- display(value) -> text (custom label of the selection), tooltip,
-- tooltipLines }. Entries with children open a
-- submenu; more than 20 entries scroll. A drawn chevron shows the state; the border
-- turns green while the menu is open.
local DROP_WIDTH = { S = "DROP_S", M = "DROP_M", L = "DROP_L" }

function Widgets.Dropdown(parent, choices, get, set, opts)
    opts = opts or {}
    local b
    local function Find(list, value)
        for _, c in ipairs(list) do
            if c.value == value and not c.children then return c.label end
            if c.children then
                local label = Find(c.children, value)
                if label then return label end
            end
        end
    end
    local function LabelFor(value) return Find(choices(), value) or tostring(value) end
    local function Fill(menu, list)
        if #list > 20 and menu.SetScrollMode then menu:SetScrollMode(20 * 20) end
        for _, c in ipairs(list) do
            if c.children then
                Fill(menu:CreateButton(c.label), c.children)
            else
                menu:CreateRadio(c.label,
                    function(value) return get() == value end,
                    function(value)
                        set(value)
                        b:Refresh()
                    end,
                    c.value)
            end
        end
    end
    local width = opts.width or (opts.size and Theme.space[DROP_WIDTH[opts.size]]) or Theme.space.DROP_L
    b = Widgets.Button(parent, "", {
        width = width, height = Theme.space.CONTROL_H,
        onClick = function(self)
            if not MenuUtil then return end
            local menu = MenuUtil.CreateContextMenu(self, function(_, root) Fill(root, choices()) end)
            self.open = true
            self.border:SetColor(unpack(C.accent))
            if menu and menu.SetClosedCallback then
                menu:SetClosedCallback(function()
                    self.open = false
                    self.border:SetColor(unpack(C.border))
                end)
            end
        end,
        tooltip = opts.tooltip, tooltipLines = opts.tooltipLines,
    })
    b.label:ClearAllPoints()
    b.label:SetPoint("LEFT", 8, 0)
    b.label:SetPoint("RIGHT", -22, 0)
    b.label:SetJustifyH("LEFT")
    b.label:SetWordWrap(false)
    b.arrow = Widgets.Chevron(b, "down", 8)
    b.arrow:SetPoint("RIGHT", -9, 0)
    b:HookScript("OnEnter", function(self) self.arrow:SetColor(C.text) end)
    b:HookScript("OnLeave", function(self)
        self.arrow:SetColor(C.textDim)
        if self.open then self.border:SetColor(unpack(C.accent)) end
    end)
    function b:Refresh()
        local value = get()
        if opts.placeholder and (value == nil or value == opts.emptyValue) then
            self.label:SetText(opts.placeholder)
        else
            self.label:SetText(opts.display and opts.display(value) or LabelFor(value))
        end
    end
    b:Refresh()
    return b
end

-------------------------------------------------------------------------------
-- Slider
-------------------------------------------------------------------------------
--- opts = { min, max, step, width, get(), set(value), format(value) -> text, release }.
-- release = true applies the value only when the mouse button is released (window scale).
function Widgets.Slider(parent, opts)
    local width = opts.width or 240
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width, 20)
    local s = CreateFrame("Slider", nil, f)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(width - 70, 10)
    s:SetPoint("LEFT")
    s:SetMinMaxValues(opts.min, opts.max)
    s:SetValueStep(opts.step)
    s:SetObeyStepOnDrag(true)
    s:EnableMouse(true)
    Theme.Fill(s, C.track)
    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(8, 16)
    thumb:SetColorTexture(unpack(C.accent))
    s:SetThumbTexture(thumb)
    local label = Theme.Text(f, 12, C.text)
    label:SetPoint("RIGHT")
    label:SetJustifyH("RIGHT")
    local format = opts.format or function(v) return tostring(v) end
    local function Round(v)
        return math.floor(v / opts.step + 0.5) * opts.step
    end
    local pending
    s:SetScript("OnValueChanged", function(_, v, userInput)
        v = Round(v)
        label:SetText(format(v))
        if userInput then
            if opts.release then pending = v else opts.set(v) end
        end
    end)
    if opts.release then
        s:SetScript("OnMouseUp", function()
            if pending then
                opts.set(pending)
                pending = nil
            end
        end)
    end
    function f:Refresh()
        local v = opts.get()
        s:SetValue(v)
        label:SetText(format(v))
    end
    f.slider = s
    f:Refresh()
    return f
end

-------------------------------------------------------------------------------
-- Edit box
-------------------------------------------------------------------------------
--- opts = { width, get() -> text, set(text) -> ok, errorMessage, tooltip, tooltipLines }
-- Enter commits (set may refuse with an error shown below), Esc and focus loss revert.
function Widgets.EditBox(parent, opts)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetSize(opts.width or 200, 24)
    e:SetAutoFocus(false)
    e:SetFontObject(Theme.Font(12))
    e:SetTextColor(unpack(C.text))
    e:SetTextInsets(6, 6, 0, 0)
    Theme.Backdrop(e, C.button, C.border)
    e.error = Theme.Text(e, 10, C.loss)
    e.error:SetPoint("TOPLEFT", e, "BOTTOMLEFT", 2, -2)
    e.error:Hide()
    local function Revert(self)
        self:SetText(opts.get() or "")
        self:SetCursorPosition(0)
    end
    e:SetScript("OnEnterPressed", function(self)
        local ok, err = opts.set(self:GetText())
        if ok == false then
            self.error:SetText(err or "")
            self.error:Show()
            return
        end
        self.error:Hide()
        self:ClearFocus()
    end)
    e:SetScript("OnEscapePressed", function(self)
        Revert(self)
        self.error:Hide()
        self:ClearFocus()
    end)
    e:SetScript("OnEditFocusLost", Revert)
    AttachTooltip(e, opts.tooltip, opts.tooltipLines)
    Revert(e)
    return e
end

-------------------------------------------------------------------------------
-- Progress bar
-------------------------------------------------------------------------------
function Widgets.ProgressBar(parent, width, height)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(width or 200, height or 14)
    bar:SetStatusBarTexture(Theme.WHITE)
    bar:SetStatusBarColor(unpack(C.accent))
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    Theme.Fill(bar, C.track)
    Theme.Border(bar)
    bar.left = Theme.Text(bar, 11, C.text)
    bar.left:SetPoint("LEFT", 4, 0)
    bar.right = Theme.Text(bar, 11, C.text)
    bar.right:SetPoint("RIGHT", -4, 0)
    bar.right:SetJustifyH("RIGHT")
    function bar:SetLabels(l, r)
        self.left:SetText(l or "")
        self.right:SetText(r or "")
    end
    return bar
end

-------------------------------------------------------------------------------
-- Scroll list (virtualised) and scroll panel (forms)
-------------------------------------------------------------------------------
--- Virtualised list. opts = { rowHeight, init(row, data) }. Returns list with :SetData(array).
function Widgets.ScrollList(parent, opts)
    local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(opts.rowHeight or 20)
    view:SetElementInitializer("Button", function(row, data)
        opts.init(row, data)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    bar:SetHideIfUnscrollable(true)
    local list = { box = box, bar = bar, view = view }
    function list:SetData(array)
        box:SetDataProvider(CreateDataProvider(array), ScrollBoxConstants.RetainScrollPosition)
    end
    return list
end

--- Scrollable form area. Returns box, content; call panel:Update(height) after layout.
function Widgets.ScrollPanel(parent)
    local box = CreateFrame("Frame", nil, parent, "WowScrollBox")
    local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)
    local content = CreateFrame("Frame", nil, box)
    content.scrollable = true
    content:SetSize(1, 1)
    local view = CreateScrollBoxLinearView(0, 0, 0, 0, 0)
    view:SetPanExtent(40)
    ScrollUtil.InitScrollBoxWithScrollBar(box, bar, view)
    bar:SetHideIfUnscrollable(true)
    box:SetScript("OnSizeChanged", function(self)
        local w = self:GetWidth()
        if w and w > 0 then content:SetWidth(w) end
    end)
    local panel = { box = box, bar = bar, content = content }
    function panel:Update(height)
        content:SetHeight(math.max(1, height))
        box:FullUpdate(ScrollBoxConstants.UpdateImmediately)
    end
    return panel
end

-------------------------------------------------------------------------------
-- Bar chart (stacked, positive above and negative below the zero line)
-------------------------------------------------------------------------------
--- Pure layout: bars = { { values = { [seriesKey] = n } } }, series = { { key } }.
-- Returns { baseline, barWidth, bars = { { x, segments = { { key, y, height } } } } }
-- with y measured from the bottom of the chart.
function Widgets.BarChartLayout(bars, series, width, height, gap)
    gap = gap or 2
    local n = #bars
    local layout = { bars = {}, barWidth = 0, baseline = 0 }
    if n == 0 or width <= 0 or height <= 0 then return layout end
    local maxPos, maxNeg = 0, 0
    for _, bar in ipairs(bars) do
        local pos, neg = 0, 0
        for _, s in ipairs(series) do
            local v = bar.values[s.key] or 0
            if v > 0 then pos = pos + v else neg = neg - v end
        end
        if pos > maxPos then maxPos = pos end
        if neg > maxNeg then maxNeg = neg end
    end
    local range = maxPos + maxNeg
    local scale = range > 0 and height / range or 0
    layout.baseline = maxNeg * scale
    layout.barWidth = math.max(1, (width - gap * (n - 1)) / n)
    for i, bar in ipairs(bars) do
        local entry = { x = (i - 1) * (layout.barWidth + gap), segments = {} }
        local up, down = layout.baseline, layout.baseline
        for _, s in ipairs(series) do
            local v = bar.values[s.key] or 0
            if v > 0 then
                entry.segments[#entry.segments + 1] = { key = s.key, y = up, height = v * scale }
                up = up + v * scale
            elseif v < 0 then
                down = down + v * scale
                entry.segments[#entry.segments + 1] = { key = s.key, y = down, height = -v * scale }
            end
        end
        layout.bars[i] = entry
    end
    return layout
end

--- Stacked bar chart. opts = { width, height, gap, series = { { key, color } },
-- tooltip = function(bar) -> title, lines }. Returns frame with :SetData(bars).
function Widgets.BarChart(parent, opts)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(opts.width or 300, opts.height or 100)
    local zero = f:CreateTexture(nil, "ARTWORK")
    zero:SetColorTexture(unpack(C.borderHover))
    zero:SetHeight(1)
    local pool, colors = {}, {}
    for _, s in ipairs(opts.series) do colors[s.key] = s.color end
    local function Bar(i)
        local b = pool[i]
        if b then return b end
        b = CreateFrame("Button", nil, f)
        b.segments = {}
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        b:SetScript("OnEnter", function(self)
            if opts.tooltip and self.data then
                local title, lines = opts.tooltip(self.data)
                Widgets.ShowTooltip(self, title, lines, "ANCHOR_TOP")
            end
        end)
        b:SetScript("OnLeave", Widgets.HideTooltip)
        pool[i] = b
        return b
    end
    local function Layout()
        local width = (f.GetWidth and f:GetWidth()) or 0
        if not width or width <= 0 then width = opts.width or 300 end
        local height = (f.GetHeight and f:GetHeight()) or 0
        if not height or height <= 0 then height = opts.height or 100 end
        local bars = f.data or {}
        local layout = Widgets.BarChartLayout(bars, opts.series, width, height, opts.gap)
        f.layout = layout
        zero:ClearAllPoints()
        zero:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, layout.baseline)
        zero:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, layout.baseline)
        for i, entry in ipairs(layout.bars) do
            local b = Bar(i)
            b.data = bars[i]
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", entry.x, 0)
            b:SetSize(layout.barWidth, height)
            for j, seg in ipairs(entry.segments) do
                local t = b.segments[j]
                if not t then
                    t = b:CreateTexture(nil, "ARTWORK")
                    b.segments[j] = t
                end
                t:SetColorTexture(unpack(colors[seg.key] or C.accent))
                t:ClearAllPoints()
                t:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, seg.y)
                t:SetSize(layout.barWidth, math.max(1, seg.height))
                t:Show()
            end
            for j = #entry.segments + 1, #b.segments do b.segments[j]:Hide() end
            b:Show()
        end
        for i = #layout.bars + 1, #pool do pool[i]:Hide() end
    end
    f:SetScript("OnSizeChanged", Layout)
    function f:SetData(bars)
        self.data = bars
        Layout()
    end
    return f
end

-------------------------------------------------------------------------------
-- Hover overlay: one mouse area exactly the size of a chart. Per-point mouse
-- areas centred on their points reached past the chart's edge and swallowed
-- clicks on neighbouring buttons (in-game finding, M7).
-------------------------------------------------------------------------------
--- Index of the point nearest to x (points = { { x, y } } sorted by x), nil if empty.
function Widgets.NearestIndex(points, x)
    local best, bestDist
    for i, p in ipairs(points) do
        local d = math.abs(p.x - x)
        if not bestDist or d < bestDist then best, bestDist = i, d end
    end
    return best
end

--- Cursor position relative to the bottom left of a frame (nil when unknown).
function Widgets.CursorIn(frame)
    local cx, cy = GetCursorPosition()
    local scale = frame:GetEffectiveScale() or 1
    local left, bottom = frame:GetLeft(), frame:GetBottom()
    if not (cx and left and bottom) then return nil end
    return cx / scale - left, cy / scale - bottom
end

--- onMove(x, y, overlay) while the cursor is over the chart, onLeave() after.
function Widgets.HoverOverlay(chart, onMove, onLeave)
    local o = CreateFrame("Frame", nil, chart)
    o:SetAllPoints(chart)
    o:SetFrameLevel((chart:GetFrameLevel() or 0) + 5)
    o:EnableMouse(true)
    local function Update(self)
        local x, y = Widgets.CursorIn(chart)
        if x then onMove(x, y, self) end
    end
    o:SetScript("OnEnter", function(self)
        Update(self)
        self:SetScript("OnUpdate", Update)
    end)
    o:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        if onLeave then onLeave(self) end
    end)
    chart.overlay = o
    return o
end

-------------------------------------------------------------------------------
-- Line chart (Line regions; also used as a sparkline without axes)
-------------------------------------------------------------------------------
--- Pure layout: values = { n, ... } -> { points = { { x, y } }, min, max } with y
-- from the bottom; a flat series is drawn in the middle.
function Widgets.LineLayout(values, width, height)
    local layout = { points = {} }
    local n = #values
    if n == 0 then return layout end
    local min, max = math.huge, -math.huge
    for _, v in ipairs(values) do
        if v < min then min = v end
        if v > max then max = v end
    end
    layout.min, layout.max = min, max
    local range = max - min
    for i, v in ipairs(values) do
        local x = n > 1 and (i - 1) / (n - 1) * width or width / 2
        local y = range > 0 and (v - min) / range * height or height / 2
        layout.points[i] = { x = x, y = y }
    end
    return layout
end

--- opts = { width, height, color, thickness, fill, tooltip = function(index, point) -> title, lines }.
-- fill = true draws a gradient area under the line (Charts.AreaStripes).
-- The tooltip follows the cursor over one hover area (HoverOverlay).
-- :SetData(values) with values = { n, ... }; :SetColor(r, g, b, a).
function Widgets.LineChart(parent, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(opts.width or 200, opts.height or 40)
    local lines, dots, stripes = {}, {}, {}
    local color = opts.color or C.accent
    local function Layout()
        local width = (f.GetWidth and f:GetWidth()) or 0
        if not width or width <= 0 then width = opts.width or 200 end
        local height = (f.GetHeight and f:GetHeight()) or 0
        if not height or height <= 0 then height = opts.height or 40 end
        local values = f.values or {}
        local layout = Widgets.LineLayout(values, width, height)
        f.layout = layout
        local points = layout.points
        for i = 2, #points do
            local line = lines[i - 1]
            if not line then
                line = Theme.SmoothLine(f:CreateLine(nil, "ARTWORK"))
                lines[i - 1] = line
            end
            line:SetThickness((opts.thickness or 2) * 1.5)
            Theme.Tint(line, color)
            line:SetStartPoint("BOTTOMLEFT", f, points[i - 1].x, points[i - 1].y)
            line:SetEndPoint("BOTTOMLEFT", f, points[i].x, points[i].y)
            line:Show()
        end
        for i = math.max(1, #points), #lines do lines[i]:Hide() end
        local used = 0
        if opts.fill and ns.Charts then
            for _, st in ipairs(ns.Charts.AreaStripes(points, math.max(3, math.ceil(width / 200)))) do
                used = used + 1
                local t = stripes[used]
                if not t then
                    t = f:CreateTexture(nil, "BORDER")
                    t:SetTexture(Theme.WHITE)
                    stripes[used] = t
                end
                t:SetGradient("VERTICAL", CreateColor(color[1], color[2], color[3], 0.02),
                    CreateColor(color[1], color[2], color[3], 0.28))
                t:ClearAllPoints()
                t:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", st.x, 0)
                t:SetSize(st.width, math.max(1, st.height))
                t:Show()
            end
        end
        for i = used + 1, #stripes do stripes[i]:Hide() end
        local last = points[#points]
        local dot = dots[1]
        if not dot then
            dot = f:CreateTexture(nil, "OVERLAY")
            dot:SetSize(5, 5)
            dots[1] = dot
        end
        dot:SetColorTexture(unpack(color))
        dot:SetShown(last ~= nil)
        if last then
            dot:ClearAllPoints()
            dot:SetPoint("CENTER", f, "BOTTOMLEFT", last.x, last.y)
        end
    end
    f:SetScript("OnSizeChanged", Layout)
    if opts.tooltip then
        Widgets.HoverOverlay(f, function(x, _, owner)
            local points = f.layout and f.layout.points or {}
            local i = Widgets.NearestIndex(points, x)
            if not i then return Widgets.HideTooltip() end
            if i == f.hoverIndex and GameTooltip:IsOwned(owner) then return end
            f.hoverIndex = i
            local title, textLines = opts.tooltip(i, points[i])
            Widgets.ShowTooltip(owner, title, textLines, "ANCHOR_TOP")
        end, function()
            f.hoverIndex = nil
            Widgets.HideTooltip()
        end)
    end
    function f:SetData(values)
        self.values = values
        Layout()
    end
    function f:SetColor(r, g, b, a)
        color = { r, g, b, a or 1 }
        Layout()
    end
    return f
end

-------------------------------------------------------------------------------
-- Confirm dialog (singleton)
-------------------------------------------------------------------------------
local dialog

local function CloseDialog(confirmed)
    if not dialog then return end
    dialog.confirmed = confirmed
    ns.UIEvents:Unregister("PLAYER_REGEN_DISABLED", "dialog")
    dialog.dimmer:Hide()
    dialog:Hide()
end

-- same frame as every dialog (Widgets.Dialog: header bar, close button, button row) over a dimmer
local function BuildDialog()
    local dimmer = CreateFrame("Frame", nil, UIParent)
    dimmer:SetAllPoints(UIParent)
    dimmer:SetFrameStrata("FULLSCREEN_DIALOG")
    dimmer:EnableMouse(true)
    Theme.Fill(dimmer, C.dimmer)
    local d
    d = Widgets.Dialog({ name = "GoblinomicsConfirmDialog", width = 400, height = 190,
        buttons = {
            { text = "", onClick = function() CloseDialog(false) end },
            { text = "", primary = true, onClick = function() CloseDialog(true) end },
        },
        onClose = function()
            dimmer:Hide()
            ns.UIEvents:Unregister("PLAYER_REGEN_DISABLED", "dialog")
            local fn = d.confirmed and d.onConfirm or d.onCancel
            d.confirmed = nil
            if fn then fn() end
        end })
    d:SetFrameStrata("FULLSCREEN_DIALOG")
    d:SetFrameLevel((dimmer:GetFrameLevel() or 0) + 10)
    d.text = Theme.Text(d.body, "body", C.text)
    d.text:SetPoint("TOPLEFT")
    d.text:SetPoint("RIGHT", d.body, "RIGHT", 0, 0)
    d.text:SetJustifyV("TOP")
    d.cancel, d.confirm = d.buttons[1], d.buttons[2]
    d.dimmer = dimmer
    return d
end

--- opts = { title, text, confirmText, cancelText, onConfirm, onCancel }
function Widgets.Confirm(opts)
    dialog = dialog or BuildDialog()
    local L = ns.L
    dialog:SetTitle(opts.title or "Goblinomics")
    dialog.text:SetText(opts.text or "")
    dialog.confirm:SetText(opts.confirmText or L["OK"])
    dialog.cancel:SetText(opts.cancelText or L["Cancel"])
    dialog.onConfirm, dialog.onCancel = opts.onConfirm, opts.onCancel
    dialog.confirmed = nil
    dialog.dimmer:Show()
    dialog:Show()
    ns.UIEvents:Register("PLAYER_REGEN_DISABLED", function() CloseDialog(false) end, "dialog")
end

-- UI-side event dispatcher (window, dialog, toasts).
ns.UIEvents = ns.Events.NewDispatcher("Core.UI")

ns.API.Widgets = Widgets
