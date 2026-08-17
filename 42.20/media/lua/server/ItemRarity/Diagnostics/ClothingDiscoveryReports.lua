require "ItemRarity/RarityConfig"
require "ItemRarity/RarityUtils"
require "ItemRarity/UtilityCalculator"
ItemRarityClothingDiscoveryReports = ItemRarityClothingDiscoveryReports or {}
local API = ItemRarityUtilityCalculator.getClothingDiagnosticApi()
local UTILITY = API.UTILITY
local NORMALIZATION = API.NORMALIZATION
local sortedKeys = API.sortedKeys
local newDistribution = API.newDistribution
local matrixTierFromAxes = API.matrixTierFromAxes
local function writeClothingUtilityDiscoveryReport(results)
    if not UTILITY.diagnosticsEnabled or not getFileWriter then return end
    local writer = getFileWriter("ItemRarity_ClothingUtilityDiscovery.txt", true, false)
    if not writer then return end
    local clothing, functionalSlots, comparisonSlots, metricAvailability, profiles = {}, {}, {}, {}, {}
    local metricNames = { "biteDefense", "scratchDefense", "bulletDefense", "insulation", "windResistance", "waterResistance",
        "conditionMax", "conditionLowerChance", "durability", "weight", "runSpeedModifier", "combatSpeedModifier", "discomfortModifier",
        "visionModifier", "hearingModifier", "enduranceModifier", "movementModifier", "fatigueChange", "wetness", "coverageZoneCount" }
    for _, name in ipairs(metricNames) do metricAvailability[name] = 0 end
    for _, data in pairs(results) do
        if data.category == "CLOTHING" then
            table.insert(clothing, data)
            local slot = data.utilityFunctionalGroup or "GENERAL_CLOTHING"
            functionalSlots[slot] = functionalSlots[slot] or { items = 0, profiles = {}, unresolved = 0 }
            functionalSlots[slot].items = functionalSlots[slot].items + 1
            if data.utilityProfile then functionalSlots[slot].profiles[data.utilityProfile] = true end
            if not (data.clothingEquipmentGraph and data.clothingEquipmentGraph.resolved) then functionalSlots[slot].unresolved = functionalSlots[slot].unresolved + 1 end
            local comparison = data.utilityFunctionalComparisonGroup or ("CLOTHING_FUNCTION:" .. slot)
            comparisonSlots[comparison] = comparisonSlots[comparison] or { profiles = {} }
            if data.utilityProfile then comparisonSlots[comparison].profiles[data.utilityProfile] = true end
            if data.utilityProfile then profiles[data.utilityProfile] = true end
            for _, name in ipairs(metricNames) do
                if data.utilityMetrics and data.utilityMetrics[name] ~= nil then metricAvailability[name] = metricAvailability[name] + 1 end
            end
        end
    end
    table.sort(clothing, function(a, b)
        local as, bs = tostring(a.utilityFunctionalGroup or "GENERAL_CLOTHING"), tostring(b.utilityFunctionalGroup or "GENERAL_CLOTHING")
        return as == bs and a.fullType < b.fullType or as < bs
    end)
    local function countSet(set)
        local total = 0
        for _ in pairs(set) do total = total + 1 end
        return total
    end
    local function value(metrics, name)
        local number = metrics and metrics[name]
        return number ~= nil and string.format("%.3f", number) or "N/A"
    end
    local matrixThresholds = { p70 = 70, p80 = 80, p90 = 90, p95 = 95 }
    local function hypotheticalTier(data)
        if data.utility == nil or data.clothingUtilityPercentile == nil then return "RARE", "no ClothingUtility score; ceiling RARE" end
        return matrixTierFromAxes({ baseScarcityTier = data.baseScarcityTier, rarityTier = data.baseScarcityTier,
            utilityEligible = true, utility = data.utility, utilityConfidence = data.utilityConfidence }, data.clothingUtilityPercentile, matrixThresholds)
    end
    local function functionGatedTier(data)
        local rawTier, rawReason, band = hypotheticalTier(data)
        if data.utilityFunctionalGroup == "ARMOR_ACCESSORY" and rawTier == "EXOTIC" then
            local regions = data.clothingDiscovery and data.clothingDiscovery.coveredRegions or {}
            if #regions < 2 then
                return "EPIC", rawReason .. "; FUNCTION GATE: one-region armor accessory is not role-equivalent to primary armor for EXOTIC", band
            end
        end
        return rawTier, rawReason, band
    end
    local function writeItem(data)
        local discovery, metrics, components = data.clothingDiscovery or {}, data.utilityMetrics or {}, data.utilityComponents or {}
        local rawTier, rawReason = hypotheticalTier(data)
        local gatedTier, gatedReason = functionGatedTier(data)
        local graph = data.clothingEquipmentGraph or {}
        local debuffs = string.format("run=%s,combat=%s,discomfort=%s,vision=%s,hearing=%s", value(metrics, "runSpeedModifier"), value(metrics, "combatSpeedModifier"),
            value(metrics, "discomfortModifier"), value(metrics, "visionModifier"), value(metrics, "hearingModifier"))
        local fields = {
            data.fullType, tostring(data.utilityPriorFunctionalGroup or "GENERAL_CLOTHING") .. " -> " .. tostring(data.utilityFunctionalGroup or "GENERAL_CLOTHING"), tostring(data.utilityFunctionalGroupReason or "-"), tostring(data.utilityFunctionalComparisonGroup or "-"),
            tostring(data.utilitySubgroup or "OTHER"), tostring(discovery.topology or "OTHER"),
            graph.resolved and ("slot=" .. tostring(graph.slotId) .. ",exclusives=" .. tostring(graph.exclusiveCount)) or "BodyLocation unresolved", tostring(data.utilitySupport or "UTILITY_LOW_CONFIDENCE"),
            #(discovery.coveredRegions or {}) > 0 and table.concat(discovery.coveredRegions, "+") or "N/A", tostring(discovery.coverageZones or "UNKNOWN"), tonumber(discovery.coverageZoneCount) or 0,
            value(metrics, "biteDefense"), value(metrics, "scratchDefense"), value(metrics, "bulletDefense"), value(components, "protectionCoverage"), value(components, "protectionBase"), value(components, "coverageFactor"),
            value(metrics, "runSpeedModifier"), value(metrics, "combatSpeedModifier"), value(components, "mobility"), value(metrics, "weight"), value(components, "weight"), value(metrics, "discomfortModifier"), debuffs,
            value(components, "durability"), value(components, "weatherProtection"), data.utility and string.format("%.3f", data.utility) or "N/A",
            data.clothingLegacyUtility and string.format("%.3f", data.clothingLegacyUtility) or "N/A",
            (data.clothingLegacyUtilityPercentile and string.format("%.2f", data.clothingLegacyUtilityPercentile) or "N/A") .. " -> " .. (data.clothingUtilityPercentile and string.format("%.2f", data.clothingUtilityPercentile) or "N/A"),
            data.clothingUtilityGlobalPercentile and string.format("%.2f", data.clothingUtilityGlobalPercentile) or "N/A",
            tostring(data.utilityConfidence), tostring(data.baseScarcityTier), tostring(data.finalRarityTier), rawTier, gatedTier, gatedReason,
        }
        writer:write(table.concat(fields, " | ") .. "\n")
    end
    writer:write("Item Rarity ClothingUtility simulation report (REPORT ONLY)\n")
    writer:write("ClothingUtility is calculated only for diagnostics. Clothing remains excluded from active FinalRarityTier adjustment, the frozen Scarcity x Utility matrix input and UI publication. Strategy D and WeaponUtility V2 are untouched.\n")
    writer:write("Runtime items are instantiated only to probe B42 getters; no item is put in an inventory or transmitted. Blood/wetness levels are dynamic character state and are not treated as intrinsic item Utility. BloodLocation/covered parts is retained only as static coverage evidence.\n\n")
    writer:write(string.format("CLOTHING_ITEMS=%d | UNIQUE_MECHANICAL_PROFILES=%d\n", #clothing, countSet(profiles)))
    writer:write("RUNTIME ATTRIBUTE AVAILABILITY\n")
    for _, name in ipairs(metricNames) do writer:write(string.format("%s = %d/%d\n", name, metricAvailability[name], #clothing)) end
    writer:write("\nFUNCTIONAL EQUIPMENT GROUPS (BodyLocation + conflict graph + anatomy)\n")
    for _, slot in ipairs({ "PRIMARY_ARMOR", "ARMOR_ACCESSORY", "TORSO_LAYER", "LOWER_BODY_LAYER", "CORE_ACCESSORY", "HEADGEAR", "FOOTWEAR", "FULL_BODY_RESTRICTIVE", "GENERAL_UNRESOLVED" }) do
        local summary = functionalSlots[slot]
        -- The comparison bucket may intentionally differ from the native role.
        -- In particular, the tiny CORE_ACCESSORY role borrows the transparent
        -- general-layer parent; do not display its two native profiles as if
        -- they were its percentile reference sample.
        local comparisonKey
        local comparisonProfiles
        local observedConfidence
        for _, data in ipairs(clothing) do
            if data.utilityFunctionalGroup == slot and data.utilityFunctionalComparisonGroup then
                comparisonKey = data.utilityFunctionalComparisonGroup
                comparisonProfiles = data.utilityFunctionalComparisonProfileCount
                observedConfidence = data.utilityConfidence
                break
            end
        end
        local comparison = comparisonKey and comparisonSlots[comparisonKey] or comparisonSlots["CLOTHING_FUNCTION:" .. slot]
        writer:write(string.format("%s | items=%d | native profiles=%d | comparison profiles=%d | unresolved BodyLocations=%d | confidence=%s\n", slot, summary and summary.items or 0,
            summary and countSet(summary.profiles) or 0, comparisonProfiles or (comparison and countSet(comparison.profiles) or 0), summary and summary.unresolved or 0,
            observedConfidence or ((summary and countSet(summary.profiles) or 0) >= NORMALIZATION.highConfidenceProfiles and "HIGH-capable" or ((summary and countSet(summary.profiles) or 0) >= NORMALIZATION.minimumProfiles and "MEDIUM-capable" or "LOW only"))))
    end
    writer:write("\nFUNCTIONAL PROFILE CATALOG (profile-deduplicated)\n")
    writer:write("functional group | comparison group | profile | items sharing profile | examples\n")
    local profileCatalog = {}
    for _, data in ipairs(clothing) do
        local group = data.utilityFunctionalGroup or "GENERAL_UNRESOLVED"
        local key = group .. "\t" .. tostring(data.utilityProfile or data.fullType)
        profileCatalog[key] = profileCatalog[key] or { group = group, comparison = data.utilityFunctionalComparisonGroup or "-", profile = data.utilityProfile or data.fullType, items = 0, examples = {} }
        local entry = profileCatalog[key]
        entry.items = entry.items + 1
        if #entry.examples < 6 then table.insert(entry.examples, data.fullType) end
    end
    local catalogKeys = sortedKeys(profileCatalog)
    for _, key in ipairs(catalogKeys) do
        local entry = profileCatalog[key]
        writer:write(string.format("%s | %s | %s | %d | %s\n", entry.group, entry.comparison, entry.profile, entry.items, table.concat(entry.examples, ",")))
    end
    writer:write("\nIMPLEMENTED DIAGNOSTIC ARCHITECTURE\n")
    writer:write("ProtectionCoverage 60% = [bite 50%, scratch 35%, bullet 15%] x anatomical coverage factor (moderate B42 structural weighting, 0.70..1.00). Coverage is a multiplier, never a standalone score. Mobility 15% = run 70% + combat 30%; inverse Weight 10%; Durability 10% = log(1 + ConditionMax x ConditionLowerChance); WeatherProtection 5% = insulation 40% + wind 35% + water 25%.\n")
    writer:write("Metrics are p05-p95 winsorized and profile-deduplicated within the functional equipment group. Utility percentile is also calculated only from that group. A group with <12 profiles is LOW confidence; 12-19 MEDIUM; 20+ HIGH-capable. CORE_ACCESSORY with <12 native profiles uses GENERAL_LAYER_PARENT only as a transparent reference fallback and is capped MEDIUM. Missing essential evidence is UTILITY_LOW_CONFIDENCE, never an invented zero.\n")
    writer:write("Raw matrix uses the frozen Scarcity x Utility matrix with the functional-group percentile. A separate role-gate sensitivity column demotes only a one-region ARMOR_ACCESSORY from raw EXOTIC to EPIC: this tests the semantic rule that accessory p95 is not automatically equivalent to primary-armor p95. It is not active and does not alter the frozen matrix.\n")
    local bulletItems = 0
    for _, data in ipairs(clothing) do if data.utilityMetrics and (data.utilityMetrics.bulletDefense or 0) > 0 then bulletItems = bulletItems + 1 end end
    writer:write(string.format("BULLET DIAGNOSTIC: %d/%d items have BulletDefense > 0. At 15%% of ProtectionCoverage (60%% of total), bullet contributes at most 9%% of total pre-coverage Utility; bite+scratch contribute 51%%, so ballistic defense is meaningful but not dominant.\n\n", bulletItems, #clothing))
    writer:write("The earlier anatomical A/B/C and cost-strength stress tests are intentionally not used here: this report isolates the requested functional-group simulation while retaining each item's intrinsic cost fields below.\n\n")
    writer:write("REQUIRED AND VANILLA REFERENCE COMPARISON\n")
    writer:write("fullType | prior -> functional group | functional reason | comparison group | legacy group | topology | graph | support | protected regions | coverage zones | coverage count | bite | scratch | bullet | ProtectionCoverage | protection base | anatomical factor | RunSpeed | CombatSpeed | Mobility | ActualWeight | WeightEfficiency | Discomfort | all intrinsic debuffs | Durability | Weather | ClothingUtility | LegacyUtility | LegacyPercentile -> FunctionalPercentile | GlobalDiagnosticPercentile | Confidence | ScarcityTier | Final active | Raw matrix tier | Function-gated tier | reason\n")
    local targets = { "Base.Gorget_Metal", "Base.Vambrace_Left", "Base.Vambrace_Right", "Base.Shoulderpad_Articulated_L_Metal", "Base.Shoulderpad_Articulated_R_Metal", "Base.Chainmail_SleeveFull_L", "Base.Chainmail_SleeveFull_R", "Base.Cuirass_Metal", "Base.Cuirass_Tire", "Base.HazmatSuit", "Base.Shoes_WorkBoots", "Base.Shoes_BlueTrainers", "Base.Hat_MetalHelmet", "Base.Jacket_ArmyCamoGreen", "Base.Vest_BulletSWAT", "Base.Trousers_ArmyService", "Base.Gloves_IceHockeyGloves", "Base.Shoes_ArmyBoots", "Base.Boilersuit" }
    for _, fullType in ipairs(targets) do if results[fullType] then writeItem(results[fullType]) else writer:write(fullType .. " | unavailable\n") end end
    local byGroup = {}
    for _, data in ipairs(clothing) do local group = data.utilityFunctionalGroup or "GENERAL_CLOTHING"; byGroup[group] = byGroup[group] or {}; table.insert(byGroup[group], data) end
    for _, groupName in ipairs({ "PRIMARY_ARMOR", "ARMOR_ACCESSORY", "TORSO_LAYER", "LOWER_BODY_LAYER", "CORE_ACCESSORY", "HEADGEAR", "FOOTWEAR", "FULL_BODY_RESTRICTIVE" }) do
        local group = byGroup[groupName] or {}
        table.sort(group, function(a, b) return (a.utility or -1) > (b.utility or -1) end)
        writer:write("\nTOP 20 " .. groupName .. "\n")
        for index, data in ipairs(group) do if index <= 20 then writeItem(data) end end
        table.sort(group, function(a, b) return (a.utility or 101) < (b.utility or 101) end)
        writer:write("\nBOTTOM 20 " .. groupName .. "\n")
        for index, data in ipairs(group) do if index <= 20 then writeItem(data) end end
    end
    local epic, exoticRaw, exoticGated = {}, {}, {}
    for _, data in ipairs(clothing) do
        local tier = hypotheticalTier(data)
        local gated = functionGatedTier(data)
        if tier == "EXOTIC" then table.insert(exoticRaw, data) elseif tier == "EPIC" then table.insert(epic, data) end
        if gated == "EXOTIC" then table.insert(exoticGated, data) end
    end
    table.sort(epic, function(a, b) return (a.utility or -1) > (b.utility or -1) end)
    table.sort(exoticRaw, function(a, b) return (a.utility or -1) > (b.utility or -1) end)
    table.sort(exoticGated, function(a, b) return (a.utility or -1) > (b.utility or -1) end)
    writer:write("\nHYPOTHETICAL MATRIX EPIC CANDIDATES (CLOTHING ONLY; NOT ACTIVE)\n")
    if #epic == 0 then writer:write("none\n") else for _, data in ipairs(epic) do writeItem(data) end end
    writer:write("\nRAW FUNCTIONAL-GROUP MATRIX EXOTIC CANDIDATES (CLOTHING ONLY; NOT ACTIVE)\n")
    if #exoticRaw == 0 then writer:write("none\n") else for _, data in ipairs(exoticRaw) do writeItem(data) end end
    writer:write("\nFUNCTION-GATED EXOTIC CANDIDATES (one-region ARMOR_ACCESSORY guard; NOT ACTIVE)\n")
    if #exoticGated == 0 then writer:write("none\n") else for _, data in ipairs(exoticGated) do writeItem(data) end end
    writer:close()
    ItemRarityUtils.info("ClothingUtility simulation report written to Zomboid/Lua/ItemRarity_ClothingUtilityDiscovery.txt (report only; active tier and UI unchanged).")
end

local function writeClothingV1ActivationReport(results)
    if not UTILITY.diagnosticsEnabled or not getFileWriter then return end
    local writer = getFileWriter("ItemRarity_ClothingUtilityV1Activation.txt", true, false)
    if not writer then return end
    local global, clothing = newDistribution(), newDistribution()
    for _, data in pairs(results) do
        global[data.finalRarityTier] = global[data.finalRarityTier] + 1
        if data.category == "CLOTHING" then clothing[data.finalRarityTier] = clothing[data.finalRarityTier] + 1 end
    end
    writer:write("Item Rarity ClothingUtility V1 activation audit\n")
    writer:write("Active: P2 protection component = 40% RelativeProtection + 60% AbsoluteProtection; comparisons use exact resolved DIRECT_SLOT. Strategy D, WeaponUtility V2 and the frozen Balanced matrix are unchanged.\n\n")
    writer:write(string.format("GLOBAL FINAL | COMMON=%d | UNCOMMON=%d | RARE=%d | EPIC=%d | EXOTIC=%d\n", global.COMMON, global.UNCOMMON, global.RARE, global.EPIC, global.EXOTIC))
    writer:write(string.format("CLOTHING FINAL | COMMON=%d | UNCOMMON=%d | RARE=%d | EPIC=%d | EXOTIC=%d\n\n", clothing.COMMON, clothing.UNCOMMON, clothing.RARE, clothing.EPIC, clothing.EXOTIC))
    writer:write("REQUIRED BEFORE/AFTER\n")
    writer:write("fullType | ScarcityTier | ClothingUtility | SlotPercentile | UtilityConfidence | SlotRankingConfidence | FinalTierBefore | FinalTierAfter\n")
    local targets = { "Base.Jacket_Leather", "Base.Jacket_NavyBlue", "Base.Jacket_Fireman", "Base.Cuirass_Metal", "Base.Cuirass_Tire",
        "Base.Hat_MetalHelmet", "Base.Hat_RiotHelmet", "Base.Shoes_WorkBoots", "Base.Shoes_BlueTrainers", "Base.Gorget_Metal",
        "Base.Vambrace_Left", "Base.Shoulderpad_Articulated_L_Metal", "Base.Shoulderpad_Articulated_R_Metal", "Base.ThighMetal_L",
        "Base.Greave_Left", "Base.Shirt_Crafted_Burlap", "Base.Dress_Knees_Crafted_Burlap" }
    for _, fullType in ipairs(targets) do
        local data = results[fullType]
        if not data then writer:write(fullType .. " | unavailable\n") else
            writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s\n", fullType, tostring(data.baseScarcityTier),
                data.utility and string.format("%.2f", data.utility) or "N/A", data.slotQualityPercentile and string.format("%.2f", data.slotQualityPercentile) or "N/A",
                tostring(data.utilityConfidence), tostring(data.slotRankingConfidence), tostring(data.clothingFinalTierBeforeV1), tostring(data.finalRarityTier)))
        end
    end
    writer:close()
    ItemRarityUtils.info("ClothingUtility V1 activation audit written to Zomboid/Lua/ItemRarity_ClothingUtilityV1Activation.txt.")
end

function ItemRarityClothingDiscoveryReports.writeDiscovery(results)
    return writeClothingUtilityDiscoveryReport(results)
end

function ItemRarityClothingDiscoveryReports.writeActivation(results)
    return writeClothingV1ActivationReport(results)
end
