require "ItemRarity/RarityUtils"

-- Read-only Literature tier simulation.  It deliberately does not mutate
-- scanner results, FinalRarityTier, registry data, or active configurations.
ItemRarityLiteratureFinalSimulation = ItemRarityLiteratureFinalSimulation or {}

local function call(o, method)
    if not o then return nil end
    local ok, f = pcall(function() return o[method] end)
    if not ok or type(f) ~= "function" then return nil end
    local worked, value = pcall(function() return f(o) end)
    return worked and value or nil
end

local function value(o, getter, field)
    local v = getter and call(o, getter) or nil
    if v == nil and field then
        local ok, direct = pcall(function() return o and o[field] end)
        if ok then v = direct end
    end
    return v
end

local function text(v)
    local s = tostring(v or "")
    local low = string.lower(s)
    return (s == "" or low == "nil" or low == "null" or low == "[]") and "" or s
end

local function number(v) return tonumber(v) end
local function lower(v) return string.lower(text(v)) end
local function nonempty(v) return text(v) ~= "" end
local function contains(v, needle) return string.find(lower(v), string.lower(needle), 1, true) ~= nil end
local function fmt(v) return v == nil and "N/A" or string.format("%.2f", tonumber(v) or 0) end

local function scriptFor(fullType)
    local manager = getScriptManager and getScriptManager() or nil
    return manager and manager:FindItem(fullType) or nil
end

local function instanceFor(script)
    if not script then return nil end
    local ok, item = pcall(function() return script:InstanceItem(nil, false) end)
    return ok and item or nil
end

local function field(script, item, getter, scriptField, itemGetter)
    return value(script, getter, scriptField) or value(item, itemGetter or getter, scriptField)
end

local function mood(v) return tonumber(v) or 0 end

local function specialReason(r)
    if nonempty(r.map) or r.itemType == "base:map" then return "MAP" end
    if nonempty(r.recipes) then return "LEARNED_RECIPES" end
    if nonempty(r.onRead) then return "ON_READ" end
    if nonempty(r.doubleClickRecipe) then return "DOUBLE_CLICK_RECIPE" end
    -- Ordinary books may carry base:hollowbook because they can become a
    -- Hollow Book.  The finished special item is structurally a container.
    if r.itemType == "base:container" then return "HOLLOW_OR_CONTAINER_SPECIAL" end
    if r.displayCategory == "reciperesource" then return "RECIPE_RESOURCE" end
    return nil
end

local function classify(r)
    if nonempty(r.skill) or (r.level and r.level >= 0) then return "SKILLBOOK" end
    if specialReason(r) then return "SPECIAL_PARTIAL" end
    if r.unhappy < 0 or r.boredom < 0 or r.stress < 0 then return "ENTERTAINMENT_LITERATURE" end
    return "TRIVIAL_LITERATURE"
end

local function structuralTierPosition(rows)
    local bySkill = {}
    for _, r in ipairs(rows) do
        if r.group == "SKILLBOOK" then
            bySkill[r.skill] = bySkill[r.skill] or {}
            table.insert(bySkill[r.skill], r)
        end
    end
    for _, list in pairs(bySkill) do
        table.sort(list, function(a, b) return (a.level or -1) < (b.level or -1) end)
        for position, r in ipairs(list) do r.position = position end
    end
end

local function scarcityTier(data)
    return tostring(data.baseScarcityTier or data.rarityTier or "COMMON")
end

local function tierFromPosition(position)
    return ({ [1] = "COMMON", [2] = "UNCOMMON", [3] = "RARE", [4] = "EPIC", [5] = "EXOTIC" })[position] or "COMMON"
end

-- Simple bounded average of independently capped positive reading effects.
-- It is not an active Utility formula.  The threshold creates COMMON,
-- UNCOMMON and RARE only; RARE is the explicit entertainment ceiling.
local function entertainmentScore(r)
    local unhappy = math.min(1, math.max(0, -r.unhappy) / 40)
    local boredom = math.min(1, math.max(0, -r.boredom) / 50)
    local stress = math.min(1, math.max(0, -r.stress) / 50)
    return (unhappy + boredom + stress) / 3 * 100, unhappy * 100, boredom * 100, stress * 100
