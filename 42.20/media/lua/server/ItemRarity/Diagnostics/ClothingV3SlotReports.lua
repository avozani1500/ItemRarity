require "ItemRarity/RarityConfig"
require "ItemRarity/RarityUtils"
require "ItemRarity/UtilityCalculator"
ItemRarityClothingSlotSimulationReports = ItemRarityClothingSlotSimulationReports or {}
local API = ItemRarityUtilityCalculator.getClothingDiagnosticApi()
local UTILITY = API.UTILITY
local NORMALIZATION = API.NORMALIZATION
local sortedCopy = API.sortedCopy
local uniqueSorted = API.uniqueSorted
local quantile = API.quantile
local clamp = API.clamp
local confidenceAtLeast = API.confidenceAtLeast
local sortedKeys = API.sortedKeys
local matrixTierFromAxes = API.matrixTierFromAxes
local clothingUtilityPercentileOfValue = API.clothingUtilityPercentileOfValue
local anatomicalWeightTotal = API.anatomicalWeightTotal
local anatomicalModelMaximum = API.anatomicalModelMaximum
local ANATOMICAL_COVERAGE_MODELS = API.ANATOMICAL_COVERAGE_MODELS
local directSlotEquipmentFunction = ItemRarityClothingComparabilityReports.directSlotEquipmentFunction
local function writeClothingV3SlotUtilitySimulation(results)
    if not UTILITY.diagnosticsEnabled or not getFileWriter then return end
    local writer = getFileWriter("ItemRarity_ClothingUtilityV3SlotSimulation.txt", true, false)
    if not writer then return end
    local clothing, records, slots, globalValues = {}, {}, {}, { weight = {}, durability = {} }
    local targets = { "Base.Jacket_NavyBlue", "Base.Jacket_Leather", "Base.Jacket_LeatherBrown", "Base.Jacket_Leather_Punk", "Base.Jacket_Fireman",
        "Base.Cuirass_Metal", "Base.Cuirass_Tire", "Base.Hat_MetalHelmet", "Base.Gorget_Metal", "Base.Vambrace_Left",
        "Base.Shoulderpad_Articulated_L_Metal", "Base.Shoulderpad_Articulated_R_Metal", "Base.Chainmail_SleeveFull_L", "Base.Chainmail_SleeveFull_R",
        "Base.Shoes_WorkBoots", "Base.Shoes_BlueTrainers", "Base.HazmatSuit" }
    local function countProfiles(list)
        local profiles = {}
        for _, record in ipairs(list) do profiles[record.data.utilityProfile] = true end
        local total = 0
        for _ in pairs(profiles) do total = total + 1 end
        return total
    end
    local function fmt(value) return value ~= nil and string.format("%.2f", value) or "N/A" end
    for _, data in pairs(results) do
        if data.category == "CLOTHING" and data.utility ~= nil and data.clothingEquipmentGraph and data.clothingEquipmentGraph.resolved then
            table.insert(clothing, data)
            local profile = data.utilityProfile
            local metrics = data.utilityMetrics or {}
            if profile and globalValues.weight[profile] == nil then
                globalValues.weight[profile], globalValues.durability[profile] = metrics.weight, metrics.durability
            end
        end
    end
    local scales = {}
    for _, metric in ipairs({ "weight", "durability" }) do
        local values = {}
        for _, value in pairs(globalValues[metric]) do if value ~= nil then table.insert(values, value) end end
        values = sortedCopy(values)
        scales[metric] = { values = values, low = quantile(values, 5), high = quantile(values, 95) }
    end
    local function globalQuality(metric, value, inverted)
        local scale = scales[metric]
        if value == nil or not scale or #scale.values == 0 then return nil end
        return percentileRank(scale.values, clamp(value, scale.low, scale.high), inverted == true)
    end
    for _, data in ipairs(clothing) do
        local metrics, parts = data.utilityMetrics or {}, data.utilityComponents or {}
        local durability, weight = globalQuality("durability", metrics.durability), globalQuality("weight", metrics.weight, true)
        local protection = parts.protectionCoverage and durability and (parts.protectionCoverage * .85 + durability * .15) or nil
        local run = metrics.runSpeedModifier and math.max(0, math.min(1, metrics.runSpeedModifier)) * 100 or nil
        local combat = metrics.combatSpeedModifier and math.max(0, math.min(1, metrics.combatSpeedModifier)) * 100 or nil
        local comfort = metrics.discomfortModifier and math.max(0, math.min(1, 1 - metrics.discomfortModifier)) * 100 or nil
        local vision = metrics.visionModifier and math.max(0, math.min(1, metrics.visionModifier)) * 100 or nil
        local hearing = metrics.hearingModifier and math.max(0, math.min(1, metrics.hearingModifier)) * 100 or nil
        local wearability = run and combat and weight and comfort and vision and hearing
            and (run * .25 + combat * .20 + weight * .10 + comfort * .20 + vision * .125 + hearing * .125) or nil
        local score = protection and wearability and math.sqrt(protection * wearability) or nil
        -- This is deliberately separate from the sample-size confidence of
        -- DIRECT_SLOT.  A Cuirass can expose every runtime attribute required
        -- by the absolute score even when only four mechanically distinct
        -- cuirasses are loaded.  The former is evidence about score validity;
        -- the latter is evidence only about the relative slot ranking.
        local attributeNames = { "biteDefense", "scratchDefense", "bulletDefense", "durability", "weight",
            "runSpeedModifier", "combatSpeedModifier", "discomfortModifier", "visionModifier", "hearingModifier" }
        local validAttributes = 0
        for _, name in ipairs(attributeNames) do if metrics[name] ~= nil then validAttributes = validAttributes + 1 end end
        local utilityConfidence = score and protection and wearability and validAttributes == #attributeNames and "HIGH"
            or (score and validAttributes >= 8 and "MEDIUM" or "LOW")
        local record = { data = data, protection = protection, durability = durability, run = run, combat = combat, weight = weight,
            comfort = comfort, vision = vision, hearing = hearing, wearability = wearability, score = score,
            validAttributes = validAttributes, utilityConfidence = utilityConfidence }
        records[data.fullType] = record
        local slot = data.clothingEquipmentGraph.slotId
        slots[slot] = slots[slot] or {}
        table.insert(slots[slot], record)
    end
    for _, slotRecords in pairs(slots) do
        local profiles, values = {}, {}
        for _, record in ipairs(slotRecords) do
            if profiles[record.data.utilityProfile] == nil then profiles[record.data.utilityProfile] = record.score end
        end
        for _, score in pairs(profiles) do if score ~= nil then table.insert(values, score) end end
        values = sortedCopy(values)
        local sample = #values
        for _, record in ipairs(slotRecords) do
            record.slotProfiles = sample
            record.slotPercentile = record.score and clothingUtilityPercentileOfValue(values, record.score) or nil
            record.slotConfidence = sample >= 20 and "HIGH" or (sample >= 8 and "MEDIUM" or "LOW")
        end
    end
    local TIER_ORDER = { COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 }
    local function tierAtLeast(tier, minimum) return (TIER_ORDER[tier] or 0) >= (TIER_ORDER[minimum] or 5) end
    local function slotEvidence(record)
        -- DIRECT_SLOT is contextual evidence. A small slot is not treated as
        -- missing quality evidence, and a p100 result in it never creates a
        -- promotion. Only a robust, clearly poor relative rank can contradict
        -- an otherwise exotic-looking pair of Scarcity + absolute quality.
        if record.slotConfidence == "LOW" or record.slotPercentile == nil then return "NEUTRAL_LOW_SAMPLE" end
        if record.slotPercentile < 20 then return "CONTRADICTS" end
        if record.slotPercentile >= 75 then return "CORROBORATES" end
        return "NEUTRAL"
    end
    -- Scarcity and absolute quality form a gradual matrix. Extreme scarcity
    -- lowers the absolute-quality requirement to sustain EXOTIC, rather than
    -- imposing a sequence of independent p95-style gates. DIRECT_SLOT only
    -- labels the contextual evidence above; it is not a small-sample veto.
    local function simulateTier(record, scenario, scoreOverride)
        local scarcity, score = record.data.baseScarcityTier, scoreOverride or record.score or -1
        if record.utilityConfidence ~= "HIGH" then return "RARE", "absolute score attributes incomplete" end
        if scarcity == "COMMON" then
            return score >= scenario.good and "UNCOMMON" or "COMMON", "common: utility promotion capped at +1"
        end
        if scarcity == "UNCOMMON" then
            return score >= scenario.good and "RARE" or "UNCOMMON", "uncommon: utility promotion capped at +1"
        end
        if not tierAtLeast(scarcity, "RARE") or score < scenario.good then
            return "RARE", "scarcity without good absolute utility is capped at RARE"
        end
        local exoticMinimum = scarcity == "EXOTIC" and scenario.exoticAtExoticScarcity
            or (scarcity == "EPIC" and scenario.exoticAtEpicScarcity or nil)
        if exoticMinimum and score >= exoticMinimum then
            if slotEvidence(record) == "CONTRADICTS" then
                return "EPIC", "robust DIRECT_SLOT rank contradicts EXOTIC despite Scarcity + absolute quality"
            end
            return "EXOTIC", string.format("%s scarcity lowers EXOTIC AbsoluteUtility requirement to %.0f", scarcity, exoticMinimum)
        end
        return "EPIC", "scarcity + good absolute utility"
    end
    local scenarios = {
        { name = "CONSERVATIVE", good = 65, exoticAtEpicScarcity = 80, exoticAtExoticScarcity = 73 },
        { name = "BALANCED", good = 60, exoticAtEpicScarcity = 75, exoticAtExoticScarcity = 68 },
        { name = "PERMISSIVE", good = 55, exoticAtEpicScarcity = 70, exoticAtExoticScarcity = 65 },
    }
    writer:write("Item Rarity ClothingUtility V3 slot simulation (REPORT ONLY)\n")
    writer:write("No active Utility, tier, Scarcity x Utility matrix or UI field changes. ClothingUtilityScore and SlotUtilityPercentile below are diagnostic V3 values only.\n\n")
    writer:write("V3 CONCEPT AND INDEPENDENT CONFIDENCES\n")
    writer:write("ClothingUtilityScore is absolute across the loaded clothing universe: ProtectionQuality=85% effective ProtectionCoverage + 15% globally robust durability; Wearability=run 25% + combat 20% + inverse global weight 10% + discomfort comfort 20% + vision 12.5% + hearing 12.5%. Score=sqrt(ProtectionQuality x Wearability), so exceptional protection cannot fully erase extreme wear costs.\n")
    writer:write("UtilityConfidence measures only whether the absolute score has valid runtime evidence: all 10 intrinsic attributes (bite, scratch, bullet, durability, weight, run, combat, discomfort, vision, hearing) plus derived ProtectionQuality/Wearability must exist for HIGH. It does NOT use BodyLocation sample size. SlotRankingConfidence measures only the deduplicated DIRECT_SLOT population: HIGH >=20, MEDIUM 8-19, LOW <8. A LOW slot is neutral, never a veto. A MEDIUM/HIGH slot only contradicts EXOTIC when its relative percentile is below p20; p75+ is corroborating context, not an additional gate. Mirrored slots are not merged because coexisting left/right items are not direct alternatives.\n\n")
    writer:write("TARGETS\n")
    writer:write("fullType | BodyLocation | slot profiles/SlotRankingConfidence | ProtectionQuality [coverage,durability] | Wearability [run,combat,weight,comfort,vision,hearing] | AbsoluteUtility/UtilityConfidence | SlotUtilityPercentile/evidence | ScarcityTier/ScarcityPercentile | active FinalTier | Conservative/Balanced/Permissive simulated tier\n")
    for _, fullType in ipairs(targets) do
        local record = records[fullType]
        if not record then writer:write(fullType .. " | unavailable\n") else
            local data, parts = record.data, record.data.utilityComponents or {}
            local simulated = {}
            for _, scenario in ipairs(scenarios) do
                local tier = simulateTier(record, scenario)
                table.insert(simulated, scenario.name .. "=" .. tier)
            end
            writer:write(string.format("%s | %s | %d/%s | %s [coverage=%s,durability=%s] | %s [run=%s,combat=%s,weight=%s,comfort=%s,vision=%s,hearing=%s] | %s/%s (%d valid) | %s | %s/%.2f | %s | %s\n",
                fullType, data.clothingEquipmentGraph.slotId, record.slotProfiles, record.slotConfidence, fmt(record.protection), fmt(parts.protectionCoverage), fmt(record.durability),
                fmt(record.wearability), fmt(record.run), fmt(record.combat), fmt(record.weight), fmt(record.comfort), fmt(record.vision), fmt(record.hearing),
                fmt(record.score), record.utilityConfidence, record.validAttributes, fmt(record.slotPercentile) .. "/" .. slotEvidence(record), tostring(data.baseScarcityTier),
                data.tableAvailability.routeWeightedPercentile or -1, tostring(data.finalRarityTier), table.concat(simulated, ",")))
        end
    end
    local jacket = results["Base.Jacket_NavyBlue"]
    if jacket and jacket.clothingEquipmentGraph and jacket.clothingEquipmentGraph.resolved then
        local jacketRecords, representative = slots[jacket.clothingEquipmentGraph.slotId] or {}, {}
        for _, record in ipairs(jacketRecords) do
            local key = record.data.utilityProfile
            representative[key] = representative[key] or { record = record, items = {} }
            table.insert(representative[key].items, record.data.fullType)
        end
        local ordered = {}
        for _, entry in pairs(representative) do table.insert(ordered, entry) end
        table.sort(ordered, function(a, b) return (a.record.score or -1) > (b.record.score or -1) end)
        writer:write("\nBASE:JACKET PROFILE TABLE (DIRECT_SLOT ONLY)\n")
        writer:write("profile representatives | ClothingUtilityScore | SlotUtilityPercentile | ProtectionQuality | effective coverage | durability | run | combat | discomfort | ActualWeight\n")
        for _, entry in ipairs(ordered) do
            local record, metrics, parts = entry.record, entry.record.data.utilityMetrics or {}, entry.record.data.utilityComponents or {}
            table.sort(entry.items)
            writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s\n", table.concat(entry.items, ","), fmt(record.score), fmt(record.slotPercentile),
                fmt(record.protection), fmt(parts.protectionCoverage), fmt(record.durability), fmt(metrics.runSpeedModifier), fmt(metrics.combatSpeedModifier), fmt(metrics.discomfortModifier), fmt(metrics.weight)))
        end
    end
    writer:write("\nGRADUAL SCARCITY x ABSOLUTE-UTILITY SENSITIVITY MATRIX (not active)\n")
    for _, scenario in ipairs(scenarios) do
        local epic, exotic = {}, {}
        for _, record in pairs(records) do
            local tier, reason = simulateTier(record, scenario)
            record.simulated = record.simulated or {}
            record.simulated[scenario.name] = { tier = tier, reason = reason }
            if tier == "EPIC" then table.insert(epic, record) elseif tier == "EXOTIC" then table.insert(exotic, record) end
        end
        table.sort(epic, function(a, b) return (a.score or -1) > (b.score or -1) end)
        table.sort(exotic, function(a, b) return (a.score or -1) > (b.score or -1) end)
        writer:write(string.format("%s: good Utility >= %.0f to sustain EPIC; EXOTIC scarcity requires >= %.0f; EPIC scarcity requires >= %.0f | EPIC=%d | EXOTIC=%d\n",
            scenario.name, scenario.good, scenario.exoticAtExoticScarcity, scenario.exoticAtEpicScarcity, #epic, #exotic))
        writer:write("  EPIC candidates\n")
        if #epic == 0 then writer:write("    none\n") end
        for _, record in ipairs(epic) do
            writer:write(string.format("    %s | Scarcity=%s/%.2f | AbsoluteUtility=%s/%s | Slot=%s p%s/%s/%s | reason=%s\n", record.data.fullType,
                record.data.baseScarcityTier, record.data.tableAvailability.routeWeightedPercentile or -1, fmt(record.score), record.utilityConfidence,
                record.data.clothingEquipmentGraph.slotId, fmt(record.slotPercentile), record.slotConfidence, slotEvidence(record), record.simulated[scenario.name].reason))
        end
        writer:write("  EXOTIC candidates\n")
        if #exotic == 0 then writer:write("    none\n") end
        for _, record in ipairs(exotic) do
            writer:write(string.format("    %s | Scarcity=%s/%.2f | AbsoluteUtility=%s/%s | Slot=%s p%s/%s/%s | reason=%s\n", record.data.fullType,
                record.data.baseScarcityTier, record.data.tableAvailability.routeWeightedPercentile or -1, fmt(record.score), record.utilityConfidence,
                record.data.clothingEquipmentGraph.slotId, fmt(record.slotPercentile), record.slotConfidence, slotEvidence(record), record.simulated[scenario.name].reason))
        end
    end
    writer:write("\nEXOTIC TRANSITIONS ACROSS SCENARIOS\n")
    writer:write("Every row below is EXOTIC in at least one scenario. 'Entered' and 'left' are explained by the Scarcity-dependent AbsoluteUtility cut, not by a slot sample-size gate.\n")
    local transitions = {}
    for _, record in pairs(records) do
        local states = {}
        local anyExotic = false
        for _, scenario in ipairs(scenarios) do
            local simulated = record.simulated[scenario.name]
            states[scenario.name] = simulated and simulated.tier or "RARE"
            if states[scenario.name] == "EXOTIC" then anyExotic = true end
        end
        if anyExotic then table.insert(transitions, { record = record, states = states }) end
    end
    table.sort(transitions, function(a, b) return (a.record.score or -1) > (b.record.score or -1) end)
    if #transitions == 0 then writer:write("none\n") end
    for _, entry in ipairs(transitions) do
        local record, states = entry.record, entry.states
        local note
        if states.CONSERVATIVE == "EXOTIC" then
            note = "survives Conservative: meets the highest Scarcity-dependent cut"
        elseif states.BALANCED == "EXOTIC" then
            note = "enters at Balanced: meets its lower Scarcity-dependent cut, not Conservative"
        else
            note = "enters only at Permissive: meets its lowest Scarcity-dependent cut"
        end
        writer:write(string.format("%s | Scarcity=%s/%.2f | AbsoluteUtility=%s | Slot=%s p%s/%s/%s | Conservative=%s | Balanced=%s | Permissive=%s | %s\n",
            record.data.fullType, record.data.baseScarcityTier, record.data.tableAvailability.routeWeightedPercentile or -1, fmt(record.score),
            record.data.clothingEquipmentGraph.slotId, fmt(record.slotPercentile), record.slotConfidence, slotEvidence(record),
            states.CONSERVATIVE, states.BALANCED, states.PERMISSIVE, note))
    end
    writer:close()

    -- Companion audit: it reuses V3's existing scores and the Balanced tier
    -- simulation. It never rewrites a candidate, never recalculates a slot
    -- rank, and applies a stronger anatomical fraction only as a diagnostic.
    ;(function()
    local auditWriter = getFileWriter("ItemRarity_ClothingBalancedExoticAudit.txt", true, false)
    if auditWriter then
        local balancedScenario, exotics, roleCounts = nil, {}, {}
        for _, scenario in ipairs(scenarios) do if scenario.name == "BALANCED" then balancedScenario = scenario break end end
        for _, record in pairs(records) do
            if record.simulated and record.simulated.BALANCED and record.simulated.BALANCED.tier == "EXOTIC" then
                local role = directSlotEquipmentFunction(record.data)
                roleCounts[role] = (roleCounts[role] or 0) + 1
                table.insert(exotics, { record = record, role = role })
            end
        end
        table.sort(exotics, function(a, b) return (a.record.score or -1) > (b.record.score or -1) end)
        local anatomicalMaximum = anatomicalModelMaximum(clothing, ANATOMICAL_COVERAGE_MODELS.B_MODERATE) or 1
        local function conflicts(graph)
            local values = {}
            for _, value in ipairs(graph.exclusive or {}) do table.insert(values, tostring(value)) end
            table.sort(values)
            return #values > 0 and table.concat(values, ",") or "none"
        end
        local function writeAuditRow(label, record, role)
            local data, graph, parts = record.data, record.data.clothingEquipmentGraph or {}, record.data.utilityComponents or {}
            local metrics, discovery = data.utilityMetrics or {}, data.clothingDiscovery or {}
            local anatomicalWeight = anatomicalWeightTotal(discovery.coveredRegions, ANATOMICAL_COVERAGE_MODELS.B_MODERATE) or 0
            local anatomicalFraction = clamp(anatomicalWeight / anatomicalMaximum, 0, 1)
            local fractionalCoverage = (parts.protectionBase or 0) * anatomicalFraction
            local fractionalProtection = fractionalCoverage * .85 + (record.durability or 0) * .15
            local fractionalScore = record.wearability and math.sqrt(math.max(0, fractionalProtection) * math.max(0, record.wearability)) or nil
            local fractionalTier, fractionalReason = simulateTier(record, balancedScenario, fractionalScore)
            auditWriter:write(string.format("%s | %s | DIRECT_SLOT=%s | FUNCTION=%s | regions=%s | Scarcity=%s/%.2f | AbsoluteUtility=%.2f | ProtectionQuality=%.2f | Wearability=%.2f | SlotRank=p%s/%s (%d profiles) | conflicts=%s\n",
                label, data.fullType, tostring(graph.slotId), role, #(discovery.coveredRegions or {}) > 0 and table.concat(discovery.coveredRegions, "+") or "N/A",
                tostring(data.baseScarcityTier), data.tableAvailability.routeWeightedPercentile or -1, record.score or -1, record.protection or -1, record.wearability or -1,
                fmt(record.slotPercentile), tostring(record.slotConfidence), record.slotProfiles or 0, conflicts(graph)))
            auditWriter:write(string.format("  ProtectionQuality: coverage %.2f x .85 = %.2f | durability %.2f x .15 = %.2f | total %.2f\n",
                parts.protectionCoverage or 0, (parts.protectionCoverage or 0) * .85, record.durability or 0, (record.durability or 0) * .15, record.protection or 0))
            auditWriter:write(string.format("  Wearability: run %.2f x .25 = %.2f | combat %.2f x .20 = %.2f | inverse-weight %.2f x .10 = %.2f | comfort %.2f x .20 = %.2f | vision %.2f x .125 = %.2f | hearing %.2f x .125 = %.2f | total %.2f\n",
                record.run or 0, (record.run or 0) * .25, record.combat or 0, (record.combat or 0) * .20, record.weight or 0, (record.weight or 0) * .10,
                record.comfort or 0, (record.comfort or 0) * .20, record.vision or 0, (record.vision or 0) * .125, record.hearing or 0, (record.hearing or 0) * .125, record.wearability or 0))
            auditWriter:write(string.format("  AbsoluteUtility: sqrt(ProtectionQuality %.2f x Wearability %.2f) = %.2f\n", record.protection or 0, record.wearability or 0, record.score or 0))
            auditWriter:write(string.format("  FRACTION-ANATOMY DIAGNOSTIC: moderate anatomical weight %.2f / observed maximum %.2f = %.3f | ProtectionBase %.2f -> coverage %.2f | ProtectionQuality %.2f | AbsoluteUtility %.2f | Balanced tier=%s | %s\n",
                anatomicalWeight, anatomicalMaximum, anatomicalFraction, parts.protectionBase or 0, fractionalCoverage, fractionalProtection, fractionalScore or 0, fractionalTier, fractionalReason))
        end
        auditWriter:write("Item Rarity Balanced Clothing EXOTIC audit (REPORT ONLY)\n")
        auditWriter:write("No active Utility, Scarcity, FinalRarityTier, UI or DIRECT_SLOT ranking changes. Fraction-anatomy is a counterfactual only: it replaces the current 0.70..1.00 coverage floor with linear moderate-anatomy fraction, to test localized protection sensitivity.\n\n")
        auditWriter:write(string.format("BALANCED EXOTIC=%d | FUNCTION DISTRIBUTION: ", #exotics))
        for index, role in ipairs(sortedKeys(roleCounts)) do auditWriter:write((index > 1 and " | " or "") .. role .. "=" .. roleCounts[role]) end
        auditWriter:write("\n\nBALANCED EXOTIC DETAILS\n")
        for _, entry in ipairs(exotics) do writeAuditRow("EXOTIC", entry.record, entry.role) end
        auditWriter:write("\nREQUIRED CROSS-FUNCTION REFERENCES\n")
        local references = { "Base.Cuirass_Metal", "Base.Hat_MetalHelmet", "Base.Gorget_Metal", "Base.Codpiece_Metal", "Base.Vambrace_Left",
            "Base.Shoulderpad_Articulated_L_Metal", "Base.Shoulderpad_Articulated_R_Metal", "Base.Chainmail_SleeveFull_L", "Base.Chainmail_SleeveFull_R", "Base.ThighMetal_L" }
        for _, fullType in ipairs(references) do
            local record = records[fullType]
            if record then writeAuditRow("REFERENCE", record, directSlotEquipmentFunction(record.data)) else auditWriter:write("REFERENCE | " .. fullType .. " | unavailable\n") end
        end
        auditWriter:close()
        ItemRarityUtils.info("Balanced Clothing EXOTIC audit written to Zomboid/Lua/ItemRarity_ClothingBalancedExoticAudit.txt (report only; active tier and UI unchanged).")
    end
    end)()
    ItemRarityUtils.info("ClothingUtility V3 slot simulation written to Zomboid/Lua/ItemRarity_ClothingUtilityV3SlotSimulation.txt (report only; active tier and UI unchanged).")
end

function ItemRarityClothingSlotSimulationReports.writeV3(results)
    return writeClothingV3SlotUtilitySimulation(results)
end
