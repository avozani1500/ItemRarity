-- Explicit, read-only diagnostic for ClothingUtility V1 P2/DIRECT_SLOT.
-- It never creates an item instance, changes a candidate, republishes the
-- registry, or invokes a scan.  It exists to compare intrinsic 0..100-style
-- components with the active within-slot percentile components.
require "ItemRarity/RarityUtils"

ItemRarityClothingAbsoluteComponentsAudit = ItemRarityClothingAbsoluteComponentsAudit or {}

local function clamp(value, low, high)
    value = tonumber(value) or 0
    return math.max(low, math.min(high, value))
end

local function sortedCopy(values)
    local copy = {}
    for _, value in ipairs(values or {}) do table.insert(copy, value) end
    table.sort(copy)
    return copy
end

local function quantile(values, percentile)
    if not values or #values == 0 then return nil end
    if #values == 1 then return values[1] end
    local position = clamp(percentile, 0, 100) / 100 * (#values - 1) + 1
    local lower, upper = math.floor(position), math.ceil(position)
    if lower == upper then return values[lower] end
    local fraction = position - lower
    return values[lower] + (values[upper] - values[lower]) * fraction
end

local function robustScale(value, scale, inverted)
    if value == nil or not scale or scale.low == nil or scale.high == nil then return nil end
    if scale.high <= scale.low then return 50 end
    local normalized = clamp((clamp(value, scale.low, scale.high) - scale.low) / (scale.high - scale.low) * 100, 0, 100)
    return inverted and (100 - normalized) or normalized
end

local function fmt(value)
    return value ~= nil and string.format("%.3f", value) or "N/A"
end

local function text(value)
    local result = tostring(value or "")
    return result ~= "" and result or "-"
end

-- Mirrors the public ScriptItem access used by ItemClassifier, but is only
-- called by this explicit report.  It lets the report distinguish a scan-time
-- classification gap from a missing ScriptItem in the currently loaded game.
local function callMethod(object, name)
    if not object or type(object[name]) ~= "function" then return nil end
    local ok, result = pcall(function() return object[name](object) end)
    return ok and result or nil
end

local function findScriptItem(fullType)
    local manager = getScriptManager and getScriptManager() or nil
    if not manager or type(manager.FindItem) ~= "function" then return nil end
    local ok, item = pcall(function() return manager:FindItem(fullType) end)
    return ok and item or nil
end

local function scriptProbe(fullType)
    local item = findScriptItem(fullType)
    if not item then return { found=false } end
    return {
        found=true,
        displayCategory=text(callMethod(item, "getDisplayCategory")),
        scriptType=text(callMethod(item, "getType")),
        itemType=text(callMethod(item, "getItemType")),
        bodyLocation=text(callMethod(item, "getBodyLocation")),
        bloodClothingType=text(callMethod(item, "getBloodClothingType")),
    }
end

local COVERAGE_WEIGHTS = {
    HEAD = 1.30, NECK = 1.25, TORSO_UPPER = 1.20, TORSO_LOWER = 1.10,
    GROIN = 1.00, UPPER_ARM = 0.85, FOREARM = 0.80, HAND = 0.70,
    THIGH = 0.80, SHIN = 0.75, FOOT = 0.65,
}

local function coverageWeight(regions)
    local total = 0
    for _, region in ipairs(regions or {}) do total = total + (COVERAGE_WEIGHTS[region] or 0) end
    return total
end

local function isClothingEvidenceRecord(data)
    return data and data.category == "CLOTHING" and type(data.utilityMetrics) == "table"
        and type(data.clothingDiscovery) == "table"
        and data.clothingMechanicalValueStatus ~= "MECHANICALLY_TRIVIAL"
end

local function hasActiveDirectSlot(data)
    return data and data.utilityComponents and data.utilityComponents.directSlot ~= nil
        and data.utility ~= nil and data.utilityKind == "CLOTHING"
end

local function summary(writer, label, values)
    values = sortedCopy(values)
    writer:write(string.format("%s | n=%d | min=%s | p05=%s | p25=%s | median=%s | p75=%s | p95=%s | max=%s\n",
        label, #values, fmt(values[1]), fmt(quantile(values, 5)), fmt(quantile(values, 25)), fmt(quantile(values, 50)),
        fmt(quantile(values, 75)), fmt(quantile(values, 95)), fmt(values[#values])))
end

local function directComponents(data)
    return ((data.utilityComponents or {}).directSlot or {})
end

local function lowerBodyRecord(data)
    local graph = data.clothingEquipmentGraph or {}
    local discovery = data.clothingDiscovery or {}
    local slot = string.lower(tostring(graph.slotId or discovery.bodyLocation or ""))
    return slot == "base:pants" or slot == "base:pants_skinny" or slot == "base:shortpants" or slot == "base:shortsshort"
end

-- These anchors are anatomical/runtime constants, deliberately not derived
-- from the records in a slot.  They are used only by the explicit V2
-- simulation below; V1 remains untouched.
local LOWER_BODY_ANATOMICAL_MAXIMUM = COVERAGE_WEIGHTS.GROIN + COVERAGE_WEIGHTS.THIGH + COVERAGE_WEIGHTS.SHIN

local function clothingC1Tier(score)
    -- Mirrors the frozen C1 cuts in UtilityCalculator.lua.  Keeping the
    -- values here makes this diagnostic self-contained and read-only.
    if score < 40.00 then return "COMMON" end
    if score < 53.64 then return "UNCOMMON" end
    if score < 61.28 then return "RARE" end
    if score < 70.00 then return "EPIC" end
    return "EXOTIC"
end

local TIER_ORDER = { COMMON=1, UNCOMMON=2, RARE=3, EPIC=4, EXOTIC=5 }

local function c1Adjustment(data)
    if data.clothingScarcityAdjustment ~= nil then return tonumber(data.clothingScarcityAdjustment) or 0 end
    local strength = tonumber(data.clothingScarcityStrength)
    if strength == nil then
        local percentile = tonumber(data.scarcityPercentile) or tonumber(((data.tableAvailability or {}).routeWeightedPercentile)) or 50
        strength = clamp(100 - percentile, 0, 100)
    end
    return (strength - 50) / 10
end

local function writeAudit(results)
    if type(results) ~= "table" or not getFileWriter then return false end
    local records, distributions, directSlotCount = {}, {
        run = {}, combat = {}, insulation = {}, wind = {}, water = {}, bite = {}, scratch = {}, bullet = {},
        weight = {}, durability = {}, coveredWeight = {}, coveredCount = {},
    }, 0
    local slotCounts = {}
    for _, data in pairs(results) do
        if isClothingEvidenceRecord(data) then
            local metrics, discovery = data.utilityMetrics or {}, data.clothingDiscovery or {}
            local graph = data.clothingEquipmentGraph or {}
            local regions = discovery.coveredRegions or {}
            local record = { data=data, metrics=metrics, regions=regions, coverageWeight=coverageWeight(regions),
                slot=tostring(graph.slotId or discovery.bodyLocation or ""), activeDirectSlot=hasActiveDirectSlot(data) }
            table.insert(records, record)
            if record.activeDirectSlot then
                directSlotCount = directSlotCount + 1
                slotCounts[record.slot] = (slotCounts[record.slot] or 0) + 1
            end
            local fields = { run="runSpeedModifier", combat="combatSpeedModifier", insulation="insulation", wind="windResistance",
                water="waterResistance", bite="biteDefense", scratch="scratchDefense", bullet="bulletDefense", weight="weight", durability="durability" }
            for key, field in pairs(fields) do if metrics[field] ~= nil then table.insert(distributions[key], tonumber(metrics[field])) end end
            if record.coverageWeight > 0 then
                table.insert(distributions.coveredWeight, record.coverageWeight)
                table.insert(distributions.coveredCount, #(regions or {}))
            end
        end
    end
    local scales = {
        weight = { low=quantile(sortedCopy(distributions.weight), 5), high=quantile(sortedCopy(distributions.weight), 95) },
        durability = { low=quantile(sortedCopy(distributions.durability), 5), high=quantile(sortedCopy(distributions.durability), 95) },
    }
    local lower = {}
    for _, record in ipairs(records) do
        if lowerBodyRecord(record.data) then
            table.insert(lower, record)
        end
    end
    for _, record in ipairs(lower) do
        local m = record.metrics
        local coverage = LOWER_BODY_ANATOMICAL_MAXIMUM > 0 and record.coverageWeight / LOWER_BODY_ANATOMICAL_MAXIMUM * 100 or nil
        local protectionBase = clamp(m.biteDefense, 0, 100) * .50 + clamp(m.scratchDefense, 0, 100) * .35 + clamp(m.bulletDefense, 0, 100) * .15
        local protection = coverage and protectionBase * coverage / 100 or nil
        local mobility = m.runSpeedModifier ~= nil and m.combatSpeedModifier ~= nil
            and (clamp(m.runSpeedModifier, 0, 1) * .70 + clamp(m.combatSpeedModifier, 0, 1) * .30) * 100 or nil
        local weather = m.insulation ~= nil and m.windResistance ~= nil and m.waterResistance ~= nil
            and (clamp(m.insulation, 0, 1) * .40 + clamp(m.windResistance, 0, 1) * .35 + clamp(m.waterResistance, 0, 1) * .25) * 100 or nil
        local weight = robustScale(m.weight, scales.weight, true)
        local durability = robustScale(m.durability, scales.durability, false)
        local discomfort = m.discomfortModifier ~= nil and (1 - clamp(m.discomfortModifier, 0, 1)) * 100 or nil
        local senses = m.visionModifier ~= nil and m.hearingModifier ~= nil
            and (clamp(m.visionModifier, 0, 1) + clamp(m.hearingModifier, 0, 1)) * 50 or nil
        if protection ~= nil and coverage ~= nil and durability ~= nil and mobility ~= nil and weight ~= nil and discomfort ~= nil and senses ~= nil and weather ~= nil then
            record.absolute = { protection=protection, coverage=coverage, durability=durability, mobility=mobility, weight=weight,
                discomfort=discomfort, senses=senses, weather=weather }
            -- Same LOWER_BODY_LAYER weights as active V1, but every component is
            -- intrinsic/global rather than ranked inside base:pants/shortpants/shortsshort.
            record.absoluteScore = protection * .34 + coverage * .12 + durability * .12 + mobility * .15 + weight * .10
                + discomfort * .10 + senses * .02 + weather * .05

            -- V2 candidate: replace only Coverage, Mobility and Weather.
            -- Protection, Durability, Weight, Discomfort and Senses retain
            -- their exact currently published V1 DIRECT_SLOT components.
            local active = directComponents(record.data)
            if active.protection ~= nil and active.durability ~= nil and active.weight ~= nil
                and active.discomfort ~= nil and active.senses ~= nil then
                record.v2Score = active.protection * .34 + coverage * .12 + active.durability * .12 + mobility * .15
                    + active.weight * .10 + active.discomfort * .10 + active.senses * .02 + weather * .05
                record.v2Adjustment = c1Adjustment(record.data)
                record.v2C1 = clamp(record.v2Score + record.v2Adjustment, 0, 100)
                record.v2Tier = clothingC1Tier(record.v2C1)
            end
        end
    end
    local writer = getFileWriter("ItemRarity_ClothingAbsoluteComponentsAudit.txt", true, false)
    if not writer then return false end
    writer:write("Item Rarity Clothing absolute-components audit (READ ONLY)\n")
    writer:write("No active Utility component, Clothing C1 combiner, tier, registry, scan, config or UI field is changed. This file reads only the current published scanner results.\n\n")
    writer:write("TARGET PRESENCE IN CURRENT PUBLISHED RESULTS\n")
    writer:write("fullType | present | scanCategory | scanDisplayCategory | utilityKind | utilityEligible | hasMetrics | hasAnatomy | scanBodyLocation | activeScore | mechanicalStatus | scriptNowFound | scriptNowDisplayCategory | scriptNowType | scriptNowItemType | scriptNowBodyLocation | scriptNowBloodClothingType\n")
    for _, fullType in ipairs({ "Base.Trousers_Denim", "Base.Shorts_ShortDenim", "Base.Shorts_LongDenim", "Base.Shorts_ShortSport", "Base.Trousers_DefaultTEXTURE", "Base.Trousers_Fireman", "Base.Trousers_LeatherBlack" }) do
        local data = results[fullType]
        local discovery = data and data.clothingDiscovery or {}
        local probe = scriptProbe(fullType)
        writer:write(table.concat({ fullType, tostring(data ~= nil), text(data and data.category), text(data and data.displayCategory), text(data and data.utilityKind),
            tostring(data and data.utilityEligible == true), tostring(data and type(data.utilityMetrics) == "table"),
            tostring(data and type(data.clothingDiscovery) == "table"), text(discovery.bodyLocation), fmt(data and data.utility), text(data and data.clothingMechanicalValueStatus),
            tostring(probe.found), text(probe.displayCategory), text(probe.scriptType), text(probe.itemType), text(probe.bodyLocation), text(probe.bloodClothingType) }, " | ") .. "\n")
    end
    writer:write("\n")
    writer:write(string.format("CLOTHING NONTRIVIAL ANATOMY RECORDS=%d | ACTIVE DIRECT_SLOT RECORDS=%d | LOWER_BODY structural records=%d | lower-body anatomical maximum=%.3f\n\n", #records, directSlotCount, #lower, LOWER_BODY_ANATOMICAL_MAXIMUM))
    writer:write("ACTIVE NORMALIZATION INVENTORY\n")
    writer:write("protection: 40% within-DIRECT_SLOT percentile + 60% absolute raw bite/scratch/bullet x 0.70..1.00 anatomy factor\n")
    writer:write("coverage: within-DIRECT_SLOT percentile of the same 0.70..1.00 anatomy factor\n")
    writer:write("durability, mobility, inverse weight, inverse discomfort, senses, weather: within-DIRECT_SLOT percentiles\n")
    writer:write("physical bite/scratch/bullet first use shared global p05/p95 to form ProtectionCoverage, but the active protection component then reintroduces a 40% slot-relative rank.\n\n")
    writer:write("RAW DISTRIBUTIONS (all nontrivial Clothing records with published anatomy/metrics; duplicates retained)\n")
    for _, key in ipairs({ "run", "combat", "insulation", "wind", "water", "bite", "scratch", "bullet", "weight", "durability", "coveredCount", "coveredWeight" }) do summary(writer, key, distributions[key]) end
    writer:write("\nACTIVE DIRECT_SLOT POPULATIONS\nslot | item records\n")
    local slots = {}
    for slot in pairs(slotCounts) do table.insert(slots, slot) end
    table.sort(slots)
    for _, slot in ipairs(slots) do writer:write(text(slot) .. " | " .. tostring(slotCounts[slot]) .. "\n") end
    writer:write("\nALL CLOTHING COMPONENT EVIDENCE\n")
    writer:write("fullType | activeDirectSlot | slot/bodyLocation | regions | regionCount | anatomyWeight | run | combat | insulation | wind | water | bite | scratch | bullet | weight | durability | activeScore | active P/Cov/Dur/Mob/Wt/Disc/Sense/Weather\n")
    table.sort(records, function(a, b) return a.data.fullType < b.data.fullType end)
    for _, record in ipairs(records) do
        local m, active = record.metrics, directComponents(record.data)
        writer:write(table.concat({ text(record.data.fullType), tostring(record.activeDirectSlot), text(record.slot), #(record.regions or {}) > 0 and table.concat(record.regions, "+") or "N/A",
            tostring(#(record.regions or {})), fmt(record.coverageWeight), fmt(m.runSpeedModifier), fmt(m.combatSpeedModifier), fmt(m.insulation), fmt(m.windResistance), fmt(m.waterResistance),
            fmt(m.biteDefense), fmt(m.scratchDefense), fmt(m.bulletDefense), fmt(m.weight), fmt(m.durability), fmt(record.data.utility),
            table.concat({ fmt(active.protection), fmt(active.coverage), fmt(active.durability), fmt(active.mobility), fmt(active.weight), fmt(active.discomfort), fmt(active.senses), fmt(active.weather) }, "/") }, " | ") .. "\n")
    end
    writer:write("\nLOWER_BODY ABSOLUTE-COMPONENT SIMULATION (diagnostic only; no tier calculation)\n")
    writer:write("Absolute protection = (bite*.50 + scratch*.35 + bullet*.15) x lower-body anatomical coverage fraction. Coverage fraction uses structural LOWER_BODY maximum, not item-population percentiles and no 0.70 floor. Mobility = (run*.70 + combat*.30)*100. Weather = (.40 insulation + .35 wind + .25 water)*100. Weight/durability use global direct-slot p05/p95 robust scales. Other components are direct bounded intrinsic values.\n")
    writer:write("fullType | slot | finalTier | activeScore | raw run/combat | raw B/S/B | regions | coverage% | abs P/Cov/Dur/Mob/Wt/Disc/Sense/Weather | absoluteLowerBodyScore\n")
    table.sort(lower, function(a, b) return (a.absoluteScore or -1) > (b.absoluteScore or -1) end)
    for _, record in ipairs(lower) do
        local m, a = record.metrics, record.absolute or {}
        writer:write(table.concat({ text(record.data.fullType), text(record.slot), text(record.data.finalRarityTier), fmt(record.data.utility), fmt(m.runSpeedModifier) .. "/" .. fmt(m.combatSpeedModifier),
            fmt(m.biteDefense) .. "/" .. fmt(m.scratchDefense) .. "/" .. fmt(m.bulletDefense), #(record.regions or {}) > 0 and table.concat(record.regions, "+") or "N/A", fmt(a.coverage),
            table.concat({ fmt(a.protection), fmt(a.coverage), fmt(a.durability), fmt(a.mobility), fmt(a.weight), fmt(a.discomfort), fmt(a.senses), fmt(a.weather) }, "/"), fmt(record.absoluteScore) }, " | ") .. "\n")
    end
    writer:close()

    -- A separate compact report is deliberately created only through this
    -- explicit diagnostics command.  It exposes the exact V2 substitution
    -- requested for every LOWER_BODY record, including C1/tier effects.
    local simulation = getFileWriter("ItemRarity_ClothingLowerBodyV2Simulation.txt", true, false)
    if simulation then
        local before, after, changes = { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }, { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }, {}
        for _, record in ipairs(lower) do
            local activeTier = text(record.data.finalRarityTier)
            local proposed = record.v2Tier
            if before[activeTier] then before[activeTier] = before[activeTier] + 1 end
            if proposed and after[proposed] then after[proposed] = after[proposed] + 1 end
            if proposed then
                table.insert(changes, { record=record, delta=(TIER_ORDER[proposed] or 0) - (TIER_ORDER[activeTier] or 0) })
            end
        end
        simulation:write("Item Rarity Clothing V2 LOWER_BODY simulation (READ ONLY)\n")
        simulation:write("No active score, Clothing C1 combiner, Scarcity adjustment, threshold, tier, registry, scan, config or UI field is changed.\n\n")
        simulation:write("FORMULAS / FIXED ANCHORS\n")
        simulation:write("AbsoluteCoverage = 100 * sum(region weights) / 2.55, clamped 0..100. Fixed LOWER_BODY anatomy: GROIN=1.00, THIGH=0.80, SHIN=0.75. It uses no item population, percentile or 0.70 floor.\n")
        simulation:write("AbsoluteMobility = 100 * (0.70 * clamp(RunSpeedModifier,0,1) + 0.30 * clamp(CombatSpeedModifier,0,1)). Runtime modifier 1.00 is the no-penalty anchor; values above 1.00 cannot create a bonus in this conservative V2 candidate.\n")
        simulation:write("AbsoluteWeather = 100 * (0.40 * clamp(Insulation,0,1) + 0.35 * clamp(WindResistance,0,1) + 0.25 * clamp(WaterResistance,0,1)).\n")
        simulation:write("V2 score = active V1 Protection*.34 + AbsoluteCoverage*.12 + active V1 Durability*.12 + AbsoluteMobility*.15 + active V1 Weight*.10 + active V1 Discomfort*.10 + active V1 Senses*.02 + AbsoluteWeather*.05.\n")
        simulation:write("C1 stays unchanged: ProposedC1 = clamp(V2 score + current ScarcityAdjustment,0,100); cuts COMMON<40, UNCOMMON<53.64, RARE<61.28, EPIC<70, EXOTIC>=70.\n\n")
        simulation:write(string.format("DISTRIBUTION | active C/U/R/E/X = %d/%d/%d/%d/%d | proposed C/U/R/E/X = %d/%d/%d/%d/%d\n\n", before.COMMON,before.UNCOMMON,before.RARE,before.EPIC,before.EXOTIC,after.COMMON,after.UNCOMMON,after.RARE,after.EPIC,after.EXOTIC))
        simulation:write("ALL LOWER_BODY PROFILES\n")
        simulation:write("fullType | regions | Bite/Scratch/Bullet | Run/Combat | Insulation/Wind/Water | activeScore | V2Score | activeC1 | proposedC1 | activeTier | proposedTier | active P/Cov/Dur/Mob/Wt/Disc/Sense/Weather | V2 Cov/Mob/Weather\n")
        table.sort(lower, function(a,b) return a.data.fullType < b.data.fullType end)
        for _, record in ipairs(lower) do
            local m, active = record.metrics, directComponents(record.data)
            local a = record.absolute or {}
            simulation:write(table.concat({ text(record.data.fullType), #(record.regions or {}) > 0 and table.concat(record.regions,"+") or "N/A",
                fmt(m.biteDefense).."/"..fmt(m.scratchDefense).."/"..fmt(m.bulletDefense), fmt(m.runSpeedModifier).."/"..fmt(m.combatSpeedModifier),
                fmt(m.insulation).."/"..fmt(m.windResistance).."/"..fmt(m.waterResistance), fmt(record.data.utility), fmt(record.v2Score), fmt(record.data.clothingAdjustedScore), fmt(record.v2C1),
                text(record.data.finalRarityTier), text(record.v2Tier), table.concat({fmt(active.protection),fmt(active.coverage),fmt(active.durability),fmt(active.mobility),fmt(active.weight),fmt(active.discomfort),fmt(active.senses),fmt(active.weather)}, "/"),
                fmt(a.coverage).."/"..fmt(a.mobility).."/"..fmt(a.weather) }, " | ").."\n")
        end
        table.sort(changes, function(a,b) if a.delta == b.delta then return (a.record.v2Score or 0) > (b.record.v2Score or 0) end return a.delta > b.delta end)
        simulation:write("\nLARGEST RISES\nfullType | activeTier -> proposedTier | tierDelta | activeScore -> V2Score | activeC1 -> proposedC1\n")
        local emitted = 0
        for _, row in ipairs(changes) do if row.delta > 0 and emitted < 15 then local r=row.record; simulation:write(string.format("%s | %s -> %s | %+d | %s -> %s | %s -> %s\n",r.data.fullType,text(r.data.finalRarityTier),text(r.v2Tier),row.delta,fmt(r.data.utility),fmt(r.v2Score),fmt(r.data.clothingAdjustedScore),fmt(r.v2C1))); emitted=emitted+1 end end
        table.sort(changes, function(a,b) if a.delta == b.delta then return (a.record.v2Score or 0) < (b.record.v2Score or 0) end return a.delta < b.delta end)
        simulation:write("\nLARGEST FALLS\nfullType | activeTier -> proposedTier | tierDelta | activeScore -> V2Score | activeC1 -> proposedC1\n")
        emitted = 0
        for _, row in ipairs(changes) do if row.delta < 0 and emitted < 15 then local r=row.record; simulation:write(string.format("%s | %s -> %s | %+d | %s -> %s | %s -> %s\n",r.data.fullType,text(r.data.finalRarityTier),text(r.v2Tier),row.delta,fmt(r.data.utility),fmt(r.v2Score),fmt(r.data.clothingAdjustedScore),fmt(r.v2C1))); emitted=emitted+1 end end
        simulation:close()
    end
    ItemRarityUtils.info(string.format("Clothing absolute-components audit written: %d Clothing anatomy records; %d active DIRECT_SLOT; %d lower-body.", #records, directSlotCount, #lower))
    return true
end

-- Live-session companion to the dedicated classifier simulation. This code
-- lives here solely because B42 cannot index a newly added Lua source file in
-- an already-running game. It is invoked only by this explicit diagnostic.
local function writeClassifierFallbackSimulation(results)
    local function lowerText(value) return string.lower(tostring(value or "")) end
    local function call(object, name)
        if not object or type(object[name]) ~= "function" then return nil end
        local ok, value = pcall(function() return object[name](object) end)
        return ok and value or nil
    end
    local function meta(fullType)
        local manager = getScriptManager and getScriptManager() or nil
        local item = manager and type(manager.FindItem) == "function" and manager:FindItem(fullType) or nil
        if not item then return { found=false } end
        return { found=true, display=text(call(item, "getDisplayCategory")), itemType=text(call(item, "getItemType")),
            body=text(call(item, "getBodyLocation")), blood=text(call(item, "getBloodClothingType")) }
    end
    local function excluded(m)
        local display, slot = lowerText(m.display), lowerText(m.body)
        if display == "accessory" or display == "clothjew" or display == "clothacc" then return true, "accessory display subtype" end
        for _, token in ipairs({ "eye", "lefteye", "righteye", "ear", "wrist", "neck", "finger", "belly", "tail", "belt", "satchel", "backpack" }) do
            -- Body locations are colon-delimited (for example base:ears).
            -- Matching the segment avoids treating `base:underwear...` as an
            -- accessory merely because it contains the letters "ear".
            if string.find(slot, ":" .. token, 1, true) then return true, "accessory/container body location: " .. token end
        end
        return false, nil
    end
    local function family(m)
        local slot, blood = lowerText(m.body), lowerText(m.blood)
        if string.find(slot, "pants", 1, true) or string.find(blood, "trousers", 1, true) then return "pants/trousers" end
        if string.find(slot, "short", 1, true) or string.find(blood, "shorts", 1, true) then return "shorts" end
        if string.find(slot, "jacket", 1, true) or string.find(slot, "coat", 1, true) then return "jackets/coats" end
        if string.find(slot, "shirt", 1, true) or string.find(slot, "torso", 1, true) then return "shirts/torso" end
        if string.find(slot, "shoe", 1, true) or string.find(slot, "foot", 1, true) then return "footwear" end
        if string.find(slot, "underwear", 1, true) or string.find(blood, "underwear", 1, true) then return "underwear" end
        return "other clothing"
    end
    local clone, changed, exempt, impact = {}, {}, {}, {}
    for fullType, data in pairs(results or {}) do
        local m, current = meta(fullType), text(data.category)
        local blocked, reason = excluded(m)
        local proposed = current
        if (current == "UNKNOWN" or current == "MISC") and not blocked and lowerText(m.itemType) == "base:clothing" then
            proposed = "CLOTHING"
            table.insert(changed, { fullType=fullType, data=data, meta=m, family=family(m) })
        elseif lowerText(m.itemType) == "base:clothing" and blocked then
            table.insert(exempt, { fullType=fullType, data=data, meta=m, reason=reason })
        end
        local copy = {}; for key, value in pairs(data) do copy[key] = value end
        copy.category = proposed
        if m.display ~= "-" then copy.displayCategory = m.display end
        clone[fullType] = copy
        local key = current .. " -> " .. proposed
        impact[key] = (impact[key] or 0) + 1
    end
    if not ItemRarityUtilityCalculator or not ItemRarityUtilityCalculator.calculate then return false end
    ItemRarityUtilityCalculator.calculate(clone)
    local counts, tiers = { CLOTHING=0, DIRECT_SLOT=0, TRIVIAL=0, ACCESSORY=0, UNKNOWN=0 }, { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }
    for _, data in pairs(clone) do
        if data.category == "CLOTHING" then
            counts.CLOTHING = counts.CLOTHING + 1
            if data.utilityComponents and data.utilityComponents.directSlot ~= nil then counts.DIRECT_SLOT = counts.DIRECT_SLOT + 1 end
            if data.clothingMechanicalValueStatus == "MECHANICALLY_TRIVIAL" then counts.TRIVIAL = counts.TRIVIAL + 1 end
            if tiers[data.finalRarityTier] ~= nil then tiers[data.finalRarityTier] = tiers[data.finalRarityTier] + 1 end
        end
        if data.utilityKind == "ACCESSORY" then counts.ACCESSORY = counts.ACCESSORY + 1 end
        if data.category == "UNKNOWN" then counts.UNKNOWN = counts.UNKNOWN + 1 end
    end
    table.sort(changed, function(a,b) return a.fullType < b.fullType end); table.sort(exempt, function(a,b) return a.fullType < b.fullType end)
    local writer = getFileWriter("ItemRarity_ClothingClassifierFallbackSimulationV2.txt", true, false)
    if not writer then return false end
    writer:write("Item Rarity Clothing classifier fallback simulation V2 (READ ONLY)\n")
    writer:write("Clone only: no active classifier, registry, scan, tier, config or UI mutation. Candidate requires base:clothing after no specific category, excluding Accessory/ClothJew/ClothAcc and structural accessory/container locations.\n\n")
    writer:write("CATEGORY IMPACT\ncurrent -> proposed | fullTypes\n")
    local keys = {}; for key in pairs(impact) do table.insert(keys, key) end; table.sort(keys)
    for _, key in ipairs(keys) do writer:write(key .. " | " .. tostring(impact[key]) .. "\n") end
    writer:write(string.format("\nSIMULATED POPULATION | CLOTHING=%d | DIRECT_SLOT=%d | MECHANICALLY_TRIVIAL=%d | ACCESSORY=%d | UNKNOWN=%d\n", counts.CLOTHING, counts.DIRECT_SLOT, counts.TRIVIAL, counts.ACCESSORY, counts.UNKNOWN))
    writer:write(string.format("Simulated Clothing tiers | COMMON=%d | UNCOMMON=%d | RARE=%d | EPIC=%d | EXOTIC=%d\n\n", tiers.COMMON, tiers.UNCOMMON, tiers.RARE, tiers.EPIC, tiers.EXOTIC))
    writer:write("ALL PROPOSED -> CLOTHING\nfullType | currentCategory | structuralFamily | DisplayCategory | ItemType | BodyLocation | BloodClothingType\n")
    for _, entry in ipairs(changed) do local m=entry.meta; writer:write(table.concat({entry.fullType,text(entry.data.category),entry.family,text(m.display),text(m.itemType),text(m.body),text(m.blood)}," | ").."\n") end
    writer:write("\nACCESSORY / CONTAINER EXEMPTIONS\nfullType | currentCategory | DisplayCategory | ItemType | BodyLocation | reason\n")
    for _, entry in ipairs(exempt) do local m=entry.meta; writer:write(table.concat({entry.fullType,text(entry.data.category),text(m.display),text(m.itemType),text(m.body),text(entry.reason)}," | ").."\n") end
    writer:write("\nC1 TARGETS\nfullType | category | group | MechanicalState | ClothingScore | ScarcityStrength | C1Adjustment | AdjustedScore | simulatedFinalTier | activeFinalTier\n")
    for _, fullType in ipairs({"Base.Trousers_Denim","Base.Shorts_ShortDenim","Base.Jacket_NavyBlue","Base.Jacket_Leather","Base.JacketLong_Random","Base.Shoes_WorkBoots","Base.Cuirass_Metal","Base.Vambrace_FullMetal_Left","Base.Briefs_SmallTrunks_Black"}) do
        local data, active = clone[fullType], results[fullType]
        if data then writer:write(table.concat({fullType,text(data.category),text(data.utilityFunctionalGroup or data.utilitySubgroup),text(data.clothingMechanicalValueStatus),fmt(data.utility),fmt(data.clothingScarcityStrength),fmt(data.clothingScarcityAdjustment),fmt(data.clothingAdjustedScore),text(data.finalRarityTier),text(active and active.finalRarityTier)}," | ").."\n") end
    end
    writer:close()
    ItemRarityUtils.info(string.format("Clothing classifier fallback simulation V2 written: %d proposed CLOTHING; CLOTHING=%d DIRECT_SLOT=%d TRIVIAL=%d UNKNOWN=%d.", #changed, counts.CLOTHING, counts.DIRECT_SLOT, counts.TRIVIAL, counts.UNKNOWN))
    return true
end

-- Structural follow-up for the corrected ACCESSORY population and the small
-- wallet predicate.  This is intentionally observational: display names are
-- included only so a player can identify an item in Portuguese, never to
-- decide its family or a proposed tier.
local function writeAccessoryWalletAudit(results)
    if type(results) ~= "table" or not getFileWriter then return false end
    local manager = getScriptManager and getScriptManager() or nil
    local function lower(value) return string.lower(tostring(value or "")) end
    local function suffix(value)
        local normalized = lower(value)
        return string.match(normalized, ":([^:]+)$") or normalized
    end
    local function hasTag(tags, token)
        return string.find(lower(tags), token, 1, true) ~= nil
    end
    local function family(display, body, tags)
        local slot = suffix(body)
        if slot == "eye" or slot == "eyes" or slot == "lefteye" or slot == "righteye" then return "GLASSES_EYEWEAR" end
        if slot == "ear" or slot == "ears" or slot == "leftear" or slot == "rightear" then return "PIERCING" end
        -- Wrist location alone is ambiguous: bracelets use the same slot.
        -- The known vanilla watch scripts expose structural tags such as
        -- `digital` or `morewhennozombies`; those are enough to keep watches
        -- out of the trivial-cosmetic simulation without a name/fullType rule.
        if (slot == "leftwrist" or slot == "rightwrist" or slot == "wrist")
            and (hasTag(tags, "digital") or hasTag(tags, "alarm") or hasTag(tags, "timepiece") or hasTag(tags, "morewhennozombies")) then
            return "WATCH_SPECIAL_PARTIAL"
        end
        if slot == "leftwrist" or slot == "rightwrist" or slot == "wrist" then return "WRIST_JEWELRY" end
        if slot == "neck" or slot == "necklace" or slot == "finger" or slot == "leftfinger" or slot == "rightfinger" then return "JEWELRY_COLLAR" end
        if slot == "belt" or slot == "belly" then return "BELT" end
        if lower(display) == "clothjew" then return "JEWELRY_COLLAR" end
        return "OTHER_ACCESSORY"
    end
    local function number(item, script, getter)
        return callMethod(item, getter) or callMethod(script, getter)
    end
    local accessories, wallets, counts, policySummary = {}, {}, {}, {}
    for _, data in pairs(results) do
        local script = manager and manager:FindItem(data.fullType) or nil
        if script then
            local runtime = nil
            local ok, item = pcall(function() return script:InstanceItem(nil, false) end)
            if ok then runtime = item end
            local display = text(callMethod(script, "getDisplayCategory"))
            local body = text(callMethod(runtime, "getBodyLocation") or callMethod(script, "getBodyLocation"))
            local name = text(callMethod(runtime, "getDisplayName") or callMethod(script, "getDisplayName"))
            local tags = text(callMethod(script, "getTags"))
            if data.category == "ACCESSORY" then
                local group = family(display, body, tags)
                counts[group] = counts[group] or { total=0, trivial=0, known=0, partial=0 }
                local tally = counts[group]
                tally.total = tally.total + 1
                local state = data.accessoryMechanicalValueStatus or "UNCLASSIFIED"
                if state == "MECHANICALLY_TRIVIAL" then tally.trivial = tally.trivial + 1
                elseif state == "MECHANICAL_VALUE_KNOWN" then tally.known = tally.known + 1
                else tally.partial = tally.partial + 1 end
                local digital = number(runtime, script, "isDigitalWatch")
                local alarm = number(runtime, script, "isAlarmSet") or number(runtime, script, "getAlarmClock")
                local reason = group == "WATCH_SPECIAL_PARTIAL" and "structural watch/timepiece tag; SPECIAL_PARTIAL pending bridge support"
                    or (state == "MECHANICALLY_TRIVIAL" and "no structural special-function signal; cosmetic trivial -> COMMON" or "not mechanically trivial; unchanged")
                local proposed = state == "MECHANICALLY_TRIVIAL" and group ~= "WATCH_SPECIAL_PARTIAL" and "COMMON" or "UNCHANGED"
                local summaryKey = group .. " | " .. state .. " | " .. text(data.finalRarityTier) .. " -> " .. proposed .. " | " .. reason
                policySummary[summaryKey] = (policySummary[summaryKey] or 0) + 1
                table.insert(accessories, { data=data, name=name, display=display, body=body, tags=tags, group=group, state=state,
                    digital=digital, alarm=alarm, proposed=proposed, reason=reason })
            elseif data.category == "CONTAINER" then
                local accept = text(callMethod(runtime, "getAcceptItemFunction") or callMethod(script, "getAcceptItemFunction"))
                local capacity = number(runtime, script, "getCapacity")
                local reduction = number(runtime, script, "getWeightReduction")
                local isWallet = string.find(lower(accept), "wallet", 1, true) ~= nil
                local namedWallet = string.find(lower(name), "carteira", 1, true) ~= nil
                if isWallet or namedWallet then
                    table.insert(wallets, { data=data, name=name, accept=accept, capacity=capacity, reduction=reduction,
                        subgroup=text(data.utilitySubgroup), predicate=tostring(data.containerWalletTrivial == true) })
                end
            end
        end
    end
    table.sort(accessories, function(a,b) return a.data.fullType < b.data.fullType end)
    table.sort(wallets, function(a,b) return a.data.fullType < b.data.fullType end)
    local writer = getFileWriter("ItemRarity_AccessoryWalletAudit.txt", true, false)
    if not writer then return false end
    writer:write("Item Rarity ACCESSORY + Wallet audit (READ ONLY)\n")
    writer:write("No classifier, Utility, tier, registry, scan or UI field is changed. Families use only body location/display subtype; display name is report-only.\n\n")
    writer:write("ACCESSORY FAMILY SUMMARY\nfamily | total | trivial | known | partial/unclassified\n")
    local groups = {}; for group in pairs(counts) do table.insert(groups, group) end; table.sort(groups)
    for _, group in ipairs(groups) do local c=counts[group]; writer:write(string.format("%s | %d | %d | %d | %d\n", group,c.total,c.trivial,c.known,c.partial)) end
    writer:write("\nTRIVIAL POLICY SIMULATION SUMMARY\nfamily | MechanicalState | activeTier -> proposedTier | reason | count\n")
    local policyKeys = {}; for key in pairs(policySummary) do table.insert(policyKeys,key) end; table.sort(policyKeys)
    for _, key in ipairs(policyKeys) do writer:write(key .. " | " .. tostring(policySummary[key]) .. "\n") end
    writer:write("\nACCESSORIES\nfullType | displayName | family | body | MechanicalState | activeFinal | Scarcity | active policy | watch/digital signal | alarm signal | proposedTier | proposed reason | tags\n")
    for _, row in ipairs(accessories) do
        writer:write(table.concat({ row.data.fullType,row.name,row.group,row.body,row.state,text(row.data.finalRarityTier),text(row.data.baseScarcityTier),
            text(row.data.utilityAdjustmentReason),text(row.digital),text(row.alarm),row.proposed,row.reason,row.tags }, " | ") .. "\n")
    end
    writer:write("\nWALLET / DISPLAYNAME=Carteira CONTAINERS\nfullType | displayName | subgroup | capacity | weightReduction | AcceptItemFunction | wallet predicate | Scarcity | FinalTier\n")
    for _, row in ipairs(wallets) do
        writer:write(table.concat({row.data.fullType,row.name,row.subgroup,text(row.capacity),text(row.reduction),row.accept,row.predicate,
            text(row.data.baseScarcityTier),text(row.data.finalRarityTier)}, " | ") .. "\n")
    end
    writer:close()
    ItemRarityUtils.info(string.format("ACCESSORY + Wallet audit written: %d accessories, %d wallet/display-name candidates.", #accessories, #wallets))
    return true
end

-- V2 macro audit: the grouping below is purely anatomical/topological.  It
-- deliberately does not inspect display names or fullTypes.  The fixed
-- maxima make coverage comparable inside an actual body role, while the
-- mobility and weather transforms use the same physical units for every
-- role.  This is report-only; none of these values are written back to a
-- scanner result.
local MACRO_ANATOMY = {
    -- `base` and `span` intentionally differ by structural anatomy.  A
    -- complete short-shirt torso and a torso-plus-arms garment must not both
    -- collapse to the same coverage score merely because each is complete in
    -- its own local sample.
    LOWER_BODY = { maximum=2.55, base=10, span=55, weights={ GROIN=1.00, THIGH=.80, SHIN=.75 } },
    UPPER_BODY = { maximum=2.30, base=20, span=30, weights={ TORSO_UPPER=1.20, TORSO_LOWER=1.10 } },
    OUTERWEAR = { maximum=3.95, base=35, span=40, weights={ TORSO_UPPER=1.20, TORSO_LOWER=1.10, UPPER_ARM=.85, FOREARM=.80 } },
    HEAD = { maximum=2.55, base=20, span=45, weights={ HEAD=1.30, NECK=1.25 } },
    HANDS = { maximum=.70, base=50, span=0, weights={ HAND=.70 } },
    FEET = { maximum=1.40, base=29, span=46, weights={ FOOT=.65, SHIN=.75 } },
    LIMB_UPPER = { maximum=2.35, base=35, span=40, weights={ UPPER_ARM=.85, FOREARM=.80, HAND=.70 } },
    LIMB_LOWER = { maximum=1.55, base=35, span=40, weights={ THIGH=.80, SHIN=.75 } },
    TORSO_ACCESSORY = { maximum=2.30, base=35, span=40, weights={ TORSO_UPPER=1.20, TORSO_LOWER=1.10 } },
    FULL_BODY = { maximum=6.50, base=25, span=55, weights={ TORSO_UPPER=1.20, TORSO_LOWER=1.10, UPPER_ARM=.85, FOREARM=.80, GROIN=1.00, THIGH=.80, SHIN=.75 } },
}

-- These three candidates are intentionally separate from the broader
-- topology experiment above.  They are centered against the published V1
-- score scale: ordinary complete torso coverage ~= 50, ordinary foot
-- coverage ~= 50, and expanded anatomy earns a bounded increment rather
-- than a population-relative percentile.  They use no item names, profiles
-- or slot population statistics.
local PHASE_CALIBRATIONS = {
    -- A normal short-sleeve torso layer always covers both torso regions.
    -- Keeping its complete score at 50 prevents basic tees from gaining a
    -- tier merely because a relative ranking was replaced.
    UPPER_BODY = { base=42, span=8, weather="physical" },
    -- Outerwear has a real anatomical advantage when it extends across arm
    -- and forearm, but full coverage stays at 70 rather than 75.
    OUTERWEAR = { base=40, span=30, weather="material" },
    -- Footwear receives a bounded absolute premium for shin coverage: foot
    -- only ~= 52; foot + shin = 60.  The smaller spread preserves a material
    -- boot advantage without allowing coverage alone to create RARE footwear.
    FEET = { base=45, span=15, weather="physical" },
    -- HANDS profiles that reach this macro all cover the same anatomical
    -- region.  Coverage is intentionally fixed at the neutral 50 instead of
    -- manufacturing differences from a small local sample.
    HANDS = { base=50, span=0, weather="centered" },
    -- HEAD uses the actual B42 coverage anatomy. HEAD alone lands near 50;
    -- HEAD+NECK reaches 60, giving neck protection a bounded material
    -- advantage without allowing coverage by itself to create a high tier.
    -- FACE is deliberately absent: the public B42 coverage vocabulary used
    -- by this audit exposes HEAD and NECK, but no independently reliable
    -- FACE region.
    HEAD = { base=40, span=20, weather="head_w20" },
}

local function regionLookup(regions)
    local lookup = {}
    for _, region in ipairs(regions or {}) do lookup[region] = true end
    return lookup
end

local function macroGroupForDirectSlot(data)
    local regions = regionLookup((data.clothingDiscovery or {}).coveredRegions)
    local role = tostring(data.clothingDirectSlotFunction or data.utilityFunctionalGroup or "")
    if role == "LOWER_BODY_LAYER" then return "LOWER_BODY" end
    if role == "FOOTWEAR" or (regions.FOOT and not regions.TORSO_UPPER and not regions.TORSO_LOWER) then return "FEET" end
    if role == "HEADGEAR" or (regions.HEAD and not regions.TORSO_UPPER and not regions.TORSO_LOWER) then return "HEAD" end
    -- ARMOR_ACCESSORY is a topology role, not an anatomical one.  A
    -- shoulderpad, greave and vambrace can all be cuirass-compatible but
    -- cover different regions, so retain that distinction in this audit.
    if role == "ARMOR_ACCESSORY" then
        if regions.TORSO_UPPER or regions.TORSO_LOWER then return "TORSO_ACCESSORY" end
        if regions.THIGH or regions.SHIN then return "LIMB_LOWER" end
        if regions.UPPER_ARM or regions.FOREARM then return "LIMB_UPPER" end
        if regions.HAND then return "HANDS" end
        return "PROTECTIVE_ACCESSORY"
    end
    -- A sleeve can include HAND as well as forearm/upper arm.  It is a limb
    -- protection profile, not a glove profile; check the wider anatomy first.
    if regions.HAND and not regions.TORSO_UPPER and not regions.TORSO_LOWER and not regions.GROIN then
        if regions.UPPER_ARM or regions.FOREARM then return "LIMB_UPPER" end
        return "HANDS"
    end
    if role == "FULL_BODY_RESTRICTIVE" then return "FULL_BODY" end
    if role == "PRIMARY_ARMOR" then return "UPPER_BODY" end
    if regions.TORSO_UPPER or regions.TORSO_LOWER then
        return (regions.UPPER_ARM or regions.FOREARM) and "OUTERWEAR" or "UPPER_BODY"
    end
    return "OTHER_DIRECT"
end

local function macroCoverage(macro, regions)
    local anatomy = MACRO_ANATOMY[macro]
    if not anatomy then return nil, nil end
    local total = 0
    for _, region in ipairs(regions or {}) do total = total + (anatomy.weights[region] or 0) end
    local fraction = clamp(total / anatomy.maximum, 0, 1)
    return clamp(anatomy.base + anatomy.span * fraction, 0, 100), fraction
end

local function phaseCoverage(macro, regions)
    local anatomy, calibration = MACRO_ANATOMY[macro], PHASE_CALIBRATIONS[macro]
    if not anatomy or not calibration then return nil, nil end
    local total = 0
    for _, region in ipairs(regions or {}) do total = total + (anatomy.weights[region] or 0) end
    local fraction = clamp(total / anatomy.maximum, 0, 1)
    return clamp(calibration.base + calibration.span * fraction, 0, 100), fraction
end

local function macroCenteredMobility(metrics)
    local run = clamp(tonumber((metrics or {}).runSpeedModifier) or 1, 0, 1.25)
    local combat = clamp(tonumber((metrics or {}).combatSpeedModifier) or 1, 0, 1.25)
    local raw = run * .70 + combat * .30
    return clamp(50 + 200 * (raw - 1), 0, 100), raw
end

local function macroCenteredWeather(metrics)
    local m = metrics or {}
    local physical = clamp(tonumber(m.insulation) or 0, 0, 1) * .40
        + clamp(tonumber(m.windResistance) or 0, 0, 1) * .35
        + clamp(tonumber(m.waterResistance) or 0, 0, 1) * .25
    return clamp(40 + 50 * physical, 0, 100), physical
end

local function phaseWeather(macro, metrics)
    local _, physical = macroCenteredWeather(metrics)
    -- UPPER_BODY: weather now expresses only actual physical protection.
    -- This retains a high score for a genuinely insulated garment while a
    -- tee's small 0.098 physical value no longer behaves like a neutral 45.
    if macro == "UPPER_BODY" then return clamp(100 * physical, 0, 100), physical, "100*PhysicalWeather" end
    -- OUTERWEAR: a small wind/insulation value is not enough on its own to
    -- promote a jacket.  Material climate value begins at .50 physical and
    -- then grows linearly to 100 at 1.00.  This is an absolute threshold,
    -- not a sample percentile, and deliberately leaves Protection/Mobility
    -- as the principal drivers of normal jackets.
    if macro == "OUTERWEAR" then return clamp(200 * (physical - .50), 0, 100), physical, "clamp(200*(PhysicalWeather-.50),0,100)" end
    if macro == "HANDS" then return clamp(20 + 80 * physical, 0, 100), physical, "clamp(20+80*PhysicalWeather,0,100)" end
    if macro == "HEAD" then return clamp(20 + 80 * physical, 0, 100), physical, "clamp(20+80*PhysicalWeather,0,100)" end
    -- FEET uses the same physical scale as UPPER_BODY. A boot with real
    -- insulation/wind/water values remains differentiated, while a normal
    -- shoe with light climate values cannot inherit a high slot percentile.
    return clamp(100 * physical, 0, 100), physical, "100*PhysicalWeather"
end

local function phaseMobility(macro, metrics)
    local run = clamp(tonumber((metrics or {}).runSpeedModifier) or 1, 0, 1.25)
    local combat = clamp(tonumber((metrics or {}).combatSpeedModifier) or 1, 0, 1.25)
    local raw = run * .70 + combat * .30
    -- Footwear modifiers such as 1.30 are meaningful, but should not be
    -- allowed to outweigh protection and durability by themselves.  The
    -- fixed slope makes 1.00 = 50, .90 ~= 43 and 1.30 ~= 68.
    if macro == "FEET" then return clamp(50 + 100 * (raw - 1), 0, 100), raw, "clamp(50+100*(MobilityRaw-1),0,100)" end
    if macro == "HANDS" then return clamp(50 + 150 * (raw - 1), 0, 100), raw, "clamp(50+150*(MobilityRaw-1),0,100)" end
    if macro == "HEAD" then return clamp(50 + 150 * (raw - 1), 0, 100), raw, "clamp(50+150*(MobilityRaw-1),0,100)" end
    return clamp(50 + 200 * (raw - 1), 0, 100), raw, "clamp(50+200*(MobilityRaw-1),0,100)"
end

local function macroRoleWeights(role)
    if role == "HEADGEAR" then return { protection=.40, coverage=.06, durability=.08, mobility=.04, weight=.05, discomfort=.10, senses=.22, weather=.05 } end
    if role == "FOOTWEAR" then return { protection=.22, coverage=.06, durability=.14, mobility=.22, weight=.13, discomfort=.13, senses=0, weather=.10 } end
    if role == "PRIMARY_ARMOR" then return { protection=.46, coverage=.12, durability=.10, mobility=.10, weight=.07, discomfort=.11, senses=0, weather=.04 } end
    if role == "ARMOR_ACCESSORY" or role == "CORE_ACCESSORY" then return { protection=.44, coverage=.18, durability=.10, mobility=.07, weight=.08, discomfort=.10, senses=0, weather=.03 } end
    if role == "FULL_BODY_RESTRICTIVE" then return { protection=.33, coverage=.20, durability=.10, mobility=.13, weight=.07, discomfort=.09, senses=.04, weather=.04 } end
    if role == "LOWER_BODY_LAYER" then return { protection=.34, coverage=.12, durability=.12, mobility=.15, weight=.10, discomfort=.10, senses=.02, weather=.05 } end
    return { protection=.36, coverage=.12, durability=.10, mobility=.15, weight=.09, discomfort=.10, senses=.05, weather=.03 }
end

local function macroTier(score, macro)
    if macro == "LOWER_BODY" or macro == "HEAD" then
        if score < 40 then return "COMMON" end
        if score < 50 then return "UNCOMMON" end
        if score < 60 then return "RARE" end
        if score < 75 then return "EPIC" end
        return "EXOTIC"
    end
    return clothingC1Tier(score)
end

local function phaseRecord(records, macro, data, direct, regions, metrics)
    if not PHASE_CALIBRATIONS[macro] then return end
    local coverage, fraction = phaseCoverage(macro, regions)
    local mobility, mobilityRaw, mobilityFormula = phaseMobility(macro, metrics)
    local weather, weatherRaw, weatherFormula = phaseWeather(macro, metrics)
    local role = tostring(data.clothingDirectSlotFunction or data.utilityFunctionalGroup or "GENERAL_UNRESOLVED")
    local score, c1, tier = nil, nil, nil
    if coverage ~= nil and direct.protection ~= nil and direct.durability ~= nil and direct.weight ~= nil and direct.discomfort ~= nil and direct.senses ~= nil then
        local w = macroRoleWeights(role)
        score = direct.protection * w.protection + coverage * w.coverage + direct.durability * w.durability
            + mobility * w.mobility + direct.weight * w.weight + direct.discomfort * w.discomfort
            + direct.senses * w.senses + weather * w.weather
        c1 = clamp(score + (tonumber(data.clothingScarcityAdjustment) or 0), 0, 100)
        tier = macroTier(c1, macro)
    end
    table.insert(records, { data=data, macro=macro, role=role, regions=regions, metrics=metrics, direct=direct,
        coverage=coverage, coverageFraction=fraction, mobility=mobility, mobilityRaw=mobilityRaw,
        weather=weather, weatherRaw=weatherRaw, weatherFormula=weatherFormula, mobilityFormula=mobilityFormula, score=score, c1=c1, tier=tier })
end

local function writePhaseSimulation(writer, phaseRecords, macro)
    local calibration = PHASE_CALIBRATIONS[macro]
    local current, proposed = { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }, { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }
    local changed = {}
    for _, r in ipairs(phaseRecords) do
        if r.data.finalRarityTier and current[r.data.finalRarityTier] ~= nil then current[r.data.finalRarityTier] = current[r.data.finalRarityTier] + 1 end
        if r.tier and proposed[r.tier] ~= nil then proposed[r.tier] = proposed[r.tier] + 1 end
        if r.tier and r.tier ~= r.data.finalRarityTier then table.insert(changed, r) end
    end
    table.sort(changed, function(a,b)
        local deltaA = math.abs((tonumber(a.c1) or 0) - (tonumber(a.data.clothingAdjustedScore) or 0))
        local deltaB = math.abs((tonumber(b.c1) or 0) - (tonumber(b.data.clothingAdjustedScore) or 0))
        if deltaA == deltaB then return a.data.fullType < b.data.fullType end
        return deltaA > deltaB
    end)
    writer:write("\nPHASE "..macro.." — "..(macro == "FEET" and "CALIBRATED ABSOLUTE CANDIDATE" or "CALIBRATED ABSOLUTE WEATHER CANDIDATE").." (READ ONLY)\n")
    writer:write(string.format("Coverage = clamp(%g + %g * anatomicalFraction,0,100). Mobility = %s. Weather = %s; PhysicalWeather=.40*Insulation+.35*Wind+.25*Water.\n", calibration.base, calibration.span, phaseRecords[1] and phaseRecords[1].mobilityFormula or "N/A", phaseRecords[1] and phaseRecords[1].weatherFormula or "N/A"))
    writer:write(string.format("profiles=%d | active C/U/R/E/X=%d/%d/%d/%d/%d | proposed C/U/R/E/X=%d/%d/%d/%d/%d | changes=%d\n",
        #phaseRecords,current.COMMON,current.UNCOMMON,current.RARE,current.EPIC,current.EXOTIC,proposed.COMMON,proposed.UNCOMMON,proposed.RARE,proposed.EPIC,proposed.EXOTIC,#changed))
    writer:write("All fields besides Coverage/Mobility/Weather, including Protection, Durability, Weight, Discomfort, Senses, role weights, C1 and tier thresholds, remain the active values.\n")
    writer:write("fullType | role | regions | Bite/Scratch/Bullet | Run/Combat | Insulation/Wind/Water | activeScore | activeC1 | activeTier | absCoverage/fraction | absMobility/raw | absWeather/raw | proposedScore | proposedC1 | proposedTier | changed\n")
    for _, r in ipairs(phaseRecords) do
        local m=r.metrics
        writer:write(table.concat({ text(r.data.fullType),r.role,#r.regions>0 and table.concat(r.regions,"+") or "N/A",
            fmt(m.biteDefense).."/"..fmt(m.scratchDefense).."/"..fmt(m.bulletDefense),fmt(m.runSpeedModifier).."/"..fmt(m.combatSpeedModifier),fmt(m.insulation).."/"..fmt(m.windResistance).."/"..fmt(m.waterResistance),
            fmt(r.data.utility),fmt(r.data.clothingAdjustedScore),text(r.data.finalRarityTier),fmt(r.coverage).."/"..fmt(r.coverageFraction),fmt(r.mobility).."/"..fmt(r.mobilityRaw),fmt(r.weather).."/"..fmt(r.weatherRaw),fmt(r.score),fmt(r.c1),text(r.tier),tostring(r.tier ~= nil and r.tier ~= r.data.finalRarityTier) }, " | ") .. "\n")
    end
    writer:write("CHANGED PROFILES (sorted by absolute C1 displacement)\n")
    for _, r in ipairs(changed) do
        writer:write(string.format("%s | %s -> %s | activeC1=%s | proposedC1=%s | delta=%s\n", text(r.data.fullType),text(r.data.finalRarityTier),text(r.tier),fmt(r.data.clothingAdjustedScore),fmt(r.c1),fmt((tonumber(r.c1) or 0) - (tonumber(r.data.clothingAdjustedScore) or 0))))
    end
    if macro == "FEET" then
        writer:write("FEET CHANGE ATTRIBUTION (weighted component deltas; positive means this calibrated candidate raises the score)\n")
        for _, r in ipairs(changed) do
            local w = macroRoleWeights(r.role)
            local d=r.direct
            local coverageDelta=(r.coverage-(tonumber(d.coverage) or 50))*(w.coverage or 0)
            local mobilityDelta=(r.mobility-(tonumber(d.mobility) or 50))*(w.mobility or 0)
            local weatherDelta=(r.weather-(tonumber(d.weather) or 50))*(w.weather or 0)
            writer:write(string.format("%s | coverage=%s | mobility=%s | weather=%s | C1 delta=%s\n", text(r.data.fullType),fmt(coverageDelta),fmt(mobilityDelta),fmt(weatherDelta),fmt((tonumber(r.c1) or 0)-(tonumber(r.data.clothingAdjustedScore) or 0))))
        end
    end
end

-- FEET calibration grid. Coverage deliberately stays fixed at the approved
-- absolute candidate (45 + 15*fraction); only the two physical transforms
-- below vary.  This is diagnostic-only and contains no slot populations.
local FEET_CALIBRATION_GRID = {
    { key="M150_W10", mobilitySlope=150, weatherBase=10, weatherSpan=90 },
    { key="M150_W20", mobilitySlope=150, weatherBase=20, weatherSpan=80 },
    { key="M200_W10", mobilitySlope=200, weatherBase=10, weatherSpan=90 },
    { key="M200_W20", mobilitySlope=200, weatherBase=20, weatherSpan=80 },
}

local FEET_REFERENCE_TYPES = {
    ["Base.Shoes_ConverseSnickers"]=true, ["Base.Shoes_WorkBoots"]=true,
    ["Base.Shoes_HikingBoots"]=true, ["Base.Shoes_GothBoots"]=true,
    ["Base.Shoes_RidingBoots"]=true, ["Base.Shoes_CowboyBoots_Fancy"]=true,
    ["Base.Shoes_Random"]=true, ["Base.Shoes_BlueTrainers"]=true,
}

local function tierOrdinal(tier)
    return ({ COMMON=1, UNCOMMON=2, RARE=3, EPIC=4, EXOTIC=5 })[tier] or 0
end

local function writeFeetCalibrationGrid(writer, feetRecords)
    writer:write("\nFEET MOBILITY + WEATHER CALIBRATION GRID (READ ONLY)\n")
    writer:write("Coverage is frozen for every grid point: clamp(45 + 15*anatomicalFraction,0,100), yielding FOOT~=51.96 and FOOT+SHIN=60. Protection, Durability, Weight, Discomfort, Senses, role weights, C1 and thresholds are all active values.\n")
    for _, calibration in ipairs(FEET_CALIBRATION_GRID) do
        local current, proposed, changed, twoPlus, rows = { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }, { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }, 0, 0, {}
        for _, r in ipairs(feetRecords) do
            local mobility = clamp(50 + calibration.mobilitySlope * ((tonumber(r.mobilityRaw) or 1) - 1), 0, 100)
            local weather = clamp(calibration.weatherBase + calibration.weatherSpan * (tonumber(r.weatherRaw) or 0), 0, 100)
            local w = macroRoleWeights(r.role)
            local score = r.direct.protection * w.protection + r.coverage * w.coverage + r.direct.durability * w.durability
                + mobility * w.mobility + r.direct.weight * w.weight + r.direct.discomfort * w.discomfort
                + r.direct.senses * w.senses + weather * w.weather
            local c1 = clamp(score + (tonumber(r.data.clothingScarcityAdjustment) or 0), 0, 100)
            local tier = macroTier(c1, "FEET")
            if current[r.data.finalRarityTier] ~= nil then current[r.data.finalRarityTier] = current[r.data.finalRarityTier] + 1 end
            if proposed[tier] ~= nil then proposed[tier] = proposed[tier] + 1 end
            local isChanged = tier ~= r.data.finalRarityTier
            if isChanged then
                changed = changed + 1
                if math.abs(tierOrdinal(tier) - tierOrdinal(r.data.finalRarityTier)) >= 2 then twoPlus = twoPlus + 1 end
            end
            table.insert(rows, { source=r, mobility=mobility, weather=weather, score=score, c1=c1, tier=tier, changed=isChanged })
        end
        table.sort(rows, function(a,b) return a.source.data.fullType < b.source.data.fullType end)
        writer:write("\n"..calibration.key.."\n")
        writer:write(string.format("Mobility=clamp(50+%d*(MobilityRaw-1),0,100); Weather=clamp(%d+%d*PhysicalWeather,0,100). current C/U/R/E/X=%d/%d/%d/%d/%d | proposed C/U/R/E/X=%d/%d/%d/%d/%d | changes=%d | changes2plus=%d\n",
            calibration.mobilitySlope,calibration.weatherBase,calibration.weatherSpan,current.COMMON,current.UNCOMMON,current.RARE,current.EPIC,current.EXOTIC,proposed.COMMON,proposed.UNCOMMON,proposed.RARE,proposed.EPIC,proposed.EXOTIC,changed,twoPlus))
        writer:write("ALL CHANGES\nfullType | regions | Protection | active Cov/Mob/Weather | proposed Cov/Mob/Weather | activeScore/C1/tier | proposedScore/C1/tier | tierDelta\n")
        for _, row in ipairs(rows) do
            if row.changed then
                local r=row.source; local d=r.direct
                writer:write(table.concat({ text(r.data.fullType),#r.regions > 0 and table.concat(r.regions,"+") or "N/A",fmt(d.protection),fmt(d.coverage).."/"..fmt(d.mobility).."/"..fmt(d.weather),fmt(r.coverage).."/"..fmt(row.mobility).."/"..fmt(row.weather),fmt(r.data.utility).."/"..fmt(r.data.clothingAdjustedScore).."/"..text(r.data.finalRarityTier),fmt(row.score).."/"..fmt(row.c1).."/"..text(row.tier),tostring(tierOrdinal(row.tier)-tierOrdinal(r.data.finalRarityTier)) }, " | ") .. "\n")
            end
        end
        writer:write("REFERENCE PROFILES\nfullType | regions | Protection | active Cov/Mob/Weather | proposed Cov/Mob/Weather | activeScore/C1/tier | proposedScore/C1/tier\n")
        for _, row in ipairs(rows) do
            if FEET_REFERENCE_TYPES[row.source.data.fullType] then
                local r=row.source; local d=r.direct
                writer:write(table.concat({ text(r.data.fullType),#r.regions > 0 and table.concat(r.regions,"+") or "N/A",fmt(d.protection),fmt(d.coverage).."/"..fmt(d.mobility).."/"..fmt(d.weather),fmt(r.coverage).."/"..fmt(row.mobility).."/"..fmt(row.weather),fmt(r.data.utility).."/"..fmt(r.data.clothingAdjustedScore).."/"..text(r.data.finalRarityTier),fmt(row.score).."/"..fmt(row.c1).."/"..text(row.tier) }, " | ") .. "\n")
            end
        end
        if calibration.key == "M150_W20" then
            local manager = getScriptManager and getScriptManager() or nil
            writer:write("M150_W20 FINAL VALIDATION — ONLY THE 8 TIER CHANGES\n")
            writer:write("fullType | displayName | activeTier | proposedTier | activeC1 | proposedC1 | Bite/Scratch/Bullet | regions | Run/Combat | Insulation/Wind/Water | weight | principal mechanical reason | Scarcity contribution\n")
            for _, row in ipairs(rows) do
                if row.changed then
                    local r, d, m = row.source, row.source.direct, row.source.metrics
                    local w = macroRoleWeights(r.role)
                    local coverageDelta = (r.coverage - (tonumber(d.coverage) or 50)) * (w.coverage or 0)
                    local mobilityDelta = (row.mobility - (tonumber(d.mobility) or 50)) * (w.mobility or 0)
                    local weatherDelta = (row.weather - (tonumber(d.weather) or 50)) * (w.weather or 0)
                    local contributions = {
                        { label="Coverage", value=coverageDelta }, { label="Mobility", value=mobilityDelta }, { label="Weather", value=weatherDelta },
                    }
                    table.sort(contributions, function(a,b) return math.abs(a.value) > math.abs(b.value) end)
                    local lead, secondary = contributions[1], contributions[2]
                    local reason = string.format("%s %+.3f; %s %+.3f", lead.label, lead.value, secondary.label, secondary.value)
                    local script = manager and manager:FindItem(r.data.fullType) or nil
                    local name = text(callMethod(script, "getDisplayName"))
                    -- C1's scarcity adjustment is deliberately unchanged on
                    -- both sides.  It can place a score near a threshold, but
                    -- it cannot be the cause of a score delta in this table.
                    local scarcity = string.format("unchanged C1 adjustment=%s; score delta is mechanical", fmt(r.data.clothingScarcityAdjustment))
                    writer:write(table.concat({ text(r.data.fullType),name,text(r.data.finalRarityTier),text(row.tier),fmt(r.data.clothingAdjustedScore),fmt(row.c1),
                        fmt(m.biteDefense).."/"..fmt(m.scratchDefense).."/"..fmt(m.bulletDefense),#r.regions > 0 and table.concat(r.regions,"+") or "N/A",fmt(m.runSpeedModifier).."/"..fmt(m.combatSpeedModifier),fmt(m.insulation).."/"..fmt(m.windResistance).."/"..fmt(m.waterResistance),fmt(m.weight),reason,scarcity }, " | ") .. "\n")
                end
            end
        end
    end
end

-- HEAD is audited with a compact absolute grid.  The coverage curve is held
-- constant in every row; only the two transforms which were previously
-- percentile-based are varied.  This keeps the decision about weather and
-- small mobility penalties independent of hats/caps/helmets population size.
local HEAD_CALIBRATION_GRID = {
    { key="M150_W20", mobilitySlope=150, weatherBase=20, weatherSpan=80 },
    { key="M150_W100", mobilitySlope=150, weatherBase=0, weatherSpan=100 },
    { key="M200_W20", mobilitySlope=200, weatherBase=20, weatherSpan=80 },
    { key="M200_W100", mobilitySlope=200, weatherBase=0, weatherSpan=100 },
}

local function writeHeadCalibrationGrid(writer, headRecords)
    writer:write("\nHEAD RAW ATTRIBUTE DISTRIBUTION (READ ONLY)\n")
    writer:write("Coverage vocabulary confirmed by runtime: HEAD and NECK. No independent FACE region is exposed by the loaded B42 coverage data, so masks are not credited as FACE coverage in this diagnostic.\n")
    local run, combat, raw, insulation, wind, water, physical = {}, {}, {}, {}, {}, {}, {}
    local anatomy = {}
    for _, r in ipairs(headRecords) do
        local m = r.metrics or {}
        table.insert(run, tonumber(m.runSpeedModifier) or 1)
        table.insert(combat, tonumber(m.combatSpeedModifier) or 1)
        table.insert(raw, tonumber(r.mobilityRaw) or 1)
        table.insert(insulation, tonumber(m.insulation) or 0)
        table.insert(wind, tonumber(m.windResistance) or 0)
        table.insert(water, tonumber(m.waterResistance) or 0)
        table.insert(physical, tonumber(r.weatherRaw) or 0)
        local key = #r.regions > 0 and table.concat(r.regions, "+") or "NONE"
        anatomy[key] = (anatomy[key] or 0) + 1
    end
    summary(writer, "RunSpeedModifier", run); summary(writer, "CombatSpeedModifier", combat)
    summary(writer, "MobilityRaw", raw); summary(writer, "Insulation", insulation)
    summary(writer, "WindResistance", wind); summary(writer, "WaterResistance", water)
    summary(writer, "PhysicalWeather", physical)
    writer:write("coverage anatomy | profiles\n")
    local keys = {}; for key in pairs(anatomy) do table.insert(keys, key) end; table.sort(keys)
    for _, key in ipairs(keys) do writer:write(key.." | "..tostring(anatomy[key]).."\n") end

    writer:write("\nHEAD MOBILITY + WEATHER CALIBRATION GRID (READ ONLY)\n")
    writer:write("Coverage stays fixed: clamp(40 + 20*anatomicalFraction,0,100): HEAD≈50.20, HEAD+NECK=60. Protection, Durability, Weight, Discomfort, Senses, role weights, C1 and thresholds remain active.\n")
    for _, calibration in ipairs(HEAD_CALIBRATION_GRID) do
        local current, proposed = { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }, { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }
        local changed, twoPlus, rows = 0, 0, {}
        for _, r in ipairs(headRecords) do
            local mobility = clamp(50 + calibration.mobilitySlope * ((tonumber(r.mobilityRaw) or 1) - 1), 0, 100)
            local weather = clamp(calibration.weatherBase + calibration.weatherSpan * (tonumber(r.weatherRaw) or 0), 0, 100)
            local w = macroRoleWeights(r.role)
            local score = r.direct.protection * w.protection + r.coverage * w.coverage + r.direct.durability * w.durability
                + mobility * w.mobility + r.direct.weight * w.weight + r.direct.discomfort * w.discomfort
                + r.direct.senses * w.senses + weather * w.weather
            local c1 = clamp(score + (tonumber(r.data.clothingScarcityAdjustment) or 0), 0, 100)
            local tier = macroTier(c1, "HEAD")
            if current[r.data.finalRarityTier] ~= nil then current[r.data.finalRarityTier] = current[r.data.finalRarityTier] + 1 end
            if proposed[tier] ~= nil then proposed[tier] = proposed[tier] + 1 end
            local isChanged = tier ~= r.data.finalRarityTier
            if isChanged then
                changed = changed + 1
                if math.abs(tierOrdinal(tier) - tierOrdinal(r.data.finalRarityTier)) >= 2 then twoPlus = twoPlus + 1 end
            end
            table.insert(rows, { source=r, mobility=mobility, weather=weather, score=score, c1=c1, tier=tier, changed=isChanged })
        end
        table.sort(rows, function(a,b) return a.source.data.fullType < b.source.data.fullType end)
        writer:write("\n"..calibration.key.."\n")
        writer:write(string.format("Mobility=clamp(50+%d*(MobilityRaw-1),0,100); Weather=clamp(%d+%d*PhysicalWeather,0,100). current C/U/R/E/X=%d/%d/%d/%d/%d | proposed C/U/R/E/X=%d/%d/%d/%d/%d | changes=%d | changes2plus=%d\n",
            calibration.mobilitySlope,calibration.weatherBase,calibration.weatherSpan,current.COMMON,current.UNCOMMON,current.RARE,current.EPIC,current.EXOTIC,proposed.COMMON,proposed.UNCOMMON,proposed.RARE,proposed.EPIC,proposed.EXOTIC,changed,twoPlus))
        writer:write("ALL CHANGES\nfullType | regions | Protection | active Cov/Mob/Weather | proposed Cov/Mob/Weather | activeScore/C1/tier | proposedScore/C1/tier | tierDelta\n")
        for _, row in ipairs(rows) do
            if row.changed then
                local r, d = row.source, row.source.direct
                writer:write(table.concat({ text(r.data.fullType),#r.regions > 0 and table.concat(r.regions,"+") or "N/A",fmt(d.protection),fmt(d.coverage).."/"..fmt(d.mobility).."/"..fmt(d.weather),fmt(r.coverage).."/"..fmt(row.mobility).."/"..fmt(row.weather),fmt(r.data.utility).."/"..fmt(r.data.clothingAdjustedScore).."/"..text(r.data.finalRarityTier),fmt(row.score).."/"..fmt(row.c1).."/"..text(row.tier),tostring(tierOrdinal(row.tier)-tierOrdinal(r.data.finalRarityTier)) }, " | ") .. "\n")
            end
        end
    end
end

-- Explicitly requested validation targets. This list is used only to focus a
-- human-readable report after the structural HEAD candidate has already been
-- computed for every profile; it is never consulted by scoring or runtime.
local HEAD_M150_W20_TARGETS = {
    ["Base.Hat_BucketHatFishing"]=true,
    ["Base.Hat_CrashHelmet"]=true,
    ["Base.Hat_FootballHelmet"]=true,
    ["Base.Hat_MetalScrapHelmet"]=true,
    ["Base.Hat_Pirate"]=true,
    ["Base.Hat_Raccoon"]=true,
    ["Base.Hat_Ranger"]=true,
    ["Base.Hat_SWAT"]=true,
}

local function writeHeadM150W20TargetAudit(writer, headRecords)
    local manager = getScriptManager and getScriptManager() or nil
    writer:write("\nHEAD M150 + W20 — TARGETED VALIDATION (READ ONLY)\n")
    writer:write("All target rows use Coverage=40+20*fraction, Mobility=clamp(50+150*(MobilityRaw-1),0,100), Weather=clamp(20+80*PhysicalWeather,0,100). No target name participates in the formula.\n")
    writer:write("fullType | displayName | activeTier -> proposedTier | Bite/Scratch/Bullet | regions | ConditionMax/durability | Run/Combat | Insulation/Wind/Water | weight | discomfort | vision/hearing | Protection | Coverage active->absolute | Mobility active->absolute | Weather active->W20 | DurabilityComponent | WeightComponent | DiscomfortComponent | SensesComponent | activeScore->V2Score | ScarcityStrength | C1Adjustment | activeC1->V2C1\n")
    local comparative = {}
    for _, r in ipairs(headRecords) do
        local m, d, data = r.metrics or {}, r.direct or {}, r.data
        local script = manager and manager:FindItem(data.fullType) or nil
        if HEAD_M150_W20_TARGETS[data.fullType] then
            local name = text(callMethod(script, "getDisplayName"))
            writer:write(table.concat({ text(data.fullType),name,text(data.finalRarityTier).." -> "..text(r.tier),
                fmt(m.biteDefense).."/"..fmt(m.scratchDefense).."/"..fmt(m.bulletDefense),#r.regions>0 and table.concat(r.regions,"+") or "N/A",
                fmt(m.conditionMax).."/"..fmt(d.durability),fmt(m.runSpeedModifier).."/"..fmt(m.combatSpeedModifier),fmt(m.insulation).."/"..fmt(m.windResistance).."/"..fmt(m.waterResistance),
                fmt(m.weight),fmt(m.discomfortModifier),fmt(m.visionModifier).."/"..fmt(m.hearingModifier),fmt(d.protection),
                fmt(d.coverage).." -> "..fmt(r.coverage),fmt(d.mobility).." -> "..fmt(r.mobility),fmt(d.weather).." -> "..fmt(r.weather),
                fmt(d.durability),fmt(d.weight),fmt(d.discomfort),fmt(d.senses),fmt(data.utility).." -> "..fmt(r.score),fmt(data.clothingScarcityStrength),fmt(data.clothingScarcityAdjustment),fmt(data.clothingAdjustedScore).." -> "..fmt(r.c1) }, " | ") .. "\n")
        end
        -- A structural comparator group for the Crash Helmet audit: no names
        -- decide membership, only the same macro plus substantial protection.
        if (tonumber(d.protection) or 0) >= 45 then table.insert(comparative, r) end
    end
    table.sort(comparative, function(a,b)
        if a.direct.protection == b.direct.protection then return a.data.fullType < b.data.fullType end
        return a.direct.protection > b.direct.protection
    end)
    writer:write("\nHEAD PROTECTIVE COMPARATORS (direct Protection >= 45, structural filter)\n")
    writer:write("fullType | regions | Protection | Bite/Scratch/Bullet | ConditionMax/durability | weight/discomfort | senses | active Cov/Mob/Weather | M150W20 Cov/Mob/Weather | activeC1/tier | V2C1/tier\n")
    for _, r in ipairs(comparative) do
        local m, d, data = r.metrics or {}, r.direct or {}, r.data
        writer:write(table.concat({text(data.fullType),#r.regions>0 and table.concat(r.regions,"+") or "N/A",fmt(d.protection),fmt(m.biteDefense).."/"..fmt(m.scratchDefense).."/"..fmt(m.bulletDefense),fmt(m.conditionMax).."/"..fmt(d.durability),fmt(m.weight).."/"..fmt(m.discomfortModifier),fmt(d.senses),fmt(d.coverage).."/"..fmt(d.mobility).."/"..fmt(d.weather),fmt(r.coverage).."/"..fmt(r.mobility).."/"..fmt(r.weather),fmt(data.clothingAdjustedScore).."/"..text(data.finalRarityTier),fmt(r.c1).."/"..text(r.tier)}, " | ").."\n")
    end
end

-- HEAD senses candidate: 1.00/1.00 is intentionally the historical neutral
-- midpoint (50). A 5% loss costs five component points and a 25% loss costs
-- twenty-five. The transform is fixed in physical modifier units, never in
-- head-slot percentile units.
local function absoluteHeadSenses(metrics)
    local m = metrics or {}
    local vision = clamp(tonumber(m.visionModifier) or 1, 0, 1.25)
    local hearing = clamp(tonumber(m.hearingModifier) or 1, 0, 1.25)
    local raw = vision * .50 + hearing * .50
    return clamp(50 + 100 * (raw - 1), 0, 100), raw
end

local function writeHeadRemainingRelativeAudit(writer, headRecords)
    writer:write("\nHEAD REMAINING RELATIVE COMPONENTS AUDIT (READ ONLY)\n")
    writer:write("Active Senses, Weight and Discomfort are currently within-slot percentile components. HEADGEAR role weights: Senses=22%, Weight=5%, Discomfort=10%. This section changes nothing.\n")
    local vision, hearing, senses, weightRaw, weightComponent, discomfortRaw, discomfortComponent = {}, {}, {}, {}, {}, {}, {}
    local senseMapping = {}
    for _, r in ipairs(headRecords) do
        local m, d = r.metrics or {}, r.direct or {}
        table.insert(vision, tonumber(m.visionModifier) or 1); table.insert(hearing, tonumber(m.hearingModifier) or 1)
        table.insert(senses, tonumber(d.senses) or 50); table.insert(weightRaw, tonumber(m.weight) or 0)
        table.insert(weightComponent, tonumber(d.weight) or 50); table.insert(discomfortRaw, tonumber(m.discomfortModifier) or 0)
        table.insert(discomfortComponent, tonumber(d.discomfort) or 50)
        local key = fmt(m.visionModifier).."/"..fmt(m.hearingModifier)
        local bucket = senseMapping[key] or { count=0, components={}, absolute=nil, raw=nil }
        bucket.count = bucket.count + 1; table.insert(bucket.components, tonumber(d.senses) or 50)
        bucket.absolute, bucket.raw = absoluteHeadSenses(m); senseMapping[key] = bucket
    end
    summary(writer, "VisionModifier", vision); summary(writer, "HearingModifier", hearing)
    summary(writer, "Active Senses component", senses); summary(writer, "Weight raw", weightRaw)
    summary(writer, "Active Weight component", weightComponent); summary(writer, "Discomfort raw", discomfortRaw)
    summary(writer, "Active Discomfort component", discomfortComponent)
    writer:write("vision/hearing | profiles | active Senses min..max | absolute Senses | sensesRaw\n")
    local mappings = {}; for key in pairs(senseMapping) do table.insert(mappings, key) end; table.sort(mappings)
    for _, key in ipairs(mappings) do
        local bucket=senseMapping[key]; local ordered=sortedCopy(bucket.components)
        writer:write(table.concat({key,tostring(bucket.count),fmt(ordered[1])..".."..fmt(ordered[#ordered]),fmt(bucket.absolute),fmt(bucket.raw)}, " | ").."\n")
    end

    local current, proposed = { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }, { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }
    local changes = {}
    for _, r in ipairs(headRecords) do
        local d, data = r.direct, r.data
        local absolute, raw = absoluteHeadSenses(r.metrics)
        local w = macroRoleWeights(r.role)
        -- SENSES ONLY: C/M/W remain active. This isolates the remaining
        -- relative component without selecting or modifying the M150/W20
        -- candidate in the preceding audit.
        local score = d.protection * w.protection + d.coverage * w.coverage + d.durability * w.durability
            + d.mobility * w.mobility + d.weight * w.weight + d.discomfort * w.discomfort
            + absolute * w.senses + d.weather * w.weather
        local c1 = clamp(score + c1Adjustment(data), 0, 100)
        local tier = macroTier(c1, "HEAD")
        if current[data.finalRarityTier] ~= nil then current[data.finalRarityTier] = current[data.finalRarityTier] + 1 end
        if proposed[tier] ~= nil then proposed[tier] = proposed[tier] + 1 end
        local row={ source=r, absolute=absolute, raw=raw, score=score, c1=c1, tier=tier }
        if tier ~= data.finalRarityTier then table.insert(changes,row) end
    end
    table.sort(changes,function(a,b)
        local deltaA=math.abs((a.c1 or 0)-(a.source.data.clothingAdjustedScore or 0)); local deltaB=math.abs((b.c1 or 0)-(b.source.data.clothingAdjustedScore or 0))
        if deltaA == deltaB then return a.source.data.fullType < b.source.data.fullType end
        return deltaA > deltaB
    end)
    writer:write("\nHEAD SENSES-ONLY ABSOLUTE SIMULATION (READ ONLY)\n")
    writer:write("AbsoluteSenses=clamp(50+100*(.50*VisionModifier+.50*HearingModifier-1),0,100). Coverage/Mobility/Weather stay active for this isolation; Protection, Durability, Weight, Discomfort, C1 and thresholds also stay active.\n")
    writer:write(string.format("current C/U/R/E/X=%d/%d/%d/%d/%d | senses-only C/U/R/E/X=%d/%d/%d/%d/%d | changes=%d\n",current.COMMON,current.UNCOMMON,current.RARE,current.EPIC,current.EXOTIC,proposed.COMMON,proposed.UNCOMMON,proposed.RARE,proposed.EPIC,proposed.EXOTIC,#changes))
    writer:write("ALL SENSES-ONLY CHANGES\nfullType | Vision/Hearing | activeSenses->absolute | activeScore/C1/tier | sensesOnlyScore/C1/tier | tierDelta\n")
    for _, row in ipairs(changes) do
        local r, d, m = row.source, row.source.direct, row.source.metrics
        writer:write(table.concat({text(r.data.fullType),fmt(m.visionModifier).."/"..fmt(m.hearingModifier),fmt(d.senses).." -> "..fmt(row.absolute),fmt(r.data.utility).."/"..fmt(r.data.clothingAdjustedScore).."/"..text(r.data.finalRarityTier),fmt(row.score).."/"..fmt(row.c1).."/"..text(row.tier),tostring(tierOrdinal(row.tier)-tierOrdinal(r.data.finalRarityTier))}, " | ").."\n")
    end

    local weak, weakAboveCommon = {}, 0
    for _, r in ipairs(headRecords) do
        local m, data = r.metrics or {}, r.data
        local headOnly = #r.regions == 1 and r.regions[1] == "HEAD"
        local noDefense = (tonumber(m.biteDefense) or 0) == 0 and (tonumber(m.scratchDefense) or 0) == 0 and (tonumber(m.bulletDefense) or 0) == 0
        local neutralSenses = (tonumber(m.visionModifier) or 1) == 1 and (tonumber(m.hearingModifier) or 1) == 1
        local lowWeather = (tonumber(r.weatherRaw) or 0) <= .20
        local noSpecial = data.clothingMechanicalSpecialReason == nil or data.clothingMechanicalSpecialReason == ""
        if headOnly and noDefense and neutralSenses and lowWeather and noSpecial then
            table.insert(weak,r)
            if data.finalRarityTier ~= "COMMON" then weakAboveCommon = weakAboveCommon + 1 end
        end
    end
    table.sort(weak,function(a,b) return a.data.fullType < b.data.fullType end)
    writer:write("\nHEADWEAR_MECHANICALLY_WEAK STRUCTURAL AUDIT (READ ONLY)\n")
    writer:write("Predicate: raw Bite=Scratch=Bullet=0; exactly HEAD; Vision=Hearing=1; PhysicalWeather<=.20; no published special-behavior reason. This is a proposed generic predicate, not an active policy.\n")
    writer:write(string.format("eligible=%d | currently above COMMON=%d\n",#weak,weakAboveCommon))
    writer:write("fullType | activeTier | ScarcityStrength | PhysicalWeather | activeScore | activeC1 | MechanicalState | specialReason\n")
    for _, r in ipairs(weak) do
        local data=r.data
        writer:write(table.concat({text(data.fullType),text(data.finalRarityTier),fmt(data.clothingScarcityStrength),fmt(r.weatherRaw),fmt(data.utility),fmt(data.clothingAdjustedScore),text(data.clothingMechanicalValueStatus),text(data.clothingMechanicalSpecialReason)}, " | ").."\n")
    end
end

local HEAD_V2_SANITY_TYPES = {
    ["Base.Hat_CrashHelmet"]=true, ["Base.Hat_FootballHelmet"]=true,
    ["Base.Hat_MetalScrapHelmet"]=true, ["Base.Hat_MetalHelmet"]=true,
    ["Base.Hat_SPHhelmet"]=true, ["Base.Hat_HardHat_Miner_With_Light"]=true,
    ["Base.Hat_BoxingBlue"]=true, ["Base.Hat_BoxingRed"]=true,
    ["Base.Hat_Pirate"]=true, ["Base.Hat_Ranger"]=true,
    ["Base.Hat_Raccoon"]=true, ["Base.Hat_BucketHatFishing"]=true,
}

local function isHeadwearMechanicallyWeak(r)
    local m, data = r.metrics or {}, r.data or {}
    local headOnly = #r.regions == 1 and r.regions[1] == "HEAD"
    local noDefense = (tonumber(m.biteDefense) or 0) == 0 and (tonumber(m.scratchDefense) or 0) == 0 and (tonumber(m.bulletDefense) or 0) == 0
    local neutralSenses = (tonumber(m.visionModifier) or 1) == 1 and (tonumber(m.hearingModifier) or 1) == 1
    local lowWeather = (tonumber(r.weatherRaw) or 0) <= .20
    local noSpecial = data.clothingMechanicalSpecialReason == nil or data.clothingMechanicalSpecialReason == ""
    return headOnly and noDefense and neutralSenses and lowWeather and noSpecial
end

-- Complete candidate requested for HEAD only. Its inputs are the already
-- audited fixed transforms: anatomy coverage, M150 mobility, W20 weather and
-- centered Senses. Non-target components remain exactly the active values.
local function writeHeadV2CompleteSimulation(writer, headRecords)
    local current, proposed = { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }, { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }
    local rows, changed, weakTotal, weakAboveCommon = {}, {}, 0, 0
    for _, r in ipairs(headRecords) do
        local d, data = r.direct, r.data
        local senses, sensesRaw = absoluteHeadSenses(r.metrics)
        local w = macroRoleWeights(r.role)
        local score = d.protection * w.protection + r.coverage * w.coverage + d.durability * w.durability
            + r.mobility * w.mobility + d.weight * w.weight + d.discomfort * w.discomfort
            + senses * w.senses + r.weather * w.weather
        local c1 = clamp(score + c1Adjustment(data), 0, 100)
        local tier = macroTier(c1, "HEAD")
        local row = { source=r, senses=senses, sensesRaw=sensesRaw, score=score, c1=c1, tier=tier }
        table.insert(rows,row)
        if current[data.finalRarityTier] ~= nil then current[data.finalRarityTier] = current[data.finalRarityTier] + 1 end
        if proposed[tier] ~= nil then proposed[tier] = proposed[tier] + 1 end
        if tier ~= data.finalRarityTier then table.insert(changed,row) end
        if isHeadwearMechanicallyWeak(r) then
            weakTotal = weakTotal + 1
            if tier ~= "COMMON" then weakAboveCommon = weakAboveCommon + 1 end
        end
    end
    table.sort(rows,function(a,b) return a.source.data.fullType < b.source.data.fullType end)
    table.sort(changed,function(a,b)
        local distanceA=math.abs(tierOrdinal(a.tier)-tierOrdinal(a.source.data.finalRarityTier))
        local distanceB=math.abs(tierOrdinal(b.tier)-tierOrdinal(b.source.data.finalRarityTier))
        if distanceA == distanceB then return a.source.data.fullType < b.source.data.fullType end
        return distanceA > distanceB
    end)
    local twoPlus=0; for _, row in ipairs(changed) do if math.abs(tierOrdinal(row.tier)-tierOrdinal(row.source.data.finalRarityTier)) >= 2 then twoPlus=twoPlus+1 end end
    writer:write("\nHEAD V2 COMPLETE SIMULATION — M150 + W20 + ABSOLUTE SENSES (READ ONLY)\n")
    writer:write("Coverage=clamp(40+20*HEAD/NECK fraction,0,100); Mobility=clamp(50+150*(MobilityRaw-1),0,100); Weather=clamp(20+80*PhysicalWeather,0,100); Senses=clamp(50+100*(.50*Vision+.50*Hearing-1),0,100). Protection, Durability, Weight, Discomfort, role weights, C1 and thresholds are active values.\n")
    writer:write(string.format("current C/U/R/E/X=%d/%d/%d/%d/%d | HEAD V2 C/U/R/E/X=%d/%d/%d/%d/%d | changes=%d | changes2plus=%d\n",current.COMMON,current.UNCOMMON,current.RARE,current.EPIC,current.EXOTIC,proposed.COMMON,proposed.UNCOMMON,proposed.RARE,proposed.EPIC,proposed.EXOTIC,#changed,twoPlus))
    writer:write("ALL HEAD V2 CHANGES\nfullType | regions | Protection | Coverage | Mobility | Weather | Senses | Weight | Discomfort | activeScore/C1/tier | V2Score/C1/tier | tierDelta\n")
    for _, row in ipairs(changed) do
        local r, d, data = row.source, row.source.direct, row.source.data
        writer:write(table.concat({text(data.fullType),#r.regions>0 and table.concat(r.regions,"+") or "N/A",fmt(d.protection),fmt(r.coverage),fmt(r.mobility),fmt(r.weather),fmt(row.senses),fmt(d.weight),fmt(d.discomfort),fmt(data.utility).."/"..fmt(data.clothingAdjustedScore).."/"..text(data.finalRarityTier),fmt(row.score).."/"..fmt(row.c1).."/"..text(row.tier),tostring(tierOrdinal(row.tier)-tierOrdinal(data.finalRarityTier))}, " | ").."\n")
    end
    writer:write("HEAD V2 SANITY CHECKS\nfullType | Protection | Coverage | Mobility | Weather | Senses | Weight | Discomfort | activeScore/C1/tier | V2Score/C1/tier\n")
    for _, row in ipairs(rows) do
        if HEAD_V2_SANITY_TYPES[row.source.data.fullType] then
            local r, d, data = row.source, row.source.direct, row.source.data
            writer:write(table.concat({text(data.fullType),fmt(d.protection),fmt(r.coverage),fmt(r.mobility),fmt(r.weather),fmt(row.senses),fmt(d.weight),fmt(d.discomfort),fmt(data.utility).."/"..fmt(data.clothingAdjustedScore).."/"..text(data.finalRarityTier),fmt(row.score).."/"..fmt(row.c1).."/"..text(row.tier)}, " | ").."\n")
        end
    end
    writer:write(string.format("HEADWEAR_MECHANICALLY_WEAK under complete V2: eligible=%d | still above COMMON=%d. No policy is applied.\n",weakTotal,weakAboveCommon))
end

-- This is intentionally a second HEAD-only view of the *same* complete V2
-- candidate.  It changes neither its components nor C1: it only answers
-- whether the generic Clothing cuts compress a mechanically strong head item.
local function headSpecificTier(score)
    if score < 40 then return "COMMON" end
    if score < 50 then return "UNCOMMON" end
    if score < 60 then return "RARE" end
    if score < 75 then return "EPIC" end
    return "EXOTIC"
end

local function headLightRouteProbe(data)
    local script = findScriptItem(data.fullType)
    local strength = callMethod(script, "getLightStrength")
    local distance = callMethod(script, "getLightDistance")
    local useDelta = callMethod(script, "getUseDelta")
    local drainable = callMethod(script, "isDrainable")
    -- candidateFor resolves LightFire before Clothing.  Therefore a published
    -- CLOTHING candidate proves there was no eligible LightFire candidate for
    -- this item in the active scan; raw script getters below are diagnostic
    -- metadata, not a second classification path.
    local route = data.utilityKind == "CLOTHING"
        and "CLOTHING selected; no eligible preceding LightFire candidate"
        or ("published utilityKind=" .. text(data.utilityKind))
    return route, strength, distance, useDelta, drainable
end

local function writeHeadV2ThresholdAudit(writer, headRecords)
    local rows, generic, specific = {}, { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }, { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }
    local cuts = { [40]=0, [50]=0, [60]=0, [75]=0 }
    for _, r in ipairs(headRecords) do
        local d, data = r.direct, r.data
        local senses = absoluteHeadSenses(r.metrics)
        local w = macroRoleWeights(r.role)
        local score = d.protection*w.protection + r.coverage*w.coverage + d.durability*w.durability
            + r.mobility*w.mobility + d.weight*w.weight + d.discomfort*w.discomfort
            + senses*w.senses + r.weather*w.weather
        local c1 = clamp(score + c1Adjustment(data), 0, 100)
        local genericTier, specificTier = macroTier(c1, "HEAD"), headSpecificTier(c1)
        generic[genericTier] = generic[genericTier] + 1
        specific[specificTier] = specific[specificTier] + 1
        for cut in pairs(cuts) do if c1 >= cut then cuts[cut] = cuts[cut] + 1 end end
        table.insert(rows, { source=r, senses=senses, score=score, c1=c1, genericTier=genericTier, specificTier=specificTier })
    end
    table.sort(rows, function(a,b)
        if a.c1 == b.c1 then return a.source.data.fullType < b.source.data.fullType end
        return a.c1 > b.c1
    end)
    writer:write("\nHEAD V2 THRESHOLD AUDIT — SAME COMPONENTS, READ ONLY\n")
    writer:write("Candidate is unchanged: absolute HEAD/NECK Coverage, M150 Mobility, W20 Weather and absolute Senses; active Protection/Durability/Weight/Discomfort/C1 remain. Generic cuts: <40 C, <53.64 U, <61.28 R, <70 E, >=70 X. HEAD-specific simulation: <40 C, <50 U, <60 R, <75 E, >=75 X.\n")
    writer:write(string.format("GENERIC C/U/R/E/X=%d/%d/%d/%d/%d | HEAD-SPECIFIC C/U/R/E/X=%d/%d/%d/%d/%d | C1 >=40/%d >=50/%d >=60/%d >=75/%d\n",
        generic.COMMON,generic.UNCOMMON,generic.RARE,generic.EPIC,generic.EXOTIC,specific.COMMON,specific.UNCOMMON,specific.RARE,specific.EPIC,specific.EXOTIC,cuts[40],cuts[50],cuts[60],cuts[75]))
    writer:write("TOP 20 BY HEAD V2 C1\nfullType | displayName | Bite/Scratch/Bullet | regions | Vision/Hearing | weight | discomfort | Protection | Coverage | Mobility | Weather | Senses | baseScore | C1 | activeTier | V2GenericTier | V2HeadSpecificTier\n")
    for index, row in ipairs(rows) do
        if index > 20 then break end
        local r, data, m = row.source, row.source.data, row.source.metrics
        local script = findScriptItem(data.fullType)
        writer:write(table.concat({ text(data.fullType),text(callMethod(script,"getDisplayName")),fmt(m.biteDefense).."/"..fmt(m.scratchDefense).."/"..fmt(m.bulletDefense),#r.regions>0 and table.concat(r.regions,"+") or "N/A",fmt(m.visionModifier).."/"..fmt(m.hearingModifier),fmt(m.weight),fmt(m.discomfortModifier),fmt(r.direct.protection),fmt(r.coverage),fmt(r.mobility),fmt(r.weather),fmt(row.senses),fmt(row.score),fmt(row.c1),text(data.finalRarityTier),text(row.genericTier),text(row.specificTier) }, " | ").."\n")
    end
    writer:write("SELECTED HEAD PROTECTION / LIGHT CHECKS\nfullType | displayName | raw Bite/Scratch/Bullet | regions | Vision/Hearing | Protection/Coverage/Mobility/Weather/Senses | baseScore/C1 | activeTier | generic/specific V2 | LightFire route evidence | script lightStrength/lightDistance/useDelta/drainable\n")
    local selected = {
        ["Base.Hat_CrashHelmet"]=true, ["Base.Hat_FootballHelmet"]=true,
        ["Base.Hat_MetalScrapHelmet"]=true, ["Base.Hat_MetalHelmet"]=true,
        ["Base.Hat_SPHhelmet"]=true, ["Base.Hat_HardHat_Miner_With_Light"]=true,
    }
    for _, row in ipairs(rows) do
        if selected[row.source.data.fullType] then
            local r, data, m = row.source, row.source.data, row.source.metrics
            local route, strength, distance, useDelta, drainable = headLightRouteProbe(data)
            local script = findScriptItem(data.fullType)
            writer:write(table.concat({ text(data.fullType),text(callMethod(script,"getDisplayName")),fmt(m.biteDefense).."/"..fmt(m.scratchDefense).."/"..fmt(m.bulletDefense),#r.regions>0 and table.concat(r.regions,"+") or "N/A",fmt(m.visionModifier).."/"..fmt(m.hearingModifier),fmt(r.direct.protection).."/"..fmt(r.coverage).."/"..fmt(r.mobility).."/"..fmt(r.weather).."/"..fmt(row.senses),fmt(row.score).."/"..fmt(row.c1),text(data.finalRarityTier),text(row.genericTier).."/"..text(row.specificTier),route,fmt(strength).."/"..fmt(distance).."/"..fmt(useDelta).."/"..tostring(drainable) }, " | ").."\n")
        end
    end
end

local function writeMacroV2Audit(results)
    if type(results) ~= "table" or not getFileWriter then return false end
    local records, summaries, phaseRecords = {}, {}, { UPPER_BODY={}, OUTERWEAR={}, FEET={}, HANDS={}, HEAD={} }
    for _, data in pairs(results) do
        local direct = directComponents(data)
        if hasActiveDirectSlot(data) and data.clothingMechanicalValueStatus ~= "MECHANICALLY_TRIVIAL" then
            local macro = macroGroupForDirectSlot(data)
            local regions, metrics = (data.clothingDiscovery or {}).coveredRegions or {}, data.utilityMetrics or {}
            local coverage, fraction = macroCoverage(macro, regions)
            local mobility, mobilityRaw = macroCenteredMobility(metrics)
            local weather, weatherRaw = macroCenteredWeather(metrics)
            local role = tostring(data.clothingDirectSlotFunction or data.utilityFunctionalGroup or "GENERAL_UNRESOLVED")
            local proposedScore, proposedC1, proposedTier = nil, nil, nil
            if coverage ~= nil and direct.protection ~= nil and direct.durability ~= nil and direct.weight ~= nil and direct.discomfort ~= nil and direct.senses ~= nil then
                local w = macroRoleWeights(role)
                proposedScore = direct.protection * w.protection + coverage * w.coverage + direct.durability * w.durability
                    + mobility * w.mobility + direct.weight * w.weight + direct.discomfort * w.discomfort
                    + direct.senses * w.senses + weather * w.weather
                proposedC1 = clamp(proposedScore + (tonumber(data.clothingScarcityAdjustment) or 0), 0, 100)
                proposedTier = macroTier(proposedC1, macro)
            end
            local record = { data=data, macro=macro, role=role, regions=regions, metrics=metrics, direct=direct,
                coverage=coverage, coverageFraction=fraction, mobility=mobility, mobilityRaw=mobilityRaw,
                weather=weather, weatherRaw=weatherRaw, proposedScore=proposedScore, proposedC1=proposedC1, proposedTier=proposedTier }
            table.insert(records, record)
            phaseRecord(phaseRecords[macro] or {}, macro, data, direct, regions, metrics)
            summaries[macro] = summaries[macro] or { total=0, current={ COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }, proposed={ COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }, changed=0 }
            local summary = summaries[macro]; summary.total = summary.total + 1
            if summary.current[data.finalRarityTier] ~= nil then summary.current[data.finalRarityTier] = summary.current[data.finalRarityTier] + 1 end
            if proposedTier and summary.proposed[proposedTier] ~= nil then summary.proposed[proposedTier] = summary.proposed[proposedTier] + 1 end
            if proposedTier and proposedTier ~= data.finalRarityTier then summary.changed = summary.changed + 1 end
        end
    end
    table.sort(records, function(a,b) return a.data.fullType < b.data.fullType end)
    local writer = getFileWriter("ItemRarity_ClothingV2MacroSimulation.txt", true, false)
    if not writer then return false end
    writer:write("Item Rarity Clothing V2 macro-component simulation (READ ONLY)\n")
    writer:write("No active score, C1 adjustment, Scarcity, tier, registry, scan, config or UI state is changed. It is a future-V2 diagnostic only.\n\n")
    writer:write("PROPOSED STRUCTURAL MACROGROUPS\n")
    writer:write("LOWER_BODY: GROIN=1.00 THIGH=.80 SHIN=.75, max=2.55, coverage=10+55*fraction. UPPER_BODY: TORSO_UPPER=1.20 TORSO_LOWER=1.10, max=2.30, coverage=20+30*fraction. OUTERWEAR: torso plus UPPER_ARM=.85 FOREARM=.80, max=3.95, coverage=35+40*fraction. HEAD: HEAD=1.30 NECK=1.25, max=2.55, coverage=20+45*fraction. HANDS: HAND=.70, coverage=50. FEET: FOOT=.65 SHIN=.75, max=1.40, coverage=29+46*fraction. ARMOR_ACCESSORY is split anatomically: LIMB_UPPER arm/forearm/hand max=2.35, LIMB_LOWER thigh/shin max=1.55, TORSO_ACCESSORY torso max=2.30; each uses coverage=35+40*fraction. FULL_BODY: torso+arms+lower body, max=6.50, coverage=25+55*fraction. OTHER_DIRECT is reported but deliberately not simulated until its anatomy is unambiguous.\n")
    writer:write("AbsoluteCoverage = clamp(macro base + macro span * anatomical fraction,0,100). The deliberately non-identical macro anchors preserve material anatomical differences (for example torso-only versus torso-plus-arms); they are not slot-population percentiles. AbsoluteMobility = clamp(50 + 200*(.70*Run + .30*Combat - 1),0,100). AbsoluteWeather = clamp(40 + 50*(.40*Insulation + .35*Wind + .25*Water),0,100).\n")
    writer:write("Future V2 replacement in this report only: active Protection/Durability/Weight/Discomfort/Senses plus absolute Coverage/Mobility/Weather; frozen role weights and current C1 adjustment retained. Protection remains explicitly marked HYBRID (40% slot-relative + 60% global absolute) and is not changed here.\n\n")
    writer:write("COMPONENT DEPENDENCY\nProtection=HYBRID | Coverage=active slot-relative, simulated absolute | Mobility=active slot-relative, simulated absolute | Weather=active slot-relative, simulated absolute | Durability=slot-relative | Weight=slot-relative inverse | Discomfort=slot-relative inverse | Senses=slot-relative\n\n")
    writer:write("MACRO DISTRIBUTION\nmacro | profiles | current C/U/R/E/X | simulated C/U/R/E/X | changed\n")
    local macros = {}; for macro in pairs(summaries) do table.insert(macros, macro) end; table.sort(macros)
    for _, macro in ipairs(macros) do
        local s=summaries[macro]; local c,p=s.current,s.proposed
        writer:write(string.format("%s | %d | %d/%d/%d/%d/%d | %d/%d/%d/%d/%d | %d\n",macro,s.total,c.COMMON,c.UNCOMMON,c.RARE,c.EPIC,c.EXOTIC,p.COMMON,p.UNCOMMON,p.RARE,p.EPIC,p.EXOTIC,s.changed))
    end
    -- The three requested phases use their own centered anchors and are
    -- printed before the broad topology control table below.
    for _, macro in ipairs({ "UPPER_BODY", "OUTERWEAR", "FEET", "HANDS", "HEAD" }) do
        table.sort(phaseRecords[macro], function(a,b) return a.data.fullType < b.data.fullType end)
        writePhaseSimulation(writer, phaseRecords[macro], macro)
    end
    writeFeetCalibrationGrid(writer, phaseRecords.FEET)
    writeHeadCalibrationGrid(writer, phaseRecords.HEAD)
    writeHeadM150W20TargetAudit(writer, phaseRecords.HEAD)
    writeHeadRemainingRelativeAudit(writer, phaseRecords.HEAD)
    writeHeadV2CompleteSimulation(writer, phaseRecords.HEAD)
    writeHeadV2ThresholdAudit(writer, phaseRecords.HEAD)
    writer:write("\nALL DIRECT_SLOT PROFILES\n")
    writer:write("fullType | macro | role | regions | Bite/Scratch/Bullet | Run/Combat | Insulation/Wind/Water | activeScore | activeC1 | activeTier | active P/Cov/Dur/Mob/Wt/Disc/Sense/Weather | absCoverage/fraction | absMobility/raw | absWeather/raw | V2Score | V2C1 | V2Tier | changed\n")
    for _, r in ipairs(records) do
        local m,d=r.metrics,r.direct
        writer:write(table.concat({ text(r.data.fullType),r.macro,r.role,#r.regions>0 and table.concat(r.regions,"+") or "N/A",
            fmt(m.biteDefense).."/"..fmt(m.scratchDefense).."/"..fmt(m.bulletDefense),fmt(m.runSpeedModifier).."/"..fmt(m.combatSpeedModifier),fmt(m.insulation).."/"..fmt(m.windResistance).."/"..fmt(m.waterResistance),
            fmt(r.data.utility),fmt(r.data.clothingAdjustedScore),text(r.data.finalRarityTier),table.concat({fmt(d.protection),fmt(d.coverage),fmt(d.durability),fmt(d.mobility),fmt(d.weight),fmt(d.discomfort),fmt(d.senses),fmt(d.weather)},"/"),
            fmt(r.coverage).."/"..fmt(r.coverageFraction),fmt(r.mobility).."/"..fmt(r.mobilityRaw),fmt(r.weather).."/"..fmt(r.weatherRaw),fmt(r.proposedScore),fmt(r.proposedC1),text(r.proposedTier),tostring(r.proposedTier ~= nil and r.proposedTier ~= r.data.finalRarityTier) }, " | ") .. "\n")
    end
    writer:close()
    ItemRarityUtils.info(string.format("Clothing V2 macro simulation written: %d active nontrivial DIRECT_SLOT profiles across %d macro groups.", #records, #macros))
    return true
end

-- Closing audit for the DIRECT_SLOT macro groups that have not yet received a
-- calibrated V2 rollout.  This is deliberately a compact, read-only report:
-- it uses no names/fullTypes as rules and does not feed any candidate value
-- back into the registry.  The control transform is intentionally labelled
-- as such; it exists to expose population-relative distortions before a
-- macro can be approved, not to silently propose a production formula.
local CLOSURE_MACROS = {
    "LIMB_UPPER", "LIMB_LOWER", "FULL_BODY", "TORSO_ACCESSORY",
    "OTHER_DIRECT", "PROTECTIVE_ACCESSORY",
}

local CLOSURE_RAW_FIELDS = {
    "biteDefense", "scratchDefense", "bulletDefense", "runSpeedModifier",
    "combatSpeedModifier", "insulation", "windResistance", "waterResistance",
    "visionModifier", "hearingModifier", "durability", "weight", "discomfortModifier",
}

local function closureTierIndex(tier)
    local values = { COMMON=1, UNCOMMON=2, RARE=3, EPIC=4, EXOTIC=5 }
    return values[tier] or 0
end

local function closureTierDistribution()
    return { COMMON=0, UNCOMMON=0, RARE=0, EPIC=0, EXOTIC=0 }
end

local function closureRangeAppend(ranges, field, value)
    value = tonumber(value)
    if value == nil then return end
    local range = ranges[field] or { min=value, max=value }
    range.min = math.min(range.min, value)
    range.max = math.max(range.max, value)
    ranges[field] = range
end

local function closureRawSignature(regions, metrics)
    local values = {}
    for _, field in ipairs(CLOSURE_RAW_FIELDS) do
        values[field] = fmt((metrics or {})[field])
    end
    values.regions = #(regions or {}) > 0 and table.concat(regions, "+") or "N/A"
    return values
end

local function closureDifferentFields(first, current)
    local different = {}
    for field, value in pairs(first or {}) do
        if current[field] ~= value then table.insert(different, field) end
    end
    table.sort(different)
    return different
end

local function closureHasFields(values)
    for _ in pairs(values or {}) do return true end
    return false
end

local function closureConfidence(profileCount)
    if profileCount >= 20 then return "HIGH" end
    if profileCount >= 8 then return "MEDIUM" end
    return "LOW"
end

local function closureComponentStatus(macro)
    -- These describe the active path before any future V2 rollout.  Frozen
    -- macro groups have their own report sections and are intentionally not
    -- included in this closure audit.
    local status = "Protection=HYBRID(60% absolute/40% relative); Coverage=RELATIVE; Durability=RELATIVE; Mobility=RELATIVE; Weight=RELATIVE; Discomfort=RELATIVE; Senses=RELATIVE; Weather=RELATIVE"
    if macro == "OTHER_DIRECT" or macro == "PROTECTIVE_ACCESSORY" then
        return status .. "; anatomy unresolved/insufficient for an absolute control"
    end
    return status
end

local function closureAbsoluteSenses(metrics)
    local vision = clamp(tonumber((metrics or {}).visionModifier) or 1, 0, 1)
    local hearing = clamp(tonumber((metrics or {}).hearingModifier) or 1, 0, 1)
    local raw = vision * .50 + hearing * .50
    return clamp(50 + 100 * (raw - 1), 0, 100), raw
end

local function closureControlComponents(macro, regions, metrics)
    if macro == "OTHER_DIRECT" or macro == "PROTECTIVE_ACCESSORY" then return nil end
    local coverage, fraction = macroCoverage(macro, regions)
    if coverage == nil then return nil end
    local run = clamp(tonumber((metrics or {}).runSpeedModifier) or 1, 0, 1.25)
    local combat = clamp(tonumber((metrics or {}).combatSpeedModifier) or 1, 0, 1.25)
    local mobilityRaw = run * .70 + combat * .30
    -- M150 is a fixed diagnostic reference: 1.00 is neutral 50 and small
    -- penalties remain small.  It is not a production decision for any of
    -- these remaining macro groups.
    local mobility = clamp(50 + 150 * (mobilityRaw - 1), 0, 100)
    local _, physical = macroCenteredWeather(metrics)
    -- W20 is likewise a conservative fixed control.  Its purpose is to make
    -- a weather-only promotion visible in the report, not to approve it.
    local weather = clamp(20 + 80 * physical, 0, 100)
    local senses, sensesRaw = nil, nil
    -- FULL_BODY has real script-level sensory variance (for example sealed
    -- equipment).  Its closure control uses the already-approved HEAD
    -- intrinsic transform instead of a local rank; other remaining macros
    -- are neutral and retain the active Senses component.
    if macro == "FULL_BODY" then senses, sensesRaw = closureAbsoluteSenses(metrics) end
    return coverage, mobility, weather, fraction, mobilityRaw, physical, senses, sensesRaw
end

local function writeRemainingMacroClosureAudit(results)
    if type(results) ~= "table" or not getFileWriter then return false end
    local groups = {}
    for _, macro in ipairs(CLOSURE_MACROS) do
        groups[macro] = {
            records={}, profiles={}, collisions={}, ranges={}, current=closureTierDistribution(),
            control=closureTierDistribution(), vanilla=0, modded=0, changed=0, changed2plus=0,
            maxC1=nil,
        }
    end
    for _, data in pairs(results) do
        local direct = directComponents(data)
        if hasActiveDirectSlot(data) and data.clothingMechanicalValueStatus ~= "MECHANICALLY_TRIVIAL" then
            local macro = macroGroupForDirectSlot(data)
            local group = groups[macro]
            if group then
                local regions = (data.clothingDiscovery or {}).coveredRegions or {}
                local metrics = data.utilityMetrics or {}
                local raw = closureRawSignature(regions, metrics)
                local profile = tostring(data.utilityProfile or "NO_PROFILE:" .. tostring(data.fullType))
                local profileEntry = group.profiles[profile]
                if not profileEntry then
                    profileEntry = { first=raw, count=0, differing={} }
                    group.profiles[profile] = profileEntry
                else
                    for _, field in ipairs(closureDifferentFields(profileEntry.first, raw)) do profileEntry.differing[field] = true end
                end
                profileEntry.count = profileEntry.count + 1
                for _, field in ipairs(CLOSURE_RAW_FIELDS) do closureRangeAppend(group.ranges, field, metrics[field]) end
                if tostring(data.fullType or ""):match("^Base%.") then group.vanilla = group.vanilla + 1 else group.modded = group.modded + 1 end
                if group.current[data.finalRarityTier] ~= nil then group.current[data.finalRarityTier] = group.current[data.finalRarityTier] + 1 end
                local c1 = tonumber(data.clothingAdjustedScore)
                if c1 and (not group.maxC1 or c1 > group.maxC1) then group.maxC1 = c1 end
                local coverage, mobility, weather, fraction, mobilityRaw, physical, senses, sensesRaw = closureControlComponents(macro, regions, metrics)
                local role = tostring(data.clothingDirectSlotFunction or data.utilityFunctionalGroup or "GENERAL_UNRESOLVED")
                local controlScore, controlC1, controlTier = nil, nil, nil
                if coverage ~= nil and direct.protection ~= nil and direct.durability ~= nil and direct.weight ~= nil and direct.discomfort ~= nil and direct.senses ~= nil then
                    local w = macroRoleWeights(role)
                    controlScore = direct.protection*w.protection + coverage*w.coverage + direct.durability*w.durability
                        + mobility*w.mobility + direct.weight*w.weight + direct.discomfort*w.discomfort
                        + (senses or direct.senses)*w.senses + weather*w.weather
                    controlC1 = clamp(controlScore + (tonumber(data.clothingScarcityAdjustment) or 0), 0, 100)
                    controlTier = clothingC1Tier(controlC1)
                    group.control[controlTier] = group.control[controlTier] + 1
                    if controlTier ~= data.finalRarityTier then
                        group.changed = group.changed + 1
                        if math.abs(closureTierIndex(controlTier) - closureTierIndex(data.finalRarityTier)) >= 2 then group.changed2plus = group.changed2plus + 1 end
                    end
                end
                table.insert(group.records, { data=data, direct=direct, regions=regions, metrics=metrics, raw=raw, profile=profile,
                    role=role, controlCoverage=coverage, controlMobility=mobility, controlWeather=weather, coverageFraction=fraction,
                    mobilityRaw=mobilityRaw, physicalWeather=physical, controlSenses=senses, controlSensesRaw=sensesRaw,
                    controlScore=controlScore, controlC1=controlC1, controlTier=controlTier })
            end
        end
    end
    local writer = getFileWriter("ItemRarity_ClothingV2ClosureAudit.txt", true, false)
    if not writer then return false end
    writer:write("Item Rarity Clothing V2 closure audit — remaining DIRECT_SLOT macros (READ ONLY)\n")
    writer:write("No Utility, tier, registry, scan, configuration or UI state is modified. Control values are M150 + W20 only to reveal scale risk; they are NOT an integration proposal.\n\n")
    writer:write("OVERALL DECISION TABLE\n")
    writer:write("macro | items/profiles | vanilla/modded | active C/U/R/E/X | control C/U/R/E/X | changes/2+ | max active C1 | raw-profile collisions | confidence | decision | primary finding\n")
    for _, macro in ipairs(CLOSURE_MACROS) do
        local group = groups[macro]
        local profiles, collisionCount = 0, 0
        for _, entry in pairs(group.profiles) do
            profiles = profiles + 1
            if closureHasFields(entry.differing) then collisionCount = collisionCount + 1 end
        end
        local decision, finding
        if macro == "OTHER_DIRECT" or macro == "PROTECTIVE_ACCESSORY" then
            decision, finding = "KEEP_CURRENT", "anatomy/function is not sufficiently resolved for a safe absolute transform"
        elseif collisionCount > 0 then
            decision, finding = "NEEDS_CALIBRATION", "deduplicated profile shares differing raw component inputs"
        elseif group.changed2plus > 0 then
            decision, finding = "NEEDS_CALIBRATION", "control transform produces 2+ tier movements; anchors require review"
        elseif group.changed > math.max(2, math.floor(#group.records * .20)) then
            decision, finding = "NEEDS_CALIBRATION", "control transform moves a material fraction of the macro population"
        else
            decision, finding = "KEEP_CURRENT", "no demonstrated relative-scale regression from the conservative control"
        end
        group.decision = decision
        local c, p = group.current, group.control
        writer:write(string.format("%s | %d/%d | %d/%d | %d/%d/%d/%d/%d | %d/%d/%d/%d/%d | %d/%d | %s | %d | %s | %s\n",
            macro,#group.records,profiles,group.vanilla,group.modded,c.COMMON,c.UNCOMMON,c.RARE,c.EPIC,c.EXOTIC,
            p.COMMON,p.UNCOMMON,p.RARE,p.EPIC,p.EXOTIC,group.changed,group.changed2plus,fmt(group.maxC1),collisionCount,
            closureConfidence(profiles),decision,finding))
    end
    for _, macro in ipairs(CLOSURE_MACROS) do
        local group = groups[macro]
        writer:write("\nMACRO "..macro.."\n")
        writer:write("active component status: "..closureComponentStatus(macro).."\n")
        writer:write("control: Coverage=macro anatomical extent; Mobility=M150; Weather=W20; all remaining components copied from active")
        if macro == "FULL_BODY" then writer:write(" except Senses=absolute 50+100*(.5*Vision+.5*Hearing-1)") end
        writer:write(".\n")
        writer:write("raw ranges: ")
        local rangeText = {}
        for _, field in ipairs(CLOSURE_RAW_FIELDS) do
            local range = group.ranges[field]
            if range then table.insert(rangeText, field.."="..fmt(range.min)..".."..fmt(range.max)) end
        end
        writer:write(table.concat(rangeText, "; ").."\n")
        local collisions = {}
        for profile, entry in pairs(group.profiles) do
            if closureHasFields(entry.differing) then table.insert(collisions, { profile=profile, entry=entry }) end
        end
        table.sort(collisions, function(a,b) return a.profile < b.profile end)
        writer:write("dedup collisions="..tostring(#collisions).." (same active utilityProfile with different raw inputs).\n")
        for i=1,math.min(5,#collisions) do
            local row=collisions[i]; local fields={}; for field in pairs(row.entry.differing) do table.insert(fields,field) end; table.sort(fields)
            writer:write("  profile="..text(row.profile).." | members="..tostring(row.entry.count).." | differing="..table.concat(fields,",").."\n")
        end
        local ordered={}; for _, record in ipairs(group.records) do table.insert(ordered,record) end
        table.sort(ordered, function(a,b) return (tonumber(a.data.clothingAdjustedScore) or -1) > (tonumber(b.data.clothingAdjustedScore) or -1) end)
        writer:write("top 5 active C1: fullType | role | regions | P/Cov/Dur/Mob/Wt/Disc/Sense/Weather | activeScore/C1/tier | controlScore/C1/tier\n")
        for i=1,math.min(5,#ordered) do
            local row=ordered[i]; local d=row.direct
            writer:write(table.concat({text(row.data.fullType),row.role,#row.regions>0 and table.concat(row.regions,"+") or "N/A",
                table.concat({fmt(d.protection),fmt(d.coverage),fmt(d.durability),fmt(d.mobility),fmt(d.weight),fmt(d.discomfort),fmt(d.senses),fmt(d.weather)},"/"),
                fmt(row.data.utility).."/"..fmt(row.data.clothingAdjustedScore).."/"..text(row.data.finalRarityTier),
                fmt(row.controlScore).."/"..fmt(row.controlC1).."/"..text(row.controlTier)}," | ").."\n")
        end
        local rises, falls = {}, {}
        for _, row in ipairs(group.records) do
            local delta = closureTierIndex(row.controlTier) - closureTierIndex(row.data.finalRarityTier)
            if delta > 0 then table.insert(rises,row) elseif delta < 0 then table.insert(falls,row) end
        end
        table.sort(rises, function(a,b) return (a.controlC1 or -1) > (b.controlC1 or -1) end)
        table.sort(falls, function(a,b) return (a.controlC1 or 101) < (b.controlC1 or 101) end)
        local function compact(label, rows)
            writer:write(label..": ")
            local names={}; for i=1,math.min(5,#rows) do local row=rows[i]; table.insert(names,text(row.data.fullType).." "..text(row.data.finalRarityTier).."->"..text(row.controlTier)) end
            writer:write(#names>0 and table.concat(names,"; ") or "none")
            writer:write("\n")
        end
        compact("largest rises",rises); compact("largest falls",falls)
    end
    writer:close()
    ItemRarityUtils.info("Clothing V2 closure audit written: remaining macro groups only; no runtime state changed.")
    return true
end

-- Final cross-macro guardrail.  It checks only invariant violations that can
-- be proven from the published data: a trivial item escaping COMMON, a
-- direct-slot item whose final tier disagrees with its own scored threshold,
-- or an incomplete deduplication key propagating a component across differing
-- raw inputs.  It deliberately does not call a visually surprising but
-- policy-consistent tier a bug.
local function globalClothingTier(data)
    local score = tonumber(data and data.clothingAdjustedScore)
    if score == nil then return nil end
    local role = tostring(data.clothingDirectSlotFunction or data.utilityFunctionalGroup or "")
    if role == "LOWER_BODY_LAYER" or role == "HEADGEAR" then
        if score < 40 then return "COMMON" end
        if score < 50 then return "UNCOMMON" end
        if score < 60 then return "RARE" end
        if score < 75 then return "EPIC" end
        return "EXOTIC"
    end
    return clothingC1Tier(score)
end

local function writeGlobalClothingClosureAudit(results)
    if type(results) ~= "table" or not getFileWriter then return false end
    local totals = { clothing=0, direct=0, accessory=0, trivial=0, rule=0, future=0, acceptable=0 }
    local suspects, profiles = {}, {}
    for _, data in pairs(results) do
        if data.category == "CLOTHING" then totals.clothing = totals.clothing + 1 end
        if data.category == "ACCESSORY" then totals.accessory = totals.accessory + 1 end
        local clothingTrivial = data.category == "CLOTHING" and data.clothingMechanicalValueStatus == "MECHANICALLY_TRIVIAL"
        local accessoryTrivial = data.category == "ACCESSORY" and data.accessoryMechanicalValueStatus == "MECHANICALLY_TRIVIAL"
        if clothingTrivial or accessoryTrivial then
            totals.trivial = totals.trivial + 1
            if data.finalRarityTier ~= "COMMON" then
                -- ACCESSORY deliberately has a narrower COMMON policy than
                -- CLOTHING: only unambiguous cosmetic anatomy is eligible.
                -- Belts, sheaths, slings and other unresolved accessory
                -- roles are a bridge/architecture limitation, not a failed
                -- invariant in the active policy.
                if accessoryTrivial and data.accessoryTrivialCosmeticEligible ~= true then
                    totals.future = totals.future + 1
                else
                    totals.rule = totals.rule + 1
                    table.insert(suspects, { data=data, reason="MECHANICALLY_TRIVIAL escaped COMMON policy", correction="apply existing structural trivial ceiling" })
                end
            end
        end
        if hasActiveDirectSlot(data) and data.clothingMechanicalValueStatus ~= "MECHANICALLY_TRIVIAL" then
            totals.direct = totals.direct + 1
            local expected = globalClothingTier(data)
            if expected and data.finalRarityTier ~= expected then
                totals.rule = totals.rule + 1
                table.insert(suspects, { data=data, reason="Final tier disagrees with published ClothingScore/C1 threshold", correction="inspect direct-slot tier route" })
            end
            local profile = tostring(data.utilityProfile or "NO_PROFILE:" .. tostring(data.fullType))
            local entry = profiles[profile]
            local raw = closureRawSignature((data.clothingDiscovery or {}).coveredRegions or {}, data.utilityMetrics or {})
            if not entry then profiles[profile] = { first=raw, data=data } else
                local differing = closureDifferentFields(entry.first, raw)
                if #differing > 0 then
                    totals.rule = totals.rule + 1
                    table.insert(suspects, { data=data, reason="utilityProfile shares different raw input: "..table.concat(differing,","), correction="extend the generic Clothing profile key" })
                end
            end
        end
    end
    local writer = getFileWriter("ItemRarity_ClothingV2FinalAudit.txt", true, false)
    if not writer then return false end
    writer:write("Item Rarity Clothing V2 final audit (READ ONLY)\n")
    writer:write("TOTAL_CLOTHING="..tostring(totals.clothing).." | DIRECT_SLOT_NONTRIVIAL="..tostring(totals.direct).." | ACCESSORY="..tostring(totals.accessory).." | TRIVIAL="..tostring(totals.trivial).."\n")
    writer:write("TOTAL_SUSPECTS="..tostring(#suspects).." | REGRA_PROVAVEL="..tostring(totals.rule).." | ARQUITETURA_FUTURA="..tostring(totals.future).." | ACEITAVEL_DESIGN="..tostring(totals.acceptable).."\n")
    writer:write("REGRA_PROVAVEL is limited to provable invariant failures; intentionally deferred low-confidence/ambiguous macros are not reclassified as bugs.\n\n")
    if #suspects == 0 then
        writer:write("REGRA_PROVAVEL=0 -- Clothing V2 structural closure criteria satisfied.\n")
    else
        writer:write("REGRA_PROVAVEL CASES\nfullType | category | finalTier | scarcityTier | utility | mechanical state | reason | generic correction\n")
        table.sort(suspects, function(a,b) return a.data.fullType < b.data.fullType end)
        for _, row in ipairs(suspects) do
            local data=row.data
            writer:write(table.concat({text(data.fullType),text(data.category),text(data.finalRarityTier),text(data.baseScarcityTier),fmt(data.utility),
                text(data.clothingMechanicalValueStatus or data.accessoryMechanicalValueStatus),text(row.reason),text(row.correction)}," | ").."\n")
        end
    end
    writer:close()
    ItemRarityUtils.info("Clothing V2 final audit written: invariant-only, no runtime state changed.")
    return true
end

function ItemRarityClothingAbsoluteComponentsAudit.write(results)
    local wrote = writeAudit(results)
    local simulated = writeClassifierFallbackSimulation(results)
    local accessoryWallet = writeAccessoryWalletAudit(results)
    local macroV2 = writeMacroV2Audit(results)
    local closure = writeRemainingMacroClosureAudit(results)
    local finalAudit = writeGlobalClothingClosureAudit(results)
    return wrote and simulated and accessoryWallet and macroV2 and closure and finalAudit
end
