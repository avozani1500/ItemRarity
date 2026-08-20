require "ItemRarity/RarityUtils"
require "ItemRarity/UtilityCalculator"

-- Read-only ClothingUtility calibration.  It deliberately never writes to
-- result.utility or result.finalRarityTier: the frozen V1/P2 score remains
-- the only active Clothing score.
ItemRarityClothingCostCalibration = ItemRarityClothingCostCalibration or {}

local API = ItemRarityUtilityCalculator.getClothingDiagnosticApi()
local clamp, sortedCopy = API.clamp, API.sortedCopy

local TIER_INDEX = { COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 }

local function number(value)
    return value ~= nil and string.format("%.2f", value) or "N/A"
end

local function modifierLoss(value, neutral)
    if value == nil then return 0 end
    return clamp((neutral - value) / neutral * 100, 0, 100)
end

-- A one-percent loss is intentionally almost free.  The curve rises through
-- normal clothing penalties, while pronounced mobility/sensory losses become
-- expensive without imposing a binary veto.
local function progressiveLoss(rawLoss, freeLoss)
    local excess = math.max(0, rawLoss - freeLoss)
    if excess == 0 then return 0 end
    return clamp(100 * ((excess / math.max(1, 100 - freeLoss)) ^ .72), 0, 100)
end

local function costComponents(data, weightPercentile)
    local metrics = data.utilityMetrics or {}
    local raw = {
        combat = modifierLoss(metrics.combatSpeedModifier, 1),
        run = modifierLoss(metrics.runSpeedModifier, 1),
        discomfort = clamp((metrics.discomfortModifier or 0) * 100, 0, 100),
        vision = modifierLoss(metrics.visionModifier, 1),
        hearing = modifierLoss(metrics.hearingModifier, 1),
        weight = 100 - (weightPercentile or 50),
    }
    local shaped = {
        combat = progressiveLoss(raw.combat, 1),
        run = progressiveLoss(raw.run, 1),
        discomfort = progressiveLoss(raw.discomfort, 2),
        vision = progressiveLoss(raw.vision, 1),
        hearing = progressiveLoss(raw.hearing, 1),
        -- Weight remains contextual and deliberately secondary.
        weight = progressiveLoss(raw.weight, 15),
    }
    local priorities = { combat=.30, run=.25, vision=.15, hearing=.15, discomfort=.10, weight=.05 }
    local total, weighted = 0, {}
    for key, priority in pairs(priorities) do
        weighted[key] = shaped[key] * priority
        total = total + weighted[key]
    end
    -- No appreciable loss below a small comfort budget.  Above it, the
    -- penalty is convex: severe trade-offs cannot be hidden by protection.
    local excess = math.max(0, total - 7)
    local penalty = excess == 0 and 0 or (excess ^ 1.28) / 5.5
    return raw, shaped, weighted, total, penalty
end

local function activeTier(data, score, percentile)
    local thresholds = data.clothingBalancedThresholds or { good=53.64, excellent=61.28, slotConfirm=70 }
    local confirmed = data.slotRankingConfidence == "LOW" or (percentile or 0) >= thresholds.slotConfirm
    if data.utilityConfidence == "LOW" then return "RARE" end
    if data.baseScarcityTier == "COMMON" then return score >= thresholds.good and confirmed and "UNCOMMON" or "COMMON" end
    if data.baseScarcityTier == "UNCOMMON" then return score >= thresholds.good and confirmed and "RARE" or "UNCOMMON" end
    if score < thresholds.good then return "RARE" end
    if data.baseScarcityTier == "RARE" then return score >= thresholds.excellent and confirmed and "EPIC" or "RARE" end
    return score >= thresholds.excellent and confirmed and data.utilityConfidence == "HIGH" and "EXOTIC" or "EPIC"
end

local function addRecord(slots, data)
    if data.utilityScoreVersion ~= "CLOTHING_V1_P2_DIRECT_SLOT" or data.utility == nil then return end
    local graph = data.clothingEquipmentGraph or {}
    local slot = graph.slotId
    if type(slot) ~= "string" or slot == "" then return end
    slots[slot] = slots[slot] or { records={} }
    table.insert(slots[slot].records, { data=data, profile=data.utilityProfile or data.fullType })
end

local function prepareSlots(results)
    local slots = {}
    for _, data in pairs(results) do addRecord(slots, data) end
    for _, slot in pairs(slots) do
        table.sort(slot.records, function(a, b) return a.data.fullType < b.data.fullType end)
        local seen, weights = {}, {}
        for _, record in ipairs(slot.records) do
            local weight = record.data.utilityMetrics and record.data.utilityMetrics.weight
            if weight ~= nil and not seen[record.profile] then seen[record.profile] = true; table.insert(weights, weight) end
        end
        slot.weights = sortedCopy(weights)
        slot.byProfile = {}
        for _, record in ipairs(slot.records) do
            local weight = record.data.utilityMetrics and record.data.utilityMetrics.weight
            local percentile = weight ~= nil and API.percentileRank(slot.weights, weight, true) or 50
            local raw, shaped, weighted, total, penalty = costComponents(record.data, percentile)
            local components = record.data.utilityComponents and record.data.utilityComponents.directSlot or {}
            local benefit = (components.protection or 0) * (API.clothingDirectSlotV1Weights(record.data.clothingDirectSlotFunction).protection or 0)
                + (components.coverage or 0) * (API.clothingDirectSlotV1Weights(record.data.clothingDirectSlotFunction).coverage or 0)
                + (components.durability or 0) * (API.clothingDirectSlotV1Weights(record.data.clothingDirectSlotFunction).durability or 0)
                + (components.weather or 0) * (API.clothingDirectSlotV1Weights(record.data.clothingDirectSlotFunction).weather or 0)
            record.raw, record.shaped, record.weighted, record.costIndex, record.penalty = raw, shaped, weighted, total, penalty
            record.benefit = benefit
            record.newScore = math.max(0, (record.data.utility or 0) - penalty)
            local existing = slot.byProfile[record.profile]
            if not existing or record.newScore > existing.newScore or (record.newScore == existing.newScore and record.data.fullType < existing.data.fullType) then
                slot.byProfile[record.profile] = record
            end
        end
        local values = {}
        for _, representative in pairs(slot.byProfile) do table.insert(values, representative.newScore) end
        slot.scores = sortedCopy(values)
        for _, record in ipairs(slot.records) do
            record.newPercentile = API.clothingUtilityPercentileOfValue(slot.scores, record.newScore) or 50
            record.newTier = activeTier(record.data, record.newScore, record.newPercentile)
        end
    end
    return slots
