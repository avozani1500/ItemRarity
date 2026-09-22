-- Explicit DEV-only forensic report. It invokes the isolated audit API only;
-- it never calls rescan(), RouteWeighted, publication or tier adjustment.
ItemRarityContainerV2FailureAudit = ItemRarityContainerV2FailureAudit or {}

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
local function text(value) return tostring(value == nil and "" or value):gsub("[\r\n|]", " ") end
local function number(value) value=tonumber(value); return value and value==value and value or nil end
local function format(value) return value == nil and "nil" or tostring(value) end
local function typeOf(value) return value == nil and "nil" or type(value) end
local function scriptFor(fullType)
    local manager = getScriptManager and getScriptManager() or nil
    return manager and manager:FindItem(fullType) or nil
end
local function writeOperand(writer, operand)
    operand = operand or {}
    writer:write(table.concat({
        "metric=" .. format(operand.metric), "value=" .. format(operand.value), "type(value)=" .. typeOf(operand.value),
        "rank.low=" .. format(operand.low), "type(low)=" .. typeOf(operand.low), "rank.high=" .. format(operand.high),
        "type(high)=" .. typeOf(operand.high), "percentile=" .. format(operand.percentile),
        "type(A percentile)=" .. typeOf(operand.percentile), "weight=" .. format(operand.weight), "type(B weight)=" .. typeOf(operand.weight),
    }, " | ") .. "\n")
end
local function writeFacts(writer, data, candidate)
    local script = scriptFor(data.fullType)
    local metrics = candidate and candidate.metrics or {}
    local module = data.module or field(script, "getModuleName", "module") or tostring(data.fullType or ""):match("^(.-)%.") or ""
    local name = data.displayName or field(script, "getDisplayName", "displayName") or data.fullType
    local maxItemSize = number(field(script, "getMaxItemSize", "maxItemSize"))
    writer:write("fullType=" .. text(data.fullType) .. "\n")
    writer:write("displayName=" .. text(name) .. "\nmodule=" .. text(module) .. "\n")
    writer:write("structuralGroup=" .. text(candidate and candidate.containerV2Group) .. "\n")
    writer:write("Capacity=" .. format(metrics.capacity) .. " | type=" .. typeOf(metrics.capacity) .. "\n")
    writer:write("WeightReduction=" .. format(metrics.weightReduction) .. " | type=" .. typeOf(metrics.weightReduction) .. "\n")
    writer:write("Weight=" .. format(metrics.emptyWeight) .. " | type=" .. typeOf(metrics.emptyWeight) .. "\n")
    writer:write("BodyLocation=" .. text(candidate and candidate.containerEquipSlot) .. "\n")
    writer:write("MaxItemSize=" .. format(maxItemSize) .. " | type=" .. typeOf(maxItemSize) .. "\n")
    writer:write("AcceptItemFunction=" .. text(candidate and candidate.containerAcceptItemFunction) .. "\n")
    writer:write("attachments=" .. format(metrics.attachments) .. " | type=" .. typeOf(metrics.attachments) .. "\n")
    writer:write("utilityEligible=" .. tostring(candidate and candidate.utilityEligible == true) .. " | skipped=" .. text(candidate and candidate.ineligibleReason) .. "\n")
end

function ItemRarityContainerV2FailureAudit.write(results)
    if not ItemRarityUtilityCalculator or not ItemRarityUtilityCalculator.auditContainerV2 or not getFileWriter then return nil end
    local audit = ItemRarityUtilityCalculator.auditContainerV2(results)
    local writer = getFileWriter("ItemRarity_ContainerV2FailureAudit.txt", true, false)
    if not writer then return nil end
    writer:write("ContainerUtility V2 failure audit (READ ONLY)\n")
    writer:write("No scan, registry, tier or formula value is changed. Each eligible target is scored only with vanilla references from its own Container V2 group.\n\n")
    writer:write("STATIC MULTIPLICATIONS\n")
    for _, expression in ipairs(audit.staticMultiplications or {}) do writer:write(expression .. "\n") end
    writer:write("\nCONTAINERS\n")
    for _, record in ipairs(audit.records or {}) do
        writer:write("\nCONTAINER\n")
        writeFacts(writer, record.data, record.candidate)
        writer:write("intermediate multiplication operands: ")
        writeOperand(writer, record.operands)
        if record.failed then writer:write("status=FAILED_CONTAINER\nerror=" .. text(record.error) .. "\nprobableExpression=" .. text(record.probableExpression) .. "\n")
        elseif record.skipped then writer:write("status=SKIPPED\nreason=" .. text(record.skipped) .. "\n")
        else writer:write("status=OK\n") end
    end
    writer:write("\nFAILURES\n")
    if #(audit.failures or {}) == 0 then writer:write("NONE\n") end
    for _, failure in ipairs(audit.failures or {}) do
        writer:write("\nFAILED_CONTAINER\n")
        writeFacts(writer, failure.data, failure.candidate)
        writer:write("stage=" .. text(failure.stage) .. "\nerror=" .. text(failure.error) .. "\n")
        writer:write("probableExpression=" .. text(failure.probableExpression) .. "\noperand A + type(A), operand B + type(B): ")
        writeOperand(writer, failure.operand)
    end
    writer:close()
    if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info("Container V2 failure audit written to Zomboid/Lua/ItemRarity_ContainerV2FailureAudit.txt") end
    return true
end
