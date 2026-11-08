if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/Util/Money.lua
-- Money formatting. Amounts are integers in copper (signed).
--   Money.Format(copper)                        -> "12g 34s 56c" with coin icons
--   Money.Format(copper, { icons = false })      -> "12g 34s 56c" with coloured letters
--   Money.Format(copper, { abbreviate = true })  -> "1.43M g" / "12.3K g" / "950g"
--   Money.Format(copper, { abbreviate = true, silver = true }) -> "950g 12s" (whole gold keeps
--       its silver; the default on WoW: Forever, where silver still counts)
--   Money.Format(copper, { color = true })       -> green for gains, red for losses
-- Pure Lua apart from the optional BreakUpLargeNumbers. Covered by spec/core/money_spec.lua.
local _, ns = ...

local Money = {}
ns.Money = Money
ns.API.Money = Money

local floor, abs = math.floor, math.abs

Money.COPPER_PER_SILVER = 100
Money.COPPER_PER_GOLD = 10000

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"
local GOLD_LETTER = "|cffffd100g|r"
local SILVER_LETTER = "|cffc7c7cfs|r"
local COPPER_LETTER = "|cffeda55fc|r"

Money.GAIN_COLOR = "3fbf3f"
Money.LOSS_COLOR = "d9463e"

local function Group(n)
    if BreakUpLargeNumbers then
        return BreakUpLargeNumbers(n)
    end
    local s = tostring(n)
    local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (result:gsub("^,", ""))
end
Money.Group = Group

--- gold, silver, copper of a non-negative copper amount.
function Money.Split(copper)
    copper = floor(abs(copper))
    return floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
end

-- decimal separator of the language (Format.lua), so "12,3K" never reads like "12.300"
local function Decimal(text)
    local sep = ns.L and ns.L["."] or "."
    if sep ~= "." then return (text:gsub("%.", sep)) end
    return text
end

local function Abbreviate(gold)
    if gold >= 1000000 then
        return Decimal(("%.2fM"):format(gold / 1000000))
    elseif gold >= 10000 then
        return Decimal(("%.1fK"):format(gold / 1000))
    end
    return Group(gold)
end

function Money.Format(copper, opts)
    if type(copper) ~= "number" then
        return "?"
    end
    opts = opts or {}
    local icons = opts.icons ~= false
    local g, s, c = Money.Split(copper)
    local gI = icons and GOLD_ICON or GOLD_LETTER
    local text
    if opts.abbreviate then
        local silver = opts.silver
        if silver == nil then silver = ns.Flavor ~= nil and ns.Flavor.IsForever() end
        text = Abbreviate(g) .. (icons and gI or " " .. gI)
        if silver and g > 0 and g < 10000 and s > 0 then
            text = text .. " " .. s .. (icons and SILVER_ICON or SILVER_LETTER)
        end
        if g == 0 then
            text = s .. (icons and SILVER_ICON or SILVER_LETTER)
        end
    else
        local parts = {}
        if g > 0 then
            parts[#parts + 1] = Group(g) .. gI
        end
        if s > 0 or (g > 0 and c > 0) then
            parts[#parts + 1] = s .. (icons and SILVER_ICON or SILVER_LETTER)
        end
        if c > 0 or #parts == 0 then
            parts[#parts + 1] = c .. (icons and COPPER_ICON or COPPER_LETTER)
        end
        text = table.concat(parts, " ")
    end
    if copper < 0 then
        text = "-" .. text
    elseif opts.sign and copper > 0 then
        text = "+" .. text
    end
    if opts.color and copper ~= 0 then
        text = "|cff" .. (copper > 0 and Money.GAIN_COLOR or Money.LOSS_COLOR) .. text .. "|r"
    end
    return text
end
