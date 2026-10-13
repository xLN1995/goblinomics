if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Insights/Sankey.lua
-- Cash flow as a Sankey diagram: three columns (sources |
-- characters & warband bank | expenses, warband bank, kept), one scale for all
-- columns so every band is exactly proportional to its amount. More than
-- MAX_BLOCKS entries per column become "Others (n)". Bands leave and enter a
-- block stacked in the order of the other side (no crossings at the block) and
-- are drawn as smooth S-curves from narrow stripes, each sheared (vertex offsets)
-- to follow the curve, so the edges run straight without steps. Hovering a block
-- highlights its bands and lists its flows.
local _, ns = ...

local Sankey = {}
ns.Sankey = Sankey

local API = ns.API
local L = ns.L

local MAX_BLOCKS = 7
local BLOCK_W = 12
local GAP = 10
local MIN_SLOT = 26        -- room for the two label lines of a small block
local LABEL_W = 150
local STRIPE = 4
local MAX_STRIPES = 50     -- per band
local ALPHA, ALPHA_ON, ALPHA_OFF = 0.35, 0.7, 0.08

Sankey.BLOCK_W, Sankey.LABEL_W = BLOCK_W, LABEL_W

local PALETTE = API.Theme.palette
local LOSS = API.Theme.colors.loss
local LOSS_SHADES = API.Theme.lossPalette

