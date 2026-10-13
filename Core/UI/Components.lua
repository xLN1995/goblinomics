if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/UI/Components.lua
-- Shared building blocks, so every module looks the same:
--   Card        panel with an upper-case caption title and a padded body
--   Segmented   2-7 options side by side (periods, day/week, two-way choices)
--   Columns     table header and row cells from one column spec (sortable heads)
--   Dialog      window with a header bar, close button, body and a button row
--   EmptyState  centred hint for empty lists and charts
--   IconButton  small button with a drawn icon (close, prev, next, play)
--   NavButton   borderless navigation row with the green bar (sidebar, lists)
-- All distances come from Theme.space, sizes from Theme.SIZE.
local _, ns = ...

local Widgets, Theme = ns.Widgets, ns.Theme
local C = Theme.colors
local S = Theme.space

-------------------------------------------------------------------------------
-- Card
-------------------------------------------------------------------------------
--- Card with background, 1 px border, caption title (upper case, grey); card.body is the padded area.
function Widgets.Card(parent, title)
    local card = CreateFrame("Frame", nil, parent)
    Theme.Backdrop(card, C.panel, C.border)
    local top = -S.PAD
    if title then
        card.title = Theme.Text(card, "caption", C.textDim)
        card.title:SetPoint("TOPLEFT", S.PAD, S.CARD_TITLE_Y)
        card.title:SetPoint("RIGHT", card, "RIGHT", -S.PAD, 0)
        card.title:SetWordWrap(false)
        card.title:SetText(tostring(title):upper())
        top = S.CARD_BODY_Y
    end
    card.body = CreateFrame("Frame", nil, card)
    card.body:SetPoint("TOPLEFT", S.PAD, top)
    card.body:SetPoint("BOTTOMRIGHT", -S.PAD, S.PAD - 2)
    function card:SetTitle(text)
        if self.title then self.title:SetText(tostring(text or ""):upper()) end
    end
    return card
end

