require "ItemRarity/RarityConfig"
require "ItemRarity/RarityUtils"
require "ItemRarity/UtilityCalculator"

ItemRarityClothingHistoricalExperiments = ItemRarityClothingHistoricalExperiments or {}

-- Dormant historical A/B/C anatomy and functional-cost experiments. They are
-- retained for development reference and have no active runtime caller.
local API = ItemRarityUtilityCalculator.getClothingDiagnosticApi()
local UTILITY = API.UTILITY
local sortedCopy = API.sortedCopy
local matrixTierFromAxes = API.matrixTierFromAxes
local clothingUtilityPercentileOfValue = API.clothingUtilityPercentileOfValue
local anatomicalWeightTotal = API.anatomicalWeightTotal
local anatomicalModelMaximum = API.anatomicalModelMaximum

-- A/C were superseded by the frozen B_MODERATE runtime model. They remain
-- local to this dormant report so historical sensitivity analysis does not
-- retain alternative anatomy curves in the active calculator.
local ANATOMICAL_COVERAGE_MODELS = {
    A_UNIFORM = {
        HEAD = 1.00, NECK = 1.00, TORSO_UPPER = 1.00, TORSO_LOWER = 1.00, GROIN = 1.00,
        UPPER_ARM = 1.00, FOREARM = 1.00, HAND = 1.00, THIGH = 1.00, SHIN = 1.00, FOOT = 1.00,
    },
    B_MODERATE = API.ANATOMICAL_COVERAGE_MODELS.B_MODERATE,
    C_STRONG = {
        HEAD = 1.70, NECK = 1.50, TORSO_UPPER = 1.40, TORSO_LOWER = 1.25, GROIN = 1.10,
        UPPER_ARM = 0.70, FOREARM = 0.60, HAND = 0.50, THIGH = 0.70, SHIN = 0.60, FOOT = 0.50,
    },
}
local function writeClothingAnatomicalAnalysis(writer, clothing, results, matrixTier)
    local anatomy = { regions = {}, tokens = {}, bodyLocations = {}, scores = {}, percentiles = {}, factors = {}, totals = {}, maxima = {} }
    local thresholds = { p70 = 70, p80 = 80, p90 = 90, p95 = 95 }
    local function sortedMapKeys(map)
        local keys = {}
        for key in pairs(map) do table.insert(keys, key) end
        table.sort(keys)
        return keys
    end
    local function value(metrics, name)
        local number = metrics and metrics[name]
        return number ~= nil and string.format("%.3f", number) or "N/A"
    end
    for region in pairs(ANATOMICAL_COVERAGE_MODELS.A_UNIFORM) do anatomy.regions[region] = { items = 0, groups = {}, profiles = {}, examples = {} } end
    for _, data in ipairs(clothing) do
        local discovery = data.clothingDiscovery or {}
        local location = tostring(discovery.bodyLocation or "UNKNOWN")
        anatomy.bodyLocations[location] = (anatomy.bodyLocations[location] or 0) + 1
        for token in pairs(discovery.observedCoverageTokens or {}) do anatomy.tokens[token] = (anatomy.tokens[token] or 0) + 1 end
        for _, region in ipairs(discovery.coveredRegions or {}) do
            local stat = anatomy.regions[region]
            if stat then
                stat.items = stat.items + 1
                stat.groups[data.utilitySubgroup or "OTHER"] = true
                stat.profiles[data.utilityProfile or data.fullType] = true
                if #stat.examples < 5 then table.insert(stat.examples, data.fullType) end
            end
        end
    end
    for model, weights in pairs(ANATOMICAL_COVERAGE_MODELS) do anatomy.maxima[model] = anatomicalModelMaximum(clothing, weights) end
    for _, data in ipairs(clothing) do
        local discovery, components = data.clothingDiscovery or {}, data.utilityComponents or {}
        anatomy.scores[data.fullType], anatomy.factors[data.fullType], anatomy.totals[data.fullType] = {}, {}, {}
        for model, weights in pairs(ANATOMICAL_COVERAGE_MODELS) do
            local total = anatomicalWeightTotal(discovery.coveredRegions, weights)
            local factor = total and anatomy.maxima[model] and (UTILITY.clothing.coverage.minimumFactor
                + (UTILITY.clothing.coverage.maximumFactor - UTILITY.clothing.coverage.minimumFactor) * total / anatomy.maxima[model]) or nil
            local protection = components.protectionBase and factor and components.protectionBase * factor or nil
            local score = protection and components.mobility and components.weight and components.durability and components.weatherProtection
                and (protection * UTILITY.clothing.architecture.protectionCoverage + components.mobility * UTILITY.clothing.architecture.mobility
                    + components.weight * UTILITY.clothing.architecture.weight + components.durability * UTILITY.clothing.architecture.durability
                    + components.weatherProtection * UTILITY.clothing.architecture.weatherProtection) or nil
            anatomy.totals[data.fullType][model], anatomy.factors[data.fullType][model], anatomy.scores[data.fullType][model] = total, factor, score
        end
    end
    for model in pairs(ANATOMICAL_COVERAGE_MODELS) do
        local byProfile, values = {}, {}
        for _, data in ipairs(clothing) do
            local score = anatomy.scores[data.fullType][model]
            if score ~= nil and byProfile[data.utilityProfile] == nil then byProfile[data.utilityProfile] = score end
        end
        for _, score in pairs(byProfile) do table.insert(values, score) end
        anatomy.percentiles[model] = {}
        values = sortedCopy(values)
        for _, data in ipairs(clothing) do anatomy.percentiles[model][data.fullType] = clothingUtilityPercentileOfValue(values, anatomy.scores[data.fullType][model]) end
    end
    local function tier(data, model)
        local percentile = anatomy.percentiles[model][data.fullType]
        if anatomy.scores[data.fullType][model] == nil or percentile == nil then return "RARE" end
        return matrixTier({ baseScarcityTier = data.baseScarcityTier, rarityTier = data.baseScarcityTier,
            utilityEligible = true, utility = anatomy.scores[data.fullType][model], utilityConfidence = data.utilityConfidence }, percentile, thresholds)
    end
    local function columns(data, model)
        local total, factor, score = anatomy.totals[data.fullType][model], anatomy.factors[data.fullType][model], anatomy.scores[data.fullType][model]
        local percentile = anatomy.percentiles[model][data.fullType]
        return string.format("%s | %s | %s | %s | %s", total and string.format("%.2f", total) or "N/A", factor and string.format("%.3f", factor) or "N/A",
            score and string.format("%.3f", score) or "N/A", percentile and string.format("%.2f", percentile) or "N/A", tier(data, model))
    end
    writer:write("ANATOMICAL COVERAGE STRUCTURE (REPORT ONLY)\n")
    writer:write("Observed B42 BodyLocation and BloodLocation/covered-part declarations are expanded into structural regions; no item name is used.\n")
    writer:write("OBSERVED BODYLOCATION DECLARATIONS\n")
    for _, location in ipairs(sortedMapKeys(anatomy.bodyLocations)) do writer:write(string.format("%s = %d items\n", location, anatomy.bodyLocations[location])) end
    writer:write("OBSERVED BLOODLOCATION / COVERED-PART TOKENS\n")
    for _, token in ipairs(sortedMapKeys(anatomy.tokens)) do writer:write(string.format("%s = %d items\n", token, anatomy.tokens[token])) end
    writer:write("\nSTRUCTURAL REGION | items covering | functional groups | unique profiles | examples\n")
    for _, region in ipairs(sortedMapKeys(anatomy.regions)) do
        local stat, groups, profiles = anatomy.regions[region], {}, 0
        for group in pairs(stat.groups) do table.insert(groups, group) end
        table.sort(groups)
        for _ in pairs(stat.profiles) do profiles = profiles + 1 end
        writer:write(string.format("%s | %d | %s | %d | %s\n", region, stat.items, table.concat(groups, ","), profiles, table.concat(stat.examples, ",")))
    end
    writer:write("\nANATOMICAL COVERAGE MODELS (SIMULATION ONLY)\n")
    writer:write("A UNIFORM: every structural region=1.00. B MODERATE: HEAD 1.30, NECK 1.25, TORSO_UPPER 1.20, TORSO_LOWER 1.10, GROIN 1.00, UPPER_ARM .85, FOREARM .80, HAND .70, THIGH .80, SHIN .75, FOOT .65. C STRONG: HEAD 1.70, NECK 1.50, TORSO_UPPER 1.40, TORSO_LOWER 1.25, GROIN 1.10, UPPER_ARM .70, FOREARM .60, HAND .50, THIGH .70, SHIN .60, FOOT .50.\n")
    writer:write("Each model is normalized to its highest observed anatomical total and mapped to coverage factor 0.70..1.00. It multiplies physical protection only, never creates Utility by itself. B/C are sensitivity hypotheses, not active game-damage probabilities.\n\n")
    writer:write("ANATOMICAL REQUIRED COMPARISON\n")
    writer:write("fullType | regions | bite | scratch | bullet | Mobility | inverse Weight | Durability | Weather | A total | A factor | A Utility | A percentile | A Final hypothetical | B total | B factor | B Utility | B percentile | B Final hypothetical | C total | C factor | C Utility | C percentile | C Final hypothetical | ScarcityTier | Final active\n")
    local targets = { "Base.Gorget_Metal", "Base.Chainmail_SleeveFull_L", "Base.Chainmail_SleeveFull_R", "Base.Vambrace_Left", "Base.Shoulderpad_Articulated_L_Metal", "Base.Shoulderpad_Articulated_R_Metal", "Base.Cuirass_Metal", "Base.Cuirass_Tire", "Base.HazmatSuit", "Base.Shoes_WorkBoots" }
    for _, fullType in ipairs(targets) do
        local data = results[fullType]
        if not data then writer:write(fullType .. " | unavailable\n") else
            local metrics, components, discovery = data.utilityMetrics or {}, data.utilityComponents or {}, data.clothingDiscovery or {}
            writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s\n", fullType,
                #(discovery.coveredRegions or {}) > 0 and table.concat(discovery.coveredRegions, "+") or "N/A", value(metrics, "biteDefense"), value(metrics, "scratchDefense"), value(metrics, "bulletDefense"),
                value(components, "mobility"), value(components, "weight"), value(components, "durability"), value(components, "weatherProtection"),
                columns(data, "A_UNIFORM"), columns(data, "B_MODERATE"), columns(data, "C_STRONG"), tostring(data.baseScarcityTier), tostring(data.finalRarityTier)))
        end
    end
    writer:write("\nANATOMICAL MODEL EFFECT ON BASELINE CLOTHING EXOTICS (NOT ACTIVE)\n")
    writer:write("fullType | baseline percentile | A percentile/tier | B percentile/tier | C percentile/tier | status A/B/C\n")
    local baseline = {}
    for _, data in ipairs(clothing) do
        if data.utility and data.clothingUtilityPercentile then
            local baselineTier = matrixTier({ baseScarcityTier = data.baseScarcityTier, rarityTier = data.baseScarcityTier,
                utilityEligible = true, utility = data.utility, utilityConfidence = data.utilityConfidence }, data.clothingUtilityPercentile, thresholds)
            if baselineTier == "EXOTIC" then table.insert(baseline, data) end
        end
    end
    table.sort(baseline, function(a, b) return a.fullType < b.fullType end)
    for _, data in ipairs(baseline) do
        local function compact(model)
            local currentTier = tier(data, model)
            return string.format("%.2f/%s", anatomy.percentiles[model][data.fullType] or -1, currentTier), currentTier
        end
        local a, ta = compact("A_UNIFORM")
        local b, tb = compact("B_MODERATE")
        local c, tc = compact("C_STRONG")
        writer:write(string.format("%s | %.2f | %s | %s | %s | %s / %s / %s\n", data.fullType, data.clothingUtilityPercentile, a, b, c,
            ta == "EXOTIC" and "continues EXOTIC" or "leaves -> " .. ta, tb == "EXOTIC" and "continues EXOTIC" or "leaves -> " .. tb, tc == "EXOTIC" and "continues EXOTIC" or "leaves -> " .. tc))
    end
    for _, model in ipairs({ "A_UNIFORM", "B_MODERATE", "C_STRONG" }) do
        local count = 0
        for _, data in ipairs(clothing) do if tier(data, model) == "EXOTIC" then count = count + 1 end end
        writer:write(string.format("%s hypothetical EXOTIC count=%d\n", model, count))
    end
