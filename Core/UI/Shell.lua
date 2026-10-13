if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/UI/Shell.lua
-- Main window: header (Jealousmeter placeholder until M3), sidebar with the
-- registered tabs, content area, footer with the version and the changelog. Built on first open; a tab page is built on its
-- first selection. While the window is hidden it holds no bus subscriptions.
local _, ns = ...

local Shell = {}
ns.Shell = Shell
local UI, Theme, Widgets = ns.UI, ns.Theme, ns.Widgets
local C = Theme.colors
local L = ns.L
local OWNER = "Core.UI"

local WIDTH, HEIGHT = 900, 580
local HEADER_H, SIDEBAR_W, FOOTER_H = 56, 176, 22

local frame
local sideFrame
local BuildSidePanel   -- defined after Build (forward declaration)
local buttons = {}   -- tab id -> sidebar button
local pages = {}     -- tab id -> page frame
local current

local function CharWindow()
    local c = ns.coreDB and ns.coreDB.char
    return c and c.window
end

local function SavePosition()
    local w = CharWindow()
    if not w then return end
    local point, _, relPoint, x, y = frame:GetPoint(1)
    w.point, w.relPoint, w.x, w.y = point, relPoint, x, y
end

local function RestorePosition()
    frame:ClearAllPoints()
    local w = CharWindow()
    if w and w.point then
        frame:SetPoint(w.point, UIParent, w.relPoint or w.point, w.x or 0, w.y or 0)
    else
        frame:SetPoint("CENTER")
    end
end

local function UpdateGold()
    if not frame then return end
    local money = GetMoney()
    if issecretvalue and issecretvalue(money) then return end
    frame.gold:SetText(ns.Money.Format(money))
end

local function UpdateRestricted()
    if not frame then return end
    frame.banner:SetShown(ns.Restriction.IsActive())
end

local EnsureButton

local function LayoutSidebar()
    for _, b in pairs(buttons) do b:Hide() end
    local S = Theme.space
    local y, bottomY = -S.SM, S.SM
    local list = UI.SortedTabs()
    for _, spec in ipairs(list) do EnsureButton(spec) end
    for i = #list, 1, -1 do
        local spec = list[i]
        if spec.bottom then
            local b = buttons[spec.id]
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", frame.sidebar, "BOTTOMLEFT", 0, bottomY)
            b:SetPoint("RIGHT", frame.sidebar, "RIGHT", 0, 0)
            b:Show()
            bottomY = bottomY + S.NAV_STEP
        end
    end
    for i = 1, #list do
        local spec = list[i]
        if not spec.bottom then
            local b = buttons[spec.id]
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", frame.sidebar, "TOPLEFT", 0, y)
            b:SetPoint("RIGHT", frame.sidebar, "RIGHT", 0, 0)
            b:Show()
            y = y - S.NAV_STEP
        end
    end
end

EnsureButton = function(spec)
    local b = buttons[spec.id]
    if not b then
        b = Widgets.NavButton(frame.sidebar, UI.Title(spec), { onClick = function() Shell.Select(spec.id) end })
        buttons[spec.id] = b
    else
        b:SetText(UI.Title(spec))
    end
    return b
end

function Shell.Select(id)
    local spec = UI.GetTab(id)
    if not UI.IsActive(spec) or not frame then return end
    if not UI.EnsureTabLoaded(spec) then
        ns.Print(L["Cannot load this page in combat"], true)
        return
    end
    spec = UI.GetTab(id)
    if current and pages[current] then
        pages[current]:Hide()
        local old = UI.GetTab(current)
        if old and old.onHide then ns.SafeCall(old.onHide, pages[current]) end
    end
    for tabId, b in pairs(buttons) do b:SetSelected(tabId == id) end
    local page = pages[id]
    if not page then
        page = CreateFrame("Frame", nil, frame.content)
        page:SetAllPoints(frame.content)
        pages[id] = page
        if spec.build then ns.SafeCall(spec.build, page) end
    end
    page:Show()
    current = id
    if spec.onShow then ns.SafeCall(spec.onShow, page) end
    local c = ns.coreDB and ns.coreDB.char
    if c then c.lastTab = id end
end

