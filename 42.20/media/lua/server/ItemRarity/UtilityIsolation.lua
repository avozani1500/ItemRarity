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
    candidate.lightUtility,candidate.fireUtility,candidate.lightTier,candidate.fireTier=nil,nil,nil,nil
    candidate.lightFireFinalTier,candidate.lightFireSelectedFunction=nil,nil
    candidate.explosiveScore,candidate.explosiveFinalTier,candidate.explosivePowerValue,candidate.explosiveRangeValue=nil,nil,nil,nil
    candidate.incendiaryFinalTier,candidate.incendiaryFireRange,candidate.noiseMakerScore,candidate.noiseMakerFinalTier=nil,nil,nil,nil
    candidate.accessoryMechanicalValue,candidate.accessoryMechanicalBaseBenefit=nil,nil
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
    -- Proven zero-benefit accessory policies do not require unrelated weight,
    -- durability or sensory metrics. Preserve their established precedence.
    local accessoryResolved=false
    if candidate.accessoryMechanicalCandidate then
        local policyOk,resolved=I.run(candidate,"Accessory:StructuralPolicy",function() return I.accessoryTrivialPolicy(candidate) end)
        accessoryResolved=policyOk and resolved==true
    end
    if not accessoryResolved then I.run(candidate, "CandidateValidation", function() return I.validate(candidate) end) end
    if candidate.kind=="LITERATURE" and not candidate.isolationStatus then
        I.run(candidate,"Literature:PolicyAdmission",function() return I.literaturePolicy(candidate) end)
    end
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

-- Declared relationship keys are strings, not an invitation to stringify
-- arbitrary bridge objects. This validates representation, not identity.
function I.requireStrings(candidate, stage, source, names)
    for _, name in ipairs(names) do
        local value = nil
        if type(source) == "table" then value = source[name] end
        if type(value) ~= "string" or value == "" then
            I.mark(candidate,stage,(value == nil or value == "") and "PARTIAL_DEFER" or "ERROR_ISOLATED",
                "Required string unavailable: "..name,{value=value,luaType=type(value),field=name})
            return false
        end
    end
    return true
end

-- Light/fire admission is separate from its two scoring axes. A partial
-- discovery is never upgraded by containment. Invalid members cannot set maxima.
function I.lightFireAdmission(c)
    if not c.utilityEligible then return false end
    if not I.requireStrings(c,"LightFire:Admission",c,{"profile"}) then return false end
    if type(c.lightFunction)~="boolean" or type(c.fireFunction)~="boolean" or not (c.lightFunction or c.fireFunction) then
        I.mark(c,"LightFire:Admission","PARTIAL_DEFER","Missing structural light/fire function"); return false
    end
    local names=c.lightFunction and {"lightStrength","lightDistance","estimatedUses"} or {"estimatedUses"}
    if not I.requireNumbers(c,"LightFire:Admission",names) then return false end
    for _,name in ipairs(names) do
        if c.metrics[name]<0 or (name=="estimatedUses" and c.metrics[name]<=0) then
            I.mark(c,"LightFire:Admission","PARTIAL_DEFER","Invalid LightFire magnitude: "..name,{value=c.metrics[name]}); return false
        end
    end
    return true
end

function I.positiveEffectAdmission(c,stage,names)
    if not I.requireStrings(c,stage,c,{"profile"}) or not I.requireNumbers(c,stage,names) then return false end
    for _,name in ipairs(names) do if c.metrics[name]<=0 then
        I.mark(c,stage,"PARTIAL_DEFER","Nonpositive effect: "..name,{value=c.metrics[name]}); return false
    end end
    return true
end

function I.accessoryTrivialPolicy(c)
    if not c.accessoryMechanicalCandidate or c.accessoryMechanicalSpecialBehavior or c.accessoryTimepiecePartial then return false end
    if type(c.metrics)~="table" then return false end
    for _,name in ipairs({"biteDefense","scratchDefense","bulletDefense","insulation","windResistance","waterResistance"}) do
        if not I.finite(c.metrics[name]) or c.metrics[name]~=0 then return false end
    end
    c.accessoryMechanicalBaseBenefit=0
    c.accessoryMechanicalDurabilityFactor=1
    c.accessoryMechanicalFunctionalCost=0
    c.accessoryMechanicalValue=0
    c.accessoryMechanicalValueStatus="MECHANICALLY_TRIVIAL"
    return true
end

