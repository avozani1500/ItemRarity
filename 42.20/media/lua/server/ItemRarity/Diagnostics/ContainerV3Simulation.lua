-- Explicit development-only ContainerUtility V3 simulation. It reads the
-- published scan rows plus ScriptItem/runtime facts and never alters the
-- scanner, RouteWeighted, UtilityCalculator, registry or FinalRarityTier.
ItemRarityContainerV3Simulation = ItemRarityContainerV3Simulation or {}

local function call(object, method)
    if not object or type(object[method]) ~= "function" then return nil end
    local ok, value = pcall(function() return object[method](object) end)
    return ok and value or nil
end

local function field(object, method, name)
    local value = call(object, method)
    if value ~= nil then return value end
    local ok, fallback = pcall(function() return object and object[name] end)
    return ok and fallback or nil
end

local function number(value)
    value = tonumber(value)
    return value and value == value and value or nil
end

local function text(value)
    local result = tostring(value or "")
    result = result:gsub("^%s*(.-)%s*$", "%1")
    if result == "" or result:lower() == "nil" or result:lower() == "null" or result == "[]" then return "" end
    return result
end

local function lower(value) return text(value):lower() end

local function contains(value, fragment)
    return string.find(lower(value), fragment, 1, true) ~= nil
end

local function count(collection)
    if not collection then return 0 end
    local ok, size = pcall(function() return collection:size() end)
    if ok and tonumber(size) then return tonumber(size) end
    if type(collection) == "table" then return #collection end
    return 0
end

local function scriptFor(fullType)
    local manager = getScriptManager and getScriptManager() or nil
    return manager and manager:FindItem(fullType) or nil
end

local function runtimeFor(script)
    if not script then return nil end
    local ok, runtime = pcall(function() return script:InstanceItem(nil, false) end)
    return ok and runtime or nil
end

local function functionalEquipSlot(value)
    local slot = lower(value)
    return slot ~= "" and not contains(slot, "none") and not contains(slot, "null")
        and slot ~= "false" and slot ~= "nil"
end

-- A capacity is mechanically comparable only where the available bridge can
-- prove that the container is general-purpose. A restriction is never guessed
-- as a numeric multiplier: SPECIALIZED/UNKNOWN intentionally carry nil.
local function restrictionState(facts)
    local hasRestrictionSignal = facts.acceptItemFunction ~= "" or (facts.maxItemSize or 0) > 0
    local isTiny = (facts.rawCapacity or math.huge) <= 5
        and (facts.weightReduction or math.huge) == 0
        and (facts.attachments or 0) == 0
        and not facts.functionalEquipSlot

    if hasRestrictionSignal and isTiny then return "TRIVIAL_SPECIALIZED", 0 end
    if hasRestrictionSignal then return "SPECIALIZED", nil end
    if (facts.rawCapacity or 0) > 0 then return "GENERAL_PURPOSE", facts.rawCapacity end
    return "UNKNOWN_RESTRICTION", nil
end

local TIER_INDEX = { COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, EXOTIC = 5 }

local function tierDistance(current, proposed)
    local left, right = TIER_INDEX[current], TIER_INDEX[proposed]
    return left and right and (right - left) or 0
end

local function displayName(script, fallback)
    return text(field(script, "getDisplayName", "displayName")) ~= ""
        and text(field(script, "getDisplayName", "displayName")) or text(fallback)
end

local function factsFor(data)
    local script = scriptFor(data.fullType)
    local runtime = runtimeFor(script)
    local metrics = type(data.utilityMetrics) == "table" and data.utilityMetrics or {}
    local rawCapacity = number(field(runtime, "getCapacity", "capacity")) or number(field(script, "getCapacity", "capacity")) or number(metrics.capacity)
    local weightReduction = number(field(runtime, "getWeightReduction", "weightReduction")) or number(field(script, "getWeightReduction", "weightReduction")) or number(metrics.weightReduction)
    local emptyWeight = number(field(runtime, "getActualWeight", "actualWeight")) or number(field(script, "getActualWeight", "actualWeight")) or number(metrics.emptyWeight)
    local equipSlot = text(field(script, "getBodyLocation", "bodyLocation"))
    if equipSlot == "" then equipSlot = text(field(runtime, "getBodyLocation", "bodyLocation")) end
    local accept = text(field(script, "getAcceptItemFunction", "acceptItemFunction"))
    if accept == "" then accept = text(field(runtime, "getAcceptItemFunction", "acceptItemFunction")) end
    local maxItemSize = number(field(script, "getMaxItemSize", "maxItemSize")) or number(field(runtime, "getMaxItemSize", "maxItemSize"))
    return {
        rawCapacity = rawCapacity,
        weightReduction = weightReduction,
        emptyWeight = emptyWeight,
        equipSlot = equipSlot,
        functionalEquipSlot = functionalEquipSlot(equipSlot),
        attachments = count(call(runtime, "getAttachmentsProvided")),
        acceptItemFunction = accept,
        maxItemSize = maxItemSize,
        displayName = displayName(script, data.displayName or data.fullType),
    }
end

