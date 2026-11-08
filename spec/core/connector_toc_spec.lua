-- Connectors must not declare their partner addon as a hard dependency: without it the
-- client warns "Failed to load missing dependency" at every login. The partner addon is
-- an optional dependency (load order), and the connector itself checks for it.
local CONNECTORS = {
    { toc = "Connectors/TSM/Goblinomics_Connector_TSM.toc", partner = "TradeSkillMaster" },
    { toc = "Connectors/Auctionator/Goblinomics_Connector_Auctionator.toc", partner = "Auctionator" },
    { toc = "Connectors/CraftSim/Goblinomics_Connector_CraftSim.toc", partner = "CraftSim" },
    { toc = "Connectors/GatherMate2/Goblinomics_Connector_GatherMate2.toc", partner = "GatherMate2" },
}

local function header(path, key)
    for line in io.lines(path) do
        local value = line:match("^## " .. key .. ":%s*(.-)%s*$")
        if value then return value end
    end
    return nil
end

describe("Connector TOCs", function()
    for _, c in ipairs(CONNECTORS) do
        it(c.partner .. " connector depends on the core only and loads after " .. c.partner, function()
            assert.equals("Goblinomics", header(c.toc, "Dependencies"))
            local optional = header(c.toc, "OptionalDeps") or ""
            assert.is_truthy(optional:find(c.partner, 1, true), "OptionalDeps lacks " .. c.partner)
        end)
    end
end)