-- Fish references are API species, including species with no loot row.
-- Validate each configuration before it can contribute to bait denominators.
-- minLength=10 is the existing Fishing size-model default, not a missing score.
function I.fishConfigurations(configurations, excluded)
    if configurations == nil then return {} end
    assert(type(configurations)=="table","Invalid global Fishing configuration collection")
    local valid={}
    for index,configuration in ipairs(configurations) do
        local owner={kind="FISH",data={fullType="<Fishing configuration "..index..">"}}
        I.run(owner,"Fish:ConfigurationAdmission",function()
            if type(configuration)~="table" then
                I.mark(owner,"Fish:ConfigurationAdmission","ERROR_ISOLATED","Invalid fish configuration",{value=configuration}); return
            end
            if configuration.itemType then
                owner.data.fullType=configuration.itemType
                if type(configuration.itemType)=="string" then owner.data.module=configuration.itemType:match("^([^%.]+)") end
            end
            if configuration.isHaveDifferentSizes==false then return end
            for _,flag in ipairs({"isHaveDifferentSizes","isPredator"}) do
                if configuration[flag]~=nil and type(configuration[flag])~="boolean" then
                    I.mark(owner,"Fish:ConfigurationAdmission","ERROR_ISOLATED","Invalid Fish flag: "..flag,{value=configuration[flag]}); return
                end
            end
            if not I.requireStrings(owner,"Fish:ConfigurationAdmission",configuration,{"itemType"}) then return end
            if excluded and excluded[configuration.itemType] then return end
            if not I.requireFields(owner,"Fish:ConfigurationAdmission",configuration,{"maxWeight","maxLength","weightFactor"}) then return end
            if configuration.minLength~=nil and not I.requireFields(owner,"Fish:ConfigurationAdmission",configuration,{"minLength"}) then return end
            if configuration.maxWeight<=0 or configuration.weightFactor<=0 or configuration.maxLength<=(configuration.minLength or 10) then
                I.mark(owner,"Fish:ConfigurationAdmission","PARTIAL_DEFER","Invalid fish size range",{
                    maxWeight=configuration.maxWeight,maxLength=configuration.maxLength,minLength=configuration.minLength,weightFactor=configuration.weightFactor}); return
            end
            if type(configuration.lure)~="table" then
                I.mark(owner,"Fish:ConfigurationAdmission","PARTIAL_DEFER","Missing fish bait profile"); return
            end
            for bait,value in pairs(configuration.lure) do
                if type(bait)~="string" or not I.finite(value) or value<0 then
                    I.mark(owner,"Fish:ConfigurationAdmission","ERROR_ISOLATED","Invalid bait coefficient",{bait=bait,value=value}); return
                end
            end
            valid[#valid+1]=configuration
        end)
    end
    return valid
end

function I.literaturePolicy(candidate)
    if not candidate.utilityEligible then return false end -- preserve SPECIAL_PARTIAL
    if not I.requireFields(candidate,"Literature:PolicyAdmission",candidate,{"utility"}) then return false end
    if not I.requireStrings(candidate,"Literature:PolicyAdmission",candidate,{"functionalGroup","literatureFinalTier"}) then return false end
    local tiers={COMMON=true,UNCOMMON=true,RARE=true,EPIC=true,EXOTIC=true}
    if not tiers[candidate.literatureFinalTier] then
        I.mark(candidate,"Literature:PolicyAdmission","ERROR_ISOLATED","Invalid Literature policy tier",{value=candidate.literatureFinalTier}); return false
    end
    local group=candidate.functionalGroup
    if group=="SKILLBOOK" then
        if not I.requireFields(candidate,"Literature:PolicyAdmission",candidate,{"literatureStructuralTier"}) then return false end
    elseif group=="MAP" then
        if not I.requireStrings(candidate,"Literature:PolicyAdmission",candidate,{"mapId"}) then return false end
    elseif group=="RECIPE_LITERATURE" then
        if not I.requireFields(candidate,"Literature:PolicyAdmission",candidate,{
            "recipeUniqueCount","recipeValue","recipeScarcityStrength","recipeFinalScore"}) then return false end
    elseif group=="ENTERTAINMENT_LITERATURE" or group=="TRIVIAL_LITERATURE" then
        if not I.requireNumbers(candidate,"Literature:PolicyAdmission",{"unhappy","boredom","stress"}) then return false end
    end
    return true
end

-- Optional builders may legitimately reject with nil. Only exceptions and
-- invalid returned candidates are isolated; rejection is not a fake failure.
function I.optionalDiscover(data, kind, action)
    local owner={data=data,kind=kind}
    local ok,candidate=I.run(owner,kind..":CandidateDiscovery",action)
    if not ok then return owner end
    if candidate==nil then return nil end
    return I.discover(data,function() return candidate end)
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
