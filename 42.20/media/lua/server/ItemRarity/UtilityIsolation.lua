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

-- Runs one loop body, retaining the original candidate object and the original
-- complete reference population. No retry, singleton normalization or cache.
function I.each(collection, iterator, stage, ownerOf, action)
    for key, value in iterator(collection) do
        local owner = ownerOf and ownerOf(value) or value
        I.run(owner, stage, function() action(value, key) end)
    end
end

return I