local function Build()
    frame = CreateFrame("Frame", "GoblinomicsMainWindow", UIParent)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:Hide()
    Theme.Backdrop(frame, C.bg, C.border)
    tinsert(UISpecialFrames, "GoblinomicsMainWindow")

    -- Header (Jealousmeter placeholder)
    local header = CreateFrame("Frame", nil, frame)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT")
    header:SetHeight(HEADER_H)
    Theme.Fill(header, C.header)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() frame:StartMoving() end)
    header:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        SavePosition()
    end)
    local logo = CreateFrame("Frame", nil, header)
    logo:SetSize(40, 40)
    logo:SetPoint("LEFT", 10, 0)
    logo:EnableMouse(true)
    logo:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:SetText("Goblinomics", unpack(C.gold))
        GameTooltip:AddLine(L["Version"] .. " " .. Goblinomics.VERSION, unpack(C.textDim))
        UI.FillHeaderTooltip(GameTooltip)
        GameTooltip:Show()
    end)
    logo:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local icon = logo:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(Theme.LOGO)
    local title = Theme.Text(header, "page", C.accent)
    title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -3)
    title:SetText("Goblinomics")
    local tagline = Theme.Text(header, "small", C.textDim)
    tagline:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 10, 3)
    tagline:SetText(L["Track. Analyze. Profit. Make Gallywix Jealous."])
    local close = Widgets.IconButton(header, "close", { size = Theme.space.CONTROL_H, onClick = function() Shell.Hide() end })
    close:SetPoint("RIGHT", -Theme.space.PAD, 0)
    frame.gold = Theme.Text(header, "title", C.gold)
    frame.gold:SetPoint("RIGHT", close, "LEFT", -16, 0)
    frame.gold:SetJustifyH("RIGHT")

    -- Sidebar and content
    local sidebar = CreateFrame("Frame", nil, frame)
    sidebar:SetPoint("TOPLEFT", 0, -HEADER_H)
    sidebar:SetPoint("BOTTOMLEFT", 0, FOOTER_H)
    sidebar:SetWidth(SIDEBAR_W)
    Theme.Fill(sidebar, C.sidebar)
    frame.sidebar = sidebar
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", SIDEBAR_W + 16, -HEADER_H - 16)
    content:SetPoint("BOTTOMRIGHT", -16, FOOTER_H + 16)
    frame.content = content

    -- Footer: version left, changelog right
    local footer = CreateFrame("Frame", nil, frame)
    footer:SetPoint("BOTTOMLEFT")
    footer:SetPoint("BOTTOMRIGHT")
    footer:SetHeight(FOOTER_H)
    Theme.Fill(footer, C.header)
    local edge = footer:CreateTexture(nil, "BORDER")
    edge:SetColorTexture(unpack(C.border))
    edge:SetPoint("TOPLEFT")
    edge:SetPoint("TOPRIGHT")
    edge:SetHeight(1)
    frame.footer = footer
    local version = Goblinomics.VERSION
    footer.version = Theme.Text(footer, "small", C.textDim)
    footer.version:SetPoint("LEFT", Theme.space.PAD, 0)
    footer.version:SetText(version:match("^%d") and ("v" .. version) or version)
    local changelog = CreateFrame("Button", nil, footer)
    changelog:SetHeight(FOOTER_H)
    changelog:SetPoint("RIGHT", -Theme.space.PAD, 0)
    changelog.label = Theme.Text(changelog, "small", C.textDim)
    changelog.label:SetPoint("RIGHT")
    changelog.label:SetText(L["Changelog"])
    local labelW = changelog.label:GetStringWidth()
    changelog:SetWidth(type(labelW) == "number" and labelW > 0 and labelW + 4 or 80)
    changelog:SetScript("OnEnter", function(self) self.label:SetTextColor(unpack(C.accent)) end)
    changelog:SetScript("OnLeave", function(self) self.label:SetTextColor(unpack(C.textDim)) end)
    changelog:SetScript("OnClick", function() if ns.Changelog then ns.Changelog.Toggle() end end)
    footer.changelog = changelog

    -- Restricted banner
    local banner = CreateFrame("Frame", nil, frame)
    banner:SetPoint("TOPLEFT", SIDEBAR_W, -HEADER_H)
    banner:SetPoint("TOPRIGHT", 0, -HEADER_H)
    banner:SetHeight(20)
    banner:SetFrameLevel(content:GetFrameLevel() + 20)
    Theme.Fill(banner, C.warnBg)
    local bannerText = Theme.Text(banner, 11, C.text)
    bannerText:SetPoint("CENTER")
    bannerText:SetText(L["Updates paused (boss encounter or Mythic+)"])
    banner:Hide()
    frame.banner = banner

    frame:SetScript("OnShow", function()
        local side = UI.GetSidePanel()
        if sideFrame and side and side.onShow then ns.SafeCall(side.onShow, sideFrame) end
        UpdateGold()
        UpdateRestricted()
        ns.Bus.On("MONEY_DELTA", UpdateGold, OWNER)
        ns.Bus.On("RESTRICTED_ENTER", UpdateRestricted, OWNER)
        ns.Bus.On("RESTRICTED_LEAVE", UpdateRestricted, OWNER)
    end)
    frame:SetScript("OnHide", function()
        ns.Bus.OffAll(OWNER)
    end)

    local scale = ns.coreDB and ns.coreDB.settings.ui.scale or 1
    frame:SetScale(scale)
    RestorePosition()
    for _, spec in ipairs(UI.SortedTabs()) do EnsureButton(spec) end
    LayoutSidebar()
    BuildSidePanel()
