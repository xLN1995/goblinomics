if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/Commands.lua
-- /gob farm start [name] | pause | resume | stop | hud | skip
-- hud switches the full-screen HUD for a farm with a route, else the small one.
local _, ns = ...

local Commands = {}
ns.Commands = Commands

local function Print(msg) ns.API.Print(msg, true) end

function Commands.Run(arg)
    local L = ns.L
    arg = strtrim(arg or "")
    local verb, rest = arg:match("^(%S*)%s*(.-)$")
    verb = (verb or ""):lower()
    local Session = ns.Session
    if verb == "start" then
        local farm
        if rest ~= "" then
            farm = ns.Farms.FindByName(rest)
            if not farm then
                Print(ns.API.Lf("No farm named %s.", rest))
                return
            end
        end
        if not Session.Start(farm and farm.id) then
            Print(L["A session is already active."])
            return
        end
        Print(ns.API.Lf("Session started: %s", farm and farm.name or L["Ad-hoc session"]))
    elseif verb == "pause" then
        if Session.IsRunning() then Session.Pause() else Session.Resume() end
    elseif verb == "resume" then
        Session.Resume()
    elseif verb == "stop" then
        if not Session.Active() then
            Print(L["No active session."])
            return
        end
        ns.HUD.StopAndSummarize()
    elseif verb == "instances" then
        for _, line in ipairs(ns.Instances.Report()) do Print(line) end
    elseif verb == "hud" then
        if not Session.Active() then
            Print(L["No active session."])
        elseif ns.FarmHUD.Toggle() then
            if ns.FarmHUD.Wanted() and not ns.FarmHUD.IsShown() then
                Print(L["The farm HUD shows up in the farm's zone, out of combat and outside instances."])
            end
        elseif ns.HUD.IsShown() then
            ns.HUD.HideForSession()
        else
            ns.HUD.ShowForSession()
        end
    elseif verb == "skip" then
        if not ns.FarmHUD.Skip() then Print(L["No route is being followed."]) end
    else
        Print("/gob farm start [" .. L["farm name"] .. "] | pause | resume | stop | hud | skip | instances")
    end
end

function Commands.Enable()
    ns.API.RegisterCommand("farm", Commands.Run, ns.L["start [name] | pause | resume | stop | hud | skip - farm sessions"])
end
