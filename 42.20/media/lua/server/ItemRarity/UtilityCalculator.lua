require "ItemRarity/RarityConfig"
require "ItemRarity/RarityTiers"
require "ItemRarity/ItemClassifier"
require "ItemRarity/RarityUtils"

-- Computes a category-local utility score after Strategy D has finished. It
-- never reads or writes loot tables and preserves `rarityTier` as the base
-- scarcity tier; `finalRarityTier` is the UI-facing result of the hybrid model.
ItemRarityUtilityCalculator = ItemRarityUtilityCalculator or {}

local UTILITY = ItemRarityConfig.utility
local NORMALIZATION = UTILITY.normalization
local TIER_STRENGTH = { "COMMON", "UNCOMMON", "RARE", "EPIC", "EXOTIC" }
local TIER_INDEX = { COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 }
local CONFIDENCE_INDEX = { LOW = 1, MEDIUM = 2, HIGH = 3 }

local function callMethod(object, name)
    if not object then return nil end
    local ok, method = pcall(function() return object[name] end)
    if not ok or type(method) ~= "function" then return nil end
    local called, value = pcall(function() return method(object) end)
    return called and value or nil
end

local function callMethodWithArgs(object, name, ...)
    if not object then return nil end
    local ok, method = pcall(function() return object[name] end)
    if not ok or type(method) ~= "function" then return nil end
    local args = { ... }
    local called, value = pcall(function() return method(object, unpack(args)) end)
    return called and value or nil
end

local function readField(object, name)
    if not object then return nil end
    local ok, value = pcall(function() return object[name] end)
    return ok and value or nil
end

local function readNumber(object, getter, field, fallback)
    local value = getter and callMethod(object, getter) or nil
    if value == nil and field then value = readField(object, field) end
    value = tonumber(value)
    if value == nil then return fallback end
    return value
end

local function readString(object, getter, field)
    local value = getter and callMethod(object, getter) or nil
    if value == nil and field then value = readField(object, field) end
    return value == nil and nil or tostring(value)
end

local function readBoolean(object, getter, field)
    local value = getter and callMethod(object, getter) or nil
    if value == nil and field then value = readField(object, field) end
    return value == true
end