end

BuildSidePanel = function()
    local spec = UI.GetSidePanel()
    if not spec or not frame or sideFrame then return end
    local width = spec.width or 110
    frame:SetWidth(WIDTH + width)
    sideFrame = CreateFrame("Frame", nil, frame)
    sideFrame:SetPoint("TOPRIGHT", 0, -HEADER_H)
    sideFrame:SetPoint("BOTTOMRIGHT", 0, FOOTER_H)
    sideFrame:SetWidth(width)
    Theme.Fill(sideFrame, C.sidebar)
    local edge = sideFrame:CreateTexture(nil, "BORDER")
    edge:SetColorTexture(unpack(C.border))
    edge:SetPoint("TOPLEFT")
    edge:SetPoint("BOTTOMLEFT")
    edge:SetWidth(1)
    frame.content:SetPoint("BOTTOMRIGHT", -16 - width, FOOTER_H + 16)
    frame.banner:SetPoint("TOPRIGHT", -width, -HEADER_H)
    if spec.build then ns.SafeCall(spec.build, sideFrame) end
    if frame:IsShown() and spec.onShow then ns.SafeCall(spec.onShow, sideFrame) end
end

function UI.OnSidePanelChanged()
    BuildSidePanel()
end

--- Side panel of a switched-off module: hidden, the content takes its place.
function UI.OnModuleSidePanel()
    if not frame or not sideFrame then
        if frame then BuildSidePanel() end
        return
    end
    local spec = UI.GetSidePanel()
    local width = spec and (spec.width or 110) or 0
    sideFrame:SetShown(spec ~= nil)
    frame:SetWidth(WIDTH + width)
    frame.content:SetPoint("BOTTOMRIGHT", -16 - width, FOOTER_H + 16)
    frame.banner:SetPoint("TOPRIGHT", -width, -HEADER_H)
end

--- Tabs of a switched-off module disappear; its open page falls back to the dashboard.
function UI.OnModuleTabs()
    if not frame then return end
    LayoutSidebar()
    if current and not UI.IsActive(UI.GetTab(current)) then Shell.Select("dashboard") end
end

function UI.OnTabsChanged(id)
    if not frame then return end
    EnsureButton(UI.GetTab(id))
    if pages[id] then
        -- the tab was replaced (e.g. a demand-loaded module filled its placeholder)
        pages[id]:Hide()
        pages[id] = nil
        if current == id then
            current = nil
            Shell.Select(id)
        end
    end
    LayoutSidebar()
end

function Shell.SetScale(scale)
    if frame then frame:SetScale(scale) end
end

function Shell.Show(tabId)
    if not frame then Build() end
    frame:Show()
    local c = ns.coreDB and ns.coreDB.char
    local target = tabId or current or (c and c.lastTab) or "dashboard"
    if not UI.IsActive(UI.GetTab(target)) then target = "dashboard" end
    if target ~= current or not tabId then
        Shell.Select(target)
    end
end

function Shell.Hide()
    if frame then frame:Hide() end
end

function Shell.IsShown()
    return frame ~= nil and frame:IsShown()
end

function Shell.Toggle(tabId)
    if Shell.IsShown() and (not tabId or tabId == current) then
        Shell.Hide()
    else
        Shell.Show(tabId)
    end
end