-------------------------------------------------------------------------------
-- Segmented control
-------------------------------------------------------------------------------
--- options: { {value, label} } or a function returning them; get() -> value; set(value).
-- opts = { width (per button, else fitted to the text), min }. :Refresh() re-reads the value.
function Widgets.Segmented(parent, options, get, set, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(S.CONTROL_H)
    f.buttons = {}
    local function List() return type(options) == "function" and options() or options end
    function f:Refresh()
        local x = 0
        local current = get()
        for i, o in ipairs(List()) do
            local b = self.buttons[i]
            if not b then
                b = Widgets.Button(self, "", { width = opts.width or 60, dimOff = true, onClick = function(btn)
                    set(btn.value)
                    self:Refresh()
                end })
                self.buttons[i] = b
            end
            b.value = o.value
            b.label:SetText(o.label)
            local w = opts.width or Widgets.FitWidth(b.label, opts.min or 40) or 60
            b:SetWidth(w)
            b:ClearAllPoints()
            b:SetPoint("LEFT", self, "LEFT", x, 0)
            b:SetSelected(o.value == current)
            b:Show()
            x = x + w - 1
        end
        for i = #List() + 1, #self.buttons do self.buttons[i]:Hide() end
        self:SetWidth(math.max(1, x + 1))
    end
    f:Refresh()
    return f
end

-------------------------------------------------------------------------------
-- Columns: table header and row cells from one spec
-------------------------------------------------------------------------------
local SORT_MARK = 9   -- room for the sort chevron inside a header cell
--- columns = { { key, label, width, align = "LEFT"|"RIGHT", sortable } }; exactly one column
-- may have width = nil and takes the remaining space. Columns before it are anchored to
-- the left, columns after it to the right, so header and rows always line up.
-- opts = { onSort(key), sortKey(), sortDesc() }.
function Widgets.Columns(columns, opts)
    opts = opts or {}
    local cols = { spec = columns }
    local flex
    for i, c in ipairs(columns) do if not c.width then flex = i end end
    flex = flex or #columns
    local function Place(fs, i, parent, y)
        local c = columns[i]
        fs:ClearAllPoints()
        if i < flex then
            local x = S.SM
            for k = 1, i - 1 do x = x + columns[k].width + S.SM end
            fs:SetPoint("LEFT", parent, "LEFT", x, y or 0)
            fs:SetWidth(c.width)
        elseif i > flex then
            local x = -S.SM
            for k = #columns, i + 1, -1 do x = x - columns[k].width - S.SM end
            fs:SetPoint("RIGHT", parent, "RIGHT", x, y or 0)
            fs:SetWidth(c.width)
        else
            local left, right = S.SM, -S.SM
            for k = 1, i - 1 do left = left + columns[k].width + S.SM end
            for k = #columns, i + 1, -1 do right = right - columns[k].width - S.SM end
            fs:SetPoint("LEFT", parent, "LEFT", left, y or 0)
            fs:SetPoint("RIGHT", parent, "RIGHT", right, y or 0)
        end
        -- header cells are buttons: text settings only apply to font strings
        if fs.SetJustifyH then fs:SetJustifyH(c.align or "LEFT") end
        if fs.SetWordWrap then fs:SetWordWrap(false) end
    end
    cols.Place = Place

    --- Header row (caption, grey, upper case); sortable heads are buttons with a chevron.
    function cols:Header(parent)
        local h = CreateFrame("Frame", nil, parent)
        h:SetHeight(S.HEADER_H)
        h.cells = {}
        for i, c in ipairs(columns) do
            local cell = CreateFrame("Button", nil, h)
            cell:SetHeight(S.HEADER_H)
            cell.label = Theme.Text(cell, "caption", C.textDim)
            cell.label:SetAllPoints()
            cell.label:SetText((c.label or ""):upper())
            cell.label:SetWordWrap(false)
            Place(cell, i, h)
            cell.label:SetJustifyH(c.align or "LEFT")
            if c.sortable and opts.onSort then
                -- the sort mark stays inside its own column: right-aligned heads keep it at the
                -- right edge (the text moves left), left-aligned ones right after the text
                cell.chevron = Widgets.Chevron(cell, "down", 6)
                if (c.align or "LEFT") == "RIGHT" then
                    cell.chevron:SetPoint("RIGHT", cell, "RIGHT", 0, 0)
                end
                cell:SetScript("OnClick", function() opts.onSort(c.key) cols:RefreshHeader() end)
                cell:SetScript("OnEnter", function(btn) btn.label:SetTextColor(unpack(C.text)) end)
                cell:SetScript("OnLeave", function(btn) btn.label:SetTextColor(unpack(C.textDim)) end)
            end
            h.cells[i] = cell
        end
        self.header = h
        self:RefreshHeader()
        return h
    end

    function cols:RefreshHeader()
        if not self.header then return end
        local key = opts.sortKey and opts.sortKey()
        for i, c in ipairs(columns) do
            local cell = self.header.cells[i]
            if cell.chevron then
                local sorted = c.key == key
                if (c.align or "LEFT") == "RIGHT" then
                    -- only the sorted head moves its text left to make room for the mark
                    cell.label:ClearAllPoints()
                    cell.label:SetPoint("TOPLEFT")
                    cell.label:SetPoint("BOTTOMRIGHT", sorted and -SORT_MARK or 0, 0)
                else
                    local text = cell.label.GetStringWidth and cell.label:GetStringWidth() or 0
                    local room = (c.width or (cell.GetWidth and cell:GetWidth()) or 0) - SORT_MARK
                    cell.chevron:ClearAllPoints()
                    cell.chevron:SetPoint("LEFT", cell, "LEFT", math.max(0, math.min((text or 0) + 3, room)), 0)
                end
                cell.chevron:SetShown(c.key == key)
                cell.chevron:SetDirection(opts.sortDesc and opts.sortDesc() and "down" or "up")
                cell.chevron:SetColor(C.text)
            end
        end
    end

    --- Font strings for a row: row.cells[key]; size "small" by default.
    function cols:Cells(row, size)
        row.cells = row.cells or {}
        for i, c in ipairs(columns) do
            local fs = row.cells[c.key]
            if not fs then
                fs = Theme.Text(row, size or "small", C.text)
                row.cells[c.key] = fs
            end
            Place(fs, i, row)
        end
        return row.cells
    end
    return cols
end

--- Row background for lists: zebra stripe on even rows and a hover highlight.
function Widgets.RowBackground(row)
    if row.zebra then return end
    row.zebra = row:CreateTexture(nil, "BACKGROUND")
    row.zebra:SetAllPoints()
    row.zebra:SetColorTexture(unpack(C.zebra))
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(unpack(C.hover))
end

-------------------------------------------------------------------------------
-- Tooltip lines in one style: gold title, grey labels and hints, white values
-------------------------------------------------------------------------------
function Widgets.TooltipTitle(text) GameTooltip:SetText(text or "", C.gold[1], C.gold[2], C.gold[3]) end

function Widgets.TooltipPair(label, value)
    GameTooltip:AddDoubleLine(label, value, C.textDim[1], C.textDim[2], C.textDim[3], C.text[1], C.text[2], C.text[3])
end

function Widgets.TooltipHint(text)
    GameTooltip:AddLine(text, C.textDim[1], C.textDim[2], C.textDim[3], true)
end

-------------------------------------------------------------------------------
-- Empty state
-------------------------------------------------------------------------------
--- Centred hint in `parent`; :Set(text, hint), :SetShown(on).
function Widgets.EmptyState(parent, text, hint)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f.text = Theme.Text(f, "body", C.textDim)
    f.text:SetPoint("CENTER", 0, 6)
    f.text:SetJustifyH("CENTER")
    f.hint = Theme.Text(f, "caption", C.textDim)
    f.hint:SetPoint("TOP", f.text, "BOTTOM", 0, -4)
    f.hint:SetJustifyH("CENTER")
    function f:Set(t, h)
        self.text:SetText(t or "")
        self.hint:SetText(h or "")
    end
    f:Set(text, hint)
    f:Hide()
    return f
end

-------------------------------------------------------------------------------
-- Icon button (drawn icons, no atlas dependency)
-------------------------------------------------------------------------------
--- kind = "close" | "prev" | "next" | "play"; opts = { size, onClick, tooltip, tooltipLines }.
function Widgets.IconButton(parent, kind, opts)
    opts = opts or {}
    local size = opts.size or S.SMALL_H
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.bg = Theme.Fill(b, C.button)
    b.border = Theme.Border(b)
    local icon
    if kind == "close" then
        icon = CreateFrame("Frame", nil, b)
        icon:SetSize(size * 0.45, size * 0.45)
        icon.lines = { Theme.SmoothLine(icon:CreateLine(nil, "OVERLAY")), Theme.SmoothLine(icon:CreateLine(nil, "OVERLAY")) }
        local h = size * 0.225
        icon.lines[1]:SetStartPoint("CENTER", icon, -h, h)
        icon.lines[1]:SetEndPoint("CENTER", icon, h, -h)
        icon.lines[2]:SetStartPoint("CENTER", icon, -h, -h)
        icon.lines[2]:SetEndPoint("CENTER", icon, h, h)
        function icon:SetColor(c)
            for _, l in ipairs(self.lines) do
                l:SetThickness(2.5)
                Theme.Tint(l, c)
            end
        end
    else
        icon = Widgets.Chevron(b, kind == "prev" and "left" or "right", size * 0.4)
    end
    icon:SetPoint("CENTER")
    icon:SetColor(C.textDim)
    b.icon = icon
    b:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(unpack(C.buttonHover))
        self.border:SetColor(unpack(C.borderHover))
        self.icon:SetColor(C.text)
        if opts.tooltip then Widgets.ShowTooltip(self, opts.tooltip, opts.tooltipLines) end
    end)
    b:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(unpack(C.button))
        self.border:SetColor(unpack(C.border))
        self.icon:SetColor(C.textDim)
        Widgets.HideTooltip()
    end)
    b:SetScript("OnClick", function(self, mouseButton) if opts.onClick then opts.onClick(self, mouseButton) end end)
    local nativeEnable = b.SetEnabled
    function b:SetEnabled(on)
        if nativeEnable then nativeEnable(self, on and true or false) end
        self:SetAlpha(on and 1 or 0.45)
    end
    return b
