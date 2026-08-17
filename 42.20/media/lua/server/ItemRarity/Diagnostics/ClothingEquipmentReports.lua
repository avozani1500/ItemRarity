require "ItemRarity/RarityConfig"
require "ItemRarity/RarityUtils"
require "ItemRarity/UtilityCalculator"
ItemRarityClothingEquipmentReports = ItemRarityClothingEquipmentReports or {}
local API = ItemRarityUtilityCalculator.getClothingDiagnosticApi()
local UTILITY = API.UTILITY
local sortedCopy = API.sortedCopy
local clothingUtilityPercentileOfValue = API.clothingUtilityPercentileOfValue
local clothingDirectSlotV1Weights = API.clothingDirectSlotV1Weights
local directSlotEquipmentFunction = ItemRarityClothingComparabilityReports.directSlotEquipmentFunction
-- EquipmentQuality is intentionally a separate report-only view from V3's
-- cross-clothing diagnostic.  Every component is normalized within the exact
-- resolved BodyLocation, so score=75 for shoes is never interpreted as the
-- same absolute role quality as score=75 for a helmet.
local function writeClothingEquipmentQualityBySlotReport(results)
    if not UTILITY.diagnosticsEnabled or not getFileWriter then return end
    local writer = getFileWriter("ItemRarity_ClothingEquipmentQualityBySlot.txt", true, false)
    if not writer then return end
    local slots, reclassified, torsoAudit = {}, {}, {}
    local included = { HEADGEAR = true, TORSO_LAYER = true, PRIMARY_ARMOR = true, LOWER_BODY_LAYER = true,
        FOOTWEAR = true, ARMOR_ACCESSORY = true, FULL_BODY_RESTRICTIVE = true, CORE_ACCESSORY = true }
    local function roleWeights(role)
        -- Weights are selected from BodyLocation/coverage-derived role only,
        -- never an item name, fullType or module.  They express what the
        -- equipment slot is for; all inputs are then normalized inside its
        -- exact DIRECT_SLOT population.
        if role == "HEADGEAR" then return { protection = .42, coverage = .06, durability = .08, mobility = .04, weight = .05, discomfort = .10, visionHearing = .25 } end
        if role == "FOOTWEAR" then return { protection = .24, coverage = .06, durability = .15, mobility = .25, weight = .15, discomfort = .15, visionHearing = 0 } end
        if role == "PRIMARY_ARMOR" then return { protection = .48, coverage = .12, durability = .10, mobility = .10, weight = .08, discomfort = .12, visionHearing = 0 } end
        if role == "ARMOR_ACCESSORY" or role == "CORE_ACCESSORY" then return { protection = .45, coverage = .18, durability = .10, mobility = .07, weight = .08, discomfort = .12, visionHearing = 0 } end
        if role == "FULL_BODY_RESTRICTIVE" then return { protection = .35, coverage = .20, durability = .10, mobility = .13, weight = .08, discomfort = .10, visionHearing = .04 } end
        if role == "LOWER_BODY_LAYER" then return { protection = .36, coverage = .12, durability = .12, mobility = .16, weight = .11, discomfort = .11, visionHearing = .02 } end
        return { protection = .38, coverage = .12, durability = .10, mobility = .15, weight = .10, discomfort = .10, visionHearing = .05 }
    end
    for _, data in pairs(results) do
        local graph, metrics, parts = data.clothingEquipmentGraph, data.utilityMetrics or {}, data.utilityComponents or {}
        if data.category == "CLOTHING" and graph and graph.resolved and included[data.utilityFunctionalGroup] and
            parts.protectionCoverage ~= nil and data.utilityProfile then
            local slot = graph.slotId
            local role, reason, audit = directSlotEquipmentFunction(data)
            if data.utilityFunctionalGroup == "TORSO_LAYER" and (audit.regions ~= "" or audit.slotId ~= "") then
                torsoAudit[audit.slotId] = torsoAudit[audit.slotId] or audit
            end
            if role ~= data.utilityFunctionalGroup then
                table.insert(reclassified, { data = data, role = role, reason = reason })
            end
            slots[slot] = slots[slot] or { role = role, scoringRole = data.utilityFunctionalGroup, records = {} }
            table.insert(slots[slot].records, { data = data, metrics = metrics, parts = parts })
        end
    end
    local function rankValues(records, getter, inverted)
        local distinct, values = {}, {}
        for _, record in ipairs(records) do
            local key, value = record.data.utilityProfile, getter(record)
            if distinct[key] == nil and value ~= nil then distinct[key] = value; table.insert(values, value) end
        end
        local sorted = sortedCopy(values)
        return sorted, function(record)
            local value = getter(record)
            return value ~= nil and percentileRank(sorted, value, inverted) or nil
        end
    end
    local slotKeys = sortedKeys(slots)
    writer:write("Item Rarity EquipmentQuality by DIRECT_SLOT (REPORT ONLY)\n")
    writer:write("No active ClothingUtility, Scarcity, matrix, FinalRarityTier or UI changes. EquipmentQualityScore is meaningful only inside the printed DIRECT_SLOT; it is never compared across footwear, headgear, armor, jackets, etc.\n")
    writer:write("Equipment function is derived from BodyLocation + coexistence graph + covered regions. The scoring-weight profile remains intentionally unchanged in this report so that this semantic reclassification cannot alter a DIRECT_SLOT ranking.\n")
    writer:write("Each slot uses profile-deduplicated runtime values. SlotRankingConfidence: HIGH >=20 profiles, MEDIUM 8-19, LOW <8. Low sample size lowers only rank certainty, not availability of a complete item-quality assessment.\n")
    writer:write("Components below are 0-100 ranks inside that exact BodyLocation. Protection uses effective bite/scratch/bullet defense after anatomical coverage; Coverage is its structural coverage factor; Mobility blends RunSpeed and CombatSpeed; Discomfort/Weight are inverted; Vision/Hearing is the mean retention.\n\n")
    table.sort(reclassified, function(a, b) return a.data.fullType < b.data.fullType end)
    writer:write(string.format("\nFUNCTION RECLASSIFICATIONS ONLY (count=%d)\n", #reclassified))
    if #reclassified == 0 then writer:write("none\n") end
    for _, change in ipairs(reclassified) do
        writer:write(string.format("%s | %s -> %s | slot=%s | regions=%s | %s\n", change.data.fullType,
            tostring(change.data.utilityFunctionalGroup), change.role, tostring(change.data.clothingEquipmentGraph.slotId),
            table.concat(change.data.clothingDiscovery.coveredRegions or {}, "+"), change.reason))
    end
    writer:write("\nTORSO_LAYER STRUCTURAL AUDIT (diagnostic only)\n")
    for _, slotId in ipairs(sortedKeys(torsoAudit)) do
        local audit = torsoAudit[slotId]
        writer:write(string.format("%s | regions=%s | resolved=%s | conflictsCuirass=%s | localizedPeripheral=%s\n", slotId,
            audit.regions ~= "" and audit.regions or "N/A", tostring(audit.resolved), tostring(audit.conflictsCuirass), tostring(audit.localized)))
    end
    for _, slotKey in ipairs(slotKeys) do
        local slot = slots[slotKey]
        local records = slot.records
        local protectionValues, protectionRank = rankValues(records, function(r) return r.parts.protectionCoverage end, false)
        local coverageValues, coverageRank = rankValues(records, function(r) return (r.parts.coverageFactor or 0) * 100 end, false)
        local durabilityValues, durabilityRank = rankValues(records, function(r) return r.metrics.durability end, false)
        local mobilityValues, mobilityRank = rankValues(records, function(r)
            local run, combat = r.metrics.runSpeedModifier, r.metrics.combatSpeedModifier
            return run ~= nil and combat ~= nil and (run * .70 + combat * .30) or nil
        end, false)
        local weightValues, weightRank = rankValues(records, function(r) return r.metrics.weight end, true)
        local discomfortValues, discomfortRank = rankValues(records, function(r) return r.metrics.discomfortModifier end, true)
        local sensesValues, sensesRank = rankValues(records, function(r)
            local vision, hearing = r.metrics.visionModifier, r.metrics.hearingModifier
            return vision ~= nil and hearing ~= nil and (vision + hearing) / 2 or nil
        end, false)
        local profileSet, uniqueProfiles = {}, 0
        for _, record in ipairs(records) do
            if not profileSet[record.data.utilityProfile] then profileSet[record.data.utilityProfile] = true; uniqueProfiles = uniqueProfiles + 1 end
        end
        local rankingConfidence = uniqueProfiles >= 20 and "HIGH" or (uniqueProfiles >= 8 and "MEDIUM" or "LOW")
        local weights = roleWeights(slot.scoringRole)
        local representatives = {}
        for _, record in ipairs(records) do
            local key = record.data.utilityProfile
            local entry = representatives[key]
            if not entry then entry = { record = record, items = {} }; representatives[key] = entry end
            table.insert(entry.items, record.data.fullType)
        end
        local ranked = {}
        for _, entry in pairs(representatives) do
            local record = entry.record
            local q = {
                protection = protectionRank(record) or 50, coverage = coverageRank(record) or 50, durability = durabilityRank(record) or 50,
                mobility = mobilityRank(record) or 50, weight = weightRank(record) or 50, discomfort = discomfortRank(record) or 50,
                visionHearing = sensesRank(record) or 50,
            }
            entry.quality = q.protection * weights.protection + q.coverage * weights.coverage + q.durability * weights.durability +
                q.mobility * weights.mobility + q.weight * weights.weight + q.discomfort * weights.discomfort + q.visionHearing * weights.visionHearing
            entry.components = q
            table.insert(ranked, entry)
        end
        table.sort(ranked, function(a, b) return a.quality > b.quality end)
        local scores = {}
        for _, entry in ipairs(ranked) do table.insert(scores, entry.quality) end
        scores = sortedCopy(scores)
        writer:write(string.format("\nDIRECT_SLOT %s | FUNCTION %s | unique mechanical profiles=%d | SlotRankingConfidence=%s\n", slotKey, slot.role, uniqueProfiles, rankingConfidence))
        writer:write(string.format("Unchanged scoring profile (%s): protection %.0f%% | coverage %.0f%% | durability %.0f%% | mobility %.0f%% | weight %.0f%% | discomfort %.0f%% | vision/hearing %.0f%%\n",
            slot.scoringRole,
            weights.protection * 100, weights.coverage * 100, weights.durability * 100, weights.mobility * 100, weights.weight * 100, weights.discomfort * 100, weights.visionHearing * 100))
        writer:write("Top 5: ")
        local leaders = {}
        for index, entry in ipairs(ranked) do if index <= 5 then table.insert(leaders, entry.items[1]) end end
        writer:write(table.concat(leaders, ", ") .. "\n")
        writer:write("rank | item(s) sharing mechanical profile | EquipmentQualityScore | SlotPercentile | Protection | Coverage | Durability | Mobility | Discomfort | Weight | Vision/Hearing\n")
        for index, entry in ipairs(ranked) do
            table.sort(entry.items)
            local q = entry.components
            writer:write(string.format("%d | %s | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f\n", index,
                table.concat(entry.items, ","), entry.quality, clothingUtilityPercentileOfValue(scores, entry.quality) or 50,
                q.protection, q.coverage, q.durability, q.mobility, q.discomfort, q.weight, q.visionHearing))
        end
    end
    writer:close()
    ItemRarityUtils.info("EquipmentQuality DIRECT_SLOT report written to Zomboid/Lua/ItemRarity_ClothingEquipmentQualityBySlot.txt (report only; active tier and UI unchanged).")
end

function ItemRarityClothingEquipmentReports.write(results)
    return writeClothingEquipmentQualityBySlotReport(results)
end
