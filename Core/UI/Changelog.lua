if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/UI/Changelog.lua
-- "What's new" window: the release notes of Core/ChangelogData.lua, one block per
-- version (heading, intro, new modules with their install state, then the
-- sections as bullet points). It opens by itself once after an update (6 s after
-- the login, never in combat, restricted phases or over the setup wizard); the
-- footer of the main window and /gob changelog open it any time. Closing it
-- remembers the version; a fresh installation and dev builds skip the popup.
local _, ns = ...

local Changelog = {}
ns.Changelog = Changelog

local Theme, Widgets = ns.Theme, ns.Widgets
local C = Theme.colors
local L = ns.L

local WIDTH, HEIGHT = 560, 520
local DELAY = 6
local OWNER = "Core.Changelog"

local win

-- Versions -------------------------------------------------------------------------------
--- Numbers and suffix of "1.0.2" / "0.9.1-beta"; nil for "dev" and "unreleased".
local function Parse(v)
    if type(v) ~= "string" then return nil end
    local nums, suffix = v:match("^v?([%d%.]+)%-?(.*)$")
    if not nums then return nil end
    local parts = {}
    for n in nums:gmatch("%d+") do parts[#parts + 1] = tonumber(n) end
    return parts, suffix
end

--- -1, 0 or 1. "dev" and "unreleased" are newer than every release; a pre-release
-- ("1.1.0-beta") is older than its release.
function Changelog.CompareVersions(a, b)
    if a == b then return 0 end
    local pa, sa = Parse(a)
    local pb, sb = Parse(b)
    if not pa and not pb then return 0 end
    if not pa then return 1 end
    if not pb then return -1 end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    if sa == sb then return 0 end
    if sa == "" then return 1 end
    if sb == "" then return -1 end
    return sa < sb and -1 or 1
end

local function Entries() return ns.CHANGELOG or {} end

--- Entries newer than lastSeen up to the running version. Without lastSeen only
-- the entry of the running version (the first one in a dev build).
function Changelog.EntriesSince(lastSeen, current)
    current = current or Goblinomics.VERSION
    local list = {}
    for _, e in ipairs(Entries()) do
        local upToCurrent = Changelog.CompareVersions(e.version, current) <= 0
        if lastSeen then
            if upToCurrent and Changelog.CompareVersions(e.version, lastSeen) > 0 then list[#list + 1] = e end
        elseif upToCurrent then
            list[#list + 1] = e
            break
        end
    end
    return list
end

-- Seen state ------------------------------------------------------------------------------
local function Root() return ns.coreDB and ns.coreDB.root end

function Changelog.LastSeen()
    local root = Root()
    return root and type(root.changelog) == "table" and root.changelog.seen or nil
end

function Changelog.MarkSeen()
    local root = Root()
    if root then root.changelog = { seen = Goblinomics.VERSION } end
end

--- Whether the window opens by itself at this login. A fresh installation marks
-- the version as seen (the setup wizard introduces the addon instead).
function Changelog.ShouldAutoShow()
    local version = Goblinomics.VERSION
    if version == "dev" or not Root() then return false end
    if ns.Setup and ns.Setup.IsPending() then
        Changelog.MarkSeen()
        return false
    end
    if Changelog.LastSeen() == version then return false end
    return #Changelog.EntriesSince(Changelog.LastSeen()) > 0
end

-- Modules ---------------------------------------------------------------------------------
--- "active", "installed" (enabled, loads later), "disabled" or "missing".
function Changelog.AddonState(addon)
    local api = C_AddOns
    if not api then return "missing" end
    if api.IsAddOnLoaded and api.IsAddOnLoaded(addon) then return "active" end
    if api.GetAddOnInfo then
        local _, _, _, _, reason = api.GetAddOnInfo(addon)
        if reason == "MISSING" then return "missing" end
    end
    if api.GetAddOnEnableState and api.GetAddOnEnableState(addon, UnitName("player")) == 0 then
        return "disabled"
    end
    return "installed"
end

local STATE = {
    active = { text = function() return L["Active"] end, color = "accent" },
    installed = { text = function() return L["Installed"] end, color = "text" },
    disabled = { text = function() return L["Disabled"] end, color = "textDim" },
    missing = { text = function() return L["Not installed"] end, color = "gold" },
}

--- Display name from the folder: Goblinomics_Connector_TSM -> "TSM Connector".
function Changelog.ModuleTitle(addon)
    local connector = addon:match("^Goblinomics_Connector_(.+)$")
    if connector then return connector .. " Connector" end
    return (addon:gsub("^Goblinomics_", ""))
end

-- Window ----------------------------------------------------------------------------------
local function TextWidth()
    local S = Theme.space
    return WIDTH - 2 * S.DIALOG_PAD - S.GUTTER - S.XS
end

--- Lays out the entries in the scroll content and returns the height.
local function Render(content, entries, highlight)
    local S = Theme.space
    for _, child in ipairs(content.lines or {}) do child:Hide() end
    content.lines = {}
    local y, width = 0, TextWidth()
    local function Add(fs, x, gapAfter)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", x, -y)
        fs:SetWidth(width - x)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        content.lines[#content.lines + 1] = fs
        y = y + (fs:GetStringHeight() or 14) + (gapAfter or S.XS)
        return fs
    end
    local function Line(text, size, color, x, gapAfter)
        local fs = Theme.Text(content, size, color)
        fs:SetText(text)
        return Add(fs, x or 0, gapAfter)
    end

    for i, e in ipairs(entries) do
        local new = highlight[e] == true
        local text = new and C.text or C.textDim
        local version = e.version == "unreleased" and L["Next version"] or e.version
        Line(e.date and (version .. "  " .. Theme.CODE.dim .. e.date .. "|r") or version, "title",
            new and C.gold or C.textDim, 0, S.SM)
        if e.intro then Line(e.intro, "body", text, 0, S.SM) end
        if e.modules and #e.modules > 0 then
            Line(L["New modules"], "body", new and C.accent or C.textDim, 0, S.XS)
            for _, m in ipairs(e.modules) do
                local st = STATE[Changelog.AddonState(m.addon)]
                local state = Theme.Text(content, "small", C[st.color])
                state:SetText(st.text())
                state:SetPoint("TOPRIGHT", 0, -y)
                state:SetJustifyH("RIGHT")
                content.lines[#content.lines + 1] = state
                Line(Changelog.ModuleTitle(m.addon), "body", text, S.PAD, 2)
                if m.text then Line(m.text, "small", C.textDim, S.PAD, S.SM) end
            end
            y = y + S.XS
        end
        for _, section in ipairs(e.sections or {}) do
            Line(section.title, "body", new and C.accent or C.textDim, 0, S.XS)
            for _, item in ipairs(section.items) do
                local bullet = Theme.Text(content, "body", C.textDim)
                bullet:SetText("-")
                bullet:SetPoint("TOPLEFT", S.XS, -y)
                content.lines[#content.lines + 1] = bullet
                Line(item, "body", text, S.PAD, S.SM)
            end
            y = y + S.XS
        end
        if i < #entries then
            local rule = content:CreateTexture(nil, "BORDER")
            rule:SetColorTexture(unpack(C.border))
            rule:SetHeight(1)
            rule:SetPoint("TOPLEFT", 0, -y)
            rule:SetPoint("RIGHT", content, "RIGHT", 0, 0)
            content.lines[#content.lines + 1] = rule
            y = y + S.PAD
        end
    end
    return y
end

--- "What's new in Goblinomics 1.1.0" with the running version; dev builds without one.
function Changelog.Title(version)
    version = version or Goblinomics.VERSION
    if type(version) == "string" and version:match("^v?%d") then
        return ns.Lf("What's new in Goblinomics %s", (version:gsub("^v", "")))
    end
    return L["What's new in Goblinomics"]
end

local function Build()
    local S = Theme.space
    win = Widgets.Dialog({ name = "GoblinomicsChangelogWindow", title = Changelog.Title(),
        width = WIDTH, height = HEIGHT,
        buttons = { { text = L["Close"], primary = true, onClick = function()
            Changelog.MarkSeen()
            win:Hide()
        end } },
        onClose = function()
            if not win.aborted then Changelog.MarkSeen() end
            win.aborted = false
            ns.UIEvents:Unregister("PLAYER_REGEN_DISABLED", OWNER)
        end })
    local logo = win.header:CreateTexture(nil, "ARTWORK")
    logo:SetSize(24, 24)
    logo:SetPoint("LEFT", S.DIALOG_PAD, 0)
    logo:SetTexture(Theme.LOGO)
    win.title:ClearAllPoints()
    win.title:SetPoint("LEFT", logo, "RIGHT", S.SM, 0)
    win.title:SetPoint("RIGHT", -40, 0)
    win.panel = Widgets.ScrollPanel(win.body)
    win.panel.box:SetPoint("TOPLEFT")
    win.panel.box:SetPoint("BOTTOMRIGHT", -S.GUTTER, 0)
end

--- Open the window. Without `all` only what is new since the last seen version
-- (or the running version's entry); with `all` every entry, the new ones on top
-- in full colour.
function Changelog.Show(all)
    if InCombatLockdown() then
        ns.Print(L["Cannot open the changelog in combat."], true)
        return false
    end
    if not win then Build() end
    local fresh = Changelog.EntriesSince(Changelog.LastSeen())
    -- nothing new: the running version's entry counts as the new one
    if #fresh == 0 then fresh = Changelog.EntriesSince(nil) end
    local key = (all and "all:" or "new:") .. tostring(Changelog.LastSeen())
    if win.rendered ~= key then
        local highlight = {}
        for _, e in ipairs(fresh) do highlight[e] = true end
        win.panel:Update(Render(win.panel.content, all and Entries() or fresh, highlight))
        win.rendered = key
    end
    if win.panel.box.ScrollToBegin then win.panel.box:ScrollToBegin() end
    win:Show()
    -- combat closes the window; the version stays unseen
    ns.UIEvents:Register("PLAYER_REGEN_DISABLED", function()
        win.aborted = true
        win:Hide()
    end, OWNER)
    return true
end

function Changelog.IsShown() return win ~= nil and win:IsShown() end
Changelog.window = function() return win end

function Changelog.Toggle()
    if Changelog.IsShown() then win:Hide() else Changelog.Show(true) end
end

-- After an update --------------------------------------------------------------------------
local function TryAutoShow()
    if not Changelog.ShouldAutoShow() then return end
    if InCombatLockdown() or (ns.Restriction and ns.Restriction.IsActive())
        or (ns.Setup and ns.Setup.IsShown()) then
        ns.Timer.After(10, TryAutoShow, OWNER)
        return
    end
    Changelog.Show(false)
end

--- Called at PLAYER_LOGIN (Bootstrap), after the setup wizard had its turn.
function Changelog.OnLogin()
    if Changelog.ShouldAutoShow() then ns.Timer.After(DELAY, TryAutoShow, OWNER) end
end

ns.API.UI.ShowChangelog = function() return Changelog.Show(true) end
