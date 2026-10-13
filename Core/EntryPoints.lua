if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/EntryPoints.lua
-- Slash commands, LDB feed, minimap button (LibDBIcon), addon compartment and key
-- binding labels. Slash work runs one tick later (a BN whisper edit box can carry
-- a secret tellTarget). The LDB feed and the minimap button are created at
-- PLAYER_LOGIN; the minimap button is the only UI that exists before first open.
local _, ns = ...

local EntryPoints = {}
ns.EntryPoints = EntryPoints
local L = ns.L

-------------------------------------------------------------------------------
-- Status
-------------------------------------------------------------------------------
function EntryPoints.PrintStatus()
    ns.Print(L["Version"] .. " " .. Goblinomics.VERSION, true)
    local list = ns.Modules.List()
    local names = {}
    for i = 1, #list do
        local m = list[i]
        if not m.internal then
            names[#names + 1] = m.name .. (m.state == "enabled" and "" or " (" .. m.state .. ")")
        end
    end
    if #names == 0 then
        ns.Print(L["No modules registered"], true)
    else
        ns.Print(L["Registered modules"] .. " (" .. #names .. "): " .. table.concat(names, ", "), true)
    end
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------
local commands = {}
EntryPoints.commands = commands
local moduleHelp = {}

--- Modules add slash subcommands: API.RegisterCommand("jealous", fn(arg), "<gold> - ...").
function ns.API.RegisterCommand(name, fn, help)
    name = name:lower()
    if commands[name] and not moduleHelp[name] then
        error(("Goblinomics: /gob %s is a core command"):format(name), 2)
    end
    commands[name] = fn
    moduleHelp[name] = help or ""
end

function commands.status() EntryPoints.PrintStatus() end

function commands.help()
    ns.Print("/gob - " .. L["Open or close the main window"], true)
    ns.Print("/gob status - " .. L["Version and modules"], true)
    ns.Print("/gob perf [reset] - " .. L["Performance report"], true)
    ns.Print("/gob price <item link> - " .. L["Prices and valuation of an item"], true)
    ns.Print("/gob import - " .. L["Import history from TSM and Journalator"], true)
    ns.Print("/gob setup - " .. L["Open the setup wizard"], true)
    ns.Print("/gob changelog - " .. L["What's new in Goblinomics"], true)
    for name, help in pairs(moduleHelp) do
        ns.Print("/gob " .. name .. " " .. help, true)
    end
    ns.Print("/gob debug [on|off] - " .. L["Print core events to chat"], true)
end

function commands.debug(arg)
    arg = arg:lower()
    local on
    if arg == "on" then
        on = true
    elseif arg == "off" then
        on = false
    else
        on = not ns.Modules.IsEnabled(ns.DEBUG_MODULE)
    end
    ns.Modules.SetEnabled(ns.DEBUG_MODULE, on)
    ns.Print(on and L["Debug output on"] or L["Debug output off"], true)
end

function commands.import() ns.UI.Show("settings") end

function commands.setup() if ns.Setup then ns.Setup.Show() end end

function commands.changelog() if ns.Changelog then ns.Changelog.Show(true) end end

function commands.perf(arg)
    if ns.PerfReport then
        ns.PerfReport(arg:lower())
    end
end

local function FormatRole(role, value)
    if role == "saleRate" then
        return ("%.3f"):format(value)
    end
    return ns.Money.Format(value)
end

--- /gob price <item link>: prices per role and the valuation as tradable and bound item.
function commands.price(arg)
    local key = ns.ItemKey.FromLink(arg)
    if not key then
        ns.Print(L["Usage: /gob price <item link>"], true)
        return
    end
    ns.Print(arg .. " |cff999999" .. key .. "|r", true)
    for _, role in ipairs({ "market", "destroy", "saleRate", "vendor" }) do
        local value, source, pending = ns.Price.Get(key, role)
        local text
        if value then
            text = FormatRole(role, value) .. " |cff999999(" .. source .. ")|r"
        elseif pending then
            text = L["loading item data, try again"]
        else
            text = "|cff999999-|r"
        end
        ns.Print("  " .. role .. ": " .. text, true)
    end
    for _, bound in ipairs({ false, true }) do
        local r = ns.Value.Evaluate(key, { bound = bound })
        local gaps = {}
        for role in pairs(r.gaps) do gaps[#gaps + 1] = role end
        table.sort(gaps)
        ns.Print(("  %s: %s, %s = %s%s"):format(
            bound and L["bound"] or L["tradable"], r.rule, r.tier, ns.Money.Format(r.unit),
            #gaps > 0 and (" |cff999999[" .. L["gaps"] .. ": " .. table.concat(gaps, ", ") .. "]|r") or ""), true)
    end
end

function EntryPoints.Toggle()
    ns.UI.Toggle()
end

function EntryPoints.HandleSlash(msg)
    msg = strtrim(msg or "")
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()   -- arguments keep their case (item links)
    local fn = commands[cmd]
    if cmd == "" then
        EntryPoints.Toggle()
    elseif fn then
        fn(arg)
    else
        commands.help()
    end
end

SLASH_GOBLINOMICS1 = "/gob"
SLASH_GOBLINOMICS2 = "/goblinomics"
SlashCmdList.GOBLINOMICS = function(msg)
    C_Timer.After(0, function() EntryPoints.HandleSlash(msg) end)
end

-------------------------------------------------------------------------------
-- Key binding labels (Bindings.xml in the addon root is loaded by the client).
-- Set at file scope, translated once the locale is active.
-------------------------------------------------------------------------------
BINDING_CATEGORY_GOBLINOMICS = "Goblinomics"
BINDING_HEADER_GOBLINOMICS = "Goblinomics"
BINDING_NAME_GOBLINOMICS_TOGGLE = "Open or close the main window"
BINDING_NAME_GOBLINOMICS_FARM_HUD = "Farm HUD on or off"
BINDING_NAME_GOBLINOMICS_FARM_SKIP = "Farm HUD: skip the next stop"

-------------------------------------------------------------------------------
-- LDB feed and minimap button
-------------------------------------------------------------------------------
local LDB_NAME = "Goblinomics"
local ldb

local function WarbandMoney()
    local tracked = ns.MoneyTracker and ns.MoneyTracker.GetWarband()
    if tracked then return tracked end
    if C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType
        and (not C_PlayerInfo or not C_PlayerInfo.HasAccountInventoryLock or C_PlayerInfo.HasAccountInventoryLock()) then
        return C_Bank.FetchDepositedMoney(Enum.BankType.Account)
    end
end

local function IsPlain(v)
    return v ~= nil and not (issecretvalue and issecretvalue(v))
end

function EntryPoints.FillTooltip(tt)
    tt:AddLine("Goblinomics", 0.247, 0.749, 0.247)
    local money = GetMoney()
    if IsPlain(money) then
        tt:AddDoubleLine(L["Character"], ns.Money.Format(money), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    local warband = WarbandMoney()
    if IsPlain(warband) then
        tt:AddDoubleLine(L["Warband bank"], ns.Money.Format(warband), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    ns.UI.FillTooltipProviders(tt)
    tt:AddLine(" ")
    tt:AddLine(L["Left-click: open or close"], 0.6, 0.6, 0.6)
    tt:AddLine(L["Right-click: settings"], 0.6, 0.6, 0.6)
end

function EntryPoints.OnClick(mouseButton)
    if mouseButton == "RightButton" then
        ns.UI.Show("settings")
    else
        EntryPoints.Toggle()
    end
end

function EntryPoints.RefreshText()
    if not ldb then return end
    local money = GetMoney()
    if IsPlain(money) then
        ldb.text = ns.Money.Format(money, { abbreviate = true })
    end
end

local function CreateFeed()
    local broker = LibStub("LibDataBroker-1.1", true)
    if not broker or ldb then return end
    ldb = broker:NewDataObject(LDB_NAME, {
        type = "data source",
        label = "Goblinomics",
        text = "Goblinomics",
        icon = ns.Theme.ICON,
        OnClick = function(_, mouseButton) EntryPoints.OnClick(mouseButton) end,
        OnTooltipShow = function(tt) EntryPoints.FillTooltip(tt) end,
    })
    EntryPoints.ldb = ldb
    EntryPoints.RefreshText()
    ns.Bus.On("MONEY_DELTA", function(_, payload)
        if payload.scope == "player" then EntryPoints.RefreshText() end
    end, "Core.LDB")
    -- GetMoney() can read 0 right after login; refresh once the client settled.
    ns.Timer.After(3, EntryPoints.RefreshText, "Core.LDB")
end

local function RegisterMinimap()
    local icon = LibStub("LibDBIcon-1.0", true)
    if not icon or not ldb or icon:IsRegistered(LDB_NAME) then return end
    icon:Register(LDB_NAME, ldb, ns.coreDB.settings.minimap)
end

function EntryPoints.SetMinimapShown(shown)
    local settings = ns.coreDB.settings
    settings.minimap.hide = not shown
    local icon = LibStub("LibDBIcon-1.0", true)
    if not icon then return end
    if shown then icon:Show(LDB_NAME) else icon:Hide(LDB_NAME) end
end

-------------------------------------------------------------------------------
-- Addon compartment (TOC: AddonCompartmentFunc / FuncOnEnter / FuncOnLeave)
-------------------------------------------------------------------------------
function Goblinomics_OnAddonCompartmentClick(_, mouseButton)
    EntryPoints.OnClick(mouseButton)
end

function Goblinomics_OnAddonCompartmentEnter(_, button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    EntryPoints.FillTooltip(GameTooltip)
    GameTooltip:Show()
end

function Goblinomics_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end

-------------------------------------------------------------------------------
-- Lifecycle hooks called by Bootstrap
-------------------------------------------------------------------------------
function EntryPoints.OnCoreLoaded()
    BINDING_NAME_GOBLINOMICS_TOGGLE = L["Open or close the main window"]
    BINDING_NAME_GOBLINOMICS_FARM_HUD = L["Farm HUD on or off"]
    BINDING_NAME_GOBLINOMICS_FARM_SKIP = L["Farm HUD: skip the next stop"]
end

function EntryPoints.OnLogin()
    CreateFeed()
    RegisterMinimap()
    if ns.RegisterBlizzardOptions then
        ns.RegisterBlizzardOptions()
    end
end