local function proposed(data, facts, state, effectiveCapacity)
    if state == "TRIVIAL_SPECIALIZED" then
        return 0, "COMMON", "restricted micro-container: capacity<=5, reduction=0, no attachments and no functional equip slot; Scarcity excluded"
    end
    if state == "GENERAL_PURPOSE" then
        if data.utility ~= nil then
            return data.utility, data.finalRarityTier, "general-purpose capacity remains on its current safe ContainerUtility route"
        end
        return nil, data.finalRarityTier, "general-purpose structure confirmed; no V3 score invented for a currently deferred comparison group"
    end
    if state == "SPECIALIZED" then
        return nil, data.finalRarityTier, "specialized restriction detected; EffectiveCapacity=nil until accepted-content semantics are bridged"
    end
    return nil, data.finalRarityTier, "restriction state unresolved; current behavior preserved"
end

local function orderedRows(results)
    local rows = {}
    for _, data in pairs(results or {}) do
        if data.category == "CONTAINER" then table.insert(rows, data) end
    end
    table.sort(rows, function(a, b) return tostring(a.fullType or "") < tostring(b.fullType or "") end)
    return rows
end

local function formatNumber(value)
    return value == nil and "nil" or string.format("%.3f", value)
end

function ItemRarityContainerV3Simulation.write(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local writer = getFileWriter("ItemRarity_ContainerV3Simulation.txt", true, false)
    if not writer then return nil end

    local impact = { total = 0, unchanged = 0, promoted = 0, demoted = 0, one = 0, twoPlus = 0 }
    local changes, stateCounts = {}, {}
    writer:write("ContainerUtility V3 structural simulation (READ ONLY)\n")
    writer:write("No scanner, scarcity, UtilityCalculator, FinalRarityTier or registry value is changed.\n")
    writer:write("EffectiveCapacity is raw Capacity only for GENERAL_PURPOSE, 0 for TRIVIAL_SPECIALIZED, and nil where restrictions cannot be quantified safely.\n\n")
    writer:write("fullType | displayName | structuralGroup | restrictionState | rawCapacity | effectiveCapacity | weightReduction | emptyWeight | equipSlot | attachments | acceptItemFunction | maxItemSize | currentUtility | proposedUtilityV3 | currentFinalTier | proposedFinalTier | reason\n")

    for _, data in ipairs(orderedRows(results)) do
        local facts = factsFor(data)
        local state, effectiveCapacity = restrictionState(facts)
        local proposedUtility, proposedTier, reason = proposed(data, facts, state, effectiveCapacity)
        local currentTier = data.finalRarityTier or data.baseScarcityTier or data.rarityTier or "UNKNOWN"
        local distance = tierDistance(currentTier, proposedTier)
        impact.total = impact.total + 1
        stateCounts[state] = (stateCounts[state] or 0) + 1
        if distance == 0 then
            impact.unchanged = impact.unchanged + 1
        else
            if distance > 0 then impact.promoted = impact.promoted + 1 else impact.demoted = impact.demoted + 1 end
            if math.abs(distance) == 1 then impact.one = impact.one + 1 else impact.twoPlus = impact.twoPlus + 1 end
            table.insert(changes, { data = data, facts = facts, state = state, currentTier = currentTier, proposedTier = proposedTier, reason = reason, distance = distance })
        end
        writer:write(table.concat({
            text(data.fullType), facts.displayName, text(data.containerV2Group or data.utilitySubgroup), state,
            formatNumber(facts.rawCapacity), formatNumber(effectiveCapacity), formatNumber(facts.weightReduction), formatNumber(facts.emptyWeight),
            facts.equipSlot, tostring(facts.attachments), facts.acceptItemFunction, formatNumber(facts.maxItemSize),
            formatNumber(data.utility), formatNumber(proposedUtility), currentTier, proposedTier, reason,
        }, " | ") .. "\n")
    end

    writer:write("\nIMPACT\n")
    writer:write(string.format("total containers=%d | unchanged=%d | promoted=%d | demoted=%d | changed by 1 tier=%d | changed by 2+ tiers=%d\n",
        impact.total, impact.unchanged, impact.promoted, impact.demoted, impact.one, impact.twoPlus))
    writer:write(string.format("GENERAL_PURPOSE=%d | SPECIALIZED=%d | TRIVIAL_SPECIALIZED=%d | UNKNOWN_RESTRICTION=%d\n",
        stateCounts.GENERAL_PURPOSE or 0, stateCounts.SPECIALIZED or 0, stateCounts.TRIVIAL_SPECIALIZED or 0, stateCounts.UNKNOWN_RESTRICTION or 0))
    writer:write("\nCHANGED TIERS\nfullType | displayName | state | current | proposed | delta | reason\n")
    for _, row in ipairs(changes) do
        writer:write(table.concat({ text(row.data.fullType), row.facts.displayName, row.state, row.currentTier, row.proposedTier, tostring(row.distance), row.reason }, " | ") .. "\n")
    end
    writer:close()
    if ItemRarityUtils and ItemRarityUtils.info then
        ItemRarityUtils.info(string.format("Container V3 simulation written: containers=%d changed=%d", impact.total, #changes))
    end
    return true
end
