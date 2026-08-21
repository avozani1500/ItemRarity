require "ItemRarity/RarityUtils"

-- Read-only ACCESSORY audit.  It deliberately does not call UtilityCalculator
-- and does not write to any registry/tier field: this is discovery before a
-- possible future AccessoryUtility implementation.
ItemRarityAccessoryMechanicalValueReport = ItemRarityAccessoryMechanicalValueReport or {}

local function field(object, name)
    local ok, value = pcall(function() return object and object[name] end)
    return ok and value or nil
end

local function call(object, name)
    local method = field(object, name)
    if type(method) ~= "function" then return nil end
    local ok, value = pcall(function() return method(object) end)
    return ok and value or nil
end

local function number(value)
    return value ~= nil and string.format("%.2f", value) or "N/A"
end

local function lower(value) return string.lower(tostring(value or "")) end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function sortedCopy(values)
    local copy = {}
    for _, value in ipairs(values) do table.insert(copy, value) end
    table.sort(copy)
    return copy
end

local function quantile(values, percentile)
    if #values == 0 then return nil end
    local position = clamp(percentile, 0, 100) / 100 * (#values - 1) + 1
    local low, high = math.floor(position), math.ceil(position)
    if low == high then return values[low] end
    return values[low] + (values[high] - values[low]) * (position - low)
end

local function robust(value, scale)
    if value == nil or not scale.low or not scale.high then return 0 end
    if scale.high <= scale.low then return value > 0 and 50 or 0 end
    return clamp((clamp(value, scale.low, scale.high) - scale.low) / (scale.high - scale.low) * 100, 0, 100)
end

local function modifierLoss(value)
    return value == nil and 0 or clamp((1 - value) * 100, 0, 100)
end

local function progressiveLoss(loss, free)
    local excess = math.max(0, loss - free)
    return excess == 0 and 0 or clamp(100 * ((excess / math.max(1, 100 - free)) ^ .72), 0, 100)
end

local function functionalCost(metrics, weightPercentile)
    local components = {
        combat = progressiveLoss(modifierLoss(metrics.combatSpeedModifier), 1) * .30,
        run = progressiveLoss(modifierLoss(metrics.runSpeedModifier), 1) * .25,
        discomfort = progressiveLoss(clamp((metrics.discomfortModifier or 0) * 100, 0, 100), 2) * .10,
        vision = progressiveLoss(modifierLoss(metrics.visionModifier), 1) * .15,
        hearing = progressiveLoss(modifierLoss(metrics.hearingModifier), 1) * .15,
        weight = progressiveLoss(100 - (weightPercentile or 50), 15) * .05,
    }
    local total = 0
    for _, value in pairs(components) do total = total + value end
    local excess = math.max(0, total - 7)
    return excess == 0 and 0 or (excess ^ 1.28) / 5.5, components
end

local function countCoverage(value)
    local unique = {}
    for token in string.gmatch(lower(value), "[^;,%s]+") do unique[token] = true end
    local count = 0
    for _ in pairs(unique) do count = count + 1 end
    return count
end

local function isAccessory(data, scriptItem)
    if data.category == "ACCESSORY" then return true end
    if lower(data.displayCategory) == "accessory" then return true end
    return lower(call(scriptItem, "getDisplayCategory")) == "accessory"
end

local function readNumber(runtimeItem, scriptItem, getter, member)
    local value = tonumber(call(runtimeItem, getter))
    if value == nil then value = tonumber(call(scriptItem, getter)) end
    if value == nil then value = tonumber(field(scriptItem, member)) end
    return value
end

local function recordFor(data)
    local manager = getScriptManager and getScriptManager() or nil
    local scriptItem = manager and manager:FindItem(data.fullType) or nil
    if not scriptItem or not isAccessory(data, scriptItem) then return nil end
    local ok, runtimeItem = pcall(function() return scriptItem:InstanceItem(nil, false) end)
    if not ok then runtimeItem = nil end
    local bloodLocation = call(runtimeItem, "getBloodClothingType") or call(scriptItem, "getBloodClothingType")
        or call(runtimeItem, "getBloodLocation") or call(scriptItem, "getBloodLocation") or field(scriptItem, "bloodLocation") or ""
    local bodyLocation = call(runtimeItem, "getBodyLocation") or call(scriptItem, "getBodyLocation") or field(scriptItem, "bodyLocation") or ""
    local tags = tostring(call(scriptItem, "getTags") or field(scriptItem, "tags") or "")
    local conditionMax = readNumber(runtimeItem, scriptItem, "getConditionMax", "conditionMax")
    local lowerChance = readNumber(runtimeItem, scriptItem, "getConditionLowerChance", "conditionLowerChance")
    local metrics = {
        biteDefense = readNumber(runtimeItem, scriptItem, "getBiteDefense", "biteDefense"),
        scratchDefense = readNumber(runtimeItem, scriptItem, "getScratchDefense", "scratchDefense"),
        bulletDefense = readNumber(runtimeItem, scriptItem, "getBulletDefense", "bulletDefense"),
        insulation = readNumber(runtimeItem, scriptItem, "getInsulation", "insulation"),
        windResistance = readNumber(runtimeItem, scriptItem, "getWindResistance", "windResistance"),
        waterResistance = readNumber(runtimeItem, scriptItem, "getWaterResistance", "waterResistance"),
        conditionMax = conditionMax,
        conditionLowerChance = lowerChance,
        durability = conditionMax and lowerChance and math.log(1 + math.max(0, conditionMax) * math.max(0, lowerChance)) or nil,
        weight = readNumber(runtimeItem, scriptItem, "getActualWeight", "actualWeight"),
        runSpeedModifier = readNumber(runtimeItem, scriptItem, "getRunSpeedModifier", "runSpeedModifier"),
        combatSpeedModifier = readNumber(runtimeItem, scriptItem, "getCombatSpeedModifier", "combatSpeedModifier"),
        discomfortModifier = readNumber(runtimeItem, scriptItem, "getDiscomfortModifier", "discomfortModifier"),
        visionModifier = readNumber(runtimeItem, scriptItem, "getVisionModifier", "visionModifier"),
        hearingModifier = readNumber(runtimeItem, scriptItem, "getHearingModifier", "hearingModifier"),
    }
    if metrics.windResistance == nil then metrics.windResistance = readNumber(runtimeItem, scriptItem, "getWindresistance", "windresistance") end
    local activated = field(scriptItem, "activatedItem") == true or call(scriptItem, "isActivatedItem") == true
    local keepOnDeplete = field(scriptItem, "keepOnDeplete") == true or call(scriptItem, "isKeepOnDeplete") == true
    local specialTags = string.find(lower(tags), "scba", 1, true) ~= nil or string.find(lower(tags), "hazmat", 1, true) ~= nil
    local special = activated or keepOnDeplete or specialTags
    local profile = table.concat({ tostring(bodyLocation), tostring(bloodLocation), tostring(metrics.biteDefense), tostring(metrics.scratchDefense),
        tostring(metrics.bulletDefense), tostring(metrics.insulation), tostring(metrics.windResistance), tostring(metrics.waterResistance),
        tostring(metrics.conditionMax), tostring(metrics.conditionLowerChance), tostring(metrics.weight), tostring(metrics.runSpeedModifier),
        tostring(metrics.combatSpeedModifier), tostring(metrics.discomfortModifier), tostring(metrics.visionModifier), tostring(metrics.hearingModifier) }, ":")
    return {
        data = data, scriptType = tostring(call(scriptItem, "getType") or ""), bodyLocation = tostring(bodyLocation), bloodLocation = tostring(bloodLocation),
        tags = tags, metrics = metrics, profile = profile, special = special,
        specialReason = string.format("activated=%s,keepOnDeplete=%s,specialTag=%s,onCreate=%s", tostring(activated), tostring(keepOnDeplete), tostring(specialTags), tostring((field(scriptItem, "onCreate") or call(scriptItem, "getOnCreate")) ~= nil)),
    }
end

local function makeScale(records, name)
    local seen, values = {}, {}
    for _, record in ipairs(records) do
        local value = record.metrics[name]
        if value ~= nil and not seen[record.profile] then seen[record.profile] = true; table.insert(values, value) end
    end
    values = sortedCopy(values)
    return { low = quantile(values, 5), high = quantile(values, 95) }
end

local function prepare(results)
    local records = {}
    for _, data in pairs(results) do
        local record = recordFor(data)
        if record then table.insert(records, record) end
    end
    table.sort(records, function(a, b) return a.data.fullType < b.data.fullType end)
    local scales = {
        biteDefense = makeScale(records, "biteDefense"), scratchDefense = makeScale(records, "scratchDefense"), bulletDefense = makeScale(records, "bulletDefense"),
        insulation = makeScale(records, "insulation"), windResistance = makeScale(records, "windResistance"), waterResistance = makeScale(records, "waterResistance"),
        durability = makeScale(records, "durability"), weight = makeScale(records, "weight"),
    }
    local profileWeights, weightValues = {}, {}
    for _, record in ipairs(records) do if record.metrics.weight ~= nil and not profileWeights[record.profile] then profileWeights[record.profile] = true; table.insert(weightValues, record.metrics.weight) end end
    weightValues = sortedCopy(weightValues)
    for _, record in ipairs(records) do
        local m = record.metrics
        local coverage = countCoverage(record.bloodLocation)
        record.coverage = coverage
        record.coverageFactor = coverage == 0 and 0 or (.70 + .30 * clamp(coverage / 3, 0, 1))
        record.protection = (robust(m.biteDefense, scales.biteDefense) * .50 + robust(m.scratchDefense, scales.scratchDefense) * .35 + robust(m.bulletDefense, scales.bulletDefense) * .15) * record.coverageFactor
        record.weather = robust(m.insulation, scales.insulation) * .40 + robust(m.windResistance, scales.windResistance) * .35 + robust(m.waterResistance, scales.waterResistance) * .25
        record.durabilityFactor = .75 + .25 * (robust(m.durability, scales.durability) / 100)
        local weightPercentile = 50
        if m.weight ~= nil and #weightValues > 1 then
            local below = 0; for _, value in ipairs(weightValues) do if value <= m.weight then below = below + 1 end end
            weightPercentile = (below - 1) / (#weightValues - 1) * 100
        end
        record.cost, record.costComponents = functionalCost(m, weightPercentile)
        record.baseBenefit = record.protection * .85 + record.weather * .15
        record.value = math.max(0, record.baseBenefit * record.durabilityFactor - record.cost)
        local coreKnown = m.biteDefense ~= nil and m.scratchDefense ~= nil and m.bulletDefense ~= nil and m.insulation ~= nil and m.windResistance ~= nil and m.waterResistance ~= nil
        record.status = record.special and "MECHANICAL_VALUE_PARTIAL" or (not coreKnown and "MECHANICAL_VALUE_PARTIAL" or (record.baseBenefit <= .01 and "MECHANICALLY_TRIVIAL" or "MECHANICAL_VALUE_KNOWN"))
    end
    return records
end

local function rarePlus(tier) return tier == "RARE" or tier == "EPIC" or tier == "EXOTIC" end

function ItemRarityAccessoryMechanicalValueReport.write(results)
    if type(results) ~= "table" or not getFileWriter then return false end
    local writer = getFileWriter("ItemRarity_AccessoryMechanicalValue.txt", true, false)
    if not writer then return false end
    local records = prepare(results)
    local profiles, values, statusCounts, rareTrivial = {}, {}, { MECHANICALLY_TRIVIAL = 0, MECHANICAL_VALUE_KNOWN = 0, MECHANICAL_VALUE_PARTIAL = 0 }, {}
    for _, record in ipairs(records) do
        profiles[record.profile] = profiles[record.profile] or {}
        table.insert(profiles[record.profile], record)
        statusCounts[record.status] = statusCounts[record.status] + 1
        if not profiles[record.profile].valueAdded then table.insert(values, record.value); profiles[record.profile].valueAdded = true end
        if rarePlus(record.data.finalRarityTier) and record.status == "MECHANICALLY_TRIVIAL" then table.insert(rareTrivial, record) end
    end
    values = sortedCopy(values)
    local duplicateProfiles = 0
    for _, group in pairs(profiles) do if #group > 1 then duplicateProfiles = duplicateProfiles + 1 end end
    writer:write("Item Rarity ACCESSORY MechanicalValue audit (REPORT ONLY)\n")
    writer:write("No active tier, Utility, registry, classifier, or UI field is changed. ACCESSORY is discovered from runtime/script DisplayCategory=Accessory (or an existing ACCESSORY category), not fullType/name.\n")
    writer:write("BaseBenefit = 85% protection x covered-region evidence + 15% weather. MechanicalValue = BaseBenefit x DurabilityFactor - intrinsic FunctionalCost. Durability cannot create benefit by itself.\n")
    writer:write("Status: TRIVIAL = known zero benefit; KNOWN = quantified nonzero benefit; PARTIAL = special behavior or incomplete runtime attribute evidence.\n\n")
    writer:write(string.format("ITEMS=%d | UNIQUE_MECHANICAL_PROFILES=%d | DUPLICATED_PROFILES=%d | TRIVIAL=%d | KNOWN=%d | PARTIAL=%d\n", #records, #values, duplicateProfiles, statusCounts.MECHANICALLY_TRIVIAL, statusCounts.MECHANICAL_VALUE_KNOWN, statusCounts.MECHANICAL_VALUE_PARTIAL))
    writer:write(string.format("VALUE DISTRIBUTION (profiles) | min=%s | p10=%s | p25=%s | p50=%s | p75=%s | p90=%s | p95=%s | max=%s\n\n", number(quantile(values, 0)), number(quantile(values, 10)), number(quantile(values, 25)), number(quantile(values, 50)), number(quantile(values, 75)), number(quantile(values, 90)), number(quantile(values, 95)), number(quantile(values, 100))))
    writer:write("RARE+ MECHANICALLY_TRIVIAL (candidate future cap audit)\nfullType | tier | occurrences | distributions | BodyLocation | BloodLocation | tags\n")
    for _, record in ipairs(rareTrivial) do writer:write(string.format("%s | %s | %d | %d | %s | %s | %s\n", record.data.fullType, record.data.finalRarityTier, record.data.occurrences or 0, #(record.data.distributions or {}), record.bodyLocation, record.bloodLocation, record.tags)) end
    writer:write("\nMECHANICALLY IDENTICAL / NEAR-IDENTICAL PROFILE GROUPS\n")
    local profileGroups = {}
    for _, group in pairs(profiles) do if #group > 1 then table.insert(profileGroups, group) end end
    table.sort(profileGroups, function(a, b) return a[1].profile < b[1].profile end)
    for _, group in ipairs(profileGroups) do
        local names = {}; for _, record in ipairs(group) do table.insert(names, record.data.fullType .. "(" .. record.data.finalRarityTier .. ")") end
        writer:write(table.concat(names, ", ") .. "\n")
    end
    writer:write("\nALL ACCESSORY RECORDS\nfullType | tier | occurrences | BodyLocation | BloodLocation | bite | scratch | bullet | insulation | wind | water | condMax | lowerChance | weight | run | combat | discomfort | vision | hearing | coverage | BaseBenefit | DurabilityFactor | FunctionalCost | MechanicalValue | Status | tags/special\n")
    for _, record in ipairs(records) do
        local m, c = record.metrics, record.costComponents
        writer:write(string.format("%s | %s | %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %d | %s | %s | %s | %s | %s | %s | %s\n",
            record.data.fullType, record.data.finalRarityTier, record.data.occurrences or 0, record.bodyLocation, record.bloodLocation,
            number(m.biteDefense), number(m.scratchDefense), number(m.bulletDefense), number(m.insulation), number(m.windResistance), number(m.waterResistance),
            number(m.conditionMax), number(m.conditionLowerChance), number(m.weight), number(m.runSpeedModifier), number(m.combatSpeedModifier), number(m.discomfortModifier),
            number(m.visionModifier), number(m.hearingModifier), record.coverage, number(record.baseBenefit), number(record.durabilityFactor), number(record.cost), number(record.value),
            record.status, record.tags .. " | " .. record.specialReason))
    end
    writer:close()
    ItemRarityUtils.info(string.format("ACCESSORY MechanicalValue audit written: %d items, %d profiles, %d RARE+ trivial candidates.", #records, #values, #rareTrivial))
    return true
end
