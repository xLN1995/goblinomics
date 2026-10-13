if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/UI/Theme.lua
-- Flat-dark look in the EllesmereUI style: solid colour textures, 1 px borders,
-- goblin green as accent, gold for values, red only for losses. Font objects are
-- created on first use. Design tokens: Theme.space for every
-- distance and height, Theme.SIZE for the type scale (roles), colours only from
-- Theme.colors / Theme.palette; Theme.Hex and Theme.Colorize for text colours.
local ADDON_NAME, ns = ...

local Theme = {}
ns.Theme = Theme

Theme.MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"
Theme.WHITE = "Interface\\Buttons\\WHITE8X8"
Theme.ICON = Theme.MEDIA .. "goblinomics_icon_64"    -- coin logo, small (64 px)
Theme.LOGO = Theme.MEDIA .. "goblinomics_logo_128"   -- coin logo, detailed (128 px)
-- white shapes with smooth alpha edges (tools/make_hud_media.py), tinted where used
Theme.DOT = Theme.MEDIA .. "hud_dot"       -- filled circle, 64 px (the circle fills 7/8 of it)
Theme.RING = Theme.MEDIA .. "hud_ring"     -- thin circle outline, 512 px
Theme.STROKE = Theme.MEDIA .. "hud_line"   -- line profile fading out at both edges

Theme.colors = {
    bg = { 0.05, 0.07, 0.09, 0.97 },
    header = { 0.07, 0.09, 0.11, 1 },
    sidebar = { 0.06, 0.08, 0.10, 1 },
    panel = { 0.08, 0.10, 0.12, 1 },
    border = { 1, 1, 1, 0.08 },
    borderHover = { 1, 1, 1, 0.28 },
    text = { 0.92, 0.92, 0.92, 1 },
    textDim = { 0.58, 0.60, 0.62, 1 },
    accent = { 0.247, 0.749, 0.247, 1 },
    accentSoft = { 0.247, 0.749, 0.247, 0.16 },
    gold = { 1, 0.82, 0, 1 },
    loss = { 0.851, 0.275, 0.243, 1 },   -- #d9463e
    button = { 0.07, 0.10, 0.12, 0.9 },
    buttonHover = { 0.10, 0.14, 0.17, 1 },
    track = { 0.27, 0.27, 0.27, 0.65 },
    dimmer = { 0, 0, 0, 0.45 },
    -- spacing and layout additions
    lossSoft = { 0.85, 0.27, 0.24, 0.18 },
    hover = { 1, 1, 1, 0.05 },
    zebra = { 1, 1, 1, 0.03 },
    trackSoft = { 1, 1, 1, 0.05 },
    neutral = { 0.55, 0.58, 0.62, 1 },
    teal = { 0.20, 0.70, 0.70, 1 },
    blue = { 0.35, 0.55, 0.95, 1 },
    purple = { 0.65, 0.45, 0.90, 1 },
    orange = { 0.95, 0.60, 0.20, 1 },
    pink = { 0.90, 0.40, 0.60, 1 },
    brass = { 0.973, 0.769, 0.4, 1 },
    brassDark = { 0.89, 0.604, 0.251, 1 },
    diamond = { 0.6, 0.85, 1, 1 },
    overlay = { 0.05, 0.07, 0.09, 0.9 },
    warnBg = { 0.35, 0.25, 0.05, 0.9 },
}
local C = Theme.colors
C.gain = C.accent

--- Categorical palette (Sankey, wealth parts, chart series) and a red one for losses.
Theme.palette = { C.accent, C.teal, C.gold, C.blue, C.purple, C.orange, C.pink, C.neutral }
Theme.lossPalette = { { 0.85, 0.27, 0.24, 1 }, { 0.80, 0.40, 0.22, 1 }, { 0.70, 0.22, 0.35, 1 },
    { 0.90, 0.50, 0.40, 1 }, { 0.65, 0.30, 0.20, 1 }, { 0.75, 0.35, 0.50, 1 }, { 0.60, 0.25, 0.28, 1 }, C.neutral }

--- Distances and heights shared by every page, card, list and dialog.
Theme.space = {
    XS = 4, SM = 6, GAP = 10, PAD = 12, DIALOG_PAD = 16,
    CARD_TITLE_Y = -10, CARD_BODY_Y = -28,
    TOOLBAR_H = 24, CONTENT_TOP = -32,
    MASTER_W = 250, MASTER_GAP = 16, GUTTER = 14,
    ROW_S = 18, ROW = 22, ROW_L = 32, HEADER_H = 18,
    CONTROL_H = 24, SMALL_H = 20, NAV_H = 28, NAV_STEP = 30, DIALOG_BTN_W = 140,
    DROP_S = 100, DROP_M = 140, DROP_L = 180,
}

