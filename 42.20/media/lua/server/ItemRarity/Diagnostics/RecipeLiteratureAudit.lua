require "ItemRarity/RarityUtils"

-- Read-only audit for permanent LearnedRecipes. No registry/result mutation.
ItemRarityRecipeLiteratureAudit = ItemRarityRecipeLiteratureAudit or {}

local function call(o, method, ...)
    if not o then return nil end
    local ok, f = pcall(function() return o[method] end)
    if not ok or type(f) ~= "function" then return nil end
    local args = { ... }
    local worked, value = pcall(function() return f(o, unpack(args)) end)
    return worked and value or nil
end

local function text(v)
    local s = tostring(v or "")
    local low = string.lower(s)
    return (s == "" or low == "nil" or low == "null" or low == "[]") and "" or s
end

local function scriptFor(fullType)
    local manager = getScriptManager and getScriptManager() or nil
    return manager and manager:FindItem(fullType) or nil
end

local function instanceFor(script)
    if not script then return nil end
    local ok, item = pcall(function() return script:InstanceItem(nil, false) end)
    return ok and item or nil
end

local function read(script, item, getter, field)
    local v = call(script, getter)
    if v == nil then
        local ok, direct = pcall(function() return script and script[field] end)
        if ok then v = direct end
    end
    if v == nil then v = call(item, getter) end
    return text(v)
end

local function learnedRecipeNames(script, item)
    local source = call(script, "getLearnedRecipes") or call(item, "getLearnedRecipes")
    local result, seen = {}, {}
    local size = tonumber(call(source, "size"))
    if size then
        for index = 0, size - 1 do
            local name = text(call(source, "get", index))
            if name ~= "" and not seen[name] then seen[name] = true; table.insert(result, name) end
        end
    else
        local raw = text(source)
        raw = raw:gsub("^%[", ""):gsub("%]$", "")
        for name in string.gmatch(raw, "[^,;]+") do
            name = text(name):gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" and not seen[name] then seen[name] = true; table.insert(result, name) end
        end
    end
    table.sort(result)
    return result
end

local function scarcityStrength(data)
    local percentile = data.scarcityPercentile or (data.tableAvailability and data.tableAvailability.routeWeightedPercentile) or 50
    return 100 - percentile, percentile
end

-- Bounded quantity signal: first recipes matter, while 8 -> 16 recipes has
-- much less impact. It is deliberately recipe-count only, not recipe quality.
local function recipeValue(uniqueCount)
    return uniqueCount <= 0 and 0 or (100 * uniqueCount / (uniqueCount + 3))
end

local function score(recipe, scarcity, recipeWeight)
    return recipe * recipeWeight + scarcity * (1 - recipeWeight)
end

local function orderedKeys(map)
    local keys = {}; for key in pairs(map) do table.insert(keys, key) end; table.sort(keys); return keys
end

local function tierCounts(rows)
    local counts = { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }
    for _, row in ipairs(rows) do counts[row.finalTier or "COMMON"] = (counts[row.finalTier or "COMMON"] or 0) + 1 end
    return counts
end