end

local function findRecord(slots, fullType)
    for _, slot in pairs(slots) do
        for _, record in ipairs(slot.records) do if record.data.fullType == fullType then return record, slot end end
    end
end

function ItemRarityClothingCostCalibration.write(results)
    if type(results) ~= "table" or not getFileWriter then return false end
    local writer = getFileWriter("ItemRarity_ClothingCostCalibration.txt", true, true)
    if not writer then return false end
    local slots = prepareSlots(results)
    writer:write("Item Rarity Clothing functional-cost calibration (REPORT ONLY)\n")
    writer:write("Frozen active score, DIRECT_SLOT, Strategy D, tiers, registry and UI are not changed.\n\n")
    writer:write("NEW HYPOTHETICAL SCORE = active EquipmentQuality - progressive functional penalty. Costs use B42 intrinsic fields only.\n")
    writer:write("Cost priority: Combat 30%, Run 25%, Vision 15%, Hearing 15%, Discomfort 10%, contextual Weight 5%.\n")
    writer:write("Each raw loss has a tiny free zone (combat/run/vision/hearing 1%, discomfort 2%, weight 15th inverse-percentile); remaining cost follows x^0.72. Aggregate cost above 7 receives convex penalty (cost-7)^1.28/5.5.\n")
    writer:write("This keeps minimal debuffs nearly free, makes moderate costs visible, and makes severe stacked costs costly without a hard veto.\n\n")
    writer:write("fullType | DIRECT_SLOT | ProtectionBenefit | DurabilityBenefit | WeatherBenefit | CombatCost | RunCost | DiscomfortCost | VisionCost | HearingCost | WeightCost | CostIndex | ProgressivePenalty | EquipmentQualityActive | EquipmentQualityNew | SlotPctlActive->New | FinalActive->Hypothetical | raw[combat,run,discomfort,vision,hearing,weight]\n")
    local targets = {
        "Base.Vambrace_Left", "Base.Vambrace_Leather_Left", "Base.Shoulderpad_Articulated_L_Metal",
        "Base.Cuirass_Metal", "Base.Cuirass_Tire", "Base.Jacket_Leather", "Base.Jacket_Fireman", "Base.Jacket_NavyBlue",
        "Base.Shoes_WorkBoots", "Base.Shoes_BlueTrainers", "Base.Briefs_White", "Base.Socks_Ankle", "Base.Hat_BaseballCap",
    }
    for _, fullType in ipairs(targets) do
        local record = findRecord(slots, fullType)
        if not record then
            writer:write(fullType .. " | unavailable/not ClothingUtility eligible\n")
        else
            local data, c = record.data, record.data.utilityComponents and record.data.utilityComponents.directSlot or {}
            local roleWeights = API.clothingDirectSlotV1Weights(data.clothingDirectSlotFunction)
            writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s->%s | %s->%s | raw=%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n",
                fullType, tostring((data.clothingEquipmentGraph or {}).slotId), number((c.protection or 0) * (roleWeights.protection or 0)), number((c.durability or 0) * (roleWeights.durability or 0)), number((c.weather or 0) * (roleWeights.weather or 0)),
                number(record.weighted.combat), number(record.weighted.run), number(record.weighted.discomfort), number(record.weighted.vision), number(record.weighted.hearing), number(record.weighted.weight), number(record.costIndex), number(record.penalty),
                number(data.utility), number(record.newScore), number(data.slotQualityPercentile), number(record.newPercentile), tostring(data.finalRarityTier), tostring(record.newTier),
                record.raw.combat, record.raw.run, record.raw.discomfort, record.raw.vision, record.raw.hearing, record.raw.weight))
        end
    end
    local distribution = { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }
    local changed = {}
    for _, slot in pairs(slots) do for _, record in ipairs(slot.records) do
        distribution[record.newTier] = distribution[record.newTier] + 1
        if record.newTier ~= record.data.finalRarityTier then table.insert(changed, record) end
    end end
    table.sort(changed, function(a, b) return a.data.fullType < b.data.fullType end)
    writer:write(string.format("\nHYPOTHETICAL CLOTHING DISTRIBUTION | COMMON=%d | UNCOMMON=%d | RARE=%d | EPIC=%d | EXOTIC=%d\n", distribution.COMMON, distribution.UNCOMMON, distribution.RARE, distribution.EPIC, distribution.EXOTIC))
    writer:write("TIER CHANGES\n")
    for _, record in ipairs(changed) do writer:write(string.format("%s | %s -> %s | %.2f -> %.2f | penalty=%.2f | cost=%.2f\n", record.data.fullType, record.data.finalRarityTier, record.newTier, record.data.utility, record.newScore, record.penalty, record.costIndex)) end
    writer:close()
    ItemRarityUtils.info("Clothing functional-cost calibration written to Zomboid/Lua/ItemRarity_ClothingCostCalibration.txt (report only).")
    return true
end