end

-------------------------------------------------------------------------------
-- Navigation row
-------------------------------------------------------------------------------
--- Borderless row with a 3 px green bar when selected (main sidebar, settings, lists).
function Widgets.NavButton(parent, text, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(opts.height or S.NAV_H)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0, 0, 0, 0)
    b.bar = b:CreateTexture(nil, "ARTWORK")
    b.bar:SetPoint("TOPLEFT")
    b.bar:SetPoint("BOTTOMLEFT")
    b.bar:SetWidth(3)
    b.bar:SetColorTexture(unpack(C.accent))
    b.bar:Hide()
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(unpack(C.hover))
    b.label = Theme.Text(b, "body", C.textDim)
    b.label:SetPoint("LEFT", 14, 0)
    b.label:SetPoint("RIGHT", -8, 0)
    b.label:SetWordWrap(false)
    b.label:SetText(text or "")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", function(self, mouseButton) if opts.onClick then opts.onClick(self, mouseButton) end end)
    function b:SetText(t) self.label:SetText(t) end
    function b:SetSelected(on)
        self.selected = on
        self.bar:SetShown(on)
        self.bg:SetColorTexture(unpack(on and C.accentSoft or { 0, 0, 0, 0 }))
        self.label:SetTextColor(unpack(on and C.text or C.textDim))
    end
    return b
