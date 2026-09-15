-- Explicit, read-only classification simulation for ordinary B42 clothing.
-- It clones published result rows, never changes ItemClassifier, scanner
-- results, registry, configuration, loot tables, or any active tier.
require "ItemRarity/RarityUtils"

ItemRarityClothingClassifierFallbackSimulation = ItemRarityClothingClassifierFallbackSimulation or {}

local TARGETS = {
    "Base.Trousers_Denim", "Base.Shorts_ShortDenim", "Base.Jacket_NavyBlue",
    "Base.Jacket_Leather", "Base.JacketLong_Random", "Base.Shoes_WorkBoots",
    "Base.Cuirass_Metal", "Base.Vambrace_FullMetal_Left", "Base.Briefs_SmallTrunks_Black",
}

local function text(value)
    local result = tostring(value or "")
    return result ~= "" and result or "-"
end

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function callMethod(object, name)
    if not object or type(object[name]) ~= "function" then return nil end
    local ok, result = pcall(function() return object[name](object) end)
    return ok and result or nil
end

local function scriptMetadata(fullType)
    local manager = getScriptManager and getScriptManager() or nil
    local item = manager and type(manager.FindItem) == "function" and manager:FindItem(fullType) or nil
    if not item then return { found=false } end
    return {
        found=true,
        displayCategory=text(callMethod(item, "getDisplayCategory")),
        itemType=text(callMethod(item, "getItemType")),
        bodyLocation=text(callMethod(item, "getBodyLocation")),
        bloodClothingType=text(callMethod(item, "getBloodClothingType")),
    }
end

-- B42 exposes a generic `base:clothing` type for garments *and* some worn
-- jewelry/accessories.  These exclusions use only runtime structural signals:
-- the Clothing display subtype and equip/body location, never a name or type.
local function isStructuralAccessoryOrContainer(metadata)
    local display, slot = lower(metadata.displayCategory), lower(metadata.bodyLocation)
    if display == "accessory" or display == "clothjew" or display == "clothacc" then return true, "accessory display subtype" end
    for _, token in ipairs({ "eye", "lefteye", "righteye", "ear", "wrist", "neck", "finger", "belly", "tail", "belt", "satchel", "backpack" }) do
        if string.find(slot, ":" .. token, 1, true) then return true, "accessory/container body location: " .. token end
    end
    return false, nil
end

-- A category already resolved from a specific DisplayCategory keeps priority.
-- The base:clothing fallback applies only after the structural exclusions.
local function proposedCategory(data, metadata)
    local current, display, itemType = text(data.category), lower(metadata.displayCategory), lower(metadata.itemType)
    if current ~= "UNKNOWN" and current ~= "MISC" then return current, false, "already specific" end
    local excluded, reason = isStructuralAccessoryOrContainer(metadata)
    if excluded then return current, false, reason end
    if itemType == "base:clothing" then return "CLOTHING", true, "base:clothing fallback after no specific category" end
    return current, false, "no clothing structural fallback"
end

local function structuralFamily(metadata)
    local slot, blood = lower(metadata.bodyLocation), lower(metadata.bloodClothingType)
    if string.find(slot, "pants", 1, true) or string.find(blood, "trousers", 1, true) then return "pants/trousers" end
    if string.find(slot, "short", 1, true) or string.find(blood, "shorts", 1, true) then return "shorts" end
    if string.find(slot, "jacket", 1, true) or string.find(slot, "coat", 1, true) then return "jackets/coats" end
    if string.find(slot, "shirt", 1, true) or string.find(slot, "torso", 1, true) then return "shirts/torso" end
    if string.find(slot, "shoe", 1, true) or string.find(slot, "foot", 1, true) then return "footwear" end
    if string.find(slot, "underwear", 1, true) or string.find(blood, "underwear", 1, true) then return "underwear" end
    return "other clothing"
end

local function shallowCopy(source)
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    return copy
end

local function tierCounts()
    return { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }
end

local function joinTierCounts(counts)
    return string.format("COMMON=%d | UNCOMMON=%d | RARE=%d | EPIC=%d | EXOTIC=%d", counts.COMMON, counts.UNCOMMON, counts.RARE, counts.EPIC, counts.EXOTIC)
end