--- Keep the largest MAX_BLOCKS - 1 entries and bundle the rest; returns list, map label -> shown label.
local function Bundle(list, valueOf)
    local shown, map = {}, {}
    if #list <= MAX_BLOCKS then
        for i, e in ipairs(list) do shown[i] = e; map[e.label] = e.label end
        return shown, map
    end
    local sorted = {}
    for i, e in ipairs(list) do sorted[i] = e end
    table.sort(sorted, function(a, b) return valueOf(a) > valueOf(b) end)
    local others = { label = API.Lf("Others (%d)", #sorted - MAX_BLOCKS + 1), amount = 0, income = 0, outgo = 0, others = true }
    for i, e in ipairs(sorted) do
        if i < MAX_BLOCKS then
            shown[#shown + 1] = e
            map[e.label] = e.label
        else
            others.amount = others.amount + (e.amount or 0)
            others.income = others.income + (e.income or 0)
            others.outgo = others.outgo + (e.outgo or 0)
            map[e.label] = others.label
        end
    end
    shown[#shown + 1] = others
    return shown, map
end

--- Pure layout. flow = Data.Flow(); width/height of the drawing area.
-- Returns { height, columns = { { { label, value, share, x, y, height, color, links = {} } } },
--   bands = { { from, to, amount, x0, y0, x1, y1, thickness, color } }, empty }
-- y measured from the top; height may exceed the given height when small blocks need room.
function Sankey.Layout(flow, width, height)
    local function Amount(e) return e.amount end
    local function CharValue(e) return math.max(e.income, e.outgo) end
    local sources, srcMap = Bundle(flow.sources, Amount)
    local chars, charMap = Bundle(flow.chars, CharValue)
    local sinks, sinkMap = Bundle(flow.sinks, Amount)
    local cols = {
        { list = sources, value = Amount, map = srcMap },
        { list = chars, value = CharValue, map = charMap },
        { list = sinks, value = Amount, map = sinkMap },
    }
    local layout = { columns = {}, bands = {}, empty = #chars == 0 }
    -- one scale for all columns
    local k = math.huge
    for _, c in ipairs(cols) do
        local total = 0
        for _, e in ipairs(c.list) do total = total + c.value(e) end
        c.total = total
        if total > 0 then
            k = math.min(k, (height - GAP * math.max(0, #c.list - 1)) / total)
        end
    end
    if k == math.huge or k <= 0 then k = 0 end
    layout.scale = k
    local xs = { LABEL_W, (width - BLOCK_W) / 2, width - LABEL_W - BLOCK_W }
    local needed = 0
    local byLabel = {}
    for ci, c in ipairs(cols) do
        local blocks, used = {}, 0
        for i, e in ipairs(c.list) do
            local v = c.value(e)
            local h = v * k
            blocks[i] = { label = e.label, entry = e, value = v, share = c.total > 0 and v / c.total or 0,
                x = xs[ci], height = h, slot = math.max(h, MIN_SLOT), links = {}, column = ci,
                color = ci == 1 and (e.label == L["Warband bank"] and PALETTE[4] or PALETTE[(i - 1) % #PALETTE + 1])
                    or ci == 2 and PALETTE[3]
                    or (e.label == L["Kept"] and PALETTE[1] or e.label == L["Warband bank"] and PALETTE[4]
                        or LOSS_SHADES[(i - 1) % #LOSS_SHADES + 1] or LOSS) }
            used = used + blocks[i].slot + (i > 1 and GAP or 0)
            byLabel[ci .. "|" .. e.label] = blocks[i]
        end
        c.used = used
        c.blocks = blocks
        needed = math.max(needed, used)
    end
    layout.height = math.max(height, needed)
    for ci, c in ipairs(cols) do
        local y = (layout.height - c.used) / 2
        for _, b in ipairs(c.blocks) do
            b.y = y + (b.slot - b.height) / 2
            y = y + b.slot + GAP
        end
        layout.columns[ci] = c.blocks
    end
    -- links between neighbouring columns, labels mapped to the bundled blocks
    local merged = {}
    for _, l in ipairs(flow.links) do
        local fromCol = srcMap[l.from] and 1 or (charMap[l.from] and 2) or nil
        if fromCol then
            local from = fromCol == 1 and srcMap[l.from] or charMap[l.from]
            local toCol = fromCol + 1
            local to = toCol == 2 and charMap[l.to] or sinkMap[l.to]
            if to then
                local key = fromCol .. "|" .. from .. ">" .. to
                local m = merged[key]
                if not m then
                    m = { from = byLabel[fromCol .. "|" .. from], to = byLabel[toCol .. "|" .. to], amount = 0 }
                    merged[key] = m
                    layout.bands[#layout.bands + 1] = m
                end
                m.amount = m.amount + l.amount
            end
        end
    end
    -- stack bands at each block in the order of the other side
    table.sort(layout.bands, function(a, b)
        if a.from.column ~= b.from.column then return a.from.column < b.from.column end
        if a.from.y ~= b.from.y then return a.from.y < b.from.y end
        return a.to.y < b.to.y
    end)
    local outOffset, inOffset = {}, {}
    for _, band in ipairs(layout.bands) do
        band.thickness = band.amount * k
        band.x0 = band.from.x + BLOCK_W
        band.y0 = band.from.y + (outOffset[band.from] or 0)
        outOffset[band.from] = (outOffset[band.from] or 0) + band.thickness
        band.color = band.from.column == 1 and band.from.color or band.to.color
        band.from.links[#band.from.links + 1] = band
        band.to.links[#band.to.links + 1] = band
    end
    local byTarget = {}
    for _, band in ipairs(layout.bands) do byTarget[#byTarget + 1] = band end
    table.sort(byTarget, function(a, b)
        if a.to ~= b.to then return (a.to.column * 100000 + a.to.y) < (b.to.column * 100000 + b.to.y) end
        return a.from.y < b.from.y
    end)
    for _, band in ipairs(byTarget) do
        band.x1 = band.to.x
        band.y1 = band.to.y + (inOffset[band.to] or 0)
        inOffset[band.to] = (inOffset[band.to] or 0) + band.thickness
    end
    return layout
end

--- Stripes of one band: { { x, width, y, yEnd } } (top edge at the stripe's left and
-- right end, from the top); the curve is smoothstep from y0 to y1.
function Sankey.Stripes(band)
    local list = {}
    local dx = band.x1 - band.x0
    if dx <= 0 then return list end
    local function Top(x)
        local t = (x - band.x0) / dx
        return band.y0 + (band.y1 - band.y0) * t * t * (3 - 2 * t)
    end
    local step = math.max(STRIPE, math.ceil(dx / MAX_STRIPES))
    local x = band.x0
    while x < band.x1 do
        local w = math.min(step, band.x1 - x)
        list[#list + 1] = { x = x, width = w, y = Top(x), yEnd = Top(x + w) }
        x = x + w
    end
    return list
end

local function Money(copper)
    return API.Money.Format(math.floor((copper or 0) + 0.5), { abbreviate = true })
end

--- Sankey frame. :SetData(flow) lays out and draws; returns the needed height via .needed.
function Sankey.Create(parent, height)
    local Theme = API.Theme
    local C = Theme.colors
    local f = CreateFrame("Frame", nil, parent)
    local stripes, blocks, bandStripes = {}, {}, {}
    local usedStripes = 0
    local empty = API.Widgets.EmptyState(f, L["No bookings in this period."])

    local function Stripe()
        usedStripes = usedStripes + 1
        local t = stripes[usedStripes]
        if not t then
            t = Theme.Unsnap(f:CreateTexture(nil, "BORDER"))
            stripes[usedStripes] = t
        end
        t:Show()
        return t
    end

    local function Paint(band, alpha)
        local c = band.color
        for _, t in ipairs(bandStripes[band] or {}) do t:SetColorTexture(c[1], c[2], c[3], alpha) end
    end

    local function Highlight(block)
        for _, band in ipairs(f.layout and f.layout.bands or {}) do
            local on = block == nil or band.from == block or band.to == block
            Paint(band, block == nil and ALPHA or (on and ALPHA_ON or ALPHA_OFF))
        end
    end

    local function Block(i)
        local b = blocks[i]
        if b then return b end
        b = CreateFrame("Frame", nil, f)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetAllPoints()
        b.name = Theme.Text(f, 11, C.text)
        b.name:SetWordWrap(false)
        b.amount = Theme.Text(f, 10, C.textDim)
        b.amount:SetWordWrap(false)
        b.labelBg = f:CreateTexture(nil, "ARTWORK")
        b.labelBg:SetColorTexture(C.panel[1], C.panel[2], C.panel[3], 0.85)
        b:EnableMouse(true)
        b:SetScript("OnEnter", function(self)
            Highlight(self.block)
            local lines = { Money(self.block.value) .. "  (" .. API.Format:Percent(self.block.share) .. ")" }
            local links = {}
            for _, band in ipairs(self.block.links) do links[#links + 1] = band end
            table.sort(links, function(x, y) return x.amount > y.amount end)
            for n, band in ipairs(links) do
                if n > 10 then break end
                local incoming = band.to == self.block
                lines[#lines + 1] = (incoming and (L["From"] .. " " .. band.from.label) or (L["To"] .. " " .. band.to.label))
                    .. ": " .. Money(band.amount)
            end
            API.Widgets.ShowTooltip(self, self.block.label, lines)
        end)
        b:SetScript("OnLeave", function()
            Highlight(nil)
            API.Widgets.HideTooltip()
        end)
        blocks[i] = b
        return b
    end

    function f:SetData(flow)
        local width = (self.GetWidth and self:GetWidth()) or 0
        if not width or width <= 0 then width = 640 end
        local layout = Sankey.Layout(flow, width, height)
        self.layout = layout
        self.needed = layout.height
        usedStripes = 0
        wipe(bandStripes)
        for _, band in ipairs(layout.bands) do
            local list = {}
            for _, s in ipairs(Sankey.Stripes(band)) do
                local t = Stripe()
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", self, "TOPLEFT", s.x, -s.y)
                t:SetSize(s.width, math.max(1, band.thickness))
                -- shear the right edge down to the curve: no steps between stripes
                local drop = -(s.yEnd - s.y)
                t:SetVertexOffset(3, 0, drop)   -- upper right
                t:SetVertexOffset(4, 0, drop)   -- lower right
                list[#list + 1] = t
            end
            bandStripes[band] = list
            Paint(band, ALPHA)
        end
        for i = usedStripes + 1, #stripes do stripes[i]:Hide() end
        local n = 0
        for ci, column in ipairs(layout.columns) do
            for _, block in ipairs(column) do
                n = n + 1
                local b = Block(n)
                b.block = block
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", self, "TOPLEFT", block.x, -block.y)
                b:SetSize(BLOCK_W, math.max(2, block.height))
                b.tex:SetColorTexture(block.color[1], block.color[2], block.color[3], 0.9)
                b.name:SetText(block.label)
                b.amount:SetText(Money(block.value) .. "  " .. API.Format:Percent(block.share))
                b.name:ClearAllPoints()
                b.amount:ClearAllPoints()
                local mid = block.y + block.height / 2
                if ci == 1 then
                    b.name:SetPoint("BOTTOMRIGHT", self, "TOPLEFT", block.x - 6, -mid + 1)
                    b.amount:SetPoint("TOPRIGHT", self, "TOPLEFT", block.x - 6, -mid - 1)
                    b.name:SetJustifyH("RIGHT")
                    b.amount:SetJustifyH("RIGHT")
                elseif ci == 3 then
                    b.name:SetPoint("BOTTOMLEFT", self, "TOPLEFT", block.x + BLOCK_W + 6, -mid + 1)
                    b.amount:SetPoint("TOPLEFT", self, "TOPLEFT", block.x + BLOCK_W + 6, -mid - 1)
                    b.name:SetJustifyH("LEFT")
                    b.amount:SetJustifyH("LEFT")
                else
                    b.name:SetPoint("BOTTOMLEFT", self, "TOPLEFT", block.x + BLOCK_W + 6, -mid + 1)
                    b.amount:SetPoint("TOPLEFT", self, "TOPLEFT", block.x + BLOCK_W + 6, -mid - 1)
                    b.name:SetJustifyH("LEFT")
                    b.amount:SetJustifyH("LEFT")
                end
                b.name:SetWidth(LABEL_W - 12)
                b.amount:SetWidth(LABEL_W - 12)
                -- the middle column's labels sit on the bands: a panel-coloured backing keeps them readable
                b.labelBg:SetShown(ci == 2)
                if ci == 2 then
                    b.labelBg:ClearAllPoints()
                    b.labelBg:SetPoint("TOPLEFT", self, "TOPLEFT", block.x + BLOCK_W + 3, -mid + 14)
                    b.labelBg:SetSize(math.min(LABEL_W - 6, math.max(b.name:GetStringWidth() or 60,
                        b.amount:GetStringWidth() or 60) + 8), 28)
                end
                b:Show()
                b.name:Show()
                b.amount:Show()
            end
        end
        for i = n + 1, #blocks do
            blocks[i]:Hide()
            blocks[i].name:Hide()
            blocks[i].amount:Hide()
            blocks[i].labelBg:Hide()
        end
        empty:SetShown(layout.empty)
        self.flow = flow
    end
    f:SetScript("OnSizeChanged", function(self) if self.flow then self:SetData(self.flow) end end)
    return f
end
