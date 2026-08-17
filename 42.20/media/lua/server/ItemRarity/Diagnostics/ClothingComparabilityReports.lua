require "ItemRarity/RarityConfig"
require "ItemRarity/RarityUtils"
require "ItemRarity/UtilityCalculator"
ItemRarityClothingComparabilityReports = ItemRarityClothingComparabilityReports or {}
local API = ItemRarityUtilityCalculator.getClothingDiagnosticApi()
local UTILITY = API.UTILITY
local sortedKeys = API.sortedKeys
local hasOnlyAccessoryRegions = API.hasOnlyAccessoryRegions
local regionSet = API.regionSet
-- Structural comparison discovery only.  A direct candidate occupies the
-- same B42 BodyLocation; a substitution candidate occupies a mutually
-- exclusive slot and overlaps anatomically.  Compatible pieces are explicitly
-- reported as complements, never silently mixed into the comparison sample.
local function writeClothingSlotComparabilityReport(results)
    if not UTILITY.diagnosticsEnabled or not getFileWriter then return end
    local writer = getFileWriter("ItemRarity_ClothingSlotComparability.txt", true, false)
    if not writer then return end
    local clothing, slots = {}, {}
    local targets = { "Base.Jacket_NavyBlue", "Base.Cuirass_Metal", "Base.Gorget_Metal", "Base.Hat_MetalHelmet", "Base.Vambrace_Left",
        "Base.Shoulderpad_Articulated_L_Metal", "Base.Shoulderpad_Articulated_R_Metal", "Base.Chainmail_SleeveFull_L", "Base.Chainmail_SleeveFull_R",
        "Base.Shoes_WorkBoots", "Base.Shoes_BlueTrainers", "Base.HazmatSuit" }
    local function profileCount(list)
        local profiles = {}
        for _, data in ipairs(list) do if data.utilityProfile then profiles[data.utilityProfile] = true end end
        local total = 0
        for _ in pairs(profiles) do total = total + 1 end
        return total
    end
    local function has(list, value)
        for _, entry in ipairs(list or {}) do if entry == value then return true end end
        return false
    end
    local function overlap(left, right)
        local regions = {}
        for _, region in ipairs(left.clothingDiscovery and left.clothingDiscovery.coveredRegions or {}) do regions[region] = true end
        for _, region in ipairs(right.clothingDiscovery and right.clothingDiscovery.coveredRegions or {}) do if regions[region] then return true end end
        return false
    end
    local function exclusive(left, right)
        local leftGraph, rightGraph = left.clothingEquipmentGraph or {}, right.clothingEquipmentGraph or {}
        return has(leftGraph.exclusive, rightGraph.slotId) or has(rightGraph.exclusive, leftGraph.slotId)
    end
    local function examples(list, self)
        local names = {}
        for _, data in ipairs(list) do
            if data.fullType ~= self.fullType then table.insert(names, data.fullType) end
        end
        table.sort(names)
        if #names == 0 then return "none" end
        local visible = {}
        for index, name in ipairs(names) do
            if index > 18 then table.insert(visible, "+" .. tostring(#names - 18) .. " more"); break end
            table.insert(visible, name)
        end
        return table.concat(visible, ",")
    end
    for _, data in pairs(results) do
        if data.category == "CLOTHING" and data.clothingEquipmentGraph and data.clothingEquipmentGraph.resolved then
            table.insert(clothing, data)
            local slot = data.clothingEquipmentGraph.slotId
            slots[slot] = slots[slot] or {}
            table.insert(slots[slot], data)
        end
    end
    writer:write("Item Rarity BodyLocation comparability discovery (REPORT ONLY)\n")
    writer:write("No ClothingUtility score, percentile, tier, matrix input or UI field is changed. Groups are derived only from resolved Human BodyLocation, BloodLocation-derived covered regions and BodyLocation exclusivity. Item names are printed only as evidence, never used to form a group.\n\n")
    writer:write("COMPARISON RULES\n")
    writer:write("DIRECT_SLOT: same BodyLocation; these are alternatives because only one item can occupy a slot. EXCLUSION_ENVELOPE: DIRECT_SLOT plus a mutually exclusive slot with at least one shared anatomical region; these are substitution candidates. COVERAGE_TOPOLOGY_PARENT: same coverage-zone topology plus overlapping derived regions, used only if direct/exclusion samples remain under 12 mechanical profiles. Compatible overlapping pieces are complements and are not comparison candidates. Confidence target: HIGH >=20 profiles, MEDIUM 12-19, LOW <12.\n\n")
    writer:write("BODYLOCATION SLOT CATALOG (all resolved clothing)\n")
    writer:write("slot | items | unique mechanical profiles | coverage-zone examples | conflict degree\n")
    local slotNames = sortedKeys(slots)
    for _, slot in ipairs(slotNames) do
        local list, zones, degree = slots[slot], {}, 0
        for _, data in ipairs(list) do
            local zone = data.clothingDiscovery and data.clothingDiscovery.coverageZones
            if zone then zones[zone] = true end
            degree = math.max(degree, #(data.clothingEquipmentGraph.exclusive or {}))
        end
        writer:write(string.format("%s | %d | %d | %s | %d\n", slot, #list, profileCount(list), table.concat(sortedKeys(zones), "+"), degree))
    end
    writer:write("\nTARGET COMPARABILITY\n")
    writer:write("fullType | BodyLocation | BloodLocation/topology | derived regions | conflicts | direct slot profiles/items | exclusion envelope profiles/items | coverage parent profiles/items | selected comparison group | confidence | direct competitors | compatible anatomical complements\n")
    for _, fullType in ipairs(targets) do
        local data = results[fullType]
        if not data or not (data.clothingEquipmentGraph and data.clothingEquipmentGraph.resolved) then
            writer:write(fullType .. " | unavailable or unresolved BodyLocation\n")
        else
            local graph, discovery = data.clothingEquipmentGraph, data.clothingDiscovery or {}
            local direct, envelope, parent, compatible = {}, {}, {}, {}
            for _, other in ipairs(clothing) do
                local sameSlot = other.clothingEquipmentGraph.slotId == graph.slotId
                local overlaps = overlap(data, other)
                local excludes = exclusive(data, other)
                local sameTopology = discovery.coverageZones ~= nil and discovery.coverageZones == (other.clothingDiscovery and other.clothingDiscovery.coverageZones)
                if sameSlot then table.insert(direct, other) end
                if sameSlot or (excludes and overlaps) then table.insert(envelope, other) end
                if sameTopology and overlaps then table.insert(parent, other) end
                if other.fullType ~= data.fullType and not sameSlot and not excludes and overlaps then table.insert(compatible, other) end
            end
            local directProfiles, envelopeProfiles, parentProfiles = profileCount(direct), profileCount(envelope), profileCount(parent)
            local chosen, chosenProfiles
            if directProfiles >= 12 then chosen, chosenProfiles = "DIRECT_SLOT", directProfiles
            elseif envelopeProfiles >= 12 then chosen, chosenProfiles = "EXCLUSION_ENVELOPE", envelopeProfiles
            elseif parentProfiles >= 12 then chosen, chosenProfiles = "COVERAGE_TOPOLOGY_PARENT", parentProfiles
            elseif envelopeProfiles >= directProfiles and envelopeProfiles >= parentProfiles then chosen, chosenProfiles = "LOW_SAMPLE_EXCLUSION_ENVELOPE", envelopeProfiles
            else chosen, chosenProfiles = "LOW_SAMPLE_COVERAGE_TOPOLOGY_PARENT", parentProfiles end
            local confidence = chosenProfiles >= 20 and "HIGH-capable" or (chosenProfiles >= 12 and "MEDIUM-capable" or "LOW")
            writer:write(string.format("%s | %s | %s/%s | %s | %s | %d/%d | %d/%d | %d/%d | %s (%d profiles) | %s | %s | %s\n", fullType,
                tostring(graph.slotId), tostring(discovery.coveredParts or "-"), tostring(discovery.topology or "-"), table.concat(discovery.coveredRegions or {}, "+"),
                table.concat(graph.exclusive or {}, ","), directProfiles, #direct, envelopeProfiles, #envelope, parentProfiles, #parent, chosen, chosenProfiles, confidence,
                examples(direct, data), examples(compatible, data)))
            writer:write(string.format("  EXCLUSION_SUBSTITUTES: %s\n", examples(envelope, data)))
            writer:write(string.format("  COVERAGE_PARENT_REFERENCES: %s\n", examples(parent, data)))
        end
    end
    local navy = results["Base.Jacket_NavyBlue"]
    if navy and navy.clothingEquipmentGraph and navy.clothingEquipmentGraph.resolved then
        local peers = slots[navy.clothingEquipmentGraph.slotId] or {}
        writer:write("\nJACKET_NavyBlue DIRECT_SLOT EVIDENCE\n")
        writer:write("All entries below share its resolved BodyLocation; any leather-jacket variants present here are evidence from the graph, not a name rule.\n")
        for _, peer in ipairs(peers) do
            local metrics, discovery = peer.utilityMetrics or {}, peer.clothingDiscovery or {}
            writer:write(string.format("%s | regions=%s | bite=%.1f | scratch=%.1f | bullet=%.1f | run=%.2f | combat=%.2f | discomfort=%.2f | weight=%.2f\n", peer.fullType,
                table.concat(discovery.coveredRegions or {}, "+"), metrics.biteDefense or 0, metrics.scratchDefense or 0, metrics.bulletDefense or 0,
                metrics.runSpeedModifier or 0, metrics.combatSpeedModifier or 0, metrics.discomfortModifier or 0, metrics.weight or 0))
        end
    end
    writer:close()
    ItemRarityUtils.info("BodyLocation comparability discovery written to Zomboid/Lua/ItemRarity_ClothingSlotComparability.txt (report only; no utility/tier/UI changes).")
end

-- Shared structural classification for all diagnostic views. A localized slot
-- compatible with Cuirass is a complementary armor accessory, not a torso
-- layer merely because its coverage touches the upper body.
local function directSlotEquipmentFunction(data)
    local graph = data.clothingEquipmentGraph or {}
    local regions = data.clothingDiscovery and data.clothingDiscovery.coveredRegions or {}
    local conflictsCuirass = false
    for _, excluded in ipairs(graph.exclusive or {}) do
        if string.lower(tostring(excluded)) == "base:cuirass" then conflictsCuirass = true break end
    end
    local localized = hasOnlyAccessoryRegions(regionSet(regions))
    local audit = { resolved = graph.resolved == true, slotId = tostring(graph.slotId or ""), conflictsCuirass = conflictsCuirass, localized = localized,
        regions = table.concat(regions, "+") }
    local shoulderSlot = string.find(string.lower(audit.slotId), "shoulderpad", 1, true) ~= nil
    if audit.resolved and string.lower(audit.slotId) ~= "base:cuirass" and not conflictsCuirass and (localized or shoulderSlot) then
        return "ARMOR_ACCESSORY", "localized protected region in a Cuirass-compatible BodyLocation", audit
    end
    return data.utilityFunctionalGroup or "GENERAL_UNRESOLVED", "unchanged inherited structural role", audit
end

-- V3 is a report-only architecture: absolute quality uses global robust
-- component scales, while relative position is calculated only in the exact
-- BodyLocation slot.  No anatomy-wide fallback is used to inflate a slot.
function ItemRarityClothingComparabilityReports.write(results)
    return writeClothingSlotComparabilityReport(results)
end

ItemRarityClothingComparabilityReports.directSlotEquipmentFunction = directSlotEquipmentFunction
