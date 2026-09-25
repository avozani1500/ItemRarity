-- Item-local boundaries only. Never wrap a scanner, route builder or publisher.
ItemRarityUtilityIsolation = ItemRarityUtilityIsolation or {}
local I = ItemRarityUtilityIsolation
I.warningKeys = I.warningKeys or {}

function I.finite(value)
    return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function render(value)
    local ok, text = pcall(tostring, value)
    if not ok then text = "<unprintable>" end
    return text .. " (" .. type(value) .. ")"
end

function I.beginScan()
    I.report = { isolatedItemFailures=0, partialItems=0, unsupportedItems=0, entries={} }
end

function I.mark(candidate, stage, status, reason, values)
    if candidate.isolationStatus then return end
    local data = candidate.data or {}
    local entry = {
        fullType=data.fullType, displayName=data.displayName, module=data.module,
        utility=candidate.kind, stage=stage, status=status, error=render(reason), values={},
    }
    for key, value in pairs(values or candidate.metrics or {}) do entry.values[tostring(key)] = render(value) end
    candidate.isolationStatus, candidate.isolationStage = status, stage
    candidate.utilityState = status == "ERROR_ISOLATED" and "ERROR_ISOLATED" or "PARTIAL"
    entry.state = candidate.utilityState
    candidate.utility, candidate.utilityEligible, candidate.utilityConfidence = nil, false, "LOW"
    candidate.utilitySupport, candidate.ineligibleReason = "UTILITY_PARTIAL", status .. ": " .. render(reason)
    candidate.failedUtilityKind, candidate.kind = candidate.kind, "UNSUPPORTED"
    candidate.clothingUtilityCandidate, candidate.accessoryMechanicalCandidate = false, false
    -- Scorers may have assigned outputs before throwing. No such output is
    -- eligible for publication or compatible-weapon inheritance afterwards.
    candidate.firearmFinalTier, candidate.firearmFinalScore = nil, nil
    candidate.ammoInheritedFirearmTier, candidate.magazineFinalTier = nil, nil
    if not I.report then I.beginScan() end
    table.insert(I.report.entries, entry)
    if status == "ERROR_ISOLATED" then I.report.isolatedItemFailures = I.report.isolatedItemFailures + 1
    else I.report.partialItems = I.report.partialItems + 1 end
    local warningKey = render(entry.fullType) .. "\031" .. stage .. "\031" .. entry.error
    if I.warningKeys[warningKey] then return end
    I.warningKeys[warningKey] = true
    local fields = {}
    for key, value in pairs(entry.values) do table.insert(fields, key .. "=" .. value) end
    table.sort(fields)
    local message = "[ItemRarity][" .. status .. "] fullType=" .. render(entry.fullType)
        .. " displayName=" .. render(entry.displayName) .. " module=" .. render(entry.module)
        .. " Utility=" .. render(entry.utility) .. " stage=" .. stage .. " state=" .. entry.state .. " error=" .. entry.error
        .. " values={" .. table.concat(fields, "; ") .. "}"
    -- Logging must not turn a contained item exception into another failure.
    if print then pcall(print, message) end
end

function I.run(candidate, stage, action)
    if candidate.isolationStatus then return false end
    local ok, result = pcall(action)
    if not ok then I.mark(candidate, stage, "ERROR_ISOLATED", result) end
    return ok, result
end

-- Candidate metrics have an explicit mixed schema. Missing numeric values are
-- retained as missing; only present, invalid values are rejected before ranks.
local stringMetrics = {
    ammoType=true, gunType=true, eatType=true, customEatSound=true, foodType=true,
    onCooked=true, replaceOnCooked=true, onCreate=true, skill=true, mapId=true,
    onRead=true, doubleClickRecipe=true,
}
local booleanMetrics = {
    cookable=true, dangerousUncooked=true, poison=true, alcoholic=true, cantEat=true,
    removeNegativeEffectOnCooked=true, predator=true, usesBattery=true, activated=true, equippable=true,
}
function I.validate(candidate)
    if candidate.metrics == nil then return true end
    if type(candidate.metrics) ~= "table" then
        I.mark(candidate, "CandidateValidation", "ERROR_ISOLATED", "metrics must be a table", {metrics=candidate.metrics})
        return false
    end
    for name, value in pairs(candidate.metrics) do
        local valid
        if stringMetrics[name] then valid = type(value) == "string"
        elseif booleanMetrics[name] then valid = type(value) == "boolean"
        else valid = I.finite(value) end
        if not valid then
            I.mark(candidate, "CandidateValidation", "ERROR_ISOLATED", "invalid metric: " .. tostring(name))
            return false
        end
    end
    return true
