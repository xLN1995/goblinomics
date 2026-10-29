-- busted helper: runs once before the specs (see .busted).
package.path = "./?.lua;./?/init.lua;" .. package.path

WoWMock = require("spec.support.wow_mock")

--- Load an addon file the way the WoW client does: the chunk receives
-- (addonName, privateNamespace) as its vararg.
function load_addon_file(path, addonName, ns)
    local chunk, err = loadfile(path)
    assert(chunk, err)
    return chunk(addonName or "Goblinomics", ns or {})
end

-- Libraries the specs never need (UI-only or loaded once by the mock).
local SKIP_LIBS = {
    ["Libs/LibStub/LibStub.lua"] = true,
    ["Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua"] = true,
    ["Libs/LibDataBroker-1.1/LibDataBroker-1.1.lua"] = true,
    ["Libs/LibDBIcon-1.0/LibDBIcon-1.0.lua"] = true,
    ["Libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua"] = true,
    ["Libs/LibDeflate/LibDeflate.lua"] = true,
    ["Libs/LibSerialize/LibSerialize.lua"] = true,
}

--- Lua files of a TOC in load order (paths with forward slashes).
function toc_files(tocPath, baseDir)
    local files = {}
    for line in io.lines(tocPath) do
        line = line:gsub("\r", "")
        if line ~= "" and not line:match("^#") and line:match("%.lua$") then
            files[#files + 1] = (baseDir or "") .. line:gsub("\\", "/")
        end
    end
    return files
end

--- Reset the mock and load the whole core in TOC order with one shared namespace.
-- opts.boot = true also fires ADDON_LOADED("Goblinomics"); opts.login = true fires PLAYER_LOGIN too.
-- opts.money sets the character's money before login (the baseline is taken at login).
function load_core(opts)
    opts = opts or {}
    WoWMock.reset()
    if opts.money then WoWMock.set_money(opts.money) end
    if opts.db then _G.GoblinomicsDB = opts.db end
    local ns = {}
    for _, file in ipairs(toc_files("Goblinomics.toc")) do
        if not SKIP_LIBS[file] then
            load_addon_file(file, "Goblinomics", ns)
        end
    end
    if opts.boot or opts.login then
        WoWMock.fire("ADDON_LOADED", "Goblinomics")
    end
    if opts.login then
        WoWMock.loggedIn = true
        WoWMock.fire("PLAYER_LOGIN")
    end
    return ns
end

--- Boot the core plus the Vault module (shared Vault namespace returned as vns).
function load_vault(opts)
    opts = opts or {}
    local ns = load_core({ boot = true, money = opts.money or 1 })
    if opts.before then opts.before(ns) end
    local vns = {}
    for _, file in ipairs(toc_files("Modules/Vault/Goblinomics_Vault.toc", "Modules/Vault/")) do
        load_addon_file(file, "Goblinomics_Vault", vns)
    end
    WoWMock.fire("ADDON_LOADED", "Goblinomics_Vault")
    if opts.login ~= false then
        WoWMock.loggedIn = true
        WoWMock.fire("PLAYER_LOGIN")
    end
    return ns, vns
end

--- Boot the core plus the Ledger module (shared Ledger namespace returned as lns).
function load_ledger(opts)
    opts = opts or {}
    local ns = load_core({ boot = true, money = opts.money or 100000 })
    if opts.before then opts.before(ns) end
    local lns = {}
    for _, file in ipairs(toc_files("Modules/Ledger/Goblinomics_Ledger.toc", "Modules/Ledger/")) do
        load_addon_file(file, "Goblinomics_Ledger", lns)
    end
    WoWMock.fire("ADDON_LOADED", "Goblinomics_Ledger")
    if opts.login ~= false then
        WoWMock.loggedIn = true
        WoWMock.fire("PLAYER_LOGIN")
    end
    return ns, lns
end

--- Boot the core plus Ledger and Flips (namespaces returned as lns, fns).
-- opts.before(ns, lns) runs after the Ledger is loaded, before Flips.
function load_flips(opts)
    opts = opts or {}
    local ns = load_core({ boot = true, money = opts.money or 100000 })
    local lns = {}
    for _, file in ipairs(toc_files("Modules/Ledger/Goblinomics_Ledger.toc", "Modules/Ledger/")) do
        load_addon_file(file, "Goblinomics_Ledger", lns)
    end
    WoWMock.fire("ADDON_LOADED", "Goblinomics_Ledger")
    if opts.before then opts.before(ns, lns) end
    local fns = {}
    for _, file in ipairs(toc_files("Modules/Flips/Goblinomics_Flips.toc", "Modules/Flips/")) do
        load_addon_file(file, "Goblinomics_Flips", fns)
    end
    WoWMock.fire("ADDON_LOADED", "Goblinomics_Flips")
    WoWMock.loggedIn = true
    WoWMock.fire("PLAYER_LOGIN")
    return ns, fns, lns
end

--- Boot the core plus the Gatherer module (shared Gatherer namespace returned as pns).
function load_gatherer(opts)
    opts = opts or {}
    local ns = load_core({ boot = true, money = opts.money or 100000 })
    if opts.before then opts.before(ns) end
    local pns = {}
    for _, file in ipairs(toc_files("Modules/Gatherer/Goblinomics_Gatherer.toc", "Modules/Gatherer/")) do
        load_addon_file(file, "Goblinomics_Gatherer", pns)
    end
    WoWMock.fire("ADDON_LOADED", "Goblinomics_Gatherer")
    if opts.login ~= false then
        WoWMock.loggedIn = true
        WoWMock.fire("PLAYER_LOGIN")
    end
    WoWMock.flush()
    return ns, pns
end

--- Boot the core, optionally the Ledger (opts.ledger), and the Workshop.
-- Returns core ns, workshop ns, ledger ns (or nil).
function load_workshop(opts)
    opts = opts or {}
    local ns = load_core({ boot = true, money = opts.money or 100000 })
    if opts.before then opts.before(ns) end
    local lns
    if opts.ledger then
        lns = {}
        for _, file in ipairs(toc_files("Modules/Ledger/Goblinomics_Ledger.toc", "Modules/Ledger/")) do
            load_addon_file(file, "Goblinomics_Ledger", lns)
        end
        WoWMock.fire("ADDON_LOADED", "Goblinomics_Ledger")
    end
    local wns = {}
    for _, file in ipairs(toc_files("Modules/Workshop/Goblinomics_Workshop.toc", "Modules/Workshop/")) do
        load_addon_file(file, "Goblinomics_Workshop", wns)
    end
    WoWMock.fire("ADDON_LOADED", "Goblinomics_Workshop")
    WoWMock.loggedIn = true
    WoWMock.fire("PLAYER_LOGIN")
    WoWMock.flush()
    return ns, wns, lns
end

--- Boot core, Vault, Ledger (and optionally Workshop/Gatherer), then load the
-- load-on-demand Insights addon. Returns core ns, insights ns, { vault, ledger }.
function load_insights(opts)
    opts = opts or {}
    local ns = load_core({ boot = true, money = opts.money or 1000000 })
    WoWMock.lod.Goblinomics_Insights = true
    local mods = {}
    for _, m in ipairs({ { "Modules/Vault/Goblinomics_Vault.toc", "Modules/Vault/", "Goblinomics_Vault", "vault" },
        { "Modules/Ledger/Goblinomics_Ledger.toc", "Modules/Ledger/", "Goblinomics_Ledger", "ledger" } }) do
        local mns = {}
        for _, file in ipairs(toc_files(m[1], m[2])) do load_addon_file(file, m[3], mns) end
        WoWMock.fire("ADDON_LOADED", m[3])
        mods[m[4]] = mns
    end
    WoWMock.loggedIn = true
    WoWMock.fire("PLAYER_LOGIN")
    WoWMock.flush()
    local ins = {}
    for _, file in ipairs(toc_files("Modules/Insights/Goblinomics_Insights.toc", "Modules/Insights/")) do
        load_addon_file(file, "Goblinomics_Insights", ins)
    end
    WoWMock.fire("ADDON_LOADED", "Goblinomics_Insights")
    WoWMock.flush()
    return ns, ins, mods
end

--- Boot core, Ledger and Workshop, then load the load-on-demand Import addon
-- (M8). opts.before(ns) runs before the modules load (fixtures, characters).
-- Returns core ns, import ns, { ledger, workshop }.
function load_import(opts)
    opts = opts or {}
    local ns = load_core({ boot = true, money = opts.money or 100000 })
    if opts.before then opts.before(ns) end
    WoWMock.lod.Goblinomics_Import = true
    local mods = {}
    for _, m in ipairs({ { "Modules/Ledger/Goblinomics_Ledger.toc", "Modules/Ledger/", "Goblinomics_Ledger", "ledger" },
        { "Modules/Workshop/Goblinomics_Workshop.toc", "Modules/Workshop/", "Goblinomics_Workshop", "workshop" } }) do
        local mns = {}
        for _, file in ipairs(toc_files(m[1], m[2])) do load_addon_file(file, m[3], mns) end
        WoWMock.fire("ADDON_LOADED", m[3])
        mods[m[4]] = mns
    end
    WoWMock.loggedIn = true
    WoWMock.fire("PLAYER_LOGIN")
    WoWMock.flush()
    local ins = {}
    for _, file in ipairs(toc_files("Modules/Import/Goblinomics_Import.toc", "Modules/Import/")) do
        load_addon_file(file, "Goblinomics_Import", ins)
    end
    WoWMock.fire("ADDON_LOADED", "Goblinomics_Import")
    WoWMock.flush()
    return ns, ins, mods
end

--- Boot core and Vault, then load the load-on-demand Link addon (M8).
-- Returns core ns, link ns, vault ns.
function load_link(opts)
    opts = opts or {}
    local ns = load_core({ boot = true, money = opts.money or 100000 })
    if opts.before then opts.before(ns) end
    WoWMock.lod.Goblinomics_Link = true
    local vns = {}
    for _, file in ipairs(toc_files("Modules/Vault/Goblinomics_Vault.toc", "Modules/Vault/")) do
        load_addon_file(file, "Goblinomics_Vault", vns)
    end
    WoWMock.fire("ADDON_LOADED", "Goblinomics_Vault")
    WoWMock.loggedIn = true
    WoWMock.fire("PLAYER_LOGIN")
    WoWMock.flush()
    local lns = {}
    for _, file in ipairs(toc_files("Modules/Link/Goblinomics_Link.toc", "Modules/Link/")) do
        load_addon_file(file, "Goblinomics_Link", lns)
    end
    WoWMock.fire("ADDON_LOADED", "Goblinomics_Link")
    WoWMock.flush()
    return ns, lns, vns
end