end

--- Mark a list row as selected in the navigation style (bar + soft background).
function Widgets.MarkSelected(row, on)
    if not row.selBar then
        row.selBar = row:CreateTexture(nil, "ARTWORK")
        row.selBar:SetPoint("TOPLEFT")
        row.selBar:SetPoint("BOTTOMLEFT")
        row.selBar:SetWidth(3)
        row.selBar:SetColorTexture(unpack(C.accent))
        row.selBg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.selBg:SetAllPoints()
        row.selBg:SetColorTexture(unpack(C.accentSoft))
    end
    row.selBar:SetShown(on and true or false)
    row.selBg:SetShown(on and true or false)
end

-------------------------------------------------------------------------------
-- Dialog
-------------------------------------------------------------------------------
local dialogCount = 0

--- spec = { title, width, height, name, closable = true, onClose, buttons = { { text, onClick,
-- primary } } }. Returns the frame with .body (padded) and :Row(label, control, y) for a label
-- grid (labels 0..130, controls from 140); Esc closes. Primary button right, others left.
function Widgets.Dialog(spec)
    dialogCount = dialogCount + 1
    local name = spec.name or ("GoblinomicsDialog" .. dialogCount)
    local d = CreateFrame("Frame", name, UIParent)
    d:SetSize(spec.width or 440, spec.height or 320)
    d:SetPoint("CENTER", 0, 60)
    d:SetFrameStrata("DIALOG")
    d:SetToplevel(true)
    d:SetClampedToScreen(true)
    d:SetMovable(true)
    d:EnableMouse(true)
    Theme.Backdrop(d, C.bg, C.borderHover)
    local header = CreateFrame("Frame", nil, d)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(36)
    Theme.Fill(header, C.header)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() d:StartMoving() end)
    header:SetScript("OnDragStop", function() d:StopMovingOrSizing() end)
    d.header = header
    d.title = Theme.Text(header, "title", C.gold)
    d.title:SetPoint("LEFT", S.DIALOG_PAD, 0)
    d.title:SetPoint("RIGHT", -40, 0)
    d.title:SetWordWrap(false)
    d.title:SetText(spec.title or "")
    if spec.closable ~= false then
        d.close = Widgets.IconButton(header, "close", { onClick = function() d:Hide() end })
        d.close:SetPoint("RIGHT", -S.PAD, 0)
    end
    local hasButtons = spec.buttons and #spec.buttons > 0
    d.body = CreateFrame("Frame", nil, d)
    d.body:SetPoint("TOPLEFT", S.DIALOG_PAD, -36 - S.PAD)
    d.body:SetPoint("BOTTOMRIGHT", -S.DIALOG_PAD, hasButtons and (S.CONTROL_H + 2 * S.PAD) or S.DIALOG_PAD)
    d.buttons = {}
    local left = S.DIALOG_PAD
    for _, bspec in ipairs(spec.buttons or {}) do
        local b = Widgets.Button(d, bspec.text, { width = bspec.width or S.DIALOG_BTN_W, onClick = bspec.onClick })
        if bspec.primary then
            b:SetPoint("BOTTOMRIGHT", -S.DIALOG_PAD, S.PAD)
        else
            b:SetPoint("BOTTOMLEFT", left, S.PAD)
            left = left + (bspec.width or S.DIALOG_BTN_W) + S.SM
        end
        d.buttons[#d.buttons + 1] = b
    end
    function d:SetTitle(t) self.title:SetText(t or "") end
    --- label left, control from x = 140 at offset y (negative) in the body
    function d:Row(label, control, y)
        local fs = Theme.Text(self.body, "body", C.textDim)
        fs:SetPoint("TOPLEFT", 0, y - 4)
        fs:SetWidth(132)
        fs:SetWordWrap(false)
        fs:SetText(label or "")
        control:ClearAllPoints()
        control:SetPoint("TOPLEFT", self.body, "TOPLEFT", 140, y)
        return fs
    end
    d:SetScript("OnHide", function() if spec.onClose then spec.onClose() end end)
    if UISpecialFrames then tinsert(UISpecialFrames, name) end
    d:Hide()
    return d
end