end

function I.discover(data, action)
    local owner = { data=data, kind="CANDIDATE_DISCOVERY" }
    local ok, candidate = I.run(owner, "CandidateDiscovery", action)
    if not ok then return owner end
    if type(candidate) ~= "table" then
        I.mark(owner, "CandidateDiscovery", "ERROR_ISOLATED", "Candidate builder returned a non-table",
            {value=candidate,luaType=type(candidate)})
        return owner
    end
    I.run(candidate, "CandidateValidation", function() return I.validate(candidate) end)
    if not candidate.isolationStatus then
        if candidate.kind == "UNSUPPORTED" then candidate.utilityState = "UNSUPPORTED"
        elseif candidate.utilityEligible == false then candidate.utilityState = "PARTIAL"
        else candidate.utilityState = "SAFE" end
    end
    return candidate
end

-- Per-Utility schemas opt in explicitly. No missing value is substituted.
function I.requireNumbers(candidate, stage, names)
    if not I.validate(candidate) then return false end
    for _, name in ipairs(names) do
        local value = candidate.metrics and candidate.metrics[name]
        if not I.finite(value) then
            local status = value == nil and "PARTIAL_DEFER" or "ERROR_ISOLATED"
            I.mark(candidate, stage .. ":" .. name, status, "Required numeric metric unavailable",
                {value=value,luaType=type(value),metric=name})
            return false
        end
    end
    return true
end

-- Explicit opt-in for required non-metric fields/components. No coercion.
function I.requireFields(candidate, stage, source, names)
    for _, name in ipairs(names) do
        local value = nil
        if type(source) == "table" then value = source[name] end
        if not I.finite(value) then
            I.mark(candidate, stage, value == nil and "PARTIAL_DEFER" or "ERROR_ISOLATED",
                "Required numeric field unavailable: " .. name, {value=value,luaType=type(value),field=name})
            return false
        end
    end
    return true
end

-- A proof for the existing zero-benefit Clothing policy is independent of
-- comparative rank, body regions and durability. Six measured zeroes are
-- evidence; a missing getter is not. Special/ambiguous functions stay out.
function I.clothingStructuralPolicy(candidate)
    if candidate.kind ~= "CLOTHING" or candidate.isolationStatus
        or candidate.mechanicalSpecialBehavior or type(candidate.metrics) ~= "table" then return false end
    for _, name in ipairs({"biteDefense","scratchDefense","bulletDefense","insulation","windResistance","waterResistance"}) do
        local value=candidate.metrics[name]
        if not I.finite(value) or value ~= 0 then return false end
    end
    candidate.structuralPolicy = "CLOTHING_TRIVIAL"
    candidate.utilityState = "STRUCTURAL_POLICY_RESOLVED"
    candidate.rankingEligible = false
    candidate.clothingUtilityCandidate = false
    candidate.utilityEligible, candidate.utility = false, nil
    candidate.utilityConfidence = "HIGH"
    candidate.mechanicalAttributesKnown = true
    candidate.mechanicalBaseBenefit, candidate.mechanicalValue = 0, 0
    candidate.mechanicalValueStatus = "MECHANICALLY_TRIVIAL"
    -- Do not invent durability/cost or a numerical ClothingUtility. The
    -- existing final-tier policy owns COMMON; this is not a new tier formula.
    candidate.ineligibleReason = "Clothing trivial structural policy resolved; no mechanical ranking required"
    return true
end