--- Type scale by role; Theme.Text takes a role name or one of these sizes.
Theme.SIZE = { micro = 9, caption = 10, small = 11, body = 12, title = 14, page = 16, value = 18, hero = 24 }

local hexCache = {}
--- "rrggbb" of a colour table.
function Theme.Hex(c)
    local hex = hexCache[c]
    if not hex then
        hex = ("%02x%02x%02x"):format(math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5),
            math.floor(c[3] * 255 + 0.5))
        hexCache[c] = hex
    end
    return hex
end

-- money colours follow the theme (Money.lua loads earlier and keeps plain defaults)
if ns.Money then
    ns.Money.GAIN_COLOR, ns.Money.LOSS_COLOR = Theme.Hex(C.accent), Theme.Hex(C.loss)
end

--- Colour escape codes for text in the theme colours ("|cffrrggbb"; end with "|r").
Theme.CODE = {
    dim = "|cff" .. Theme.Hex(C.textDim), good = "|cff" .. Theme.Hex(C.accent),
    bad = "|cff" .. Theme.Hex(C.loss), gold = "|cff" .. Theme.Hex(C.gold),
}

--- Text in a colour for font strings with escape sequences.
function Theme.Colorize(text, c)
    return "|cff" .. Theme.Hex(c) .. tostring(text) .. "|r"
end

local fonts = {}

--- Font object for a size and optional flags ("OUTLINE").
function Theme.Font(size, flags)
    local key = size .. (flags or "")
    local font = fonts[key]
    if not font then
        font = CreateFont("GoblinomicsFont" .. key:gsub("%W", ""))
        font:SetFont(STANDARD_TEXT_FONT, size, flags or "")
        font:SetShadowOffset(1, -1)
        font:SetShadowColor(0, 0, 0, 0.8)
        fonts[key] = font
    end
    return font
end

function Theme.Text(parent, size, color, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFontObject(Theme.Font(Theme.SIZE[size] or size))
    fs:SetTextColor(unpack(color or Theme.colors.text))
    fs:SetJustifyH("LEFT")
    return fs
end

function Theme.Fill(frame, color, layer)
    local t = frame:CreateTexture(nil, layer or "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(unpack(color))
    return t
end

local function OnePixel(region, horizontal)
    if PixelUtil then
        if horizontal then PixelUtil.SetHeight(region, 1, 1) else PixelUtil.SetWidth(region, 1, 1) end
    elseif horizontal then
        region:SetHeight(1)
    else
        region:SetWidth(1)
    end
end

--- 1 px border from four textures. Returns an object with :SetColor(r, g, b, a).
function Theme.Border(frame, color)
    local edges = {}
    local specs = {
        { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
        { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false },
    }
    for i = 1, 4 do
        local t = frame:CreateTexture(nil, "BORDER")
        t:SetColorTexture(unpack(color or Theme.colors.border))
        t:SetPoint(specs[i][1])
        t:SetPoint(specs[i][2])
        OnePixel(t, specs[i][3])
        edges[i] = t
    end
    return {
        SetColor = function(_, r, g, b, a)
            for i = 1, 4 do edges[i]:SetColorTexture(r, g, b, a) end
        end,
    }
end

--- Solid background plus 1 px border.
function Theme.Backdrop(frame, bg, border)
    local fill = Theme.Fill(frame, bg or Theme.colors.panel)
    local edge = Theme.Border(frame, border)
    return fill, edge
end

-- Smooth shapes ----------------------------------------------------------------------------------
-- Diagonal lines and round dots look stepped when drawn as solid colour and snapped
-- to the pixel grid. These give them soft edges and sub-pixel placement; frames,
-- fills and borders stay pixel-exact on purpose.

--- Place a texture or line between pixels instead of snapping it to them.
function Theme.Unsnap(region)
    if region.SetSnapToPixelGrid then region:SetSnapToPixelGrid(false) end
    if region.SetTexelSnappingBias then region:SetTexelSnappingBias(0) end
    return region
end

--- A line with soft edges; colour it with Theme.Tint. The stroke fades out at its
-- edges, so it needs about 1.5x the thickness of a solid line.
function Theme.SmoothLine(line)
    line:SetTexture(Theme.STROKE)
    return Theme.Unsnap(line)
end

--- A round dot with a soft edge; colour it with Theme.Tint.
function Theme.SmoothDot(texture)
    texture:SetTexture(Theme.DOT)
    return Theme.Unsnap(texture)
end

--- Colour a smooth shape: c = { r, g, b, a }, alpha overrides c's alpha.
function Theme.Tint(region, c, alpha)
    region:SetVertexColor(c[1], c[2], c[3], alpha or c[4] or 1)
end

ns.API.Theme = Theme
