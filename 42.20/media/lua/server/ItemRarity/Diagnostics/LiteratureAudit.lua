require "ItemRarity/RarityUtils"

-- Literature discovery only.  This module reads ScriptItem/runtime metadata
-- and never mutates scanner results, Utility, FinalRarityTier or the registry.
ItemRarityLiteratureAudit = ItemRarityLiteratureAudit or {}

local function call(o, name)
    if not o then return nil end
    local ok, method = pcall(function() return o[name] end)
    if not ok or type(method) ~= "function" then return nil end
    local worked, value = pcall(function() return method(o) end)
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
    if s == "" or low == "nil" or low == "null" or low == "[]" then return "" end
    return s
end

local function number(v)
    return tonumber(v)
end

local function nonempty(v)
    return text(v) ~= ""
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

local function field(script, item, getter, scriptField, itemGetter)
    return value(script, getter, scriptField) or value(item, itemGetter or getter, scriptField)
end

local function fmt(v)
    if v == nil then return "N/A" end
    local n = number(v)
    return n and string.format("%.2f", n) or (text(v) ~= "" and text(v) or "N/A")
end

local function mood(v)
    return number(v) or 0
end

local function profile(record)
    return table.concat({
        record.group, text(record.skill), tostring(record.level), tostring(record.maxLevel), tostring(record.progressionPosition), text(record.map), text(record.recipes),
        fmt(record.pages), fmt(record.unhappy), fmt(record.boredom), fmt(record.stress), text(record.onRead),
    }, ":")
end

local function contains(textValue, needle)
    return string.find(string.lower(text(textValue)), string.lower(needle), 1, true) ~= nil
end

local function recipeCount(recipes)
    local s = text(recipes):gsub("^%[", ""):gsub("%]$", "")
    if s == "" then return 0 end
    local count = 0
    for _ in string.gmatch(s, "[^,;]+") do count = count + 1 end
    return count
end

local function classify(r)
    -- These signals are ScriptItem mechanics, not item names or translations.
    if nonempty(r.skill) or (r.level ~= nil and r.level >= 0) then return "SKILLBOOK", "skill/level training declaration" end
    -- B42 exposes the map identity on MapItem instances, but not consistently
    -- through ScriptItem.  ItemType=base:map is the structural script type the
    -- game uses for map items, so it remains valid evidence even when MapID is
    -- unavailable through this bridge.
    if nonempty(r.map) or string.lower(r.itemType) == "base:map" then return "MAP", nonempty(r.map) and "Map/MapID declaration" or "ItemType=base:map (MapID bridge unavailable)" end
    -- base:hollowbook is also a tag on ordinary books that may be used as a
    -- hollow-book base.  Only ItemType=base:container identifies an already
    -- functional Hollow Book.
    if nonempty(r.recipes) or nonempty(r.onRead) or nonempty(r.doubleClickRecipe) or contains(r.itemType, "base:container") or string.lower(r.displayCategory) == "reciperesource" then
        return "SPECIAL_PARTIAL", nonempty(r.recipes) and "LearnedRecipes declaration" or nonempty(r.onRead) and "OnRead callback effect" or "RecipeResource declaration; recipe bridge unavailable"
    end
    if r.unhappy ~= 0 or r.boredom ~= 0 or r.stress ~= 0 then return "ENTERTAINMENT_LITERATURE", "declared reading mood effect" end
    return "TRIVIAL_LITERATURE", "no measured skill/map/recipe/callback/mood benefit"
end

local function orderedKeys(map)
    local keys = {}
    for key in pairs(map) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end

local function skillBookMultiplier(skill, level)
    local definition = SkillBook and SkillBook[skill] or nil
    if not definition or not level then return nil end
    local index = ({ [1] = 1, [3] = 2, [5] = 3, [7] = 4, [9] = 5 })[level]
    return index and number(definition["maxMultiplier" .. index]) or nil
end

local function moduleOf(fullType)
    return string.match(fullType or "", "^([^.]+)%.") or "UNKNOWN"
end