local function collectionSize(value)
    if value == nil then return 0 end
    local size = callMethod(value, "size")
    if tonumber(size) then return tonumber(size) end
    local ok, length = pcall(function() return #value end)
    return ok and tonumber(length) or 0
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function round(value)
    return math.floor((value or 0) * 100 + 0.5) / 100
end

local function sortedCopy(values)
    local copy = {}
    for index, value in ipairs(values) do copy[index] = value end
    table.sort(copy)
    return copy
end

local function quantile(sortedValues, percentile)
    local count = #sortedValues
    if count == 0 then return nil end
    if count == 1 then return sortedValues[1] end
    local position = clamp(percentile / 100, 0, 1) * (count - 1) + 1
    local lower, upper = math.floor(position), math.ceil(position)
    if lower == upper then return sortedValues[lower] end
    local fraction = position - lower
    return sortedValues[lower] + (sortedValues[upper] - sortedValues[lower]) * fraction
end

local function uniqueSorted(values)
    local sorted, unique = sortedCopy(values), {}
    local previous = nil
    for _, value in ipairs(sorted) do
        if previous == nil or value ~= previous then
            table.insert(unique, value)
            previous = value
        end
    end
    return unique
end

local function percentileRank(sortedUniqueValues, value, inverted)
    local count = #sortedUniqueValues
    if count == 0 then return nil end
    if count == 1 then return 50 end
    local first, last = nil, nil
    for index, candidate in ipairs(sortedUniqueValues) do
        if candidate == value then
            first = first or index
            last = index
        end
    end
    if not first then return nil end
    local rank = ((first + last - 2) / (2 * (count - 1))) * 100
    return inverted and (100 - rank) or rank
end

local function confidenceAtLeast(actual, required)
    return (CONFIDENCE_INDEX[actual] or 0) >= (CONFIDENCE_INDEX[required] or 0)
end

local function contains(text, fragment)
    return type(text) == "string" and string.find(string.lower(text), fragment, 1, true) ~= nil
end

local function weaponFamily(scriptItem)
    local categories = readString(scriptItem, "getWeaponCategories", nil) or ""
    local subCategory = readString(scriptItem, nil, "subCategory") or ""
    local text = string.lower(categories .. ";" .. subCategory)
    if string.find(text, "longblade", 1, true) then return "LONG_BLADE" end
    if string.find(text, "smallblade", 1, true) then return "SMALL_BLADE" end
    if string.find(text, "axe", 1, true) then return "AXE" end
    if string.find(text, "spear", 1, true) then return "SPEAR" end
    if string.find(text, "blunt", 1, true) then return "BLUNT" end
    return "OTHER_MELEE"
end

local function isSkillCombatFamily(family)
    -- B42's IsoGameCharacter.getWeaponLevel() resolves weapon skill from the
    -- HandWeapon WeaponCategory: Axe, Spear, SmallBlade, LongBlade, Blunt or
    -- SmallBlunt. `weaponFamily()` deliberately folds SmallBlunt into BLUNT.
    return family == "AXE" or family == "SPEAR" or family == "SMALL_BLADE"
        or family == "LONG_BLADE" or family == "BLUNT"
end

local function containerSubgroup(scriptItem, runtimeItem)
    -- ScriptItem's public container fields are not exposed by the B42 Lua
    -- bridge. InventoryContainer exposes the populated runtime values.
    local body = readString(runtimeItem, "canBeEquipped", nil)
        or readString(runtimeItem, "getBodyLocation", nil)
        or readString(scriptItem, "getBodyLocation", nil)
        or ""
    body = string.lower(body)
    local capacity = readNumber(runtimeItem, "getCapacity", nil, 0) or 0
    local maxItemSize = readNumber(scriptItem, "getMaxItemSize", "maxItemSize", 0) or 0
    if capacity <= 0 then return "NON_WEARABLE_CONTAINER" end
    -- Java enums stringify as expanded names in the B42 Lua bridge (for
    -- example ItemBodyLocation.NONE), not only as the literal "none".
    if body == "" or contains(body, "none") or contains(body, "null") then
        return maxItemSize > 0 and "CASE" or "NON_WEARABLE_CONTAINER"
    end
    if contains(body, "belt") or contains(body, "holster") or contains(body, "ammo_strap") or contains(body, "webbing") then
        return "BELT_OR_ATTACHMENT_CONTAINER"
    end
    if contains(body, "back") then return "BACKPACK" end
    if contains(body, "satchel") or contains(body, "fanny") then return "WEARABLE_BAG" end

    -- Do not infer equipability from capacity alone. The Lua bridge can expose
    -- a generic InventoryItem body location when `canBeEquipped()` is null;
    -- an unrecognised slot is therefore safely treated as non-wearable.
    return maxItemSize > 0 and "CASE" or "NON_WEARABLE_CONTAINER"
end

local function profileKey(metrics, orderedNames)
    local parts = {}
    for _, name in ipairs(orderedNames) do
        local value = metrics[name]
        table.insert(parts, value == nil and "-" or string.format("%.5f", value))
    end
    return table.concat(parts, ":")
end

local function readRuntimeOrScriptNumber(runtimeItem, scriptItem, getter, field)
    local value = readNumber(runtimeItem, getter, field, nil)
    if value == nil then value = readNumber(scriptItem, getter, field, nil) end
    return value
end

local function readRuntimeOrScriptString(runtimeItem, scriptItem, getter, field)
    local value = readString(runtimeItem, getter, field)
    if value == nil or value == "" then value = readString(scriptItem, getter, field) end
    return value
end

local function clothingSubgroup(bodyLocation)
    local location = string.lower(bodyLocation or "")
    if contains(location, "fullsuit") or contains(location, "longdress") or contains(location, "dress") or contains(location, "boilersuit") then return "FULL_BODY" end
    if contains(location, "hat") or contains(location, "head") or contains(location, "eyes") or contains(location, "mask")
        or contains(location, "gorget") or contains(location, "scba") then return "HEAD" end
    if contains(location, "shirt") or contains(location, "torso") or contains(location, "jacket") or contains(location, "vest")
        or contains(location, "waistcoat") or contains(location, "apron") or contains(location, "jersey") or contains(location, "sweater")
        or contains(location, "tanktop") or contains(location, "fulltop") or contains(location, "cuirass") or contains(location, "shoulder")
        or contains(location, "elbow") or contains(location, "forearm") or contains(location, "arm") then return "TORSO" end
    if contains(location, "trouser") or contains(location, "pants") or contains(location, "skirt") or contains(location, "groin")
        or contains(location, "underwear") or contains(location, "legs") or contains(location, "shorts") or contains(location, "thigh")
        or contains(location, "calf") or contains(location, "knee") then return "LEGS" end
    if contains(location, "glove") or contains(location, "hand") then return "HANDS" end
    if contains(location, "shoe") or contains(location, "boot") or contains(location, "sock") or contains(location, "foot") then return "FEET" end
    return "OTHER"
end

local function coverageSummary(coveredParts)
    if not coveredParts or coveredParts == "" then return "UNKNOWN", 0 end
    local normalized = string.lower(coveredParts)
    local zones, count = {}, 0
    local definitions = {
        { "HEAD", { "head", "neck", "fullhelmet" } },
        { "TORSO", { "torso", "upperbody", "upperarm", "upperarms", "forearm", "shirt", "jumper", "jacket", "apron" } },
        { "HANDS", { "hand" } },
        { "LEGS", { "groin", "upperleg", "lowerleg", "trousers", "shortsshort" } },
        { "FEET", { "foot", "shoes" } },
    }
    for _, definition in ipairs(definitions) do
        for _, token in ipairs(definition[2]) do
            if string.find(normalized, token, 1, true) then
                table.insert(zones, definition[1])
                count = count + 1
                break
            end
        end
    end
    return #zones > 0 and table.concat(zones, "+") or "UNKNOWN", count
end

local function subgroupFromCoverage(coverageZones)
    if coverageZones == "UNKNOWN" then return "OTHER" end
    if contains(coverageZones, "torso") and contains(coverageZones, "legs") then return "FULL_BODY" end
    if coverageZones == "HEAD" or coverageZones == "TORSO" or coverageZones == "LEGS" or coverageZones == "HANDS" or coverageZones == "FEET" then
        return coverageZones
    end
    return "OTHER"
end

local function coverageEvidenceCount(coveredParts)
    if not coveredParts or coveredParts == "" or string.lower(coveredParts) == "nil" then return nil end
    local count = 0
    for _ in string.gmatch(coveredParts, "[^,%[%]]+") do count = count + 1 end
    return count > 0 and count or nil
end

-- BloodLocation exposes a mix of atomic body-part tokens and clothing-layer
-- tokens. Map both forms to a structural anatomy vocabulary without consulting
-- item names. A layer token expands only to the regions that its B42 runtime
-- coverage declaration represents.
local COVERED_REGION_MAP = {
    head = { "HEAD" }, fullhelmet = { "HEAD", "NECK" }, neck = { "NECK" },
    upperbody = { "TORSO_UPPER" }, shirt = { "TORSO_UPPER", "TORSO_LOWER" }, shirtnosleeves = { "TORSO_UPPER", "TORSO_LOWER" },
    shirtlongsleeves = { "TORSO_UPPER", "TORSO_LOWER", "UPPER_ARM", "FOREARM" }, jumper = { "TORSO_UPPER", "TORSO_LOWER" },
    jumpernosleeves = { "TORSO_UPPER", "TORSO_LOWER" }, jacket = { "TORSO_UPPER", "TORSO_LOWER", "UPPER_ARM", "FOREARM" },
    longjacket = { "TORSO_UPPER", "TORSO_LOWER", "UPPER_ARM", "FOREARM", "THIGH" }, apron = { "TORSO_LOWER" },
    upperarms = { "UPPER_ARM" }, upperarm_l = { "UPPER_ARM" }, upperarm_r = { "UPPER_ARM" },
    forearm_l = { "FOREARM" }, forearm_r = { "FOREARM" }, hand_l = { "HAND" }, hand_r = { "HAND" }, hands = { "HAND" },
    trousers = { "GROIN", "THIGH", "SHIN" }, shortsshort = { "GROIN", "THIGH" }, groin = { "GROIN" },
    upperleg_l = { "THIGH" }, upperleg_r = { "THIGH" }, lowerleg_l = { "SHIN" }, lowerleg_r = { "SHIN" }, lowerlegs = { "SHIN" },
    shoes = { "FOOT" },
}

local function coveredRegions(coveredParts)
    if not coveredParts or coveredParts == "" or string.lower(coveredParts) == "nil" then return {}, {} end
    local regions, observedTokens = {}, {}
    for token in string.gmatch(string.lower(coveredParts), "[^,%[%]]+") do
        token = string.gsub(token, "^%s+", "")
        token = string.gsub(token, "%s+$", "")
        if token ~= "" then
            observedTokens[token] = true
            for _, region in ipairs(COVERED_REGION_MAP[token] or {}) do regions[region] = true end
        end
    end
    local ordered = {}
    for region in pairs(regions) do table.insert(ordered, region) end
    table.sort(ordered)
    return ordered, observedTokens
end

-- The Human BodyLocation group is the B42 equipment topology actually used
-- when items are worn.  Resolve a script item's slot against that graph rather
-- than inferring a role from its display name or fullType.  A custom slot that
-- is not registered in the current runtime remains observable, but is marked
-- unresolved so it cannot receive artificial HIGH confidence later.
local function bodyLocationGraph(bodyLocation)
    local graph = { bodyLocation = bodyLocation or "", resolved = false, exclusive = {}, exclusiveCount = 0 }
    -- BodyLocations.getGroup is static in B42.  Unlike instance bridge calls,
    -- it must not receive the Lua table as an implicit first argument.
    local group = nil
    if BodyLocations and type(BodyLocations.getGroup) == "function" then
        local ok, value = pcall(function() return BodyLocations.getGroup("Human") end)
        if ok then group = value end
    end
    local locations = group and callMethod(group, "getAllLocations") or nil
    local target = string.lower(tostring(bodyLocation or ""))
    local size = collectionSize(locations)
    local resolvedSlot, cuirassSlot = nil, nil
    for index = 0, size - 1 do
        local location = callMethodWithArgs(locations, "get", index)
        local id = location and callMethod(location, "getId") or nil
        local idText = string.lower(tostring(id or ""))
        if idText == target then resolvedSlot = id end
        if idText == "base:cuirass" then cuirassSlot = id end
    end
    if not resolvedSlot then return graph end
    graph.resolved, graph.slot = true, resolvedSlot
    graph.slotId = tostring(resolvedSlot)
    graph.isCuirass = cuirassSlot ~= nil and tostring(resolvedSlot) == tostring(cuirassSlot)
    graph.conflictsCuirass = cuirassSlot ~= nil and callMethodWithArgs(group, "isExclusive", resolvedSlot, cuirassSlot) == true
    graph.compatibleWithCuirass = cuirassSlot ~= nil and not graph.isCuirass and not graph.conflictsCuirass
    for index = 0, size - 1 do
        local location = callMethodWithArgs(locations, "get", index)
        local id = location and callMethod(location, "getId") or nil
        if id and callMethodWithArgs(group, "isExclusive", resolvedSlot, id) == true then
            table.insert(graph.exclusive, tostring(id))
        end
    end
    table.sort(graph.exclusive)
    graph.exclusiveCount = #graph.exclusive
    return graph
end

-- Some clothing advertises a real special function through runtime/script
-- behavior rather than a numeric defense field (for example an activated
-- breathing-system garment).  This is intentionally generic: it inspects
-- behavior markers, never a fullType or item name.
local function clothingSpecialBehaviorEvidence(scriptItem)
    local tags = string.lower(readString(scriptItem, "getTags", "tags") or "")
    local activated = readBoolean(scriptItem, "isActivatedItem", "activatedItem")
    local keepOnDeplete = readBoolean(scriptItem, "isKeepOnDeplete", "keepOnDeplete")
    local onCreate = readString(scriptItem, "getOnCreate", "onCreate")
    local specialTag = string.find(tags, "scba", 1, true) ~= nil or string.find(tags, "hazmatsuit", 1, true) ~= nil
    -- OnCreate alone is often cosmetic/randomization metadata. It is recorded
    -- as evidence, but only an activated/depleting behavior or an explicit
    -- breathing-system tag is enough to make the value non-quantifiable.
    if activated or keepOnDeplete or specialTag then
        return true, string.format("activated=%s,onCreate=%s,keepOnDeplete=%s,specialTag=%s", tostring(activated), tostring(onCreate ~= nil), tostring(keepOnDeplete), tostring(specialTag))
    end
    return false, nil
end

local function regionSet(regions)
    local set = {}
    for _, region in ipairs(regions or {}) do set[region] = true end
    return set
end

local function hasAnyRegion(set, values)
    for _, value in ipairs(values) do if set[value] then return true end end
    return false
end

local function hasOnlyAccessoryRegions(set)
    local count = 0
    local allowed = { NECK = true, UPPER_ARM = true, FOREARM = true, HAND = true, THIGH = true, SHIN = true }
    for region in pairs(set) do
        count = count + 1
        if not allowed[region] then return false end
    end
    return count > 0
end

-- Functional role is inferred from static coverage plus the actual conflict
-- graph.  PRIMARY_ARMOR consumes the cuirass/torso-armor role; accessories
-- occupy a compatible peripheral slot.  This intentionally leaves ordinary
-- shirts and jackets in GENERAL_CLOTHING even if they carry minor defense.
local function clothingFunctionalGroup(graph, regions, metrics)
    local set = regionSet(regions)
    local physical = (metrics.biteDefense or 0) > 0 or (metrics.scratchDefense or 0) > 0 or (metrics.bulletDefense or 0) > 0
    local hasTorso = hasAnyRegion(set, { "TORSO_UPPER", "TORSO_LOWER" })
    local hasLowerBody = hasAnyRegion(set, { "GROIN", "THIGH", "SHIN" })
    local coverageCount = 0
    for _ in pairs(set) do coverageCount = coverageCount + 1 end
    if hasTorso and hasLowerBody then return "FULL_BODY_RESTRICTIVE", "coverage spans torso and lower/full-body regions" end
    if set.FOOT and not hasTorso then return "FOOTWEAR", "dedicated foot coverage" end
    if set.HEAD and not hasTorso then return "HEADGEAR", "dedicated head coverage" end
    if physical and hasOnlyAccessoryRegions(set) and graph.resolved and graph.compatibleWithCuirass then
        return "ARMOR_ACCESSORY", "localized protective coverage in a slot compatible with cuirass"
    end
    if physical and hasTorso and graph.resolved and (graph.isCuirass or graph.conflictsCuirass) then
        return "PRIMARY_ARMOR", "torso protection occupying or conflicting with cuirass role"
    end
    -- Ordinary clothing is now split by its actual occupied anatomy.  A
    -- localized central region in a cuirass-compatible slot is deliberately
    -- kept distinct from trousers/skirts: it is structurally a complement,
    -- not a lower-body layer.  This does not inspect the item name.
    if hasTorso then return "TORSO_LAYER", "non-primary torso layer" end
    if hasLowerBody then
        if coverageCount == 1 and set.GROIN and graph.resolved and graph.compatibleWithCuirass then
            return "CORE_ACCESSORY", "single localized central region in a cuirass-compatible slot"
        end
        return "LOWER_BODY_LAYER", "non-primary lower-body layer"
    end
    -- The loaded B42 dataset has no examples here, but retain a transparent
    -- fallback for a future modded Clothing item with no usable coverage.
    return "GENERAL_UNRESOLVED", graph.resolved and "no structural coverage for layer classification" or "unresolved BodyLocation fallback"
end

local function clothingTopology(subgroup, bodyLocation, coveredParts, coverageZones)
    local location = string.lower(bodyLocation or "")
    local covered = string.lower(coveredParts or "")
    if subgroup == "FULL_BODY" then
        return coverageZones and coverageZones ~= "UNKNOWN" and "FULL_BODY_MULTI_ZONE" or "FULL_BODY_UNRESOLVED"
    end
    if subgroup == "HEAD" then
        if contains(covered, "fullhelmet") then return "HEAD_FULL" end
        if contains(covered, "neck") then return "HEAD_NECK" end
        return "HEAD_CORE"
    end
    if subgroup == "TORSO" then
        if contains(location, "shoulder") or contains(location, "elbow") or contains(location, "forearm") or contains(location, "arm") then return "ARM_GUARD" end
        if contains(covered, "shirtlongsleeves") or contains(covered, "jacket") or contains(covered, "upperarms") then return "TORSO_LONG_SLEEVE" end
        return "TORSO_CORE"
    end
    if subgroup == "LEGS" then
        if contains(location, "thigh") or contains(location, "calf") or contains(location, "knee") then return "LEG_GUARD" end
        if contains(covered, "trousers") or contains(covered, "lowerleg") then return "LEGS_LONG" end
        return "LEGS_SHORT"
    end
    if subgroup == "FEET" then return contains(covered, "lowerleg") and "FEET_EXTENDED" or "FEET_CORE" end
    if subgroup == "HANDS" then return "HANDS_CORE" end
    return "OTHER"
end

local function makeClothingDiscoveryCandidate(data, scriptItem)
    -- B42's generated item scripts declare clothing properties, while the
    -- temporary Clothing runtime item confirms which getters actually cross
    -- the Lua bridge. This is diagnostics only: no clothing score or tier
    -- adjustment is created in this stage.
    local ok, runtimeItem = pcall(function() return scriptItem:InstanceItem(nil, false) end)
    if not ok then runtimeItem = nil end
    local bodyLocation = readRuntimeOrScriptString(runtimeItem, scriptItem, "getBodyLocation", "bodyLocation") or ""
    local coveredParts = readRuntimeOrScriptString(runtimeItem, scriptItem, "getBloodClothingType", "bloodClothingType")
        or readRuntimeOrScriptString(runtimeItem, scriptItem, "getBloodLocation", "bloodLocation")
        or readRuntimeOrScriptString(runtimeItem, scriptItem, "getCoveredParts", "coveredParts")
    local coverageZones, coverageZoneCount = coverageSummary(coveredParts)
    local regions, observedTokens = coveredRegions(coveredParts)
    local subgroup = clothingSubgroup(bodyLocation)
    if subgroup == "OTHER" then subgroup = subgroupFromCoverage(coverageZones) end
    local topology = clothingTopology(subgroup, bodyLocation, coveredParts, coverageZones)
    local conditionMax = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getConditionMax", "conditionMax")
    local conditionLowerChance = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getConditionLowerChance", "conditionLowerChance")
    local metrics = {
        biteDefense = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getBiteDefense", "biteDefense"),
        scratchDefense = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getScratchDefense", "scratchDefense"),
        bulletDefense = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getBulletDefense", "bulletDefense"),
        insulation = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getInsulation", "insulation"),
        windResistance = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getWindResistance", "windResistance"),
        waterResistance = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getWaterResistance", "waterResistance"),
        conditionMax = conditionMax,
        conditionLowerChance = conditionLowerChance,
        durability = conditionMax and conditionLowerChance and math.log(1 + math.max(0, conditionMax) * math.max(0, conditionLowerChance)) or nil,
        weight = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getActualWeight", "actualWeight"),
        runSpeedModifier = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getRunSpeedModifier", "runSpeedModifier"),
        combatSpeedModifier = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getCombatSpeedModifier", "combatSpeedModifier"),
        discomfortModifier = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getDiscomfortModifier", "discomfortModifier"),
        visionModifier = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getVisionModifier", "visionModifier"),
        hearingModifier = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getHearingModifier", "hearingModifier"),
        -- Probe only: no endurance or generic movement field is assumed to
        -- belong to clothing. The report records availability before either
        -- could ever be considered for an experimental cost model.
        enduranceModifier = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getEnduranceModifier", "enduranceModifier")
            or readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getEnduranceMod", "enduranceMod"),
        movementModifier = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getMovementModifier", "movementModifier"),
        fatigueChange = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getFatigueChange", "fatigueChange"),
        wetness = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getWetness", "wetness"),
        coverageZoneCount = coverageZoneCount > 0 and coverageZoneCount or nil,
        coverageEvidenceCount = coverageEvidenceCount(coveredParts),
    }
    -- Some B42 bindings use a lowercase 'r' in the Java getter name. Probe it
    -- only as a fallback so the report records the actual available value.
    if metrics.windResistance == nil then
        metrics.windResistance = readRuntimeOrScriptNumber(runtimeItem, scriptItem, "getWindresistance", "windresistance")
    end
    local equipmentGraph = bodyLocationGraph(bodyLocation)
    local mechanicalSpecialBehavior, mechanicalSpecialReason = clothingSpecialBehaviorEvidence(scriptItem)
    local functionalGroup, functionalReason = clothingFunctionalGroup(equipmentGraph, regions, metrics)
    local priorFunctionalGroup = (functionalGroup == "TORSO_LAYER" or functionalGroup == "LOWER_BODY_LAYER"
        or functionalGroup == "CORE_ACCESSORY" or functionalGroup == "GENERAL_UNRESOLVED") and "GENERAL_CLOTHING" or functionalGroup
    local profile = profileKey(metrics, { "biteDefense", "scratchDefense", "bulletDefense", "insulation", "windResistance",
        "waterResistance", "conditionMax", "conditionLowerChance", "weight", "runSpeedModifier", "combatSpeedModifier", "coverageEvidenceCount" })
        .. ":" .. subgroup .. ":" .. topology .. ":" .. tostring(coveredParts or "-")
    return {
        data = data,
        kind = "CLOTHING",
        subgroup = subgroup,
        parentGroup = "CLOTHING",
        functionalGroup = functionalGroup,
        functionalGroupReason = functionalReason,
        priorFunctionalGroup = priorFunctionalGroup,
        equipmentGraph = equipmentGraph,
        mechanicalSpecialBehavior = mechanicalSpecialBehavior,
        mechanicalSpecialReason = mechanicalSpecialReason,
        metrics = metrics,
        profile = profile,
        utilityEligible = false,
        clothingUtilityCandidate = true,
        ineligibleReason = "ClothingUtility is diagnostic only; excluded from active FinalRarityTier",
        clothingDiscovery = {
            bodyLocation = bodyLocation,
            coveredParts = coveredParts or "",
            coverageZones = coverageZones,
            coverageZoneCount = coverageZoneCount,
            topology = topology,
            coveredRegions = regions,
            observedCoverageTokens = observedTokens,
        },
    }
end

local function makeContainerCandidate(data, scriptItem)
    -- The temporary object is never put into an inventory and is never
    -- transmitted. It exists only long enough to read the B42 runtime API.
    local ok, runtimeItem = pcall(function() return scriptItem:InstanceItem(nil, false) end)
    if not ok then runtimeItem = nil end
    local subgroup = containerSubgroup(scriptItem, runtimeItem)
    local capacity = readNumber(runtimeItem, "getCapacity", nil, nil)
    local weightReduction = readNumber(runtimeItem, "getWeightReduction", nil, nil)
    local emptyWeight = readNumber(runtimeItem, "getActualWeight", nil, nil)
    local runSpeedModifier = readNumber(scriptItem, nil, "runSpeedModifier", nil)
    -- The ScriptItem field is currently not bridged in B42. Treat an absent
    -- modifier as missing rather than silently interpreting it as a bonus.
    if runSpeedModifier ~= nil and runSpeedModifier <= 0 then runSpeedModifier = nil end
    local attachments = collectionSize(callMethod(runtimeItem, "getAttachmentsProvided"))
    local metrics = {
        capacity = capacity and capacity >= 0 and capacity or nil,
        weightReduction = weightReduction and weightReduction >= 0 and weightReduction or nil,
        emptyWeight = emptyWeight and emptyWeight > 0 and emptyWeight or nil,
        runSpeedModifier = runSpeedModifier,
        attachments = attachments,
    }
    return {
        data = data,
        kind = "CONTAINER",
        subgroup = subgroup,
        parentGroup = "WEARABLE_CONTAINER",
        metrics = metrics,
        profile = profileKey(metrics, { "capacity", "weightReduction", "emptyWeight", "runSpeedModifier", "attachments" }),
        utilityEligible = subgroup == "BACKPACK" or subgroup == "WEARABLE_BAG" or subgroup == "BELT_OR_ATTACHMENT_CONTAINER",
        ineligibleReason = (subgroup == "BACKPACK" or subgroup == "WEARABLE_BAG" or subgroup == "BELT_OR_ATTACHMENT_CONTAINER") and nil or "container is not wearable",
        config = UTILITY.container,
        directions = { capacity = false, weightReduction = false, emptyWeight = true, runSpeedModifier = false, attachments = false },
    }
end

local function makeMeleeCandidate(data, scriptItem)
    local ranged = readBoolean(scriptItem, "isRanged", "ranged")
    local displayCategory = string.lower(data.displayCategory or "")
    local ok, runtimeItem = pcall(function() return scriptItem:InstanceItem(nil, false) end)
    if not ok then runtimeItem = nil end
    local minDamage = readNumber(scriptItem, "getMinDamage", "minDamage", nil)
    local maxDamage = readNumber(scriptItem, "getMaxDamage", "maxDamage", nil)
    local averageDamage = minDamage and maxDamage and (minDamage + maxDamage) / 2 or nil
    local swingTime = readNumber(scriptItem, "getSwingTime", "swingTime", nil)
    local criticalChance = readNumber(scriptItem, nil, "criticalChance", 0)
    local criticalMultiplier = readNumber(scriptItem, nil, "critDmgMultiplier", 1)
    local runtimeCriticalChance = readNumber(runtimeItem, "getCriticalChance", "criticalChance", nil)
    local runtimeCriticalMultiplier = readNumber(runtimeItem, "getCriticalDamageMultiplier", "criticalDamageMultiplier", nil)
    local conditionMax = readNumber(scriptItem, "getConditionMax", "conditionMax", nil)
    local conditionLowerChance = readNumber(scriptItem, "getConditionLowerChance", "conditionLowerChance", nil)
    local durability = conditionMax and conditionLowerChance and math.log(1 + math.max(0, conditionMax) * math.max(0, conditionLowerChance)) or nil
    local weight = readNumber(scriptItem, "getActualWeight", "actualWeight", nil)
    local endurance = readNumber(scriptItem, "getEnduranceMod", "enduranceMod", nil)
    local baseSpeed = readNumber(runtimeItem, "getBaseSpeed", "baseSpeed", 1)
    local metrics = {
        averageDamage = averageDamage and averageDamage > 0 and averageDamage or nil,
        attackSpeed = swingTime and swingTime > 0 and swingTime or nil,
        range = readNumber(scriptItem, "getMaxRange", "maxRange", nil),
        -- Retained only for the V1 snapshot. ScriptItem does not bridge these
        -- attributes correctly in B42; active V2 uses runtimeCritical below.
        critical = math.max(0, criticalChance or 0) * math.max(0, criticalMultiplier or 0),
        runtimeCritical = runtimeCriticalChance and runtimeCriticalMultiplier
            and math.max(0, runtimeCriticalChance) * math.max(0, runtimeCriticalMultiplier) or nil,
        durability = durability,
        multiHit = readNumber(scriptItem, "getMaxHitCount", "maxHitCount", nil),
        weight = weight,
        endurance = endurance,
        strainProxy = weight and endurance and weight * endurance or nil,
        -- Comparative tempo signal only; never a real attack time or DPS.
        attackTempo = swingTime and swingTime > 0 and (0.8 * baseSpeed) / swingTime or nil,
        knockdown = readNumber(scriptItem, "getKnockdownMod", "knockdownMod", nil),
    }
    local hasCombatBasics = metrics.averageDamage ~= nil and metrics.attackSpeed ~= nil
    local family = weaponFamily(scriptItem)
    -- Functional item category is not combat identity: B42 marks Crowbar and
    -- several weapons as TOOL, yet their HandWeapon category routes combat
    -- skill (and XP) through Blunt/Axe/Spear/etc.  The skill category is the
    -- invariant that belongs in a combat Utility model.
    local hasCombatSkill = isSkillCombatFamily(family)
    local eligible = (data.category == "WEAPON" or data.category == "TOOL") and hasCombatSkill
        and not ranged and not contains(displayCategory, "brokenweapon") and hasCombatBasics
    local reason = nil
    if data.category ~= "WEAPON" and data.category ~= "TOOL" then reason = "functional category is not melee-capable"
    elseif not hasCombatSkill then reason = "HandWeapon has no B42 combat-skill category"
    elseif ranged then reason = "ranged weapon; firearms are not implemented"
    elseif contains(displayCategory, "brokenweapon") then reason = "broken weapon is not eligible"
    elseif not hasCombatBasics then reason = "missing melee damage or swing-time data" end
    return {
        data = data,
        kind = "MELEE_WEAPON",
        subgroup = family,
        parentGroup = "MELEE_WEAPON",
        metrics = metrics,
        profile = profileKey(metrics, { "averageDamage", "attackSpeed", "range", "critical", "durability", "multiHit", "weight", "endurance", "knockdown" }),
        utilityEligible = eligible,
        ineligibleReason = reason,
        config = UTILITY.meleeWeapon,
        directions = { averageDamage = false, attackSpeed = true, range = false, critical = false, durability = false, multiHit = false, weight = true, endurance = true, knockdown = false },
    }
end

local function candidateFor(data)
    local manager = getScriptManager and getScriptManager() or nil
    local scriptItem = manager and manager:FindItem(data.fullType) or nil
    if not scriptItem then
        return { data = data, utilityEligible = false, ineligibleReason = "ScriptItem is unavailable" }
    end
    if data.category == "CONTAINER" then return makeContainerCandidate(data, scriptItem) end
    if data.category == "CLOTHING" then return makeClothingDiscoveryCandidate(data, scriptItem) end
    if data.category == "WEAPON" or data.category == "TOOL" then return makeMeleeCandidate(data, scriptItem) end
    return { data = data, utilityEligible = false, ineligibleReason = "category is not implemented for Utility" }
end

local function countProfiles(candidates)
    local profiles = {}
    for _, candidate in ipairs(candidates) do profiles[candidate.profile] = true end
    local count = 0
    for _ in pairs(profiles) do count = count + 1 end
    return count
end

local function resolveGroups(candidates)
    local subgroupMembers, parentMembers = {}, {}
    for _, candidate in ipairs(candidates) do
        if candidate.utilityEligible and candidate.kind == "CONTAINER" then
            subgroupMembers[candidate.kind .. ":" .. candidate.subgroup] = subgroupMembers[candidate.kind .. ":" .. candidate.subgroup] or {}
            table.insert(subgroupMembers[candidate.kind .. ":" .. candidate.subgroup], candidate)
            parentMembers[candidate.kind .. ":" .. candidate.parentGroup] = parentMembers[candidate.kind .. ":" .. candidate.parentGroup] or {}
            table.insert(parentMembers[candidate.kind .. ":" .. candidate.parentGroup], candidate)
        end
    end
    local groups = {}
    for _, candidate in ipairs(candidates) do
        if candidate.utilityEligible and candidate.kind == "CONTAINER" then
            local subgroupKey = candidate.kind .. ":" .. candidate.subgroup
            local parentKey = candidate.kind .. ":" .. candidate.parentGroup
            local subgroup = subgroupMembers[subgroupKey] or {}
            if countProfiles(subgroup) >= NORMALIZATION.minimumProfiles then
                candidate.normalizationGroup = subgroupKey
            else
                candidate.normalizationGroup = parentKey
            end
            local group = groups[candidate.normalizationGroup]
            if not group then
                group = {
                    members = {},
                    -- A subgroup that falls back must rank against all valid
                    -- members of its parent, not merely other small
                    -- subgroups that happened to fall back too.
                    references = candidate.normalizationGroup == parentKey and parentMembers[parentKey] or subgroup,
                }
                groups[candidate.normalizationGroup] = group
            end
            table.insert(group.members, candidate)
        end
    end
    return groups
end

local function countValid(candidate, weights)
    local count = 0
    for name in pairs(weights) do if candidate.metrics[name] ~= nil then count = count + 1 end end
    return count
end

local function essentialsPresent(candidate)
    for _, name in ipairs(candidate.config.essential) do
        if candidate.metrics[name] == nil then return false end
    end
    return true
end

local function scoreGroup(group)
    local members, references = group.members, group.references
    local profileRepresentatives = {}
    for _, candidate in ipairs(references) do
        if not profileRepresentatives[candidate.profile] then profileRepresentatives[candidate.profile] = candidate end
    end
    local representatives = {}
    for _, candidate in pairs(profileRepresentatives) do table.insert(representatives, candidate) end
    local profileCount = #representatives
    local weights = members[1].config.weights
    local metricRanks = {}

    for metricName in pairs(weights) do
        local values = {}
        for _, candidate in ipairs(representatives) do
            local value = candidate.metrics[metricName]
            if value ~= nil then table.insert(values, value) end
        end
        if #values > 0 then
            local sorted = sortedCopy(values)
            local low = quantile(sorted, NORMALIZATION.winsorLowPercentile)
            local high = quantile(sorted, NORMALIZATION.winsorHighPercentile)
            local adjusted = {}
            for _, value in ipairs(values) do table.insert(adjusted, clamp(value, low, high)) end
            metricRanks[metricName] = uniqueSorted(adjusted)
            for _, candidate in ipairs(members) do
                local value = candidate.metrics[metricName]
                if value ~= nil then
                    local bounded = clamp(value, low, high)
                    candidate.metricPercentiles = candidate.metricPercentiles or {}
                    candidate.metricPercentiles[metricName] = percentileRank(metricRanks[metricName], bounded, candidate.directions[metricName])
                end
            end
        end
    end

    for _, candidate in ipairs(members) do
        local numerator, denominator = 0, 0
        for metricName, weight in pairs(weights) do
            local percentile = candidate.metricPercentiles and candidate.metricPercentiles[metricName] or nil
            if percentile ~= nil then
                numerator = numerator + percentile * weight
                denominator = denominator + weight
            end
        end
        local validCount = countValid(candidate, weights)
        local essentials = essentialsPresent(candidate)
        local confidence = "LOW"
        if essentials and validCount >= NORMALIZATION.minimumValidAttributes and profileCount >= NORMALIZATION.minimumProfiles then
            confidence = "MEDIUM"
            if validCount >= NORMALIZATION.highConfidenceValidAttributes and profileCount >= NORMALIZATION.highConfidenceProfiles then confidence = "HIGH" end
        end
        candidate.utility = denominator > 0 and (numerator / denominator) or nil
        candidate.utilityConfidence = confidence
        candidate.profileCount = profileCount
        candidate.validAttributeCount = validCount
        candidate.essentialsPresent = essentials
        if not essentials then candidate.ineligibleReason = "missing essential Utility attribute" end
    end
end

local function scoreMeleeV2(candidates)
    local members, representativesByProfile = {}, {}
    for _, candidate in ipairs(candidates) do
        if candidate.utilityEligible and candidate.kind == "MELEE_WEAPON" then
            -- B42 runtime HandWeapon critical is the only critical input used
            -- by the active V2 mechanical profile.
            candidate.metrics.critical = candidate.metrics.runtimeCritical
            candidate.metricPercentiles = {}
            candidate.profile = profileKey(candidate.metrics, {
                "averageDamage", "attackTempo", "range", "critical", "durability", "multiHit", "weight", "endurance", "knockdown",
            })
            table.insert(members, candidate)
            if not representativesByProfile[candidate.profile] then representativesByProfile[candidate.profile] = candidate end
        end
    end
    local representatives = {}
    for _, candidate in pairs(representativesByProfile) do table.insert(representatives, candidate) end
    local profileCount = #representatives
    local metricDirections = {
        averageDamage = false, attackTempo = false, runtimeCritical = false, multiHit = false,
        strainProxy = true, weight = true, range = false, knockdown = false, durability = false,
    }
    for metric, inverted in pairs(metricDirections) do
        local values = {}
        for _, candidate in ipairs(representatives) do
            if candidate.metrics[metric] ~= nil then table.insert(values, candidate.metrics[metric]) end
        end
        if #values > 0 then
            local sorted = sortedCopy(values)
            local low = quantile(sorted, NORMALIZATION.winsorLowPercentile)
            local high = quantile(sorted, NORMALIZATION.winsorHighPercentile)
            local ranks, boundedValues = {}, {}
            for _, value in ipairs(values) do table.insert(boundedValues, clamp(value, low, high)) end
            ranks = uniqueSorted(boundedValues)
            for _, candidate in ipairs(members) do
                local value = candidate.metrics[metric]
                if value ~= nil then
                    candidate.metricPercentiles = candidate.metricPercentiles or {}
                    candidate.metricPercentiles[metric] = percentileRank(ranks, clamp(value, low, high), inverted)
                end
            end
        end
    end
    local weights = UTILITY.meleeWeapon.v2
    for _, candidate in ipairs(members) do
        local p = function(name) return candidate.metricPercentiles and candidate.metricPercentiles[name] or nil end
        local averageDamage, runtimeCritical, multiHit, attackTempo = p("averageDamage"), p("runtimeCritical"), p("multiHit"), p("attackTempo")
        local strainProxy, weight = p("strainProxy"), p("weight")
        local range, knockdown, durability = p("range"), p("knockdown"), p("durability")
        local valid = 0
        for _, value in ipairs({ averageDamage, runtimeCritical, multiHit, attackTempo, strainProxy, weight, range, knockdown, durability }) do
            if value ~= nil then valid = valid + 1 end
        end
        -- V2 has no neutral fabricated values: a melee profile must expose all
        -- modeled signals, including the runtime critical bridge, to score.
        local essentials = valid == 9
        if essentials then
            local offense = averageDamage * weights.offense.averageDamage + runtimeCritical * weights.offense.runtimeCritical
                + multiHit * weights.offense.multiHit + attackTempo * weights.offense.attackTempo
            local efficiency = strainProxy * weights.efficiency.strainProxy + weight * weights.efficiency.weight
            local control = range * weights.control.range + knockdown * weights.control.knockdown
            local reliability = durability
            local penalty = math.max(0, weights.softBalance.threshold - math.min(efficiency, reliability)) * weights.softBalance.factor
            candidate.utility = offense * weights.architecture.offense + efficiency * weights.architecture.efficiency
                + control * weights.architecture.control + reliability * weights.architecture.reliability - penalty
            candidate.utilityComponents = { offense = offense, efficiency = efficiency, control = control, reliability = reliability, softBalancePenalty = penalty }
        else
            candidate.utility = nil
            candidate.ineligibleReason = "V2 missing runtime melee attribute"
        end
        candidate.utilityConfidence = essentials and valid >= NORMALIZATION.highConfidenceValidAttributes and profileCount >= NORMALIZATION.highConfidenceProfiles
            and "HIGH" or (essentials and valid >= NORMALIZATION.minimumValidAttributes and profileCount >= NORMALIZATION.minimumProfiles and "MEDIUM" or "LOW")
        candidate.profileCount = profileCount
        candidate.validAttributeCount = valid
        candidate.essentialsPresent = essentials
        candidate.normalizationGroup = "MELEE_WEAPON:V2_GLOBAL"
        candidate.utilityScoreVersion = UTILITY.meleeWeapon.utilityVersion
    end
end

local function clothingNormalizationGroup(candidate, candidates)
    local references = {}
    for _, other in ipairs(candidates) do
        if other.clothingUtilityCandidate and other.functionalGroup == candidate.functionalGroup then table.insert(references, other) end
    end
    local group = candidate.functionalGroup or "GENERAL_CLOTHING"
    if countProfiles(references) >= NORMALIZATION.minimumProfiles then return "CLOTHING_FUNCTION:" .. group, references, "FUNCTIONAL_GROUP" end
    -- CORE_ACCESSORY is intentionally allowed to borrow the former general
    -- clothing parent only when its own observed sample is small.  Its native
    -- sample count is retained and later caps confidence, so the fallback
    -- never manufactures a HIGH-confidence local percentile.
    if group == "CORE_ACCESSORY" then
        local parent = {}
        local parentGroups = { TORSO_LAYER = true, LOWER_BODY_LAYER = true, CORE_ACCESSORY = true }
        for _, other in ipairs(candidates) do
            if other.clothingUtilityCandidate and parentGroups[other.functionalGroup] then table.insert(parent, other) end
        end
        if countProfiles(parent) >= NORMALIZATION.minimumProfiles then
            return "CLOTHING_FUNCTION:GENERAL_LAYER_PARENT", parent, "PARENT_FALLBACK_SMALL_CORE_ACCESSORY"
        end
    end
    -- Do not borrow samples from another role just to create a flattering
    -- percentile.  A small slot role remains comparable only to itself and
    -- therefore stays LOW confidence until real profiles are available.
    return "CLOTHING_FUNCTION:" .. group .. ":SMALL_GROUP", references, "SMALL_FUNCTIONAL_GROUP"
end

local function clothingMetricRanks(references, metric, inverted)
    local representatives, values = {}, {}
    for _, candidate in ipairs(references) do
        if not representatives[candidate.profile] then representatives[candidate.profile] = candidate end
    end
    for _, candidate in pairs(representatives) do
        local value = candidate.metrics[metric]
        if value ~= nil then table.insert(values, value) end
    end
    if #values == 0 then return nil, nil, nil end
    local sorted = sortedCopy(values)
    local low, high = quantile(sorted, NORMALIZATION.winsorLowPercentile), quantile(sorted, NORMALIZATION.winsorHighPercentile)
    local bounded = {}
    for _, value in ipairs(values) do table.insert(bounded, clamp(value, low, high)) end
    return uniqueSorted(bounded), low, high
end

local function clothingUtilityPercentileOfValue(sortedValues, value)
    if #sortedValues == 0 or value == nil then return nil end
    local first, last = nil, nil
    for index, candidate in ipairs(sortedValues) do
        if candidate == value then first = first or index; last = index end
    end
    if not first then return nil end
    return #sortedValues == 1 and 50 or ((first + last - 2) / (2 * (#sortedValues - 1))) * 100
end

local function clothingGlobalRobustScales(candidates, metricNames)
    local representatives, scales = {}, {}
    for _, candidate in ipairs(candidates) do
        if not representatives[candidate.profile] then representatives[candidate.profile] = candidate end
    end
    for _, metric in ipairs(metricNames) do
        local values = {}
        for _, candidate in pairs(representatives) do
            local value = candidate.metrics[metric]
            if value ~= nil then table.insert(values, value) end
        end
        if #values > 0 then
            local sorted = sortedCopy(values)
            scales[metric] = { low = quantile(sorted, NORMALIZATION.winsorLowPercentile), high = quantile(sorted, NORMALIZATION.winsorHighPercentile) }
        end
    end
    return scales
end

local function globalRobustScale(value, scale)
    if value == nil or not scale then return nil end
    if scale.high <= scale.low then return 50 end
    return clamp((clamp(value, scale.low, scale.high) - scale.low) / (scale.high - scale.low) * 100, 0, 100)
end

local ANATOMICAL_COVERAGE_MODELS = {
    B_MODERATE = {
        HEAD = 1.30, NECK = 1.25, TORSO_UPPER = 1.20, TORSO_LOWER = 1.10, GROIN = 1.00,
        UPPER_ARM = 0.85, FOREARM = 0.80, HAND = 0.70, THIGH = 0.80, SHIN = 0.75, FOOT = 0.65,
    },
}

local function anatomicalWeightTotal(regions, weights)
    if not regions or #regions == 0 then return nil end
    local total = 0
    for _, region in ipairs(regions) do total = total + (weights[region] or 0) end
    return total > 0 and total or nil
end

local function anatomicalModelMaximum(clothing, weights)
    local maximum = 0
    for _, data in ipairs(clothing) do
        local total = anatomicalWeightTotal(data.clothingDiscovery and data.clothingDiscovery.coveredRegions, weights)
        if total and total > maximum then maximum = total end
    end
    return maximum > 0 and maximum or nil
end

-- Kept in its own function because Build 42's Lua compiler has a hard cap of
-- 200 locals per function. This is report-only sensitivity analysis: it never
-- writes a candidate field or changes the active tier path.
-- Historical anatomical A/B/C report moved to Diagnostics/ClothingHistoricalExperiments.

-- Experimental report only. The base ClothingUtility remains unchanged: these
-- scenarios expose a separate functional-cost axis rather than retuning any
-- active benefit weight.
-- Historical functional-cost report moved to Diagnostics/ClothingHistoricalExperiments.
local function assignFunctionalCoverageFactors(clothing)
    local weights = ANATOMICAL_COVERAGE_MODELS.B_MODERATE
    local maximum = anatomicalModelMaximum(clothing, weights)
    for _, candidate in ipairs(clothing) do
        local total = anatomicalWeightTotal(candidate.clothingDiscovery and candidate.clothingDiscovery.coveredRegions, weights)
        candidate.anatomicalCoverageTotal = total
        candidate.functionalCoverageFactor = total and maximum and (UTILITY.clothing.coverage.minimumFactor
            + (UTILITY.clothing.coverage.maximumFactor - UTILITY.clothing.coverage.minimumFactor) * total / maximum) or nil
    end
end

local function clothingProgressiveLoss(loss, freeLoss)
    local excess = math.max(0, loss - freeLoss)
    if excess == 0 then return 0 end
    return clamp(100 * ((excess / math.max(1, 100 - freeLoss)) ^ .72), 0, 100)
end

local function assignClothingMechanicalBaseBenefit(clothing)
    local scales = clothingGlobalRobustScales(clothing, { "durability", "insulation", "windResistance", "waterResistance" })
    for _, candidate in ipairs(clothing) do
        local m = candidate.metrics or {}
        local coreKnown = m.biteDefense ~= nil and m.scratchDefense ~= nil and m.bulletDefense ~= nil
            and m.insulation ~= nil and m.windResistance ~= nil and m.waterResistance ~= nil
        local rawProtection = ((clamp(m.biteDefense or 0, 0, 100) * .50) + (clamp(m.scratchDefense or 0, 0, 100) * .35)
            + (clamp(m.bulletDefense or 0, 0, 100) * .15)) * clamp(candidate.functionalCoverageFactor or .70, 0, 1)
        local insulation = globalRobustScale(m.insulation, scales.insulation) or 0
        local wind = globalRobustScale(m.windResistance, scales.windResistance) or 0
        local water = globalRobustScale(m.waterResistance, scales.waterResistance) or 0
        local weather = insulation * .40 + wind * .35 + water * .25
        local durability = globalRobustScale(m.durability, scales.durability) or 0
        candidate.mechanicalBaseBenefit = rawProtection * .85 + weather * .15
        candidate.mechanicalDurabilityFactor = .75 + .25 * durability / 100
        candidate.mechanicalAttributesKnown = coreKnown
    end
end

local function assignClothingMechanicalValueStatus(candidates)
    for _, candidate in ipairs(candidates) do
        if candidate.clothingUtilityCandidate then
            local m = candidate.metrics or {}
            local direct = candidate.utilityComponents and candidate.utilityComponents.directSlot or {}
            local combatLoss = clamp((1 - (m.combatSpeedModifier or 1)) * 100, 0, 100)
            local runLoss = clamp((1 - (m.runSpeedModifier or 1)) * 100, 0, 100)
            local discomfort = clamp((m.discomfortModifier or 0) * 100, 0, 100)
            local visionLoss = clamp((1 - (m.visionModifier or 1)) * 100, 0, 100)
            local hearingLoss = clamp((1 - (m.hearingModifier or 1)) * 100, 0, 100)
            local weightLoss = 100 - (direct.weight or 50)
            local costIndex = clothingProgressiveLoss(combatLoss, 1) * .30 + clothingProgressiveLoss(runLoss, 1) * .25
                + clothingProgressiveLoss(visionLoss, 1) * .15 + clothingProgressiveLoss(hearingLoss, 1) * .15
                + clothingProgressiveLoss(discomfort, 2) * .10 + clothingProgressiveLoss(weightLoss, 15) * .05
            local excess = math.max(0, costIndex - 7)
            candidate.mechanicalFunctionalCost = excess == 0 and 0 or (excess ^ 1.28) / 5.5
            candidate.mechanicalValue = math.max(0, (candidate.mechanicalBaseBenefit or 0) * (candidate.mechanicalDurabilityFactor or .75) - candidate.mechanicalFunctionalCost)
            if candidate.mechanicalSpecialBehavior or not candidate.mechanicalAttributesKnown then
                candidate.mechanicalValueStatus = "MECHANICAL_VALUE_PARTIAL"
            elseif (candidate.mechanicalBaseBenefit or 0) <= .01 then
                candidate.mechanicalValueStatus = "MECHANICALLY_TRIVIAL"
            else
                candidate.mechanicalValueStatus = "MECHANICAL_VALUE_KNOWN"
            end
        end
    end
end

local function scoreClothingUtility(candidates)
    local clothing = {}
    for _, candidate in ipairs(candidates) do if candidate.clothingUtilityCandidate then table.insert(clothing, candidate) end end
    assignFunctionalCoverageFactors(clothing)
    assignClothingMechanicalBaseBenefit(clothing)
    local grouped = {}
    for _, candidate in ipairs(clothing) do
        local groupKey, references, groupMode = clothingNormalizationGroup(candidate, clothing)
        local nativeReferences = {}
        for _, other in ipairs(clothing) do
            if other.functionalGroup == candidate.functionalGroup then table.insert(nativeReferences, other) end
        end
        candidate.normalizationGroup = groupKey
        candidate.clothingNormalizationMode = groupMode
        candidate.functionalComparisonGroup = groupKey
        candidate.functionalNativeProfileCount = countProfiles(nativeReferences)
        candidate.functionalComparisonProfileCount = countProfiles(references)
        grouped[groupKey] = grouped[groupKey] or { members = {}, references = references }
        table.insert(grouped[groupKey].members, candidate)
    end
    local config = UTILITY.clothing
    -- Bite/scratch/bullet are explicit game percentages and must retain an
    -- absolute shared scale. Ranking them only within FULL_BODY would make a
    -- lightly protective Hazmat appear equivalent to real armor just because
    -- most full-body garments have zero defense.
    local physicalScales = clothingGlobalRobustScales(clothing, { "biteDefense", "scratchDefense", "bulletDefense" })
    -- DIRECT_SLOT independently ranks defense, mobility, durability and cost.
    -- This preparatory pass supplies only weather normalized within the same
    -- structural reference group, plus the shared protection inputs below.
    local rankedMetrics = { "insulation", "windResistance", "waterResistance" }
    for _, group in pairs(grouped) do
        local ranks = {}
        for _, metric in ipairs(rankedMetrics) do
            local values, low, high = clothingMetricRanks(group.references, metric, false)
            ranks[metric] = { values = values, low = low, high = high }
        end
        group.ranks = ranks
        for _, candidate in ipairs(group.members) do
            candidate.metricPercentiles = {}
            for _, metric in ipairs(rankedMetrics) do
                local rank = ranks[metric]
                local raw = candidate.metrics[metric]
                if raw ~= nil and rank.values then
                    candidate.metricPercentiles[metric] = percentileRank(rank.values, clamp(raw, rank.low, rank.high), false)
                end
            end
            local p = function(name) return candidate.metricPercentiles[name] end
            local bite = globalRobustScale(candidate.metrics.biteDefense, physicalScales.biteDefense)
            local scratch = globalRobustScale(candidate.metrics.scratchDefense, physicalScales.scratchDefense)
            local bullet = globalRobustScale(candidate.metrics.bulletDefense, physicalScales.bulletDefense)
            local run, combat = candidate.metrics.runSpeedModifier, candidate.metrics.combatSpeedModifier
            local weight, durability = candidate.metrics.weight, candidate.metrics.durability
            local insulation, wind, water = p("insulation"), p("windResistance"), p("waterResistance")
            local protectionBase = bite and scratch and bullet and (bite * config.protection.biteDefense + scratch * config.protection.scratchDefense + bullet * config.protection.bulletDefense) or nil
            -- Coverage is a bounded multiplier of actual physical protection,
            -- not a standalone score. Broad low-defense clothing cannot beat
            -- a narrow highly protective item purely by covering more zones.
            local coverageFactor = candidate.functionalCoverageFactor
            local protectionCoverage = protectionBase and coverageFactor and protectionBase * coverageFactor or nil
            local weather = insulation and wind and water and (insulation * config.weather.insulation + wind * config.weather.windResistance + water * config.weather.waterResistance) or nil
            -- Preserve the exact completeness requirement of the former
            -- global score. Its aggregate Utility was retired; DIRECT_SLOT
            -- consumes these shared raw inputs and owns the active score.
            if protectionCoverage and run and combat and weight and durability and weather then
                candidate.utilityComponents = { protectionCoverage = protectionCoverage, protectionBase = protectionBase, coverageFactor = coverageFactor,
                    weatherProtection = weather }
            else
                candidate.utilityComponents = nil
            end
        end
    end
end

-- Active ClothingUtility V1.  This is deliberately based on exact resolved
-- BodyLocation alternatives, not a global clothing universe.  The weights and
-- P2 protection component are the frozen values validated by the reports.
local function clothingDirectSlotV1Role(candidate)
    local graph = candidate.equipmentGraph or {}
    local regions = candidate.clothingDiscovery and candidate.clothingDiscovery.coveredRegions or {}
    local conflictsCuirass = false
    for _, excluded in ipairs(graph.exclusive or {}) do
        if string.lower(tostring(excluded)) == "base:cuirass" then conflictsCuirass = true break end
    end
    local slotId = string.lower(tostring(graph.slotId or ""))
    local shoulderSlot = string.find(slotId, "shoulderpad", 1, true) ~= nil
    if graph.resolved and slotId ~= "base:cuirass" and not conflictsCuirass
        and (hasOnlyAccessoryRegions(regionSet(regions)) or shoulderSlot) then
        return "ARMOR_ACCESSORY"
    end
    return candidate.functionalGroup or "GENERAL_UNRESOLVED"
end

local function clothingDirectSlotV1Weights(role)
    if role == "HEADGEAR" then return { protection=.40, coverage=.06, durability=.08, mobility=.04, weight=.05, discomfort=.10, senses=.22, weather=.05 } end
    if role == "FOOTWEAR" then return { protection=.22, coverage=.06, durability=.14, mobility=.22, weight=.13, discomfort=.13, senses=0, weather=.10 } end
    if role == "PRIMARY_ARMOR" then return { protection=.46, coverage=.12, durability=.10, mobility=.10, weight=.07, discomfort=.11, senses=0, weather=.04 } end
    if role == "ARMOR_ACCESSORY" or role == "CORE_ACCESSORY" then return { protection=.44, coverage=.18, durability=.10, mobility=.07, weight=.08, discomfort=.10, senses=0, weather=.03 } end
    if role == "FULL_BODY_RESTRICTIVE" then return { protection=.33, coverage=.20, durability=.10, mobility=.13, weight=.07, discomfort=.09, senses=.04, weather=.04 } end
    if role == "LOWER_BODY_LAYER" then return { protection=.34, coverage=.12, durability=.12, mobility=.15, weight=.10, discomfort=.10, senses=.02, weather=.05 } end
    return { protection=.36, coverage=.12, durability=.10, mobility=.15, weight=.09, discomfort=.10, senses=.05, weather=.03 }
end

local function scoreClothingDirectSlotV1(candidates)
    local slots, entries = {}, {}
    local function ranker(records, field, inverted)
        local seen, values = {}, {}
        for _, record in ipairs(records) do
            local value = record.values[field]
            if not seen[record.candidate.profile] and value ~= nil then seen[record.candidate.profile] = true; table.insert(values, value) end
        end
        values = sortedCopy(values)
        return function(record) return record.values[field] ~= nil and percentileRank(values, record.values[field], inverted) or nil end
    end
    for _, candidate in ipairs(candidates) do
        local graph, metrics, parts = candidate.equipmentGraph, candidate.metrics or {}, candidate.utilityComponents or {}
        if candidate.clothingUtilityCandidate and graph and graph.resolved and candidate.profile and parts.protectionCoverage ~= nil then
            local run, combat = metrics.runSpeedModifier, metrics.combatSpeedModifier
            local vision, hearing = metrics.visionModifier, metrics.hearingModifier
            local values = {
                protection = parts.protectionCoverage,
                coverage = parts.coverageFactor and parts.coverageFactor * 100 or nil,
                durability = metrics.durability,
                mobility = run ~= nil and combat ~= nil and (run * .70 + combat * .30) or nil,
                weight = metrics.weight,
                discomfort = metrics.discomfortModifier,
                senses = vision ~= nil and hearing ~= nil and (vision + hearing) * .50 or nil,
                weather = parts.weatherProtection,
            }
            local valid = 0
            for _, value in pairs(values) do if value ~= nil then valid = valid + 1 end end
            local record = { candidate=candidate, values=values, valid=valid, role=clothingDirectSlotV1Role(candidate) }
            record.utilityConfidence = valid >= 8 and "HIGH" or (valid >= 6 and "MEDIUM" or "LOW")
            local slotId = graph.slotId
            slots[slotId] = slots[slotId] or { records={}, role=record.role }
            table.insert(slots[slotId].records, record)
        end
    end
    for _, slot in pairs(slots) do
        local ranks = {
            protection=ranker(slot.records, "protection", false), coverage=ranker(slot.records, "coverage", false),
            durability=ranker(slot.records, "durability", false), mobility=ranker(slot.records, "mobility", false),
            weight=ranker(slot.records, "weight", true), discomfort=ranker(slot.records, "discomfort", true),
            senses=ranker(slot.records, "senses", false), weather=ranker(slot.records, "weather", false),
        }
        local representatives, profileCount = {}, 0
        for _, record in ipairs(slot.records) do
            if not representatives[record.candidate.profile] then representatives[record.candidate.profile] = record; profileCount = profileCount + 1 end
        end
        slot.profileCount = profileCount
        slot.rankingConfidence = profileCount >= 20 and "HIGH" or (profileCount >= 8 and "MEDIUM" or "LOW")
        local weights = clothingDirectSlotV1Weights(slot.role)
        for _, record in pairs(representatives) do
            local components = {}
            for field, getter in pairs(ranks) do components[field] = getter(record) or 50 end
            local metrics, parts = record.candidate.metrics, record.candidate.utilityComponents
            local absolute = ((clamp(metrics.biteDefense or 0, 0, 100) * .50) + (clamp(metrics.scratchDefense or 0, 0, 100) * .35)
                + (clamp(metrics.bulletDefense or 0, 0, 100) * .15)) * clamp(parts.coverageFactor or 1, 0, 1)
            components.relativeProtection = components.protection
            components.absoluteProtection = absolute
            components.protection = components.relativeProtection * .40 + components.absoluteProtection * .60
            record.quality = components.protection * weights.protection + components.coverage * weights.coverage + components.durability * weights.durability
                + components.mobility * weights.mobility + components.weight * weights.weight + components.discomfort * weights.discomfort
                + components.senses * weights.senses + components.weather * weights.weather
            record.components = components
            table.insert(entries, record)
        end
        local ordered, scores = {}, {}
        for _, record in pairs(representatives) do table.insert(ordered, record); table.insert(scores, record.quality) end
        table.sort(ordered, function(a, b) return a.quality > b.quality end)
        scores = sortedCopy(scores)
        for rank, representative in ipairs(ordered) do
            local percentile = clothingUtilityPercentileOfValue(scores, representative.quality) or 50
            for _, record in ipairs(slot.records) do
                if record.candidate.profile == representative.candidate.profile then
                    local candidate = record.candidate
                    candidate.utilityEligible = representative.quality ~= nil
                    candidate.utility = representative.quality
                    candidate.utilityConfidence = representative.utilityConfidence
                    candidate.profileCount = slot.profileCount
                    candidate.validAttributeCount = representative.valid
                    candidate.directSlotFunctionalGroup = representative.role
                    candidate.clothingUtilityPercentile = percentile
                    candidate.slotQualityPercentile = percentile
                    candidate.slotQualityRank = rank
                    candidate.slotRankingConfidence = slot.rankingConfidence
                    candidate.utilityScoreVersion = "CLOTHING_V1_P2_DIRECT_SLOT"
                    candidate.utilityComponents = candidate.utilityComponents or {}
                    candidate.utilityComponents.relativeProtection = representative.components.relativeProtection
                    candidate.utilityComponents.absoluteProtection = representative.components.absoluteProtection
                    candidate.utilityComponents.protectionComponent = representative.components.protection
                    candidate.utilityComponents.directSlot = representative.components
                    if candidate.utilityConfidence == "LOW" then candidate.ineligibleReason = "ClothingUtility V1 incomplete intrinsic runtime attributes; visual ceiling RARE"
                    else candidate.ineligibleReason = nil end
                end
            end
        end
    end
    -- Frozen from the approved Balanced P2 calibration for this loaded B42
    -- dataset.  Do not silently re-derive the cuts from a different internal
    -- population than the diagnostic calibration report.
    local balanced = { good=53.64, excellent=61.28, slotConfirm=70 }
    for _, candidate in ipairs(candidates) do if candidate.clothingUtilityCandidate then candidate.clothingBalancedThresholds = balanced end end
end

local function utilitySupportStatus(candidate)
    if candidate.utilitySupport then return candidate.utilitySupport end
    if candidate.clothingUtilityCandidate then
        if candidate.utility == nil or candidate.utilityConfidence == "LOW" then return "UTILITY_LOW_CONFIDENCE" end
        return "UTILITY_SUPPORTED"
    end
    if not candidate.utilityEligible then return "UTILITY_UNSUPPORTED" end
    if candidate.utility == nil or candidate.utilityConfidence == "LOW" then return "UTILITY_LOW_CONFIDENCE" end
    return "UTILITY_SUPPORTED"
end

local function publishCandidateFields(candidates)
    for _, candidate in ipairs(candidates) do
        local data = candidate.data
        data.utilityKind = candidate.kind
        data.utilitySubgroup = candidate.subgroup
        data.utilityFunctionalGroup = candidate.functionalGroup
        data.utilityFunctionalGroupReason = candidate.functionalGroupReason
        data.utilityPriorFunctionalGroup = candidate.priorFunctionalGroup
        data.utilityFunctionalComparisonGroup = candidate.functionalComparisonGroup
        data.utilityFunctionalNativeProfileCount = candidate.functionalNativeProfileCount
        data.utilityFunctionalComparisonProfileCount = candidate.functionalComparisonProfileCount
        data.utilityProfile = candidate.profile
        data.utilityEligible = candidate.utilityEligible == true
        data.utility = candidate.utility and round(candidate.utility) or nil
        data.utilityConfidence = candidate.utilityConfidence or "NONE"
        data.utilityProfileCount = candidate.profileCount or 0
        data.utilityValidAttributeCount = candidate.validAttributeCount or 0
        data.utilityMetrics = candidate.metrics
        data.utilityMetricPercentiles = candidate.metricPercentiles
        data.utilityComponents = candidate.utilityComponents
        data.utilityNormalizationGroup = candidate.normalizationGroup
        data.utilityScoreVersion = candidate.utilityScoreVersion or "V1_LEGACY"
        data.utilitySupport = utilitySupportStatus(candidate)
        data.clothingDiscovery = candidate.clothingDiscovery
        data.clothingUtilityPercentile = candidate.clothingUtilityPercentile
        data.clothingDirectSlotFunction = candidate.directSlotFunctionalGroup
        data.slotQualityPercentile = candidate.slotQualityPercentile
        data.slotQualityRank = candidate.slotQualityRank
        data.slotRankingConfidence = candidate.slotRankingConfidence
        data.clothingBalancedThresholds = candidate.clothingBalancedThresholds
        data.clothingEquipmentGraph = candidate.equipmentGraph
        data.clothingMechanicalValue = candidate.mechanicalValue
        data.clothingMechanicalValueStatus = candidate.mechanicalValueStatus
        data.clothingMechanicalBaseBenefit = candidate.mechanicalBaseBenefit
        data.clothingMechanicalDurabilityFactor = candidate.mechanicalDurabilityFactor
        data.clothingMechanicalFunctionalCost = candidate.mechanicalFunctionalCost
        data.clothingMechanicalSpecialReason = candidate.mechanicalSpecialReason
    end
end

-- Declared ahead of the active calculator so the proven Scarcity × Utility
-- matrix can be shared by diagnostics and the runtime FinalRarityTier path.
local matrixTierFromAxes

local function applyTierAdjustment(data, candidate)
    data.baseScarcityTier = data.rarityTier
    data.finalRarityTier = data.rarityTier
    data.utilityEligible = candidate.utilityEligible == true
    data.utilitySubgroup = candidate.subgroup
    data.utilityFunctionalGroup = candidate.functionalGroup
    data.utilityPriorFunctionalGroup = candidate.priorFunctionalGroup
    data.utilityFunctionalComparisonGroup = candidate.functionalComparisonGroup
    data.utilityFunctionalNativeProfileCount = candidate.functionalNativeProfileCount
    data.utilityFunctionalComparisonProfileCount = candidate.functionalComparisonProfileCount
    data.utilityNormalizationGroup = candidate.normalizationGroup
    data.utility = candidate.utility and round(candidate.utility) or nil
    data.utilityConfidence = candidate.utilityConfidence or "NONE"
    data.utilityProfileCount = candidate.profileCount or 0
    data.utilityValidAttributeCount = candidate.validAttributeCount or 0
    data.utilityMetrics = candidate.metrics
    data.utilityMetricPercentiles = candidate.metricPercentiles
    data.utilityProfile = candidate.profile
    data.utilityKind = candidate.kind
    data.utilitySupport = utilitySupportStatus(candidate)
    data.clothingDirectSlotFunction = candidate.directSlotFunctionalGroup
    data.slotQualityPercentile = candidate.slotQualityPercentile
    data.slotQualityRank = candidate.slotQualityRank
    data.slotRankingConfidence = candidate.slotRankingConfidence
    data.clothingBalancedThresholds = candidate.clothingBalancedThresholds
    data.clothingDiscovery = candidate.clothingDiscovery
    data.clothingUtilityPercentile = candidate.clothingUtilityPercentile
    data.utilityAdjustmentReason = candidate.ineligibleReason or "no eligible Utility data"

    -- Scarcity is an internal potential, never a visual EPIC/EXOTIC grant by
    -- itself. Any unsupported, missing, or unreliable Utility may retain its
    -- base tier only up to RARE; this is category-agnostic and has no item
    -- name/module exception.
    if not candidate.utilityEligible or candidate.utility == nil
        or not confidenceAtLeast(candidate.utilityConfidence, UTILITY.minimumConfidenceForAdjustment) then
        if data.baseScarcityTier == "EPIC" or data.baseScarcityTier == "EXOTIC" then data.finalRarityTier = "RARE" end
        data.utilityAdjustmentReason = "no eligible/reliable Utility; visual ceiling RARE"
        if candidate.kind == "CLOTHING" then
            data.clothingMechanicalTierBeforeCap = data.finalRarityTier
            if candidate.mechanicalValueStatus == "MECHANICALLY_TRIVIAL" and (TIER_INDEX[data.finalRarityTier] or 1) > TIER_INDEX.UNCOMMON then
                data.finalRarityTier = "UNCOMMON"
                data.utilityAdjustmentReason = "Clothing MechanicalValue: trivial known benefit; visual ceiling UNCOMMON"
            end
        end
        return
    end

    local baseIndex = TIER_INDEX[data.baseScarcityTier]
    if not baseIndex then return end

    if candidate.kind == "CLOTHING" then
        local thresholds = candidate.clothingBalancedThresholds
        local slotPercentile = candidate.slotQualityPercentile or 0
        local confirmed = candidate.slotRankingConfidence == "LOW" or slotPercentile >= (thresholds and thresholds.slotConfirm or 70)
        if candidate.utilityConfidence == "LOW" then
            data.finalRarityTier = "RARE"
            data.utilityAdjustmentReason = "ClothingUtility V1 low intrinsic confidence; visual ceiling RARE"
        elseif not thresholds then
            data.utilityAdjustmentReason = "ClothingUtility V1 thresholds unavailable"
        elseif data.baseScarcityTier == "COMMON" then
            data.finalRarityTier = candidate.utility >= thresholds.good and confirmed and "UNCOMMON" or "COMMON"
            data.utilityAdjustmentReason = "ClothingUtility V1 Balanced: COMMON promotion capped at +1"
        elseif data.baseScarcityTier == "UNCOMMON" then
            data.finalRarityTier = candidate.utility >= thresholds.good and confirmed and "RARE" or "UNCOMMON"
            data.utilityAdjustmentReason = "ClothingUtility V1 Balanced: UNCOMMON promotion capped at +1"
        elseif candidate.utility < thresholds.good then
            data.finalRarityTier = "RARE"
            data.utilityAdjustmentReason = "ClothingUtility V1 Balanced: Scarcity without good DIRECT_SLOT quality"
        elseif data.baseScarcityTier == "RARE" then
            data.finalRarityTier = candidate.utility >= thresholds.excellent and confirmed and "EPIC" or "RARE"
            data.utilityAdjustmentReason = "ClothingUtility V1 Balanced: RARE requires excellent confirmed DIRECT_SLOT quality for EPIC"
        else
            data.finalRarityTier = candidate.utility >= thresholds.excellent and confirmed and candidate.utilityConfidence == "HIGH" and "EXOTIC" or "EPIC"
            data.utilityAdjustmentReason = "ClothingUtility V1 Balanced: Scarcity plus DIRECT_SLOT quality"
        end
        data.clothingMechanicalTierBeforeCap = data.finalRarityTier
        if candidate.mechanicalValueStatus == "MECHANICALLY_TRIVIAL" and (TIER_INDEX[data.finalRarityTier] or 1) > TIER_INDEX.UNCOMMON then
            data.finalRarityTier = "UNCOMMON"
            data.utilityAdjustmentReason = "Clothing MechanicalValue: trivial known benefit; visual ceiling UNCOMMON"
        end
        return
    end

    if candidate.kind == "MELEE_WEAPON" then
        -- WeaponUtility V2 supplies `utility` and the all-melee percentile.
        -- The frozen matrix, rather than the retired hybrid rank gate, owns
        -- the visual FinalRarityTier for eligible melee weapons.
        local tier, reason = matrixTierFromAxes(data, data.utilityPercentile, { p70=70, p80=80, p90=90, p95=95 })
        data.finalRarityTier = tier
        data.utilityAdjustmentReason = reason
        return
    end

    local scarcity = 100 - (data.tableAvailability.routeWeightedPercentile or 100)
    local promotionThreshold = candidate.kind == "CONTAINER" and UTILITY.container.promotionThreshold or UTILITY.promotionThreshold
    if candidate.utility >= promotionThreshold then
        if data.baseScarcityTier == "EPIC" then
            if scarcity >= UTILITY.exoticMinimumScarcity
                and candidate.utility >= UTILITY.exoticUtilityThreshold
                and confidenceAtLeast(candidate.utilityConfidence, UTILITY.exoticMinimumConfidence) then
                data.finalRarityTier = "EXOTIC"
                data.utilityAdjustmentReason = "promoted: high scarcity, exceptional Utility, high confidence"
            else
                data.utilityAdjustmentReason = "promotion gate: EXOTIC requires higher scarcity, Utility and confidence"
            end
        elseif baseIndex < #TIER_STRENGTH then
            data.finalRarityTier = TIER_STRENGTH[baseIndex + 1]
            data.utilityAdjustmentReason = "promoted: Utility >= " .. tostring(promotionThreshold)
        else
            data.utilityAdjustmentReason = "already EXOTIC"
        end
    elseif candidate.utility <= UTILITY.demotionThreshold then
        if baseIndex > 1 then
            data.finalRarityTier = TIER_STRENGTH[baseIndex - 1]
            data.utilityAdjustmentReason = "demoted: Utility <= " .. tostring(UTILITY.demotionThreshold)
        else
            data.utilityAdjustmentReason = "already COMMON"
        end
    else
        data.utilityAdjustmentReason = "Utility between adjustment thresholds"
    end
end

local function countUniqueProfiles(items)
    local profiles = {}
    for _, data in ipairs(items) do
        if data.utilityProfile then profiles[data.utilityProfile] = true end
    end
    local count = 0
    for _ in pairs(profiles) do count = count + 1 end
    return count
end

local function uniqueProfileUtilities(items)
    local profiles = {}
    for _, data in ipairs(items) do
        if data.utilityProfile and data.utility ~= nil and not profiles[data.utilityProfile] then
            profiles[data.utilityProfile] = data.utility
        end
    end
    local values = {}
    for _, utility in pairs(profiles) do table.insert(values, utility) end
    return sortedCopy(values)
end

local function percentileOfValue(sortedValues, value)
    if #sortedValues == 0 or value == nil then return nil end
    local first, last = nil, nil
    for index, candidate in ipairs(sortedValues) do
        if candidate == value then first = first or index; last = index end
    end
    if not first then return nil end
    return #sortedValues == 1 and 50 or ((first + last - 2) / (2 * (#sortedValues - 1))) * 100
end

local function appendGroup(groups, name, data)
    groups[name] = groups[name] or {}
    table.insert(groups[name], data)
end

local function buildCalibrationGroups(results)
    local groups = {}
    for _, data in pairs(results) do
        if data.utilityEligible and data.utility ~= nil then
            if data.utilityKind == "CONTAINER" then
                appendGroup(groups, data.utilitySubgroup, data)
            elseif data.utilityKind == "MELEE_WEAPON" then
                appendGroup(groups, "MELEE_WEAPON", data)
                appendGroup(groups, data.utilitySubgroup, data)
            end
        end
    end
    return groups
end

local function writeUtilityDistribution(writer, name, items)
    local values = uniqueProfileUtilities(items)
    if #values == 0 then
        writer:write(name .. " | no eligible profiles\n")
        return
    end
    local percentiles = { 5, 10, 20, 25, 50, 60, 70, 75, 80, 85, 90, 95 }
    local parts = { string.format("%s | items=%d | profiles=%d | min=%.2f", name, #items, #values, values[1]) }
    for _, percentile in ipairs(percentiles) do table.insert(parts, string.format("p%d=%.2f", percentile, quantile(values, percentile))) end
    table.insert(parts, string.format("max=%.2f", values[#values]))
    writer:write(table.concat(parts, " | ") .. "\n")
end

local function simulatedTier(data, promotionThreshold, demotionThreshold)
    local base = data.baseScarcityTier
    if not data.utilityEligible or data.utility == nil or not confidenceAtLeast(data.utilityConfidence, UTILITY.minimumConfidenceForAdjustment) then return base end
    local index = TIER_INDEX[base]
    if data.utility >= promotionThreshold then
        if base == "EPIC" then
            local scarcity = 100 - (data.tableAvailability.routeWeightedPercentile or 100)
            if scarcity >= UTILITY.exoticMinimumScarcity and data.utility >= UTILITY.exoticUtilityThreshold
                and confidenceAtLeast(data.utilityConfidence, UTILITY.exoticMinimumConfidence) then return "EXOTIC" end
        elseif index and index < #TIER_STRENGTH then
            return TIER_STRENGTH[index + 1]
        end
    elseif data.utility <= demotionThreshold and index and index > 1 then
        return TIER_STRENGTH[index - 1]
    end
    return base
end

local function tallyThreshold(items, threshold, demotionThreshold)
    local tally = { total = 0, vanilla = 0, modded = 0, paths = {} }
    for _, data in ipairs(items) do
        local final = simulatedTier(data, threshold, demotionThreshold)
        if final ~= data.baseScarcityTier and (TIER_INDEX[final] or 0) > (TIER_INDEX[data.baseScarcityTier] or 0) then
            tally.total = tally.total + 1
            if data.module == "Base" then tally.vanilla = tally.vanilla + 1 else tally.modded = tally.modded + 1 end
            local path = data.baseScarcityTier .. "->" .. final
            tally.paths[path] = (tally.paths[path] or 0) + 1
        end
    end
    return tally
end

local function formatPaths(paths)
    local output = {}
    local keys = {}
    for path in pairs(paths) do table.insert(keys, path) end
    table.sort(keys)
    for _, path in ipairs(keys) do table.insert(output, path .. "=" .. tostring(paths[path])) end
    return #output > 0 and table.concat(output, ", ") or "none"
end

local function writeScenario(writer, name, items, thresholds)
    writer:write("\nSCENARIO " .. name .. "\n")
    for _, fullType in ipairs({ "Base.Katana", "LK.LegendaryKatanaOrange", "LTW.LegendaryTacticalSword", "LB.Bag_LegendaryBackpack" }) do
        local data = items[fullType]
        if data then
            local threshold = data.utilityKind == "CONTAINER" and thresholds.container or thresholds.melee
            writer:write(string.format("%s | base=%s | utility=%s | hypothetical=%s\n", fullType, data.baseScarcityTier,
                data.utility and string.format("%.2f", data.utility) or "-", simulatedTier(data, threshold, UTILITY.demotionThreshold)))
        end
    end
end

local function sampleClass(profileCount)
    if profileCount >= 15 then return "LARGE" end
    if profileCount >= 8 then return "MEDIUM" end
    if profileCount >= 5 then return "SMALL" end
    return "TOO_SMALL"
end

local function profilePosition(sortedValues, utility)
    local percentile = percentileOfValue(sortedValues, utility)
    if not percentile then return nil, nil end
    local last = 0
    for index, value in ipairs(sortedValues) do if value == utility then last = index end end
    -- Rank is descending: 1 means best profile in the reference set.
    return #sortedValues - last + 1, percentile
end

local function buildSubfamilyMetrics(results)
    local parent, subgroups = {}, {}
    for _, data in pairs(results) do
        if data.utilityEligible and data.utilityKind == "MELEE_WEAPON" and data.utility ~= nil then
            table.insert(parent, data)
            appendGroup(subgroups, data.utilitySubgroup, data)
        end
    end
    local parentValues = uniqueProfileUtilities(parent)
    local metrics = {}
    for subgroup, items in pairs(subgroups) do
        local values = uniqueProfileUtilities(items)
        metrics[subgroup] = { values = values, size = #values, sampleClass = sampleClass(#values) }
    end
    for _, data in ipairs(parent) do
        local subgroup = metrics[data.utilitySubgroup]
        local rank, percentile = profilePosition(subgroup.values, data.utility)
        data.utilitySubgroupSize = subgroup.size
        data.utilitySubgroupRank = rank
        data.utilitySubgroupPercentile = percentile
        data.utilityParentPercentile = percentileOfValue(parentValues, data.utility)
        -- Public V2 percentile: same all-melee reference used by the hybrid
        -- promotion gate, kept alongside the legacy-named parent field.
        data.utilityPercentile = data.utilityParentPercentile
        data.utilitySampleClass = subgroup.sampleClass
    end
    return metrics, parentValues
end

-- Diagnostic-only snapshots. A vanilla snapshot is scored again from the raw
-- ScriptItem/runtime values with Base items as its reference population. It
-- intentionally never copies its values back into `results`: the active
-- FinalRarityTier/UI registry remains entirely unchanged.
local function snapshotFromRecords(records)
    local snapshot = { byFullType = {}, parentProfiles = {}, subgroupProfiles = {} }
    local parents, subgroups = {}, {}
    for _, record in ipairs(records) do
        if record.utility ~= nil then
            local parentKey = record.kind .. ":" .. record.parentGroup
            local subgroupKey = record.kind .. ":" .. record.subgroup
            parents[parentKey] = parents[parentKey] or {}
            subgroups[subgroupKey] = subgroups[subgroupKey] or {}
            table.insert(parents[parentKey], record)
            table.insert(subgroups[subgroupKey], record)
        end
    end
    local function positionGroups(groups, destination, fieldPrefix)
        for key, members in pairs(groups) do
            local profiles = {}
            for _, record in ipairs(members) do
                if profiles[record.profile] == nil then profiles[record.profile] = record.utility end
            end
            local values = {}
            for _, utility in pairs(profiles) do table.insert(values, utility) end
            values = sortedCopy(values)
            destination[key] = #values
            for _, record in ipairs(members) do
                local entry = snapshot.byFullType[record.fullType] or {}
                entry.utility = record.utility
                entry.confidence = record.confidence
                entry[fieldPrefix .. "Percentile"] = percentileOfValue(values, record.utility)
                entry[fieldPrefix .. "Profiles"] = #values
                snapshot.byFullType[record.fullType] = entry
            end
        end
    end
    positionGroups(parents, snapshot.parentProfiles, "parent")
    positionGroups(subgroups, snapshot.subgroupProfiles, "subgroup")
    return snapshot
end

local function loadedSnapshotRecords(results)
    local records = {}
    for _, data in pairs(results) do
        if data.utilityEligible and data.utility ~= nil and data.utilityKind and data.utilityProfile then
            local parentGroup = data.utilityKind == "MELEE_WEAPON" and "MELEE_WEAPON" or "WEARABLE_CONTAINER"
            table.insert(records, {
                fullType = data.fullType,
                kind = data.utilityKind,
                parentGroup = parentGroup,
                subgroup = data.utilitySubgroup or "UNKNOWN",
                profile = data.utilityProfile,
                utility = data.utility,
                confidence = data.utilityConfidence,
            })
        end
    end
    return records
end

local function vanillaSnapshotRecords(results)
    local candidates = {}
    for _, data in pairs(results) do
        if data.module == "Base" then table.insert(candidates, candidateFor(data)) end
    end
    local groups = resolveGroups(candidates)
    for _, group in pairs(groups) do scoreGroup(group) end
    local records = {}
    for _, candidate in ipairs(candidates) do
        if candidate.utilityEligible and candidate.utility ~= nil then
            table.insert(records, {
                fullType = candidate.data.fullType,
                kind = candidate.kind,
                parentGroup = candidate.parentGroup,
                subgroup = candidate.subgroup,
                profile = candidate.profile,
                utility = candidate.utility,
                confidence = candidate.utilityConfidence,
            })
        end
    end
    return records
end

local function rarityAtLeast(tier, minimum)
    return (TIER_INDEX[tier] or 0) >= (TIER_INDEX[minimum] or math.huge)
end

local function diagnosticGate(data, position, gate)
    if not position or not confidenceAtLeast(position.confidence, "HIGH") then return false end
    if not rarityAtLeast(data.baseScarcityTier, gate.minimumScarcity) then return false end
    if gate.parentMinimum and (position.parentPercentile or -1) < gate.parentMinimum then return false end
    if gate.subgroupMinimum and (position.subgroupPercentile or -1) < gate.subgroupMinimum then return false end
    return true
end

local function sortedDiagnosticItems(items, snapshot, predicate)
    local output = {}
    for _, data in ipairs(items) do
        local position = snapshot.byFullType[data.fullType]
        if position and predicate(data, position) then table.insert(output, { data = data, position = position }) end
    end
    table.sort(output, function(a, b)
        local ap, bp = a.position.parentPercentile or -1, b.position.parentPercentile or -1
        if ap == bp then return a.data.fullType < b.data.fullType end
        return ap > bp
    end)
    return output
end

local function writeDiagnosticList(writer, label, entries, limit)
    writer:write("\n" .. label .. " | count=" .. tostring(#entries) .. "\n")
    for index, entry in ipairs(entries) do
        if index > limit then break end
        local data, position = entry.data, entry.position
        writer:write(string.format("%s | scarcity=%s (p%.3f) | utility=%.2f | parentP=%.2f | subgroupP=%.2f | confidence=%s | module=%s\n",
            data.fullType, data.baseScarcityTier, data.tableAvailability.routeWeightedPercentile or -1,
            position.utility or -1, position.parentPercentile or -1, position.subgroupPercentile or -1,
            tostring(position.confidence), data.module))
    end
end

function ItemRarityUtilityCalculator.writeVanillaBaselineReport(results)
    if not UTILITY.diagnosticsEnabled or not getFileWriter then return end
    local writer = getFileWriter("ItemRarity_VanillaBaseline.txt", true, false)
    if not writer then return end

    local loaded = snapshotFromRecords(loadedSnapshotRecords(results))
    local vanilla = snapshotFromRecords(vanillaSnapshotRecords(results))
    local vanillaItems, loadedItems = {}, {}
    for _, data in pairs(results) do
        if data.module == "Base" then table.insert(vanillaItems, data) end
        table.insert(loadedItems, data)
    end
    table.sort(vanillaItems, function(a, b) return a.fullType < b.fullType end)

    writer:write("Item Rarity vanilla-vs-loaded Utility baseline (diagnostic only; active tiers/UI unchanged)\n")
    writer:write("VANILLA recomputes raw Utility using only Base profiles. LOADED uses all active profiles. Both deduplicate profiles and winsorize per the active Utility configuration.\n")
    writer:write(string.format("vanilla eligible profiles: melee=%d | wearable containers=%d\n", vanilla.parentProfiles["MELEE_WEAPON:MELEE_WEAPON"] or 0, vanilla.parentProfiles["CONTAINER:WEARABLE_CONTAINER"] or 0))
    writer:write(string.format("loaded eligible profiles: melee=%d | wearable containers=%d\n", loaded.parentProfiles["MELEE_WEAPON:MELEE_WEAPON"] or 0, loaded.parentProfiles["CONTAINER:WEARABLE_CONTAINER"] or 0))
    writer:write("\nVANILLA ELIGIBLE POSITIONS\n")
    writer:write("fullType | kind | subgroup | scarcityTier | scarcityPercentile | utilityVanilla | utilityLoaded | parentPVanilla | parentPLoaded | subgroupPVanilla | subgroupPLoaded | confidenceVanilla | confidenceLoaded\n")
    for _, data in ipairs(vanillaItems) do
        local v, l = vanilla.byFullType[data.fullType], loaded.byFullType[data.fullType]
        if v then
            writer:write(string.format("%s | %s | %s | %s | %.3f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %s | %s\n",
                data.fullType, tostring(data.utilityKind), tostring(data.utilitySubgroup), data.baseScarcityTier,
                data.tableAvailability.routeWeightedPercentile or -1, v.utility or -1, l and l.utility or -1,
                v.parentPercentile or -1, l and l.parentPercentile or -1,
                v.subgroupPercentile or -1, l and l.subgroupPercentile or -1,
                tostring(v.confidence), tostring(l and l.confidence or "NONE")))
        end
    end

    local meleeVanilla = sortedDiagnosticItems(vanillaItems, vanilla, function(data) return data.utilityKind == "MELEE_WEAPON" end)
    table.sort(meleeVanilla, function(a, b)
        if a.position.utility == b.position.utility then return a.data.fullType < b.data.fullType end
        return a.position.utility > b.position.utility
    end)
    writeDiagnosticList(writer, "TOP VANILLA MELEE BY VANILLA UTILITY", meleeVanilla, 25)
    table.sort(meleeVanilla, function(a, b)
        local as, bs = a.data.tableAvailability.routeWeightedPercentile or 100, b.data.tableAvailability.routeWeightedPercentile or 100
        if as == bs then return a.data.fullType < b.data.fullType end
        return as < bs
    end)
    writeDiagnosticList(writer, "TOP VANILLA MELEE BY SCARCITY", meleeVanilla, 25)
    local epicRule = sortedDiagnosticItems(vanillaItems, vanilla, function(data, position)
        return rarityAtLeast(data.baseScarcityTier, "RARE") and confidenceAtLeast(position.confidence, "MEDIUM")
            and (position.parentPercentile or -1) >= 80
    end)
    writeDiagnosticList(writer, "VANILLA EPIC CANDIDATES | scarcity>=RARE + parent Utility percentile>=80 + confidence>=MEDIUM", epicRule, 100)

    local gates = {
        A = { minimumScarcity = "RARE", parentMinimum = 95 },
        B = { minimumScarcity = "RARE", parentMinimum = 90, subgroupMinimum = 90 },
        C = { minimumScarcity = "EPIC", parentMinimum = 85 },
    }
    for name, gate in pairs(gates) do
        local vanillaCandidates = sortedDiagnosticItems(vanillaItems, vanilla, function(data, position) return diagnosticGate(data, position, gate) end)
        local loadedVanillaCandidates = sortedDiagnosticItems(vanillaItems, loaded, function(data, position) return diagnosticGate(data, position, gate) end)
        local loadedModdedCandidates = sortedDiagnosticItems(loadedItems, loaded, function(data, position) return data.module ~= "Base" and diagnosticGate(data, position, gate) end)
        writeDiagnosticList(writer, "EXOTIC GATE " .. name .. " | VANILLA BASELINE", vanillaCandidates, 100)
        writeDiagnosticList(writer, "EXOTIC GATE " .. name .. " | VANILLA ITEMS ON LOADED BASELINE", loadedVanillaCandidates, 100)
        writeDiagnosticList(writer, "EXOTIC GATE " .. name .. " | MODDED ITEMS ON LOADED BASELINE", loadedModdedCandidates, 100)
    end

    local shift = sortedDiagnosticItems(vanillaItems, vanilla, function(data, position)
        return position.parentPercentile ~= nil and loaded.byFullType[data.fullType] ~= nil
    end)
    table.sort(shift, function(a, b)
        local al = loaded.byFullType[a.data.fullType]
        local bl = loaded.byFullType[b.data.fullType]
        local ad = (al.parentPercentile or 0) - (a.position.parentPercentile or 0)
        local bd = (bl.parentPercentile or 0) - (b.position.parentPercentile or 0)
        if ad == bd then return a.data.fullType < b.data.fullType end
        return ad < bd
    end)
    writer:write("\nLARGEST VANILLA PARENT-PERCENTILE DROPS WHEN MODS ARE LOADED\n")
    for index, entry in ipairs(shift) do
        if index > 25 then break end
        local l = loaded.byFullType[entry.data.fullType]
        writer:write(string.format("%s | vanillaP=%.2f | loadedP=%.2f | shift=%+.2f | vanillaU=%.2f | loadedU=%.2f\n",
            entry.data.fullType, entry.position.parentPercentile or -1, l.parentPercentile or -1,
            (l.parentPercentile or 0) - (entry.position.parentPercentile or 0), entry.position.utility or -1, l.utility or -1))
    end
    local katanaV, katanaL = vanilla.byFullType["Base.Katana"], loaded.byFullType["Base.Katana"]
    writer:write("\nKATANA DIAGNOSTIC\n")
    if katanaV then
        writer:write(string.format("Base.Katana | vanilla utility=%.2f parentP=%.2f subgroupP=%.2f | loaded utility=%.2f parentP=%.2f subgroupP=%.2f\n",
            katanaV.utility or -1, katanaV.parentPercentile or -1, katanaV.subgroupPercentile or -1,
            katanaL and katanaL.utility or -1, katanaL and katanaL.parentPercentile or -1, katanaL and katanaL.subgroupPercentile or -1))
    end
    writer:close()
    ItemRarityUtils.info("Vanilla Utility baseline report written to Zomboid/Lua/ItemRarity_VanillaBaseline.txt.")
end

local function canPromoteWithSubfamily(data, model)
    if not data.utilityEligible or data.utilityKind ~= "MELEE_WEAPON" or data.utility == nil then return false end
    if not confidenceAtLeast(data.utilityConfidence, UTILITY.minimumConfidenceForAdjustment) then return false end
    local sizeClass = data.utilitySampleClass
    local subgroupPercentile = data.utilitySubgroupPercentile or -1
    local parentPercentile = data.utilityParentPercentile or -1
    local rank = data.utilitySubgroupRank or math.huge

    if model == "A" then return data.utility >= 80 end
    if model == "B" then
        if sizeClass == "LARGE" then
            return data.utility >= 70 and subgroupPercentile >= 95 and parentPercentile >= 85
        elseif sizeClass == "MEDIUM" then
            return data.utility >= 72 and subgroupPercentile >= 90 and parentPercentile >= 85
        elseif sizeClass == "SMALL" then
            return data.utility >= 75 and subgroupPercentile >= 100 and parentPercentile >= 90
        end
        return false
    end
    -- Model C protects the smaller samples more aggressively. Large groups
    -- still use their own upper tail, but medium/small groups require top rank
    -- and a clearly high parent position.
    if sizeClass == "LARGE" then
        return data.utility >= 75 and subgroupPercentile >= 95 and parentPercentile >= 90
    elseif sizeClass == "MEDIUM" then
        return data.utility >= 75 and rank <= 1 and parentPercentile >= 90
    elseif sizeClass == "SMALL" then
        return data.utility >= 75 and rank == 1 and parentPercentile >= 90
    end
    return false
end

local function simulatedSubfamilyTier(data, model)
    if not canPromoteWithSubfamily(data, model) then return data.baseScarcityTier end
    local baseIndex = TIER_INDEX[data.baseScarcityTier]
    if not baseIndex then return data.baseScarcityTier end
    if data.baseScarcityTier == "EPIC" then
        -- The subfamily signal never creates Exotic on its own. Reuse the
        -- unchanged strict gate, including the configured Utility threshold.
        local scarcity = 100 - (data.tableAvailability.routeWeightedPercentile or 100)
        if scarcity >= UTILITY.exoticMinimumScarcity and data.utility >= UTILITY.exoticUtilityThreshold
            and confidenceAtLeast(data.utilityConfidence, UTILITY.exoticMinimumConfidence) then return "EXOTIC" end
        return data.baseScarcityTier
    end
    return baseIndex < #TIER_STRENGTH and TIER_STRENGTH[baseIndex + 1] or data.baseScarcityTier
end

local function tallySubfamilyModel(results, model)
    local tally, candidates = { total = 0, vanilla = 0, modded = 0, paths = {} }, {}
    for _, data in pairs(results) do
        local final = simulatedSubfamilyTier(data, model)
        if final ~= data.baseScarcityTier then
            tally.total = tally.total + 1
            if data.module == "Base" then tally.vanilla = tally.vanilla + 1 else tally.modded = tally.modded + 1 end
            local path = data.baseScarcityTier .. "->" .. final
            tally.paths[path] = (tally.paths[path] or 0) + 1
            table.insert(candidates, { data = data, final = final })
        end
    end
    table.sort(candidates, function(a, b) return a.data.fullType < b.data.fullType end)
    return tally, candidates
end

local function writeSubfamilyCandidateList(writer, label, candidates)
    writer:write("\n" .. label .. " candidates\n")
    if #candidates == 0 then writer:write("none\n"); return end
    for _, entry in ipairs(candidates) do
        local data = entry.data
        writer:write(string.format("%s | %s -> %s | subgroup=%s | class=%s | utility=%.2f | subgroup=%d/%d p%.2f | parent p%.2f | module=%s\n",
            data.fullType, data.baseScarcityTier, entry.final, data.utilitySubgroup, data.utilitySampleClass,
            data.utility, data.utilitySubgroupRank or 0, data.utilitySubgroupSize or 0,
            data.utilitySubgroupPercentile or 0, data.utilityParentPercentile or 0, data.module))
    end
end

function ItemRarityUtilityCalculator.writeSubfamilyPromotionReport(results)
    if not UTILITY.diagnosticsEnabled or not getFileWriter then return end
    local writer = getFileWriter("ItemRarity_SubfamilyPromotion.txt", true, false)
    if not writer then return end
    local metrics, parentValues = buildSubfamilyMetrics(results)
    writer:write("Item Rarity subfamily-promotion diagnostics (active hybrid model; report makes no changes)\n")
    writer:write("Ranks are descending: 1 is the best deduplicated mechanical profile.\n\n")
    writer:write("SUBFAMILY SAMPLE CLASSES\n")
    for _, subgroup in ipairs({ "LONG_BLADE", "AXE", "BLUNT", "SMALL_BLADE", "SPEAR", "OTHER_MELEE" }) do
        local metric = metrics[subgroup]
        writer:write(string.format("%s | profiles=%d | class=%s\n", subgroup, metric and metric.size or 0, metric and metric.sampleClass or "TOO_SMALL"))
    end
    writer:write(string.format("MELEE_WEAPON parent | profiles=%d\n", #parentValues))
    writer:write("\nREPRESENTATIVE POSITIONS\n")
    for _, fullType in ipairs({ "Base.Katana", "LK.LegendaryKatanaOrange", "LTW.LegendaryTacticalSword", "Base.Axe", "Base.Sledgehammer" }) do
        local data = results[fullType]
        writer:write(string.format("%s | eligible=%s | subgroup=%s | class=%s | utility=%s | subgroupRank=%s/%s | subgroupPercentile=%s | parentPercentile=%s\n",
            fullType, data and tostring(data.utilityEligible) or "false", data and tostring(data.utilitySubgroup) or "-",
            data and tostring(data.utilitySampleClass) or "-", data and data.utility and string.format("%.2f", data.utility) or "-",
            data and data.utilitySubgroupRank and tostring(data.utilitySubgroupRank) or "-", data and data.utilitySubgroupSize and tostring(data.utilitySubgroupSize) or "-",
            data and data.utilitySubgroupPercentile and string.format("%.2f", data.utilitySubgroupPercentile) or "-",
            data and data.utilityParentPercentile and string.format("%.2f", data.utilityParentPercentile) or "-"))
    end
    writer:write("\nMODEL DEFINITIONS\n")
    writer:write("A: Utility >= 80 (current threshold reference).\n")
    writer:write("B LARGE: U>=70, subgroup p>=95, parent p>=85; MEDIUM: U>=72, subgroup p>=90, parent p>=85; SMALL: U>=75, subgroup p=100, parent p>=90; TOO_SMALL disabled.\n")
    writer:write("C LARGE: U>=75, subgroup p>=95, parent p>=90; MEDIUM: U>=75, rank=1, parent p>=90; SMALL: U>=75, rank=1, parent p>=90; TOO_SMALL disabled.\n")
    for _, model in ipairs({ "A", "B", "C" }) do
        local tally, candidates = tallySubfamilyModel(results, model)
        writer:write(string.format("\nMODEL %s | promoted=%d | vanilla=%d | modded=%d | %s\n", model, tally.total, tally.vanilla, tally.modded, formatPaths(tally.paths)))
        writeSubfamilyCandidateList(writer, "MODEL " .. model, candidates)
    end
    writer:close()
    ItemRarityUtils.info("Subfamily-promotion simulation written to Zomboid/Lua/ItemRarity_SubfamilyPromotion.txt.")
end

function ItemRarityUtilityCalculator.writeCalibrationReport(results)
    if not UTILITY.diagnosticsEnabled or not getFileWriter then return end
    local writer = getFileWriter("ItemRarity_UtilityCalibration.txt", true, false)
    if not writer then return end
    local groups = buildCalibrationGroups(results)
    writer:write("Item Rarity Utility calibration diagnostics (active model unchanged by this report)\n")
    writer:write("All distributions deduplicate utilityProfile before quantiles.\n\nUTILITY DISTRIBUTIONS\n")
    for _, name in ipairs({ "BACKPACK", "WEARABLE_BAG", "MELEE_WEAPON", "LONG_BLADE", "AXE", "BLUNT", "SMALL_BLADE", "SPEAR", "OTHER_MELEE" }) do
        writeUtilityDistribution(writer, name, groups[name] or {})
    end

    writer:write("\nREPRESENTATIVE POSITIONS\n")
    for _, fullType in ipairs({ "Base.Katana", "LK.LegendaryKatanaOrange", "LTW.LegendaryTacticalSword", "Base.Axe", "Base.Sledgehammer", "Base.Bag_Schoolbag", "Base.Bag_NormalHikingBag", "Base.Bag_BigHikingBag", "Base.Bag_ALICEpack", "LB.Bag_LegendaryBackpack" }) do
        local data = results[fullType]
        local group = data and data.utilityKind == "MELEE_WEAPON" and groups[data.utilitySubgroup] or (data and groups[data.utilitySubgroup])
        local values = group and uniqueProfileUtilities(group) or {}
        local percentile = data and percentileOfValue(values, data.utility) or nil
        local rank = nil
        if percentile and #values > 1 then rank = math.floor((percentile / 100) * (#values - 1) + 1.5) end
        writer:write(string.format("%s | subgroup=%s | utility=%s | percentile=%s | rank=%s/%d | profiles=%d | eligible=%s\n",
            fullType, data and tostring(data.utilitySubgroup) or "-", data and data.utility and string.format("%.2f", data.utility) or "-",
            percentile and string.format("%.2f", percentile) or "-", rank and tostring(rank) or "-", #values,
            data and (data.utilityProfileCount or 0) or 0, data and tostring(data.utilityEligible) or "false"))
    end

    local categoryItems = { CONTAINER = {}, MELEE_WEAPON = {} }
    for _, data in pairs(results) do
        if data.utilityEligible and data.utility ~= nil then
            if data.utilityKind == "CONTAINER" then table.insert(categoryItems.CONTAINER, data)
            elseif data.utilityKind == "MELEE_WEAPON" then table.insert(categoryItems.MELEE_WEAPON, data) end
        end
    end
    writer:write("\nPROMOTION THRESHOLD SIMULATIONS (EXOTIC GATE UNCHANGED)\n")
    for _, threshold in ipairs({ 70, 75, 80, 85, 90 }) do
        for _, category in ipairs({ "CONTAINER", "MELEE_WEAPON" }) do
            local tally = tallyThreshold(categoryItems[category], threshold, UTILITY.demotionThreshold)
            writer:write(string.format("threshold=%d | category=%s | promoted=%d | vanilla=%d | modded=%d | %s\n", threshold, category, tally.total, tally.vanilla, tally.modded, formatPaths(tally.paths)))
        end
    end
    writer:write("\nDEMOTION THRESHOLD SIMULATIONS\n")
    for _, threshold in ipairs({ 10, 15, 20, 25, 30 }) do
        for _, category in ipairs({ "CONTAINER", "MELEE_WEAPON" }) do
            local tally = { total = 0, vanilla = 0, modded = 0, paths = {} }
            for _, data in ipairs(categoryItems[category]) do
                local final = simulatedTier(data, 101, threshold)
                if final ~= data.baseScarcityTier then
                    tally.total = tally.total + 1
                    if data.module == "Base" then tally.vanilla = tally.vanilla + 1 else tally.modded = tally.modded + 1 end
                    local path = data.baseScarcityTier .. "->" .. final
                    tally.paths[path] = (tally.paths[path] or 0) + 1
                end
            end
            writer:write(string.format("threshold=%d | category=%s | demoted=%d | vanilla=%d | modded=%d | %s\n", threshold, category, tally.total, tally.vanilla, tally.modded, formatPaths(tally.paths)))
        end
    end
    writer:write("\nEXOTIC GATE DIAGNOSTIC\n")
    for _, threshold in ipairs({ 85, 90, 95 }) do
        local eligible = 0
        for _, data in pairs(results) do
            if data.utilityEligible and data.baseScarcityTier == "EPIC"
                and (100 - (data.tableAvailability.routeWeightedPercentile or 100)) >= UTILITY.exoticMinimumScarcity
                and confidenceAtLeast(data.utilityConfidence, UTILITY.exoticMinimumConfidence)
                and (data.utility or -1) >= threshold then eligible = eligible + 1 end
        end
        writer:write(string.format("utility threshold >= %d | EPIC->EXOTIC candidates with scarcity/confidence gate=%d\n", threshold, eligible))
    end
    writeScenario(writer, "CONSERVATIVE (container=85, melee=85)", results, { container = 85, melee = 85 })
    writeScenario(writer, "BALANCED (container=85, melee=75)", results, { container = 85, melee = 75 })
    writeScenario(writer, "AGGRESSIVE (container=75, melee=70)", results, { container = 75, melee = 70 })
    writer:close()
    ItemRarityUtils.info("Utility calibration report written to Zomboid/Lua/ItemRarity_UtilityCalibration.txt.")
end

function ItemRarityUtilityCalculator.calculate(results)
    if not UTILITY.enabled then return results end
    local candidates = {}
    for _, data in pairs(results) do table.insert(candidates, candidateFor(data)) end
    -- Containers retain their active score through the generic normalized
    -- container group. Melee and Clothing are scored only by their active
    -- V2/V1 calculators below; historical V1 snapshots are diagnostics-only.
    local groups = resolveGroups(candidates)
    for _, group in pairs(groups) do scoreGroup(group) end
    -- Containers keep their existing score. Every eligible melee HandWeapon
    -- (including TOOL combat items) is then recalculated as V2 Model C10.
    scoreMeleeV2(candidates)
    scoreClothingUtility(candidates)
    scoreClothingDirectSlotV1(candidates)
    assignClothingMechanicalValueStatus(candidates)
    publishCandidateFields(candidates)
    buildSubfamilyMetrics(results)
    for _, candidate in ipairs(candidates) do applyTierAdjustment(candidate.data, candidate) end
    return results
end

local function sortedKeys(map)
    local keys = {}
    for key in pairs(map) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end

local function newDistribution()
    local distribution = {}
    for _, tier in ipairs(TIER_STRENGTH) do distribution[tier] = 0 end
    return distribution
end

local function writeDistribution(writer, label, distribution)
    writer:write(label)
    for _, tier in ipairs(TIER_STRENGTH) do writer:write(string.format(" | %s=%d", tier, distribution[tier] or 0)) end
    writer:write("\n")
end

-- Shared runtime readers remain here because WeaponUtility V2 and other active
-- paths use them. The historical A/B/C laboratory receives them only when its
-- Diagnostics module is explicitly loaded.
function ItemRarityUtilityCalculator.getWeaponDiagnosticApi()
    return {
        sortedCopy = sortedCopy,
        quantile = quantile,
        uniqueSorted = uniqueSorted,
        clamp = clamp,
        percentileRank = percentileRank,
        readNumber = readNumber,
        readBoolean = readBoolean,
        weaponFamily = weaponFamily,
    }
end

-- Clothing diagnostics use this read-only bridge only when development
-- reports are explicitly enabled. All score helpers remain owned by the
-- runtime calculator because ClothingUtility V1 P2/DIRECT_SLOT uses them.
function ItemRarityUtilityCalculator.getClothingDiagnosticApi()
    return {
        UTILITY = UTILITY,
        NORMALIZATION = NORMALIZATION,
        TIER_STRENGTH = TIER_STRENGTH,
        TIER_INDEX = TIER_INDEX,
        ANATOMICAL_COVERAGE_MODELS = ANATOMICAL_COVERAGE_MODELS,
        sortedCopy = sortedCopy,
        uniqueSorted = uniqueSorted,
        quantile = quantile,
        clamp = clamp,
        percentileRank = percentileRank,
        confidenceAtLeast = confidenceAtLeast,
        readNumber = readNumber,
        readBoolean = readBoolean,
        sortedKeys = sortedKeys,
        newDistribution = newDistribution,
        matrixTierFromAxes = matrixTierFromAxes,
        clothingUtilityPercentileOfValue = clothingUtilityPercentileOfValue,
        clothingDirectSlotV1Weights = clothingDirectSlotV1Weights,
        anatomicalWeightTotal = anatomicalWeightTotal,
        anatomicalModelMaximum = anatomicalModelMaximum,
        hasOnlyAccessoryRegions = hasOnlyAccessoryRegions,
        regionSet = regionSet,
    }
end

-- This is deliberately a report-only candidate for the next FinalRarityTier
-- semantics.  It reads the current scarcity/Utility data but never changes
-- `finalRarityTier`, the published registry, Strategy D, or the UI.
local function buildUtilityPercentilesByNormalizationGroup(results)
    local groups, percentiles = {}, {}
    for _, data in pairs(results) do
        if data.utilityEligible and data.utility ~= nil then
            local key = data.utilityNormalizationGroup or ((data.utilityKind or "UNKNOWN") .. ":UNGROUPED")
            appendGroup(groups, key, data)
        end
    end
    for key, items in pairs(groups) do
        local values = uniqueProfileUtilities(items)
        for _, data in ipairs(items) do
            percentiles[data.fullType] = percentileOfValue(values, data.utility)
        end
    end
    return percentiles
end

local function scarcityVisualCeiling(scarcityTier)
    local index = TIER_INDEX[scarcityTier] or TIER_INDEX.COMMON
    return index <= TIER_INDEX.UNCOMMON and TIER_STRENGTH[index] or "RARE"
end

local function simulatedFinalTierFromAxes(data, utilityPercentile, pathBMinimum)
    pathBMinimum = pathBMinimum or 90
    local scarcityTier = data.baseScarcityTier or data.rarityTier or "COMMON"
    local scarcityIndex = TIER_INDEX[scarcityTier] or TIER_INDEX.COMMON
    local ceiling = scarcityVisualCeiling(scarcityTier)
    local trusted = data.utilityEligible and utilityPercentile ~= nil
        and confidenceAtLeast(data.utilityConfidence, UTILITY.minimumConfidenceForAdjustment)

    if not trusted then
        return ceiling, string.format("scarcity-only ceiling %s: Utility is absent, ineligible or below %s confidence", ceiling, UTILITY.minimumConfidenceForAdjustment), {
            trustedUtility = false,
            scarcityCeiling = ceiling,
        }
    end

    -- Common and Uncommon may benefit from excellent Utility, but each has a
    -- one-step ceiling.  This prevents Utility alone from manufacturing an
    -- Epic/Exotic item out of an ordinary table entry.
    if scarcityIndex == TIER_INDEX.COMMON then
        if utilityPercentile >= 90 then
            return "UNCOMMON", "COMMON + UtilityPercentile >= 90: one-step Utility promotion", {
                trustedUtility = true, scarcityCeiling = ceiling,
            }
        end
        return "COMMON", "COMMON: UtilityPercentile below the one-step promotion gate", {
            trustedUtility = true, scarcityCeiling = ceiling,
        }
    end
    if scarcityIndex == TIER_INDEX.UNCOMMON then
        if utilityPercentile >= 90 then
            return "RARE", "UNCOMMON + UtilityPercentile >= 90: one-step Utility promotion", {
                trustedUtility = true, scarcityCeiling = ceiling,
            }
        end
        return "UNCOMMON", "UNCOMMON: UtilityPercentile below the one-step promotion gate", {
            trustedUtility = true, scarcityCeiling = ceiling,
        }
    end

    -- Path A/B must be evaluated before the general EPIC p90 gate: B1/B2
    -- intentionally permit an exceptionally scarce item with p80/p85 Utility
    -- to be EXOTIC as a scarcity-and-Utility combination, not a pure power rank.
    if scarcityIndex >= TIER_INDEX.EPIC and utilityPercentile >= 95
        and data.utilityConfidence == "HIGH" then
        return "EXOTIC", "EXOTIC Path A: ScarcityTier >= EPIC + UtilityPercentile >= 95 + HIGH confidence", {
            trustedUtility = true, scarcityCeiling = ceiling,
        }
    end
    if scarcityTier == "EXOTIC" and utilityPercentile >= pathBMinimum
        and data.utilityConfidence == "HIGH" then
        return "EXOTIC", "EXOTIC Path B" .. tostring(pathBMinimum) .. ": ScarcityTier EXOTIC + UtilityPercentile >= "
            .. tostring(pathBMinimum) .. " + HIGH confidence", {
            trustedUtility = true, scarcityCeiling = ceiling,
        }
    end
    -- Scarcity RARE/EPIC/EXOTIC otherwise first means visually RARE. EPIC
    -- then requires the independent Utility p90 gate.
    if utilityPercentile < 90 then
        return "RARE", "scarcity supports RARE; UtilityPercentile below the EPIC gate (90)", {
            trustedUtility = true, scarcityCeiling = ceiling,
        }
    end
    return "EPIC", "ScarcityTier >= RARE + UtilityPercentile >= 90"
        .. (scarcityIndex >= TIER_INDEX.EPIC and "; neither EXOTIC path met" or "; scarcity below EXOTIC Path A gate"), {
            trustedUtility = true, scarcityCeiling = ceiling,
    }
end

local function writeExoticThresholdScenario(writer, results, utilityPercentiles, pathBMinimum)
    local proposed, candidates = newDistribution(), {}
    local vanilla, modded = 0, 0
    for fullType, data in pairs(results) do
        local tier, reason = simulatedFinalTierFromAxes(data, utilityPercentiles[fullType], pathBMinimum)
        proposed[tier] = proposed[tier] + 1
        if tier == "EXOTIC" then
            local path = string.find(reason, "Path A", 1, true) and "A" or ("B" .. tostring(pathBMinimum))
            table.insert(candidates, { data = data, tier = tier, reason = reason, path = path, utilityPercentile = utilityPercentiles[fullType] })
            if data.module == "Base" then vanilla = vanilla + 1 else modded = modded + 1 end
        end
    end
    table.sort(candidates, function(a, b)
        if a.utilityPercentile == b.utilityPercentile then return a.data.fullType < b.data.fullType end
        return (a.utilityPercentile or -1) > (b.utilityPercentile or -1)
    end)
    writer:write("\nEXOTIC SCENARIO B" .. tostring(pathBMinimum) .. " (REPORT ONLY)\n")
    writer:write("Path A remains: ScarcityTier >= EPIC + UtilityPercentile >= 95 + HIGH. Path B" .. tostring(pathBMinimum)
        .. ": ScarcityTier EXOTIC + UtilityPercentile >= " .. tostring(pathBMinimum) .. " + HIGH.\n")
    writeDistribution(writer, "PROPOSED FINAL", proposed)
    writer:write(string.format("EXOTIC COUNTS | vanilla-only=%d | modded=%d | all loaded=%d\n", vanilla, modded, #candidates))
    writer:write("fullType | module | ScarcityPercentile | UtilityPercentile | UtilityScore | family | FinalTier | Path\n")
    writer:write("VANILLA\n")
    local function writeCandidate(candidate)
        local data = candidate.data
        writer:write(string.format("%s | %s | %.2f | %.2f | %.2f | %s | %s | %s\n", data.fullType, data.module,
            data.tableAvailability.routeWeightedPercentile or -1, candidate.utilityPercentile or -1, data.utility or -1,
            tostring(data.utilitySubgroup or "-"), candidate.tier, candidate.path))
    end
    local anyVanilla = false
    for _, candidate in ipairs(candidates) do if candidate.data.module == "Base" then writeCandidate(candidate); anyVanilla = true end end
    if not anyVanilla then writer:write("none\n") end
    writer:write("MODDED\n")
    local anyModded = false
    for _, candidate in ipairs(candidates) do if candidate.data.module ~= "Base" then writeCandidate(candidate); anyModded = true end end
    if not anyModded then writer:write("none\n") end
end

-- Matrix experiment: rarity is a combination of table scarcity potential and
-- mechanical Utility. This is diagnostics only and intentionally does not
-- write `finalRarityTier` or any registry/UI-facing field.
local MATRIX_TIERS = {
    COMMON = { LOW = "COMMON", P70 = "COMMON", P80 = "COMMON", P90 = "UNCOMMON", P95 = "UNCOMMON" },
    UNCOMMON = { LOW = "UNCOMMON", P70 = "UNCOMMON", P80 = "UNCOMMON", P90 = "RARE", P95 = "RARE" },
    RARE = { LOW = "RARE", P70 = "RARE", P80 = "RARE", P90 = "EPIC", P95 = "EPIC" },
    EPIC = { LOW = "RARE", P70 = "RARE", P80 = "EPIC", P90 = "EPIC", P95 = "EXOTIC" },
    EXOTIC = { LOW = "RARE", P70 = "EPIC", P80 = "EPIC", P90 = "EXOTIC", P95 = "EXOTIC" },
}

local function matrixUtilityBand(utilityPercentile, thresholds)
    if utilityPercentile >= thresholds.p95 then return "P95", "p" .. tostring(thresholds.p95) .. "+" end
    if utilityPercentile >= thresholds.p90 then return "P90", "p" .. tostring(thresholds.p90) .. "–" .. string.format("%.2f", thresholds.p95 - 0.01) end
    if utilityPercentile >= thresholds.p80 then return "P80", "p" .. tostring(thresholds.p80) .. "–" .. string.format("%.2f", thresholds.p90 - 0.01) end
    if utilityPercentile >= thresholds.p70 then return "P70", "p" .. tostring(thresholds.p70) .. "–" .. string.format("%.2f", thresholds.p80 - 0.01) end
    return "LOW", "< p" .. tostring(thresholds.p70)
end

matrixTierFromAxes = function(data, utilityPercentile, thresholds)
    local scarcityTier = data.baseScarcityTier or data.rarityTier or "COMMON"
    local ceiling = scarcityVisualCeiling(scarcityTier)
    local confidence = data.utilityConfidence or "NONE"
    local trusted = data.utilityEligible and data.utility ~= nil and utilityPercentile ~= nil
        and confidenceAtLeast(confidence, "MEDIUM")
    if not trusted then
        return ceiling, "no eligible/reliable Utility (LOW/NONE/N/A); visual ceiling " .. ceiling, "N/A"
    end
    local band, bandLabel = matrixUtilityBand(utilityPercentile, thresholds)
    local matrix = MATRIX_TIERS[scarcityTier] or MATRIX_TIERS.COMMON
    local tier = matrix[band] or ceiling
    if confidence == "MEDIUM" and tier == "EXOTIC" then
        return "EPIC", "matrix " .. scarcityTier .. " × " .. bandLabel .. " -> EXOTIC; MEDIUM confidence cap -> EPIC", bandLabel
    end
    return tier, "matrix " .. scarcityTier .. " × " .. bandLabel .. " -> " .. tier .. " (" .. confidence .. " confidence)", bandLabel
end

local function writeMatrixDistribution(writer, label, distribution)
    writeDistribution(writer, label, distribution)
end

local function writeMatrixTransitionCounts(writer, transitions)
    writer:write("SCARCITY -> MATRIX FINAL TRANSITIONS\n")
    for _, entry in ipairs({
        { "COMMON", "UNCOMMON" }, { "UNCOMMON", "RARE" }, { "RARE", "EPIC" }, { "EPIC", "RARE" },
        { "EPIC", "EXOTIC" }, { "EXOTIC", "RARE" }, { "EXOTIC", "EPIC" }, { "EXOTIC", "EXOTIC" },
    }) do
        local from, to = entry[1], entry[2]
        writer:write(string.format("%s -> %s = %d\n", from, to, ((transitions[from] or {})[to] or 0)))
    end
    writer:write("ALL OBSERVED TRANSITIONS\n")
    for _, from in ipairs(TIER_STRENGTH) do
        local parts = {}
        for _, to in ipairs(TIER_STRENGTH) do
            local count = ((transitions[from] or {})[to] or 0)
            if count > 0 then table.insert(parts, from .. " -> " .. to .. "=" .. tostring(count)) end
        end
        writer:write((#parts > 0 and table.concat(parts, " | ") or from .. " -> none") .. "\n")
    end
end

local function writeMatrixSensitivity(writer, results, utilityPercentiles)
    local scenarios = {
        { name = "RELAXED", p70 = 68, p80 = 78, p90 = 88, p95 = 93 },
        { name = "PRIMARY", p70 = 70, p80 = 80, p90 = 90, p95 = 95 },
        { name = "STRICT", p70 = 72, p80 = 82, p90 = 92, p95 = 97 },
    }
    writer:write("\nSENSITIVITY (same matrix, threshold variations only)\n")
    for _, scenario in ipairs(scenarios) do
        local distribution = newDistribution()
        for fullType, data in pairs(results) do
            local tier = matrixTierFromAxes(data, utilityPercentiles[fullType], scenario)
            distribution[tier] = distribution[tier] + 1
        end
        writer:write(string.format("%s thresholds p%d/p%d/p%d/p%d", scenario.name, scenario.p70, scenario.p80, scenario.p90, scenario.p95))
        for _, tier in ipairs(TIER_STRENGTH) do writer:write(string.format(" | %s=%d", tier, distribution[tier] or 0)) end
        writer:write("\n")
    end
    local primary = scenarios[2]
    local near = {}
    for fullType, data in pairs(results) do
        local percentile = utilityPercentiles[fullType]
        if percentile ~= nil and confidenceAtLeast(data.utilityConfidence, "MEDIUM") then
            local thresholds = { primary.p70, primary.p80, primary.p90, primary.p95 }
            local nearby = {}
            for _, threshold in ipairs(thresholds) do
                if math.abs(percentile - threshold) <= 2 then table.insert(nearby, "p" .. tostring(threshold)) end
            end
            if #nearby > 0 then table.insert(near, { data = data, percentile = percentile, nearby = table.concat(nearby, ",") }) end
        end
    end
    table.sort(near, function(a, b) return a.data.fullType < b.data.fullType end)
    writer:write("Items within 2 percentile points of PRIMARY boundaries (diagnostic):\n")
    writer:write("fullType | category/family | ScarcityTier | UtilityPercentile | UtilityConfidence | near boundary\n")
    for _, entry in ipairs(near) do
        local data = entry.data
        writer:write(string.format("%s | %s/%s | %s | %.2f | %s | %s\n", data.fullType, tostring(data.category),
            tostring(data.utilitySubgroup or "-"), tostring(data.baseScarcityTier), entry.percentile,
            tostring(data.utilityConfidence), entry.nearby))
    end
end

function ItemRarityUtilityCalculator.writeFinalTierMatrixSimulationReport(results)
    if not UTILITY.diagnosticsEnabled or not getFileWriter then return end
    local writer = getFileWriter("ItemRarity_FinalTierMatrixSimulation.txt", true, false)
    if not writer then return end
    local thresholds = { p70 = 70, p80 = 80, p90 = 90, p95 = 95 }
    local utilityPercentiles = buildUtilityPercentilesByNormalizationGroup(results)
    local active, proposed, transitions, changes = newDistribution(), newDistribution(), {}, {}
    local assessments = {}
    for fullType, data in pairs(results) do
        local tier, reason, band = matrixTierFromAxes(data, utilityPercentiles[fullType], thresholds)
        assessments[fullType] = { tier = tier, reason = reason, band = band, utilityPercentile = utilityPercentiles[fullType] }
        active[data.finalRarityTier] = active[data.finalRarityTier] + 1
        proposed[tier] = proposed[tier] + 1
        local scarcity = data.baseScarcityTier or data.rarityTier or "COMMON"
        transitions[scarcity] = transitions[scarcity] or {}
        transitions[scarcity][tier] = (transitions[scarcity][tier] or 0) + 1
        if tier ~= data.finalRarityTier then table.insert(changes, data) end
    end
    table.sort(changes, function(a, b) return a.fullType < b.fullType end)
    writer:write("Item Rarity FinalRarityTier matrix simulation (REPORT ONLY)\n")
    writer:write("No active FinalRarityTier, Strategy D/ScarcityTier, WeaponUtility V2, registry or UI field is changed. Same matrix is used for vanilla and modded items; no fullType/module/name rule exists.\n")
    writer:write("PRIMARY MATRIX bands: <p70 | p70–79.99 | p80–89.99 | p90–94.99 | p95+. HIGH uses full matrix; MEDIUM may reach EPIC but is capped below EXOTIC; LOW/NONE/N/A is capped at RARE. subgroupPercentile is diagnostic only.\n\n")
    writeMatrixDistribution(writer, "CURRENT ACTIVE FINAL", active)
    writeMatrixDistribution(writer, "MATRIX PROPOSED FINAL", proposed)
    writer:write(string.format("ACTIVE_FINAL_CHANGES=%d\n\n", #changes))
    writeMatrixTransitionCounts(writer, transitions)
    writer:write("\nALL ITEMS WHOSE ACTIVE FINAL TIER WOULD CHANGE\n")
    writer:write("fullType | category/family | ScarcityPercentile | ScarcityTier | UtilityScore | UtilityPercentile | UtilityConfidence | subgroupPercentile | Final current | Final matrix | matrix band/reason\n")
    for _, data in ipairs(changes) do
        local assessment = assessments[data.fullType]
        local subgroup = data.utilitySubgroupPercentile and string.format("%.2f", data.utilitySubgroupPercentile) or "N/A"
        writer:write(string.format("%s | %s/%s | %.2f | %s | %s | %s | %s | %s | %s | %s | %s\n", data.fullType,
            tostring(data.category), tostring(data.utilitySubgroup or "-"), data.tableAvailability.routeWeightedPercentile or -1,
            tostring(data.baseScarcityTier), data.utility and string.format("%.2f", data.utility) or "N/A",
            assessment.utilityPercentile and string.format("%.2f", assessment.utilityPercentile) or "N/A", tostring(data.utilityConfidence), subgroup,
            tostring(data.finalRarityTier), assessment.tier, assessment.band .. " | " .. assessment.reason))
    end
    writer:write("\nREQUIRED COMPARISON\n")
    writer:write("fullType | category/family | ScarcityPercentile | ScarcityTier | UtilityScore | UtilityPercentile | UtilityConfidence | subgroupPercentile | Final current | Final matrix | matrix band/reason\n")
    local targets = {
        "Base.Katana", "Base.Machete", "Base.GardenFork", "Base.HuntingKnife", "Base.HuntingKnifeForged", "Base.BaseballBat",
        "Base.Crowbar", "Base.Axe", "Base.BlockMaul", "Base.Cudgel_ScrapSheet", "Base.Cudgel_GardenForkHead", "Base.ShortSword",
        "Base.LongMace", "Base.LongMace_Stone", "Base.SledgehammerForged", "Base.WoodAxeForged", "Base.MacheteForged",
        "Base.HollowBook_Handgun", "LB.Bag_LegendaryBackpack", "LK.LegendaryKatanaOrange", "LTW.LegendaryTacticalSword",
    }
    for _, fullType in ipairs(targets) do
        local data, assessment = results[fullType], assessments[fullType]
        if not data then
            writer:write(fullType .. " | unavailable in this loaded runtime\n")
        else
            local subgroup = data.utilitySubgroupPercentile and string.format("%.2f", data.utilitySubgroupPercentile) or "N/A"
            writer:write(string.format("%s | %s/%s | %.2f | %s | %s | %s | %s | %s | %s | %s | %s\n", fullType,
                tostring(data.category), tostring(data.utilitySubgroup or "-"), data.tableAvailability.routeWeightedPercentile or -1,
                tostring(data.baseScarcityTier), data.utility and string.format("%.2f", data.utility) or "N/A",
                assessment.utilityPercentile and string.format("%.2f", assessment.utilityPercentile) or "N/A", tostring(data.utilityConfidence), subgroup,
                tostring(data.finalRarityTier), assessment.tier, assessment.band .. " | " .. assessment.reason))
        end
    end
    writeMatrixSensitivity(writer, results, utilityPercentiles)
    writer:close()
    ItemRarityUtils.info("FinalRarityTier matrix simulation written to Zomboid/Lua/ItemRarity_FinalTierMatrixSimulation.txt (report only; active UI tier unchanged).")
end

function ItemRarityUtilityCalculator.writeFinalTierSimulationReport(results)
    if not UTILITY.diagnosticsEnabled or not getFileWriter then return end
    local writer = getFileWriter("ItemRarity_FinalTierSimulation.txt", true, false)
    if not writer then return end

    local utilityPercentiles = buildUtilityPercentilesByNormalizationGroup(results)
    local active, proposed = newDistribution(), newDistribution()
    local assessments = {}
    local cappedWithoutUtility, promotedByUtility, loweredScarcityOnly = 0, 0, 0
    local exoticCandidates, exoticBaseOnly = {}, 0

    for fullType, data in pairs(results) do
        local proposedTier, reason, facts = simulatedFinalTierFromAxes(data, utilityPercentiles[fullType])
        assessments[fullType] = { tier = proposedTier, reason = reason, facts = facts, utilityPercentile = utilityPercentiles[fullType] }
        active[data.finalRarityTier] = active[data.finalRarityTier] + 1
        proposed[proposedTier] = proposed[proposedTier] + 1
        if not facts.trustedUtility and (TIER_INDEX[data.baseScarcityTier] or 0) > TIER_INDEX.RARE and proposedTier == "RARE" then
            cappedWithoutUtility = cappedWithoutUtility + 1
        end
        if (TIER_INDEX[proposedTier] or 0) > (TIER_INDEX[facts.scarcityCeiling] or 0) then
            promotedByUtility = promotedByUtility + 1
        end
        if (TIER_INDEX[data.finalRarityTier] or 0) > TIER_INDEX.RARE and (TIER_INDEX[proposedTier] or 0) <= TIER_INDEX.RARE then
            loweredScarcityOnly = loweredScarcityOnly + 1
        end
        if proposedTier == "EXOTIC" then
            table.insert(exoticCandidates, data)
            if data.module == "Base" then exoticBaseOnly = exoticBaseOnly + 1 end
        end
    end

    writer:write("Item Rarity FinalRarityTier axis simulation (REPORT ONLY)\n")
    writer:write("No active tier, WeaponUtility V2, Strategy D/scarcity data, registry or UI field is changed by this report.\n")
    writer:write("Default comparison below uses B3 (Path B >= p90). Scenario sections compare B1=p80, B2=p85 and B3=p90. Scarcity alone caps visual tier at RARE; EPIC requires scarcity >= RARE + UtilityPercentile >= 90 + confidence >= "
        .. tostring(UTILITY.minimumConfidenceForAdjustment) .. "; EXOTIC Path A requires ScarcityTier >= EPIC + UtilityPercentile >= 95 + HIGH confidence. subgroupPercentile is diagnostic only. COMMON/UNCOMMON can gain at most one tier from UtilityPercentile >= 90.\n")
    writer:write("ScarcityPercentile below is Strategy D routeWeightedPercentile / availability percentile: lower means scarcer.\n\n")
    writeDistribution(writer, "CURRENT ACTIVE FINAL", active)
    writeDistribution(writer, "PROPOSED SIMULATION", proposed)
    writer:write(string.format("CAPPED_AT_RARE_NO_TRUSTED_UTILITY=%d | PROMOTED_BY_UTILITY_ABOVE_SCARCITY_CEILING=%d | LOWERED_FROM_ACTIVE_EPIC_OR_EXOTIC_TO_RARE_OR_LOWER=%d\n\n",
        cappedWithoutUtility, promotedByUtility, loweredScarcityOnly))

    writer:write("REQUIRED COMPARISON\n")
    writer:write("fullType | ScarcityTier | ScarcityPercentile | UtilityPercentile | UtilityConfidence | subgroupPercentile | FinalTier current | FinalTier proposed | reason\n")
    local targets = {
        "Base.Katana", "Base.Machete", "Base.GardenFork", "Base.HuntingKnife", "Base.HuntingKnifeForged",
        "Base.BaseballBat", "Base.Crowbar", "Base.Axe", "Base.BlockMaul", "Base.Cudgel_ScrapSheet",
        "Base.HollowBook_Handgun", "LB.Bag_LegendaryBackpack", "LK.LegendaryKatanaOrange", "LTW.LegendaryTacticalSword",
    }
    for _, fullType in ipairs(targets) do
        local data, assessment = results[fullType], assessments[fullType]
        if not data then
            writer:write(fullType .. " | unavailable in this loaded runtime\n")
        else
            local subgroup = "N/A"
            if data.utilitySubgroupPercentile ~= nil then subgroup = string.format("%.2f (diagnostic)", data.utilitySubgroupPercentile) end
            writer:write(string.format("%s | %s | %.2f | %s | %s | %s | %s | %s | %s\n", fullType,
                tostring(data.baseScarcityTier), data.tableAvailability.routeWeightedPercentile or -1,
                assessment.utilityPercentile and string.format("%.2f", assessment.utilityPercentile) or "N/A",
                tostring(data.utilityConfidence), subgroup, tostring(data.finalRarityTier), assessment.tier, assessment.reason))
        end
    end
    table.sort(exoticCandidates, function(a, b)
        local aPercentile, bPercentile = utilityPercentiles[a.fullType] or -1, utilityPercentiles[b.fullType] or -1
        if aPercentile == bPercentile then return a.fullType < b.fullType end
        return aPercentile > bPercentile
    end)
    writer:write("\nALL PROPOSED EXOTIC CANDIDATES\n")
    writer:write("Counts use the approved V2 scores from this loaded runtime: Base-only item subset=" .. tostring(exoticBaseOnly)
        .. " | all loaded items=" .. tostring(#exoticCandidates) .. ".\n")
    writer:write("fullType | module | ScarcityTier | ScarcityPercentile | UtilityPercentile | UtilityConfidence | subgroupPercentile | FinalTier | path\n")
    if #exoticCandidates == 0 then writer:write("none\n") end
    for _, data in ipairs(exoticCandidates) do
        local assessment = assessments[data.fullType]
        local subgroup = data.utilitySubgroupPercentile and string.format("%.2f (diagnostic)", data.utilitySubgroupPercentile) or "N/A"
        writer:write(string.format("%s | %s | %s | %.2f | %.2f | %s | %s | %s | %s\n", data.fullType,
            tostring(data.module), tostring(data.baseScarcityTier), data.tableAvailability.routeWeightedPercentile or -1,
            assessment.utilityPercentile or -1, tostring(data.utilityConfidence), subgroup, assessment.tier, assessment.reason))
    end
    writeExoticThresholdScenario(writer, results, utilityPercentiles, 80)
    writeExoticThresholdScenario(writer, results, utilityPercentiles, 85)
    writeExoticThresholdScenario(writer, results, utilityPercentiles, 90)
    writer:close()
    ItemRarityUtils.info("FinalRarityTier axis simulation written to Zomboid/Lua/ItemRarity_FinalTierSimulation.txt (report only; active UI tier unchanged).")
end

-- Historical Clothing diagnostics were moved to Diagnostics/ClothingReports.

function ItemRarityUtilityCalculator.writeReports(results)
    if not ItemRarityConfig.devReportsEnabled or not getFileWriter then return end
    local details = getFileWriter("ItemRarity_UtilityReport.txt", true, false)
    local changes = getFileWriter("ItemRarity_UtilityTierChanges.txt", true, false)
    if not details or not changes then return end

    local ordered = {}
    for _, data in pairs(results) do table.insert(ordered, data) end
    table.sort(ordered, function(a, b) return a.fullType < b.fullType end)
    details:write("Item Rarity Utility and FinalRarityTier report\n")
    details:write("Strategy D remains the base scarcity tier. UI uses FinalRarityTier.\n")
    details:write("fullType | category | subgroup | utilitySupport | base | scarcityPercentile | utility | utilityConfidence | eligible | adjustment | final\n")
    for _, data in ipairs(ordered) do
        details:write(string.format("%s | %s | %s | %s | %s | %.3f | %s | %s | %s | %s | %s\n",
            data.fullType, tostring(data.category), tostring(data.utilitySubgroup or "-"), tostring(data.utilitySupport or "UTILITY_UNSUPPORTED"), tostring(data.baseScarcityTier),
            data.tableAvailability.routeWeightedPercentile or -1, data.utility and string.format("%.2f", data.utility) or "-",
            tostring(data.utilityConfidence), tostring(data.utilityEligible), tostring(data.utilityAdjustmentReason), tostring(data.finalRarityTier)))
    end
    details:close()

    local baseGlobal, finalGlobal = newDistribution(), newDistribution()
    local byCategory, promoted, demoted, unchanged = {}, {}, {}, {}
    for _, data in ipairs(ordered) do
        baseGlobal[data.baseScarcityTier] = baseGlobal[data.baseScarcityTier] + 1
        finalGlobal[data.finalRarityTier] = finalGlobal[data.finalRarityTier] + 1
        local category = byCategory[data.category] or { base = newDistribution(), final = newDistribution() }
        category.base[data.baseScarcityTier] = category.base[data.baseScarcityTier] + 1
        category.final[data.finalRarityTier] = category.final[data.finalRarityTier] + 1
        byCategory[data.category] = category
        if data.finalRarityTier ~= data.baseScarcityTier then
            if (TIER_INDEX[data.finalRarityTier] or 0) > (TIER_INDEX[data.baseScarcityTier] or 0) then table.insert(promoted, data) else table.insert(demoted, data) end
        else
            table.insert(unchanged, data)
        end
    end
    changes:write("Item Rarity FinalRarityTier change report (UI uses FinalRarityTier)\n")
    writeDistribution(changes, "GLOBAL BASE", baseGlobal)
    writeDistribution(changes, "GLOBAL FINAL", finalGlobal)
    for _, categoryName in ipairs(sortedKeys(byCategory)) do
        writeDistribution(changes, "CATEGORY " .. categoryName .. " BASE", byCategory[categoryName].base)
        writeDistribution(changes, "CATEGORY " .. categoryName .. " FINAL", byCategory[categoryName].final)
    end
    local function profileCount(list)
        local profiles = {}
        for _, data in ipairs(list) do
            if data.utilityProfile then profiles[(data.utilityKind or "UNKNOWN") .. ":" .. data.utilityProfile] = true end
        end
        local total = 0
        for _ in pairs(profiles) do total = total + 1 end
        return total
    end
    changes:write(string.format("\nPROMOTED=%d items | %d mechanical profiles | DEMOTED=%d items | UNCHANGED=%d\n",
        #promoted, profileCount(promoted), #demoted, #unchanged))
    local function writeList(label, list, limit)
        changes:write("\n" .. label .. "\n")
        for index, data in ipairs(list) do
            if index > limit then break end
            changes:write(string.format("%s | %s -> %s | utility=%s | confidence=%s | %s\n", data.fullType,
                data.baseScarcityTier, data.finalRarityTier, data.utility and string.format("%.2f", data.utility) or "-",
                data.utilityConfidence, data.utilityAdjustmentReason))
        end
    end
    writeList("PROMOTED", promoted, #promoted)
    writeList("DEMOTED", demoted, #demoted)
    writeList("UNCHANGED EXAMPLES", unchanged, 100)
    changes:close()
    ItemRarityUtils.info(string.format("Utility experiment: promoted=%d | demoted=%d | unchanged=%d. Reports written to Zomboid/Lua/ItemRarity_UtilityReport.txt and ItemRarity_UtilityTierChanges.txt.", #promoted, #demoted, #unchanged))
    ItemRarityUtilityCalculator.writeCalibrationReport(results)
    ItemRarityUtilityCalculator.writeSubfamilyPromotionReport(results)
    ItemRarityUtilityCalculator.writeVanillaBaselineReport(results)
    require "ItemRarity/Diagnostics/WeaponLaboratory"
    ItemRarityWeaponLaboratory.writeAnalysis(results)
    require "ItemRarity/Diagnostics/WeaponReports"
    ItemRarityWeaponReports.writeV1ToV2(results)
    ItemRarityUtilityCalculator.writeFinalTierSimulationReport(results)
    ItemRarityUtilityCalculator.writeFinalTierMatrixSimulationReport(results)
    require "ItemRarity/Diagnostics/ClothingReports"
    ItemRarityClothingReports.writeAll(results)
end
