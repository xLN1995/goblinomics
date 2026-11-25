if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Ledger/Rules.lua
-- Mail rules: { field = "subject" | "sender", pattern, mode = "wildcard" | "lua",
-- category, tag, enabled }. Wildcards (* any text, ? one character) match the whole
-- field case-insensitively; Lua patterns are the expert mode and are validated with
-- pcall. The first enabled rule that matches wins.
local _, ns = ...

local Rules = {}
ns.Rules = Rules

local cache = {}   -- rule -> compiled pattern (weak by rule table)
setmetatable(cache, { __mode = "k" })

function Rules.WildcardToPattern(text)
    local escaped = text:lower():gsub("[%(%)%.%%%+%-%[%]%^%$]", "%%%0")
    escaped = escaped:gsub("%*", ".*"):gsub("%?", ".")
    return "^" .. escaped .. "$"
end

--- pattern or nil, errorMessage
function Rules.Compile(rule)
    if type(rule) ~= "table" or type(rule.pattern) ~= "string" or rule.pattern == "" then
        return nil, "empty pattern"
    end
    if rule.mode == "lua" then
        local ok, err = pcall(string.find, "", rule.pattern)
        if not ok then return nil, tostring(err) end
        return rule.pattern
    end
    return Rules.WildcardToPattern(rule.pattern)
end

local function Compiled(rule)
    local c = cache[rule]
    if c == nil or c.pattern ~= rule.pattern or c.mode ~= rule.mode then
        local pattern = Rules.Compile(rule)
        c = { pattern = pattern or false, source = rule.pattern, mode = rule.mode }
        c.pattern, c.pattern_ = pattern or false, nil
        cache[rule] = c
    end
    return c.pattern
end

--- First enabled rule matching the mail, or nil.
function Rules.MatchMail(rules, sender, subject)
    for i = 1, #(rules or {}) do
        local rule = rules[i]
        if rule.enabled ~= false then
            local pattern = Compiled(rule)
            local value = rule.field == "sender" and sender or subject
            if pattern and type(value) == "string" then
                local subjectValue = rule.mode == "lua" and value or value:lower()
                local ok, found = pcall(string.find, subjectValue, pattern)
                if ok and found then return rule end
            end
        end
    end
    return nil
end

--- Normalised name for own-character checks ("Name" or "Name-Realm" -> "Name-Realm").
function Rules.NormalizeName(name, defaultRealm)
    if type(name) ~= "string" or name == "" then return nil end
    if not name:find("-", 1, true) then
        name = name .. "-" .. (defaultRealm or "")
    end
    return name:gsub("%s", "")
end

--- True when name belongs to a known character of this account.
function Rules.IsOwnCharacter(name)
    -- region-wide unique names (WoW: Forever): a shard realm suffix carries no identity
    if type(name) == "string" and ns.API.RegionalNames() then name = name:match("^([^%-]+)") end
    local full = Rules.NormalizeName(name, ns.API.RealmKey())
    if not full then return false end
    for _, key in ipairs(ns.API.KnownCharacters()) do
        if key == full then return true end
    end
    return false
end
