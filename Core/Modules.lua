if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/Modules.lua
-- Module registry and lifecycle (API v1).
--
--   registered --ADDON_LOADED--> initialized --PLAYER_LOGIN--> enabled <--> disabled
--
-- RegisterModule runs in the module's main chunk and creates its event dispatcher
-- there (CPU attribution). OnInit runs at the module's ADDON_LOADED after its DB
-- namespace and migrations; OnEnable at PLAYER_LOGIN, or one tick later for
-- modules loaded after login (demand-loaded addons can be dispatched from secure
-- code). Disabling runs OnDisable and removes the module's events, bus
-- subscriptions, timers and jobs. All callbacks run through ns.SafeCall.
local _, ns = ...

local Modules = {}
ns.Modules = Modules
local API = ns.API

local registry = {}
local order = {}
local loggedIn = false

local Module = {}
Module.__index = Module

local function DefaultEnabled(id)
    local m = registry[id]
    return not (m and m.spec.defaultEnabled == false)
end

local function IsEnabledSetting(id)
    local db = ns.coreDB
    local cfg = db and db.settings.modules[id]
    if cfg and cfg.enabled ~= nil then
        return cfg.enabled
    end
    return DefaultEnabled(id)
end

function API.RegisterModule(id, spec)
    if type(id) ~= "string" or id == "" then
        error("Goblinomics.API.v1.RegisterModule: id must be a non-empty string", 2)
    end
    if type(spec) ~= "table" then
        error("Goblinomics.API.v1.RegisterModule: spec must be a table", 2)
    end
    if spec.apiVersion ~= ns.API_VERSION then
        error(("Goblinomics.API.v1.RegisterModule: module %q requires API version %s, core provides %d")
            :format(id, tostring(spec.apiVersion), ns.API_VERSION), 2)
    end
    if registry[id] then
        error(("Goblinomics.API.v1.RegisterModule: module %q is already registered"):format(id), 2)
    end
    local m = setmetatable({
        id = id,
        name = spec.name or id,
        order = spec.order or 100,
        addon = spec.addon or id,
        internal = spec.internal == true,
        spec = spec,
        state = "registered",
        OnInit = spec.OnInit,
        OnEnable = spec.OnEnable,
        OnDisable = spec.OnDisable,
        OnLogout = spec.OnLogout,
    }, Module)
    m.events = ns.Events.NewDispatcher(id)
    registry[id] = m
    order[#order + 1] = id
    return m
end

function API.GetModules()
    local result = {}
    for i = 1, #order do
        result[i] = order[i]
    end
    return result
end

function API.GetModule(id)
    return registry[id]
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------
local function Init(m)
    local dbSpec = m.spec.db
    if dbSpec then
        m.db = ns.DB:Namespace(m.id, dbSpec.sv, dbSpec)
        if not m.db.ok then
            m.state = "failed"
            m.error = m.db.error
            ns.Print(("%s: %s"):format(m.name, tostring(m.db.error)), true)
            return
        end
    end
    m.state = "initialized"
    if m.OnInit then
        ns.SafeCall(m.OnInit, m)
    end
end

local function Enable(m)
    if m.state ~= "initialized" and m.state ~= "disabled" then
        return
    end
    if not IsEnabledSetting(m.id) then
        m.state = "disabled"
        return
    end
    if m.db then
        m.db:BindChar(ns.CharKey())
    end
    m.state = "enabled"
    if m.OnEnable then
        -- UI registrations during OnEnable belong to this module (UI.IsActive)
        local previous = Modules.current
        Modules.current = m.id
        ns.SafeCall(m.OnEnable, m)
        Modules.current = previous
    end
end

local function Disable(m)
    if m.state ~= "enabled" then
        return
    end
    if m.OnDisable then
        ns.SafeCall(m.OnDisable, m)
    end
    m.events:UnregisterAll()
    ns.Bus.OffAll(m.id)
    ns.Timer.CancelOwner(m.id)
    ns.Jobs.CancelOwner(m.id)
    m.state = "disabled"
end

function Modules.OnAddonLoaded(addonName)
    for i = 1, #order do
        local m = registry[order[i]]
        if m.state == "registered" and m.addon == addonName then
            Init(m)
            if loggedIn and m.state == "initialized" then
                ns.Timer.After(0, function() Enable(m) end, "Modules")
            end
        end
    end
end

function Modules.OnLogin()
    loggedIn = true
    for i = 1, #order do
        Enable(registry[order[i]])
    end
end

function Modules.OnLogout()
    for i = 1, #order do
        local m = registry[order[i]]
        if m.state == "enabled" and m.OnLogout then
            ns.SafeCall(m.OnLogout, m)
        end
    end
end

--- Enable or disable a module persistently; applies immediately.
function Modules.SetEnabled(id, enabled)
    local m = registry[id]
    local modules = ns.coreDB.settings.modules
    if enabled == DefaultEnabled(id) then
        modules[id] = nil
    else
        modules[id] = { enabled = enabled }
    end
    if m then
        if enabled then Enable(m) else Disable(m) end
    end
    if ns.UI and ns.UI.ModuleStateChanged then ns.UI.ModuleStateChanged(id, enabled) end
    ns.Bus.Emit("MODULE_STATE_CHANGED", { id = id, enabled = enabled })
end

function Modules.IsEnabled(id)
    return IsEnabledSetting(id)
end

function Modules.List()
    local result = {}
    for i = 1, #order do
        result[i] = registry[order[i]]
    end
    table.sort(result, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    return result
end

-------------------------------------------------------------------------------
-- Module methods
-------------------------------------------------------------------------------
function Module:IsEnabled()
    return self.state == "enabled"
end

--- Register a WoW event while the module is enabled. handler: function(event, ...)
-- or the name of a method (called as self:method(event, ...)). key (default: the
-- event) lets several parts of a module handle the same event.
function Module:RegisterEvent(event, handler, key)
    if self.state ~= "enabled" then
        error(("module %q: RegisterEvent only while enabled (in OnEnable or later)"):format(self.id), 2)
    end
    local fn = handler or event
    if type(fn) == "string" then
        local name = fn
        fn = function(e, ...) return self[name](self, e, ...) end
    end
    self.events:Unregister(event, key or event)
    return self.events:Register(event, fn, key or event)
end

function Module:UnregisterEvent(event, key)
    self.events:Unregister(event, key or event)
end

function Module:On(event, fn)
    ns.Bus.On(event, fn, self.id)
end

function Module:Off(event)
    ns.Bus.Off(event, self.id)
end

function Module:After(sec, fn)
    ns.Timer.After(sec, fn, self.id)
end

function Module:RunJob(name, fn, onDone)
    ns.Jobs.Run(self.id, name, fn, onDone)
end