function ItemRarityRecipeLiteratureAudit.write(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local rows, recipeOwners = {}, {}
    for _, data in pairs(results) do
        if data.category == "LITERATURE" then
            local script = scriptFor(data.fullType)
            local item = instanceFor(script)
            if script then
                local recipes = learnedRecipeNames(script, item)
                if #recipes > 0 then
                    local strength, percentile = scarcityStrength(data)
                    local r = {
                        data = data, recipes = recipes, recipeCount = #recipes,
                        recipeValue = recipeValue(#recipes), scarcityStrength = strength,
                        scarcityPercentile = percentile,
                        onRead = read(script, item, "getOnRead", "onRead"),
                        onCreate = read(script, item, "getOnCreate", "onCreate"),
                        doubleClickRecipe = read(script, item, "getDoubleClickRecipe", "doubleClickRecipe"),
                        itemType = read(script, item, "getItemType", "itemType"),
                        displayCategory = read(script, item, "getDisplayCategory", "displayCategory"),
                        finalTier = data.finalRarityTier,
                        module = data.module or "UNKNOWN",
                    }
                    r.modelA = score(r.recipeValue, r.scarcityStrength, .70)
                    r.modelB = score(r.recipeValue, r.scarcityStrength, .60)
                    r.modelC = score(r.recipeValue, r.scarcityStrength, .50)
                    table.insert(rows, r)
                    for _, recipe in ipairs(recipes) do
                        recipeOwners[recipe] = recipeOwners[recipe] or {}
                        table.insert(recipeOwners[recipe], data.fullType)
                    end
                end
            end
        end
    end
    table.sort(rows, function(a,b) return a.data.fullType < b.data.fullType end)
    local vanilla, modded = 0, 0
    for _, r in ipairs(rows) do if r.module == "Base" then vanilla = vanilla + 1 else modded = modded + 1 end end
    local duplicateRecipes = {}
    for recipe, owners in pairs(recipeOwners) do
        table.sort(owners)
        if #owners > 1 then table.insert(duplicateRecipes, { recipe=recipe, owners=owners }) end
    end
    table.sort(duplicateRecipes, function(a,b) return a.recipe < b.recipe end)
    local writer = getFileWriter("ItemRarity_RecipeLiteratureAudit.txt", true, false)
    if not writer then return nil end
    writer:write("Item Rarity Recipe Literature audit (READ ONLY; active tiers/registry unchanged)\n")
    writer:write("RecipeValue = 100 * uniqueRecipes / (uniqueRecipes + 3). It is a bounded count signal only; recipe usefulness is intentionally not evaluated.\n")
    writer:write("Model A = 70% RecipeValue + 30% ScarcityStrength; B = 60/40; C = 50/50. Scores are diagnostics, not tier proposals.\n\n")
    writer:write(string.format("FULLTYPES=%d | VANILLA=%d | MODDED=%d | UNIQUE_RECIPES=%d | DUPLICATED_RECIPE_IDS=%d\n", #rows, vanilla, modded, #orderedKeys(recipeOwners), #duplicateRecipes))
    local tiers = tierCounts(rows)
    writer:write(string.format("ACTIVE TIERS C/U/R/E/X=%d/%d/%d/%d/%d\n\n", tiers.COMMON, tiers.UNCOMMON, tiers.RARE, tiers.EPIC, tiers.EXOTIC))
    writer:write("ITEM AUDIT\n")
    writer:write("fullType | module | displayCategory | itemType | unique recipe count | RecipeValue | ScarcityTier | ScarcityPercentile | ScarcityStrength | active tier | model A | model B | model C | OnCreate | OnRead | DoubleClickRecipe | LearnedRecipes\n")
    for _, r in ipairs(rows) do
        writer:write(string.format("%s | %s | %s | %s | %d | %.2f | %s | %.2f | %.2f | %s | %.2f | %.2f | %.2f | %s | %s | %s | [%s]\n",
            r.data.fullType, r.module, r.displayCategory, r.itemType, r.recipeCount, r.recipeValue,
            tostring(r.data.baseScarcityTier or r.data.rarityTier), r.scarcityPercentile, r.scarcityStrength, tostring(r.finalTier),
            r.modelA, r.modelB, r.modelC, r.onCreate, r.onRead, r.doubleClickRecipe, table.concat(r.recipes, ", ")))
    end
    writer:write("\nDUPLICATED RECIPE IDS\n")
    writer:write("recipe | source fullTypes\n")
    if #duplicateRecipes == 0 then writer:write("None\n") end
    for _, entry in ipairs(duplicateRecipes) do writer:write(entry.recipe .. " | " .. table.concat(entry.owners, ", ") .. "\n") end
    writer:close()
    ItemRarityUtils.info("Recipe Literature audit written to Zomboid/Lua/ItemRarity_RecipeLiteratureAudit.txt (read-only).")
    return true
end
