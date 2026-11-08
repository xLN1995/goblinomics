-- Core/ClientGate.lua
-- Client failsafe. MUST stay the FIRST file in the core TOC.
--
-- Goblinomics runs on WoW Midnight (12.1+) and on WoW: Forever, which shares the
-- Mainline API (interface 16xxx, project "Camelot"). On any older client every
-- other file of the suite returns at its first line, so no SavedVariables are read
-- or written and a downgrade restores the addon with settings untouched.
--
-- Fail-open by design: if the interface number cannot be read, the suite runs
-- normally. On a supported client this file is a few comparisons and exits; no
-- globals, no frames. Core/Flavor.lua repeats the Forever check for the modules.

local iface = select(4, GetBuildInfo())
if type(iface) ~= "number" then return end
-- the nil guard matters: on an old client both project globals are nil
local forever = (WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT)
    or (iface >= 16000 and iface < 20000)
if forever or iface >= 120100 then return end

GOBLINOMICS_CLIENT_BLOCKED = true

local notice = CreateFrame("Frame")
notice:RegisterEvent("PLAYER_LOGIN")
notice:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    print("|cff3fbf3fGoblinomics|r: this version requires World of Warcraft 12.1 or newer, or WoW: Forever. The addon stays disabled.")
end)