end

-- Experimental report only. The base ClothingUtility remains unchanged: these
-- scenarios expose a separate functional-cost axis rather than retuning any
-- active benefit weight.
local function writeClothingFunctionalCostAnalysis(writer, clothing, results, matrixTier)
    local thresholds = { p70 = 70, p80 = 80, p90 = 90, p95 = 95 }
    local modelNames = { "CURRENT", "COST_LIGHT", "COST_STRONG" }
    local scenarios = { CURRENT = 0, COST_LIGHT = 0.35, COST_STRONG = 0.75 }
    local scores, percentiles, costs, penalties = {}, {}, {}, {}
    local function number(value) return value ~= nil and string.format("%.3f", value) or "N/A" end
    local function rawDebuff(metrics, name)
        local value = metrics and metrics[name]
        return value == nil and 0 or value
    end
    for _, data in ipairs(clothing) do
        local metrics, parts, ranks = data.utilityMetrics or {}, data.utilityComponents or {}, data.utilityMetricPercentiles or {}
        local runCost = ranks.runSpeedModifier and 100 - ranks.runSpeedModifier or nil
        local combatCost = ranks.combatSpeedModifier and 100 - ranks.combatSpeedModifier or nil
        local weightCost = parts.weight and 100 - parts.weight or nil
        local discomfort = rawDebuff(metrics, "discomfortModifier") * 100
        local visionLoss = math.max(0, 1 - rawDebuff(metrics, "visionModifier")) * 100
        local hearingLoss = math.max(0, 1 - rawDebuff(metrics, "hearingModifier")) * 100
        local cost = runCost and combatCost and weightCost and (runCost * .30 + combatCost * .25 + weightCost * .20
            + discomfort * .10 + visionLoss * .075 + hearingLoss * .075) or nil
        costs[data.fullType] = { run = runCost, combat = combatCost, weight = weightCost, discomfort = discomfort,
            vision = visionLoss, hearing = hearingLoss, total = cost }
        penalties[data.fullType], scores[data.fullType] = {}, {}
        local excess = cost and math.max(0, cost - 55) or nil
        local softCost = excess and (excess * excess / 45) or nil
        for _, model in ipairs(modelNames) do
            local penalty = softCost and softCost * scenarios[model] or nil
            penalties[data.fullType][model] = penalty
            scores[data.fullType][model] = data.utility and penalty and math.max(0, data.utility - penalty) or nil
        end
    end
    for _, model in ipairs(modelNames) do
        local profiles, values = {}, {}
        for _, data in ipairs(clothing) do
            local score = scores[data.fullType][model]
            if score ~= nil and profiles[data.utilityProfile] == nil then profiles[data.utilityProfile] = score end
        end
        for _, score in pairs(profiles) do table.insert(values, score) end
        percentiles[model] = {}
        values = sortedCopy(values)
        for _, data in ipairs(clothing) do percentiles[model][data.fullType] = clothingUtilityPercentileOfValue(values, scores[data.fullType][model]) end
    end
    local function tier(data, model)
        local score, percentile = scores[data.fullType][model], percentiles[model][data.fullType]
        if score == nil or percentile == nil then return "RARE" end
        return matrixTier({ baseScarcityTier = data.baseScarcityTier, rarityTier = data.baseScarcityTier,
            utilityEligible = true, utility = score, utilityConfidence = data.utilityConfidence }, percentile, thresholds)
    end
    local function modelColumn(data, model)
        local score, percentile, penalty = scores[data.fullType][model], percentiles[model][data.fullType], penalties[data.fullType][model]
        return string.format("%s | %s | %s | %s", number(score), number(percentile), number(penalty), tier(data, model))
    end
    writer:write("\nFUNCTIONAL COST / COMFORT SIMULATION (REPORT ONLY)\n")
    writer:write("Confirmed B42 clothing fields: ActualWeight, RunSpeedModifier, CombatSpeedModifier, DiscomfortModifier, VisionModifier and HearingModifier. Wetness is runtime state rather than intrinsic item cost, and is deliberately excluded. EnduranceModifier, MovementModifier and FatigueChange are probe-only: their availability is reported above and they are excluded unless a real clothing value is exposed.\n")
    writer:write("CURRENT is the approved provisional ClothingUtility unchanged. COST_LIGHT and COST_STRONG subtract a soft cost only above CostIndex 55: SoftCost=(max(0, CostIndex-55)^2)/45, multiplied by .35 or .75. CostIndex = run loss 30% + combat loss 25% + weight burden 20% + discomfort 10% + vision loss 7.5% + hearing loss 7.5%. This is a stress test, not an active formula.\n")
    writer:write("ProtectionValue remains actual ProtectionCoverage, and coverage never scores independently. MobilityComfortValue is the current run/combat retention component; cost uses the inverse of those same retention ranks transparently as a soft extreme-cost check.\n")
    writer:write("fullType | ProtectionValue | coverage | MobilityComfort | WeightEfficiency | debuffs raw [run,combat,discomfort,vision,hearing,endurance,movement,fatigue] | Durability | Weather | CostIndex [run,combat,weight,discomfort,vision,hearing] | CURRENT utility/pctl/penalty/tier | LIGHT utility/pctl/penalty/tier | STRONG utility/pctl/penalty/tier | ScarcityTier | Final active\n")
    local targets = { "Base.Cuirass_Metal", "Base.Cuirass_Tire", "Base.HazmatSuit", "Base.Gorget_Metal", "Base.Vambrace_Left", "Base.Shoulderpad_Articulated_L_Metal", "Base.Shoulderpad_Articulated_R_Metal", "Base.Shoes_WorkBoots", "Base.Shoes_BlueTrainers" }
    for _, fullType in ipairs(targets) do
        local data = results[fullType]
        if not data then writer:write(fullType .. " | unavailable\n") else
            local metrics, parts, discovery, cost = data.utilityMetrics or {}, data.utilityComponents or {}, data.clothingDiscovery or {}, costs[fullType] or {}
            local debuffs = string.format("run=%s,combat=%s,discomfort=%s,vision=%s,hearing=%s,endurance=%s,movement=%s,fatigue=%s", number(metrics.runSpeedModifier), number(metrics.combatSpeedModifier),
                number(metrics.discomfortModifier), number(metrics.visionModifier), number(metrics.hearingModifier), number(metrics.enduranceModifier), number(metrics.movementModifier), number(metrics.fatigueChange))
            local costParts = string.format("%.2f [run=%.2f,combat=%.2f,weight=%.2f,discomfort=%.2f,vision=%.2f,hearing=%.2f]", cost.total or -1,
                cost.run or -1, cost.combat or -1, cost.weight or -1, cost.discomfort or -1, cost.vision or -1, cost.hearing or -1)
            writer:write(string.format("%s | %s | %s/%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s\n", fullType,
                number(parts.protectionCoverage), tostring(discovery.coverageZones or "UNKNOWN"), tostring(discovery.coverageZoneCount or 0), number(parts.mobility), number(parts.weight), debuffs,
                number(parts.durability), number(parts.weatherProtection), costParts, modelColumn(data, "CURRENT"), modelColumn(data, "COST_LIGHT"), modelColumn(data, "COST_STRONG"),
                tostring(data.baseScarcityTier), tostring(data.finalRarityTier)))
        end
    end
    for _, model in ipairs(modelNames) do
        local count = 0
        for _, data in ipairs(clothing) do if tier(data, model) == "EXOTIC" then count = count + 1 end end
        writer:write(string.format("%s hypothetical EXOTIC clothing count=%d\n", model, count))
    end
end

-- The moderate anatomical model is used only for the functional-group
-- simulation.  It keeps coverage as a multiplier of real defense and makes a
-- sleeve (upper arm + forearm + hand) meaningfully distinct from a vambrace
-- (forearm only), without awarding Utility for coverage alone.
function ItemRarityClothingHistoricalExperiments.writeAnatomicalAnalysis(writer, clothing, results, matrixTier)
    return writeClothingAnatomicalAnalysis(writer, clothing, results, matrixTier)
end

function ItemRarityClothingHistoricalExperiments.writeFunctionalCostAnalysis(writer, clothing, results, matrixTier)
    return writeClothingFunctionalCostAnalysis(writer, clothing, results, matrixTier)
end
