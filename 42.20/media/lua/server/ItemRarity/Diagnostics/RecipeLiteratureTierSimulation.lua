require "ItemRarity/RarityUtils"

-- Read-only V1 score/tier simulation for Literature with LearnedRecipes.
ItemRarityRecipeLiteratureTierSimulation = ItemRarityRecipeLiteratureTierSimulation or {}

local function call(o, method, ...)
    if not o then return nil end
    local ok, f = pcall(function() return o[method] end)
    if not ok or type(f) ~= "function" then return nil end
    local args = { ... }; local worked, value = pcall(function() return f(o, unpack(args)) end)
    return worked and value or nil
end

local function text(v)
    local s = tostring(v or ""); local low = string.lower(s)
    return (s == "" or low == "nil" or low == "null" or low == "[]") and "" or s
end

local function scriptFor(fullType)
    local manager = getScriptManager and getScriptManager() or nil
    return manager and manager:FindItem(fullType) or nil
end

local function uniqueRecipes(script)
    -- Mirror active V1: do not create an InventoryItem, because that can run
    -- OnCreate and inject dynamic recipes that are outside this V1's source.
    local source = call(script, "getLearnedRecipes")
    local out, seen = {}, {}; local size = tonumber(call(source, "size"))
    if size then
        for i = 0, size - 1 do
            local recipe = text(call(source, "get", i))
            if recipe ~= "" and not seen[recipe] then seen[recipe] = true; table.insert(out, recipe) end
        end
    else
        local raw = text(source):gsub("^%[", ""):gsub("%]$", "")
        for recipe in string.gmatch(raw, "[^,;]+") do
            recipe = text(recipe):gsub("^%s+", ""):gsub("%s+$", "")
            if recipe ~= "" and not seen[recipe] then seen[recipe] = true; table.insert(out, recipe) end
        end
    end
    table.sort(out); return out
end

local function recipeValue(count) return count <= 0 and 0 or 100 * count / (count + 3) end
local function score(value, scarcity) return .70 * value + .30 * scarcity end
local function tier(finalScore)
    if finalScore >= 85 then return "EXOTIC" end
    if finalScore >= 70 then return "EPIC" end
    if finalScore >= 50 then return "RARE" end
    if finalScore >= 30 then return "UNCOMMON" end
    return "COMMON"
end

local function writeRows(writer, title, rows, limit)
    writer:write("\n" .. title .. "\n")
    writer:write("fullType | source | module | unique recipes | RecipeValue | ScarcityTier | ScarcityPercentile | ScarcityStrength | FinalRecipeScore | simulated tier | active tier | match\n")
    local count = 0
    for _, r in ipairs(rows) do
        count = count + 1
        if not limit or count <= limit then
            local source = r.module == "Base" and "VANILLA" or "MODDED"
            local activeTier = tostring(r.data.finalRarityTier or "-")
            local match = activeTier == r.tier and "MATCH" or "DIFF"
            writer:write(string.format("%s | %s | %s | %d | %.2f | %s | %.2f | %.2f | %.2f | %s | %s | %s\n", r.data.fullType, source, r.module, r.count, r.value, r.scarcityTier, r.scarcityPercentile, r.scarcityStrength, r.score, r.tier, activeTier, match))
        end
    end
    if count == 0 then writer:write("None\n") end
end

function ItemRarityRecipeLiteratureTierSimulation.write(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local rows = {}
    for _, data in pairs(results) do
        if data.category == "LITERATURE" then
            local script = scriptFor(data.fullType)
            local recipes = uniqueRecipes(script)
            if #recipes > 0 then
                local scarcityPercentile = data.scarcityPercentile or (data.tableAvailability and data.tableAvailability.routeWeightedPercentile) or 50
                local r = { data=data, module=data.module or "UNKNOWN", count=#recipes, value=recipeValue(#recipes), scarcityPercentile=scarcityPercentile, scarcityStrength=100-scarcityPercentile, scarcityTier=tostring(data.baseScarcityTier or data.rarityTier) }
                r.score, r.tier = score(r.value, r.scarcityStrength), tier(score(r.value, r.scarcityStrength))
                table.insert(rows, r)
            end
        end
    end
    table.sort(rows, function(a,b) return a.data.fullType < b.data.fullType end)
    local byTier = { COMMON={}, UNCOMMON={}, RARE={}, EPIC={}, EXOTIC={} }
    local mismatches = 0
    for _, r in ipairs(rows) do
        table.insert(byTier[r.tier], r)
        if tostring(r.data.finalRarityTier or "-") ~= r.tier then mismatches = mismatches + 1 end
    end
    for _, list in pairs(byTier) do table.sort(list, function(a,b) return a.score == b.score and a.data.fullType < b.data.fullType or a.score > b.score end) end
    local writer = getFileWriter("ItemRarity_RecipeLiteratureTierSimulation.txt", true, false)
    if not writer then return nil end
    writer:write("Recipe Literature V1 score simulation (READ ONLY; no active tier/registry changes)\n")
    writer:write("RecipeValue = 100 * uniqueRecipes / (uniqueRecipes + 3)\n")
    writer:write("FinalRecipeScore = 70% RecipeValue + 30% ScarcityStrength, where ScarcityStrength = 100 - ScarcityPercentile.\n")
    writer:write("Active score bands: <30 COMMON | 30..49.99 UNCOMMON | 50..69.99 RARE | 70..84.99 EPIC | >=85 EXOTIC.\n")
    writer:write(string.format("TOTAL=%d | C/U/R/E/X=%d/%d/%d/%d/%d | ACTIVE_VS_SIM_MISMATCHES=%d\n", #rows, #byTier.COMMON, #byTier.UNCOMMON, #byTier.RARE, #byTier.EPIC, #byTier.EXOTIC, mismatches))
    writeRows(writer, "ALL EXOTIC", byTier.EXOTIC)
    writeRows(writer, "ALL EPIC", byTier.EPIC)
    writeRows(writer, "TOP 10 RARE", byTier.RARE, 10)
    writeRows(writer, "TOP 10 UNCOMMON", byTier.UNCOMMON, 10)
    writer:write("\nFULL LIST (ORDERED BY FULLTYPE)\n")
    writeRows(writer, "ALL RECIPE LITERATURE", rows)
    writer:close()
    ItemRarityUtils.info("Recipe Literature tier simulation written to Zomboid/Lua/ItemRarity_RecipeLiteratureTierSimulation.txt (read-only).")
    return true
end
