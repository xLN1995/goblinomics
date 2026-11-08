if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/Flavor.lua
-- Which client runs the suite, detected once at load:
--   "retail"   WoW Midnight 12.1+
--   "forever"  WoW: Forever (interface 16xxx, project "Camelot"): the Mainline API,
--              but no expansions, no crafting orders, no concentration, no warband
--              bank and a Classic-sized economy (an epic mount costs 1,000 g)
-- The core reads ns.Flavor, the modules API.Flavor. The check is the same as in
-- Core/ClientGate.lua, which must stay standalone.
local _, ns = ...

local Flavor = {}
ns.Flavor = Flavor
ns.API.Flavor = Flavor

local function Detect()
    if WOW_PROJECT_CAMELOT ~= nil and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT then return "forever" end
    local iface = select(4, GetBuildInfo())
    if type(iface) == "number" and iface >= 16000 and iface < 20000 then return "forever" end
    return "retail"
end

Flavor.id = Detect()

function Flavor.IsForever() return Flavor.id == "forever" end
function Flavor.IsRetail() return Flavor.id == "retail" end