function I.clothingAdmission(candidate)
    candidate.rankingEligible = false
    if not I.requireNumbers(candidate, "Clothing:ReferenceAdmission", {
        "biteDefense","scratchDefense","bulletDefense","durability","weight",
        "runSpeedModifier","combatSpeedModifier","visionModifier","hearingModifier",
        "discomfortModifier","insulation","windResistance","waterResistance",
    }) then return false end
    if type(candidate.profile) ~= "string" or type(candidate.functionalGroup) ~= "string"
        or type(candidate.clothingDiscovery) ~= "table" then
        I.mark(candidate,"Clothing:ReferenceAdmission","PARTIAL_DEFER","Missing Clothing comparison metadata")
        return false
    end
    local regions = candidate.clothingDiscovery.coveredRegions
    if type(regions) ~= "table" or #regions == 0 then
        I.mark(candidate,"Clothing:ReferenceAdmission","PARTIAL_DEFER","Missing anatomical regions")
        return false
    end
    for _, region in pairs(regions) do
        if type(region) ~= "string" then
            I.mark(candidate,"Clothing:ReferenceAdmission","ERROR_ISOLATED","Invalid anatomical region",{value=region})
            return false
        end
    end
    local graph = candidate.equipmentGraph
    if graph ~= nil and type(graph) ~= "table" then
        I.mark(candidate,"Clothing:ReferenceAdmission","ERROR_ISOLATED","Invalid equipment graph",{value=graph})
        return false
    end
    if graph and graph.resolved then
        if type(graph.slotId) ~= "string" then
            I.mark(candidate,"Clothing:ReferenceAdmission","PARTIAL_DEFER","Missing resolved slot identity")
            return false
        end
        if graph.exclusive ~= nil and type(graph.exclusive) ~= "table" then
            I.mark(candidate,"Clothing:ReferenceAdmission","ERROR_ISOLATED","Invalid exclusive slots",{value=graph.exclusive})
            return false
        end
    end
    local scarcity=candidate.data.scarcityPercentile
    if scarcity == nil and candidate.data.tableAvailability then scarcity=candidate.data.tableAvailability.routeWeightedPercentile end
    if scarcity ~= nil and not I.finite(scarcity) then
        I.mark(candidate,"Clothing:ReferenceAdmission","ERROR_ISOLATED","Invalid Clothing Scarcity input",{value=scarcity})
        return false
    end
    candidate.rankingEligible = true
    return true
end

function I.foodAdmission(candidate)
    if not I.requireNumbers(candidate,"Food:ReferenceAdmission",{
        "hungerChange","thirstChange","hungerBenefit","thirstBenefit","calories","daysTotallyRotten",
        "unhappyChange","boredomChange","stressChange","foodSicknessChange",
    }) then return false end
    if type(candidate.profile) ~= "string" or (candidate.functionalGroup ~= "FOOD" and candidate.functionalGroup ~= "DRINK") then
        I.mark(candidate,"Food:ReferenceAdmission","PARTIAL_DEFER","Missing Food comparison identity")
        return false
    end
    for _, name in ipairs({"cookable","dangerousUncooked","poison"}) do
        local value=candidate.metrics[name]
        if type(value) ~= "boolean" then
            I.mark(candidate,"Food:ReferenceAdmission",value == nil and "PARTIAL_DEFER" or "ERROR_ISOLATED",
                "Required Food flag unavailable: "..name,{value=value,luaType=type(value)})
            return false
        end
    end
    if candidate.metrics.cookable and not I.requireNumbers(candidate,"Food:ReferenceAdmission",{"minutesToCook"}) then return false end
    local scarcity=candidate.data.scarcityPercentile
    if scarcity == nil and candidate.data.tableAvailability then scarcity=candidate.data.tableAvailability.routeWeightedPercentile end
    if scarcity ~= nil and not I.finite(scarcity) then
        I.mark(candidate,"Food:ReferenceAdmission","ERROR_ISOLATED","Invalid Food Scarcity input",{value=scarcity})
        return false
    end
    return true
end

-- Runs one loop body, retaining the original candidate object and the original
-- complete reference population. No retry, singleton normalization or cache.
function I.each(collection, iterator, stage, ownerOf, action)
    for key, value in iterator(collection) do
        local owner = ownerOf and ownerOf(value) or value
        I.run(owner, stage, function() action(value, key) end)
    end
end

return I