local function addProgressionPositions(records)
    local skills = {}
    for _, r in ipairs(records) do
        if r.group == "SKILLBOOK" then
            skills[r.skill] = skills[r.skill] or {}
            table.insert(skills[r.skill], r)
        end
    end
    for _, rows in pairs(skills) do
        table.sort(rows, function(a, b) return (a.level or -1) < (b.level or -1) end)
        for index, r in ipairs(rows) do r.progressionPosition = index end
    end
end

function ItemRarityLiteratureAudit.write(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local records, groups = {}, {}
    for _, data in pairs(results) do
        if data.category == "LITERATURE" then
            local script = scriptFor(data.fullType)
            local item = instanceFor(script)
            if script then
                local r = {
                    data = data,
                    displayCategory = text(field(script, item, "getDisplayCategory", "displayCategory")),
                    itemType = text(field(script, item, "getItemType", "itemType") or field(script, item, "getType", "type")),
                    tags = text(field(script, item, "getTags", "tags")),
                    skill = text(field(script, item, "getSkillTrained", "skillTrained")),
                    level = number(field(script, item, "getLvlSkillTrained", "lvlSkillTrained")),
                    maxLevel = number(field(script, item, "getMaxLevelTrained", "maxLevelTrained")),
                    levelsTrained = number(field(script, item, "getNumLevelsTrained", "numLevelsTrained")),
                    pages = number(field(script, item, "getNumberOfPages", "numberOfPages") or field(script, item, "getNumPages", "numPages")),
                    recipes = text(field(script, item, "getLearnedRecipes", "learnedRecipes") or field(script, item, "getTeachedRecipes", "teachedRecipes") or field(script, item, "getRecipes", "recipes")),
                    map = text(field(script, item, "getMapID", "map") or field(script, item, "getMapId", "mapId") or field(script, item, "getMap", "map")),
                    unhappy = mood(field(script, item, "getUnhappyChange", "unhappyChange")),
                    boredom = mood(field(script, item, "getBoredomChange", "boredomChange")),
                    stress = mood(field(script, item, "getStressChange", "stressChange")),
                    onRead = text(field(script, item, "getOnRead", "onRead")),
                    doubleClickRecipe = text(field(script, item, "getDoubleClickRecipe", "doubleClickRecipe")),
                }
                r.xpMultiplier = skillBookMultiplier(r.skill, r.level)
                r.group, r.reason = classify(r)
                r.recipeCount = recipeCount(r.recipes)
                r.module = moduleOf(data.fullType)
                table.insert(records, r)
            end
        end
    end
    table.sort(records, function(a, b) return a.data.fullType < b.data.fullType end)
    addProgressionPositions(records)
    -- Add groups only after relative structural positions have been derived.
    groups = {}
    for _, r in ipairs(records) do
        r.profile = profile(r)
        groups[r.group] = groups[r.group] or { rows = {}, profiles = {} }
        table.insert(groups[r.group].rows, r)
        groups[r.group].profiles[r.profile] = true
    end
    local writer = getFileWriter("ItemRarity_LiteratureAudit.txt", true, false)
    if not writer then return nil end
    writer:write("Item Rarity Literature audit (READ ONLY; active tiers/registry unchanged)\n")
    writer:write("Classification order: SKILLBOOK(skill/level) > MAP(MapID or ItemType=base:map) > SPECIAL_PARTIAL(LearnedRecipes/callback/RecipeResource) > ENTERTAINMENT(mood) > TRIVIAL. No item name/fullType is used as evidence.\n\n")
    writer:write("GROUP SUMMARY\n")
    writer:write("group | fullTypes | unique mechanical profiles | structural evidence\n")
    for _, group in ipairs(orderedKeys(groups)) do
        local g = groups[group]
        local count = 0; for _ in pairs(g.profiles) do count = count + 1 end
        writer:write(string.format("%s | %d | %d | %s\n", group, #g.rows, count,
            group == "SKILLBOOK" and "skill/level" or group == "MAP" and "MapID or ItemType" or group == "ENTERTAINMENT_LITERATURE" and "mood" or group == "SPECIAL_PARTIAL" and "recipe/callback/declaration" or "none"))
    end
    writer:write("\nSKILLBOOK STRUCTURAL PROGRESSION\n")
    writer:write("Position is derived only by sorting each SkillTrained family by LvlSkillTrained. Pages and subjective skill importance are excluded. XP multiplier is observational only.\n")
    writer:write("position | books | level ranges observed | XP multiplier min..max | interpretation\n")
    local positions = {}
    for _, r in ipairs(records) do
        if r.group == "SKILLBOOK" then
            local p = r.progressionPosition or 0
            positions[p] = positions[p] or { count = 0, levels = {}, minXP = nil, maxXP = nil }
            local row = positions[p]; row.count = row.count + 1; row.levels[r.level] = true
            if r.xpMultiplier then row.minXP = not row.minXP and r.xpMultiplier or math.min(row.minXP, r.xpMultiplier); row.maxXP = not row.maxXP and r.xpMultiplier or math.max(row.maxXP, r.xpMultiplier) end
        end
    end
    for _, p in ipairs(orderedKeys(positions)) do
        local row, levels = positions[p], orderedKeys(positions[p].levels)
        writer:write(string.format("TIER_%s | %d | %s | %s..%s | same relative book position across skill families\n", p, row.count, table.concat(levels, ","), fmt(row.minXP), fmt(row.maxXP)))
    end
    writer:write("\nRECIPE / LEARNED_RECIPES AUDIT\n")
    writer:write("fullType | module | displayCategory | recipe count | LearnedRecipes | mood effects | ScarcityTier | ScarcityPercentile\n")
    local recipeRows = {}
    for _, r in ipairs(records) do if r.group == "SPECIAL_PARTIAL" and r.recipeCount > 0 then table.insert(recipeRows, r) end end
    table.sort(recipeRows, function(a,b) return a.data.fullType < b.data.fullType end)
    for _, r in ipairs(recipeRows) do
        local d = r.data; local scarcityPercentile = d.scarcityPercentile or (d.tableAvailability and d.tableAvailability.routeWeightedPercentile) or 0
        writer:write(string.format("%s | %s | %s | %d | %s | U=%s B=%s S=%s | %s | %.2f\n", d.fullType, r.module, r.displayCategory, r.recipeCount, r.recipes, fmt(r.unhappy), fmt(r.boredom), fmt(r.stress), tostring(d.baseScarcityTier or d.rarityTier), tonumber(scarcityPercentile)))
    end
    writer:write("\nENTERTAINMENT BENEFIT PROFILES\n")
    writer:write("fullType | Unhappy | Boredom | Stress | all three are read-time effects; negative values are benefits.\n")
    for _, r in ipairs(records) do
        if r.group == "ENTERTAINMENT_LITERATURE" then writer:write(string.format("%s | %s | %s | %s\n", r.data.fullType, fmt(r.unhappy), fmt(r.boredom), fmt(r.stress))) end
    end
    writer:write("\nFULL AUDIT\n")
    writer:write("fullType | displayCategory | ItemType | recommended group | reason | skill | level | maxLevel | structural tier | levelsTrained | XP multiplier | pages | recipes | Map/MapID | Unhappy | Boredom | Stress | OnRead | doubleClickRecipe | tags | ScarcityTier | ScarcityPercentile\n")
    for _, r in ipairs(records) do
        local d = r.data
        local scarcityPercentile = d.scarcityPercentile or (d.tableAvailability and d.tableAvailability.routeWeightedPercentile) or 0
        writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %.2f\n",
            d.fullType, r.displayCategory, r.itemType, r.group, r.reason, r.skill, fmt(r.level), fmt(r.maxLevel), fmt(r.progressionPosition), fmt(r.levelsTrained), fmt(r.xpMultiplier), fmt(r.pages), r.recipes, r.map,
            fmt(r.unhappy), fmt(r.boredom), fmt(r.stress), r.onRead, r.doubleClickRecipe, r.tags, tostring(d.baseScarcityTier or d.rarityTier), tonumber(scarcityPercentile)))
    end
    writer:close()
    ItemRarityUtils.info("Literature audit written to Zomboid/Lua/ItemRarity_LiteratureAudit.txt (read-only).")
    return true
end
