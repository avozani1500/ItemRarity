require "ItemRarity/RarityConfig"
require "ItemRarity/RarityUtils"
require "ItemRarity/UtilityCalculator"
ItemRarityClothingWearabilityReports = ItemRarityClothingWearabilityReports or {}
local API = ItemRarityUtilityCalculator.getClothingDiagnosticApi()
local UTILITY = API.UTILITY
local sortedCopy = API.sortedCopy
local clothingUtilityPercentileOfValue = API.clothingUtilityPercentileOfValue
local matrixTierFromAxes = API.matrixTierFromAxes
local function writeClothingWearabilityAnalysis(results)
    if not UTILITY.diagnosticsEnabled or not getFileWriter then return end
    local writer = getFileWriter("ItemRarity_ClothingWearabilityAnalysis.txt", true, false)
    if not writer then return end
    local clothing, records, groups = {}, {}, {}
    local targets = { "Base.Cuirass_Metal", "Base.Cuirass_Tire", "Base.Hat_MetalHelmet", "Base.Gorget_Metal", "Base.Vambrace_Left",
        "Base.Shoulderpad_Articulated_L_Metal", "Base.Shoulderpad_Articulated_R_Metal", "Base.Chainmail_SleeveFull_L", "Base.Chainmail_SleeveFull_R",
        "Base.HazmatSuit", "Base.Shoes_WorkBoots", "Base.Shoes_BlueTrainers", "Base.Jacket_NavyBlue", "Base.Dress_Knees_Crafted_Burlap" }
    local function clamp100(value) return math.max(0, math.min(100, value or 0)) end
    local function format(value) return value ~= nil and string.format("%.2f", value) or "N/A" end
    for _, data in pairs(results) do if data.category == "CLOTHING" and data.utility ~= nil then table.insert(clothing, data) end end
    for _, data in ipairs(clothing) do
        local metrics, parts, ranks = data.utilityMetrics or {}, data.utilityComponents or {}, data.utilityMetricPercentiles or {}
        local protection = parts.protectionCoverage and parts.durability and (parts.protectionCoverage * .85 + parts.durability * .15) or nil
        -- Run and combat are role-relative retention percentiles. Actual
        -- discomfort/vision/hearing retain their B42 runtime scale: 1 is no
        -- impairment; discomfort is an additive source before the final
        -- BodyDamage discomfort target is multiplied by 100.
        local run = ranks.runSpeedModifier
        local combat = ranks.combatSpeedModifier
        local weight = parts.weight
        local comfort = metrics.discomfortModifier ~= nil and clamp100((1 - metrics.discomfortModifier) * 100) or nil
        local vision = metrics.visionModifier ~= nil and clamp100(metrics.visionModifier * 100) or nil
        local hearing = metrics.hearingModifier ~= nil and clamp100(metrics.hearingModifier * 100) or nil
        local wearability = run and combat and weight and comfort and vision and hearing
            and (run * .25 + combat * .20 + weight * .20 + comfort * .15 + vision * .10 + hearing * .10) or nil
        local geometric = protection and wearability and math.sqrt(protection * wearability) or nil
        local harmony = geometric and math.max(0, geometric - .20 * math.abs(protection - wearability)) or nil
        records[data.fullType] = { data = data, protection = protection, run = run, combat = combat, weight = weight, comfort = comfort,
            vision = vision, hearing = hearing, wearability = wearability, geometric = geometric, harmony = harmony }
        local group = data.utilityFunctionalComparisonGroup or data.utilityFunctionalGroup or "CLOTHING_FUNCTION:UNKNOWN"
        groups[group] = groups[group] or { profiles = {}, geometric = {}, harmony = {} }
        if data.utilityProfile and not groups[group].profiles[data.utilityProfile] then
            groups[group].profiles[data.utilityProfile] = { geometric = geometric, harmony = harmony }
        end
    end
    for _, group in pairs(groups) do
        for _, profile in pairs(group.profiles) do
            if profile.geometric ~= nil then table.insert(group.geometric, profile.geometric) end
            if profile.harmony ~= nil then table.insert(group.harmony, profile.harmony) end
        end
        group.geometric, group.harmony = sortedCopy(group.geometric), sortedCopy(group.harmony)
    end
    for _, record in pairs(records) do
        local group = groups[record.data.utilityFunctionalComparisonGroup or record.data.utilityFunctionalGroup or "CLOTHING_FUNCTION:UNKNOWN"]
        record.geometricPercentile = record.geometric and clothingUtilityPercentileOfValue(group.geometric, record.geometric) or nil
        record.harmonyPercentile = record.harmony and clothingUtilityPercentileOfValue(group.harmony, record.harmony) or nil
    end
    local function tier(data, score, percentile)
        if score == nil or percentile == nil then return "RARE" end
        return matrixTierFromAxes({ baseScarcityTier = data.baseScarcityTier, rarityTier = data.baseScarcityTier,
            utilityEligible = true, utility = score, utilityConfidence = data.utilityConfidence }, percentile, { p70 = 70, p80 = 80, p90 = 90, p95 = 95 })
    end
    writer:write("Item Rarity Clothing Wearability balance simulation (REPORT ONLY)\n")
    writer:write("No active tier, UI, Strategy D, WeaponUtility V2 or frozen Scarcity x Utility rule is changed. This report tests only whether the current clothing score confuses protection with ease of use.\n\n")
    writer:write("B42.20.2 RUNTIME FINDINGS\n")
    writer:write("RunSpeedModifier: worn clothing modifiers different from 1 are arithmetically averaged; missing/broken shoes additionally multiplies run speed by .85. CombatSpeedModifier: starts at 1 and sums each (modifier-1).\n")
    writer:write("DiscomfortModifier: worn values are added (Desensitized returns zero). BodyDamage uses target=clamp(clothes + bed + dragging corpse + hypo + hyper + wetness + vehicle,0,1) x sobriety x 100. Therefore, awake/sober/dry clothing alone maps .04/.16/.24/.40 to 4/16/24/40 target discomfort points. At Uncomfortable moodle level >=1, discomfort can add stress over time.\n")
    writer:write("VisionModifier and HearingModifier: effective worn multipliers are multiplicative. A single .50 vision item yields 50% vision multiplier; .75 hearing yields 75% hearing multiplier. ActualWeight has no direct clothing-speed formula in these methods; its gameplay cost is contextual through carried load/encumbrance and player capacity, so the item-only model uses the existing inverse-weight efficiency as a conservative intrinsic proxy.\n\n")
    writer:write("EXPERIMENTAL ARCHITECTURE\n")
    writer:write("ProtectionQuality = 85% physical ProtectionCoverage + 15% durability. Wearability = 25% run retention + 20% combat retention + 20% inverse weight efficiency + 15% discomfort comfort + 10% vision + 10% hearing. Weather stays separate and is intentionally not in these balance models.\n")
    writer:write("GeometricBalanced = sqrt(ProtectionQuality x Wearability). HarmonyBalanced = max(0, GeometricBalanced - .20 x abs(ProtectionQuality-Wearability)). Both percentiles are calculated only inside the current functional comparison group using deduplicated mechanical profiles. Hypothetical tier uses the frozen matrix with no new absolute/role gate.\n\n")
    writer:write("fullType | functional group | ProtectionQuality [ProtectionCoverage,Durability] | Wearability [run,combat,weight,comfort,vision,hearing] | raw runtime [run,combat,ActualWeight,Discomfort,Vision,Hearing] | current ClothingUtility | GeometricBalanced/pctl/tier | HarmonyBalanced/pctl/tier | ScarcityTier | Final active\n")
    for _, fullType in ipairs(targets) do
        local record = records[fullType]
        if not record then writer:write(fullType .. " | unavailable\n") else
            local data, metrics, parts = record.data, record.data.utilityMetrics or {}, record.data.utilityComponents or {}
            local wearParts = string.format("%.2f [run=%s,combat=%s,weight=%s,comfort=%s,vision=%s,hearing=%s]", record.wearability or -1,
                format(record.run), format(record.combat), format(record.weight), format(record.comfort), format(record.vision), format(record.hearing))
            local raw = string.format("run=%s,combat=%s,weight=%s,discomfort=%s (~%s pts sober),vision=%s,hearing=%s", format(metrics.runSpeedModifier),
                format(metrics.combatSpeedModifier), format(metrics.weight), format(metrics.discomfortModifier), format((metrics.discomfortModifier or 0) * 100), format(metrics.visionModifier), format(metrics.hearingModifier))
            writer:write(string.format("%s | %s | %s [coverage=%s,durability=%s] | %s | %s | %s | %s/%s/%s | %s/%s/%s | %s | %s\n", fullType,
                tostring(data.utilityFunctionalGroup), format(record.protection), format(parts.protectionCoverage), format(parts.durability), wearParts, raw,
                format(data.utility), format(record.geometric), format(record.geometricPercentile), tier(data, record.geometric, record.geometricPercentile),
                format(record.harmony), format(record.harmonyPercentile), tier(data, record.harmony, record.harmonyPercentile), tostring(data.baseScarcityTier), tostring(data.finalRarityTier)))
        end
    end
    writer:close()
    ItemRarityUtils.info("Clothing Wearability balance simulation written to Zomboid/Lua/ItemRarity_ClothingWearabilityAnalysis.txt (report only; active tier and UI unchanged).")
end

function ItemRarityClothingWearabilityReports.write(results)
    return writeClothingWearabilityAnalysis(results)
end