local function writeAudit(results)
    if type(results) ~= "table" or not getFileWriter then return false end

    local simulated, changed, accessoryExempt, impact = {}, {}, {}, {}
    for fullType, data in pairs(results) do
        local metadata = scriptMetadata(fullType)
        local category, changedToClothing, reason = proposedCategory(data, metadata)
        local copy = shallowCopy(data)
        copy.category = category
        copy.displayCategory = metadata.displayCategory ~= "-" and metadata.displayCategory or data.displayCategory
        simulated[fullType] = copy
        local key = text(data.category) .. " -> " .. category
        impact[key] = (impact[key] or 0) + 1
        if changedToClothing then
            table.insert(changed, { fullType=fullType, source=data, simulated=copy, metadata=metadata, family=structuralFamily(metadata), reason=reason })
        elseif lower(metadata.itemType) == "base:clothing" and isStructuralAccessoryOrContainer(metadata) then
            table.insert(accessoryExempt, { fullType=fullType, source=data, metadata=metadata, reason=reason })
        end
    end

    -- Calculate only against cloned rows. The active scanner/registry remains
    -- untouched; this is the closest exact simulation of the active utility
    -- order without publishing a different result set.
    local calculated = ItemRarityUtilityCalculator and ItemRarityUtilityCalculator.calculate(simulated)
    if not calculated then
        ItemRarityUtils.warn("Clothing classifier fallback simulation could not access UtilityCalculator")
        return false
    end

    local categoryCounts, directCount, trivialCount, accessoryCount, unknownCount = {}, 0, 0, 0, 0
    local tierDistribution = tierCounts()
    for _, data in pairs(simulated) do
        categoryCounts[data.category or "UNKNOWN"] = (categoryCounts[data.category or "UNKNOWN"] or 0) + 1
        if data.category == "CLOTHING" and data.utilityComponents and data.utilityComponents.directSlot ~= nil then directCount = directCount + 1 end
        if data.category == "CLOTHING" and data.clothingMechanicalValueStatus == "MECHANICALLY_TRIVIAL" then trivialCount = trivialCount + 1 end
        if data.accessoryMechanicalValueStatus then accessoryCount = accessoryCount + 1 end
        if data.category == "UNKNOWN" then unknownCount = unknownCount + 1 end
        if data.category == "CLOTHING" and tierDistribution[data.finalRarityTier] ~= nil then tierDistribution[data.finalRarityTier] = tierDistribution[data.finalRarityTier] + 1 end
    end

    table.sort(changed, function(a, b) return a.fullType < b.fullType end)
    table.sort(accessoryExempt, function(a, b) return a.fullType < b.fullType end)
    local writer = getFileWriter("ItemRarity_ClothingClassifierFallbackSimulation.txt", true, false)
    if not writer then return false end
    writer:write("Item Rarity Clothing classifier fallback simulation (READ ONLY)\n")
    writer:write("This simulation clones published rows, applies only the proposed structural fallback, and runs UtilityCalculator on the clone. It never mutates the active classifier, active scanner results, registry, UI, loot tables, configuration or published tiers.\n\n")
    writer:write("CANDIDATE RULE\n")
    writer:write("If no more-specific functional category was resolved, ScriptItem ItemType=base:clothing -> CLOTHING, except structural accessory/container signals: DisplayCategory Accessory/ClothJew/ClothAcc or a body/equip location for eyes, ears, wrist, neck, fingers, belly, tail, belt, satchel or backpack. No item name/fullType rule is used.\n\n")
    writer:write("CATEGORY IMPACT\ncurrent -> proposed | fullTypes\n")
    local impactKeys = {}
    for key in pairs(impact) do table.insert(impactKeys, key) end
    table.sort(impactKeys)
    for _, key in ipairs(impactKeys) do writer:write(key .. " | " .. tostring(impact[key]) .. "\n") end
    writer:write("\nSIMULATED POPULATION\n")
    writer:write("CLOTHING=" .. tostring(categoryCounts.CLOTHING or 0) .. " | DIRECT_SLOT=" .. tostring(directCount) .. " | MECHANICALLY_TRIVIAL=" .. tostring(trivialCount) .. " | ACCESSORY=" .. tostring(accessoryCount) .. " | UNKNOWN=" .. tostring(unknownCount) .. "\n")
    writer:write("Simulated CLOTHING final tiers | " .. joinTierCounts(tierDistribution) .. "\n\n")
    writer:write("ALL PROPOSED -> CLOTHING TRANSITIONS\n")
    writer:write("fullType | currentCategory | structuralFamily | DisplayCategory | ItemType | BodyLocation | BloodClothingType | reason\n")
    for _, entry in ipairs(changed) do
        local m = entry.metadata
        writer:write(table.concat({ entry.fullType, text(entry.source.category), entry.family, text(m.displayCategory), text(m.itemType), text(m.bodyLocation), text(m.bloodClothingType), entry.reason }, " | ") .. "\n")
    end
    writer:write("\nACCESSORY / CONTAINER SAFETY EXEMPTIONS (base:clothing but structural non-garment signal; unchanged)\n")
    writer:write("fullType | currentCategory | DisplayCategory | ItemType | BodyLocation | reason\n")
    for _, entry in ipairs(accessoryExempt) do
        local m = entry.metadata
        writer:write(table.concat({ entry.fullType, text(entry.source.category), text(m.displayCategory), text(m.itemType), text(m.bodyLocation), entry.reason }, " | ") .. "\n")
    end
    writer:write("\nCLOTHING C1 TARGETS IN SIMULATION\n")
    writer:write("fullType | category | directSlot/group | MechanicalState | ClothingScore | ScarcityStrength | C1Adjustment | AdjustedScore | simulatedFinalTier | activeFinalTier\n")
    for _, fullType in ipairs(TARGETS) do
        local data, active = simulated[fullType], results[fullType]
        if data then
            writer:write(table.concat({ fullType, text(data.category), text(data.utilityFunctionalGroup or data.utilitySubgroup), text(data.clothingMechanicalValueStatus),
                string.format("%.3f", tonumber(data.utility) or -1), string.format("%.3f", tonumber(data.clothingScarcityStrength) or -1),
                string.format("%.3f", tonumber(data.clothingScarcityAdjustment) or -1), string.format("%.3f", tonumber(data.clothingAdjustedScore) or -1),
                text(data.finalRarityTier), text(active and active.finalRarityTier) }, " | ") .. "\n")
        else
            writer:write(fullType .. " | not published\n")
        end
    end
    writer:close()
    ItemRarityUtils.info(string.format("Clothing classifier fallback simulation written: %d proposed CLOTHING transitions; simulated CLOTHING=%d, DIRECT_SLOT=%d, TRIVIAL=%d, UNKNOWN=%d.", #changed, categoryCounts.CLOTHING or 0, directCount, trivialCount, unknownCount))
    return true
end

function ItemRarityClothingClassifierFallbackSimulation.write(results)
    return writeAudit(results)
end