end

local function entertainmentTier(score)
    if score >= 60 then return "RARE" end
    if score >= 25 then return "UNCOMMON" end
    return "COMMON"
end

local function orderedKeys(t)
    local keys = {}; for k in pairs(t) do table.insert(keys, k) end; table.sort(keys); return keys
end

local function countTiers(rows, key)
    local counts = { COMMON = 0, UNCOMMON = 0, RARE = 0, EPIC = 0, EXOTIC = 0 }
    for _, row in ipairs(rows) do counts[row[key]] = (counts[row[key]] or 0) + 1 end
    return counts
end

local function printCounts(writer, counts)
    writer:write(string.format("COMMON=%d | UNCOMMON=%d | RARE=%d | EPIC=%d | EXOTIC=%d\n", counts.COMMON, counts.UNCOMMON, counts.RARE, counts.EPIC, counts.EXOTIC))
end

function ItemRarityLiteratureFinalSimulation.write(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local rows = {}
    for _, data in pairs(results) do
        if data.category == "LITERATURE" then
            local script = scriptFor(data.fullType)
            local item = instanceFor(script)
            if script then
                local r = {
                    data = data,
                    skill = text(field(script, item, "getSkillTrained", "skillTrained")),
                    level = number(field(script, item, "getLvlSkillTrained", "lvlSkillTrained")),
                    itemType = lower(field(script, item, "getItemType", "itemType") or field(script, item, "getType", "type")),
                    displayCategory = lower(field(script, item, "getDisplayCategory", "displayCategory")),
                    tags = text(field(script, item, "getTags", "tags")),
                    recipes = text(field(script, item, "getLearnedRecipes", "learnedRecipes")),
                    map = text(field(script, item, "getMapID", "map") or field(script, item, "getMap", "map")),
                    onRead = text(field(script, item, "getOnRead", "onRead")),
                    doubleClickRecipe = text(field(script, item, "getDoubleClickRecipe", "doubleClickRecipe")),
                    unhappy = mood(field(script, item, "getUnhappyChange", "unhappyChange")),
                    boredom = mood(field(script, item, "getBoredomChange", "boredomChange")),
                    stress = mood(field(script, item, "getStressChange", "stressChange")),
                }
                r.group = classify(r)
                r.specialReason = specialReason(r)
                r.scarcityTier = scarcityTier(data)
                table.insert(rows, r)
            end
        end
    end
    table.sort(rows, function(a, b) return a.data.fullType < b.data.fullType end)
    structuralTierPosition(rows)
    local groups = { SKILLBOOK = {}, ENTERTAINMENT_LITERATURE = {}, TRIVIAL_LITERATURE = {}, SPECIAL_PARTIAL = {} }
    for _, r in ipairs(rows) do
        if r.group == "SKILLBOOK" then r.simulatedTier = tierFromPosition(r.position)
        elseif r.group == "ENTERTAINMENT_LITERATURE" then
            r.entertainmentScore, r.unhappyComponent, r.boredomComponent, r.stressComponent = entertainmentScore(r)
            r.simulatedTier = entertainmentTier(r.entertainmentScore)
        elseif r.group == "TRIVIAL_LITERATURE" then r.simulatedTier = "COMMON"
        end
        table.insert(groups[r.group], r)
    end
    local writer = getFileWriter("ItemRarity_LiteratureFinalSimulation.txt", true, false)
    if not writer then return nil end
    writer:write("Item Rarity Literature final simulation (READ ONLY; active tiers/registry unchanged)\n")
    writer:write("SKILLBOOK: position only (T1 COMMON, T2 UNCOMMON, T3 RARE, T4 EPIC, T5 EXOTIC); Scarcity is reported only.\n")
    writer:write("ENTERTAINMENT: bounded average of independently capped positive mood reductions; <25 COMMON, 25..59.99 UNCOMMON, >=60 RARE; RARE ceiling.\n")
    writer:write("TRIVIAL: always COMMON, independent of Scarcity. SPECIAL_PARTIAL is excluded and untouched.\n\n")

    writer:write("SKILLBOOK POSITION / SCARCITY DISTRIBUTION\n")
    writer:write("position | simulated tier | books | Scarcity C/U/R/E/X\n")
    for position = 1, 5 do
        local subset = {}
        for _, r in ipairs(groups.SKILLBOOK) do if r.position == position then table.insert(subset, r) end end
        local scarcity = { COMMON = 0, UNCOMMON = 0, RARE = 0, EPIC = 0, EXOTIC = 0 }
        for _, r in ipairs(subset) do scarcity[r.scarcityTier] = (scarcity[r.scarcityTier] or 0) + 1 end
        writer:write(string.format("TIER_%d | %s | %d | %d/%d/%d/%d/%d\n", position, tierFromPosition(position), #subset, scarcity.COMMON, scarcity.UNCOMMON, scarcity.RARE, scarcity.EPIC, scarcity.EXOTIC))
    end
    writer:write("\nSKILLBOOK DETAIL\n")
    writer:write("fullType | SkillTrained | level range start | structural position | ScarcityTier | simulated tier | active FinalTier\n")
    for _, r in ipairs(groups.SKILLBOOK) do writer:write(string.format("%s | %s | %s | TIER_%d | %s | %s | %s\n", r.data.fullType, r.skill, fmt(r.level), r.position or 0, r.scarcityTier, r.simulatedTier, tostring(r.data.finalRarityTier))) end

    writer:write("\nENTERTAINMENT BENEFIT PROFILES\n")
    writer:write("fullType | Unhappy | Boredom | Stress | normalized components U/B/S | simple benefit | ScarcityTier | simulated tier | active FinalTier\n")
    for _, r in ipairs(groups.ENTERTAINMENT_LITERATURE) do
        writer:write(string.format("%s | %s | %s | %s | %s/%s/%s | %s | %s | %s | %s\n", r.data.fullType, fmt(r.unhappy), fmt(r.boredom), fmt(r.stress), fmt(r.unhappyComponent), fmt(r.boredomComponent), fmt(r.stressComponent), fmt(r.entertainmentScore), r.scarcityTier, r.simulatedTier, tostring(r.data.finalRarityTier)))
    end
    writer:write("ENTERTAINMENT simulated distribution: "); printCounts(writer, countTiers(groups.ENTERTAINMENT_LITERATURE, "simulatedTier"))

    writer:write("\nTRIVIAL LITERATURE\n")
    writer:write("fullType | ScarcityTier | simulated tier (always COMMON) | active FinalTier\n")
    for _, r in ipairs(groups.TRIVIAL_LITERATURE) do writer:write(string.format("%s | %s | COMMON | %s\n", r.data.fullType, r.scarcityTier, tostring(r.data.finalRarityTier))) end
    writer:write("TRIVIAL simulated distribution: "); printCounts(writer, countTiers(groups.TRIVIAL_LITERATURE, "simulatedTier"))

    writer:write("\nACTIVE LITERATURE V1 DISTRIBUTIONS\n")
    for _, groupName in ipairs({ "SKILLBOOK", "ENTERTAINMENT_LITERATURE", "TRIVIAL_LITERATURE" }) do
        local active = { COMMON = 0, UNCOMMON = 0, RARE = 0, EPIC = 0, EXOTIC = 0 }
        for _, r in ipairs(groups[groupName]) do
            local tier = r.data.finalRarityTier or "COMMON"
            active[tier] = (active[tier] or 0) + 1
        end
        writer:write(groupName .. ": "); printCounts(writer, active)
    end

    writer:write("\nSPECIAL/PARTIAL EXCLUDED FROM SIMULATION\n")
    writer:write("fullType | structural reason | active FinalTier (unchanged)\n")
    for _, r in ipairs(groups.SPECIAL_PARTIAL) do writer:write(string.format("%s | %s | %s\n", r.data.fullType, r.specialReason or "SPECIAL", tostring(r.data.finalRarityTier))) end
    writer:close()
    ItemRarityUtils.info("Literature final simulation written to Zomboid/Lua/ItemRarity_LiteratureFinalSimulation.txt (read-only).")
    return true
end
