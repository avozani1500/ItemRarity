-- Explicit DEV-only A/B command. Loading this file installs no observers and
-- performs no scans, writes, reloads, candidate construction or publication.
ItemRarityBatchComparison = ItemRarityBatchComparison or { snapshots={} }
local D = ItemRarityBatchComparison
local kinds = { CONTAINER=true, FIREARM=true, MELEE_WEAPON=true }
local batch2Kinds = { CLOTHING=true, ACCESSORY=true, FOOD=true, MEDICAL=true }
local batch3Kinds = { MAGAZINE=true, AMMO=true, FISH=true, LITERATURE=true }
local batch4Kinds = { LIGHTFIRE=true, EXPLOSIVE=true, INCENDIARY=true, NOISE_MAKER=true, ACCESSORY=true }
local admissions = {
    ["Container:ReferenceAdmission"]=true,
    ["Firearm:ReferenceAdmission"]=true,
    ["Melee:ReferenceAdmission"]=true,
    ["Clothing:ReferenceAdmission"]=true,
    ["Food:ReferenceAdmission"]=true,
    ["Medical:ReferenceAdmission"]=true,
    ["Magazine:Score"]=true,
    ["Ammo:Inheritance"]=true,
    ["Fish:CandidateAdmission"]=true,
    ["Literature:PolicyAdmission"]=true,
    ["LightFire:Admission"]=true,
    ["Explosive:Admission"]=true,
    ["Incendiary:Admission"]=true,
    ["NoiseMaker:Admission"]=true,
}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}; seen[value] = result
    for k, v in pairs(value) do result[k] = copy(v, seen) end
    return result
end

local function keys(t)
    local result = {}
    for k in pairs(t) do result[#result+1] = k end
    table.sort(result, function(a,b) return tostring(a) < tostring(b) end)
    return result
end

local function diff(a, b, path, out)
    if type(a) == "table" or type(b) == "table" then
        local all = {}
        local left, right = {}, {}
        if type(a) == "table" then left=a end
        if type(b) == "table" then right=b end
        for k in pairs(left) do all[k] = true end
        for k in pairs(right) do all[k] = true end
        if type(a) ~= type(b) then out[#out+1]=path.." type before="..type(a).." after="..type(b) end
        for _, k in ipairs(keys(all)) do diff(left[k], right[k], path .. "." .. tostring(k), out) end
    elseif a ~= b then
        out[#out+1] = path .. " before=" .. tostring(a) .. " (" .. type(a) .. ") after=" .. tostring(b) .. " (" .. type(b) .. ")"
    end
end

local function priorClothingDefer(c)
    if c.kind ~= "CLOTHING" and c.failedUtilityKind ~= "CLOTHING" then return nil end
    local m=c.metrics
    if type(m) ~= "table" then return "OTHER" end
    if m.biteDefense == nil then return "MISSING_BITE_DEFENSE" end
    for _,name in ipairs({"biteDefense","scratchDefense","bulletDefense","durability","weight","runSpeedModifier",
        "combatSpeedModifier","visionModifier","hearingModifier","discomfortModifier","insulation","windResistance","waterResistance"}) do
        if not ItemRarityUtilityIsolation.finite(m[name]) then return "OTHER" end
    end
    if type(c.profile) ~= "string" or type(c.functionalGroup) ~= "string" or type(c.clothingDiscovery) ~= "table" then return "OTHER" end
    local regions=c.clothingDiscovery.coveredRegions
    if type(regions) ~= "table" or #regions==0 then return "MISSING_BODY_REGIONS" end
    return nil
end

local function structuralPolicy(c)
    if c.structuralPolicy then return c.structuralPolicy end
    if c.kind == "CLOTHING" and c.mechanicalValueStatus == "MECHANICALLY_TRIVIAL" then return "CLOTHING_TRIVIAL" end
    if c.kind == "ACCESSORY" and c.accessoryMechanicalValueStatus == "MECHANICALLY_TRIVIAL" then
        if c.accessoryTrivialCosmeticEligible then return "ACCESSORY_TRIVIAL_COSMETIC" end
        return "ACCESSORY_POLICY3"
    end
    return nil
end

local function capture(observed, admitted, everAdmitted, selected, batch, fishReferences)
    local rows, references, missing, deferAudit = {}, {}, 0, {}
    local results = ItemRarityScanner.results
    for _, id in ipairs(keys(results)) do
        local data = results[id]
        local c = observed[data]
        local kind = data.failedUtilityKind or data.utilityKind
        if selected[kind] then
            if not c or c.data ~= data then
                missing = missing + 1
                print("[ItemRarity][BATCH_DIFF] " .. id .. " observation=missing")
            else
                local policyResolved = structuralPolicy(c)
                local state = "PARTIAL"
                if c.isolationStatus then
                    state = c.isolationStatus == "ERROR_ISOLATED" and "ERROR_ISOLATED" or "PARTIAL"
                elseif policyResolved then state="STRUCTURAL_POLICY_RESOLVED"
                elseif c.kind=="ACCESSORY" and c.accessoryMechanicalValueStatus=="MECHANICAL_VALUE_KNOWN" then state="STRUCTURAL_POLICY_RESOLVED"
                elseif c.kind=="AMMO" and c.utilityEligible and c.ammoInheritedFirearmTier then state="SAFE"
                elseif c.utilityEligible == true and ItemRarityUtilityIsolation.finite(c.utility) then state="SAFE"
                elseif c.kind == "UNSUPPORTED" then state="UNSUPPORTED" end
                local member = admitted[c] == true and not c.isolationStatus
                local group = c.containerV2Group or c.subgroup or kind
                local reference, absoluteReference = false, false
                -- Membership is observed at the real admission boundary.
                -- Representative identities below are RECONSTRUCTED using the
                -- existing deterministic fullType/profile deduplication rule;
                -- private percentile/anchor arrays are not directly exposed.
                if member and (kind == "MELEE_WEAPON" or selected == batch2Kinds or selected==batch4Kinds or id:match("^Base%.")) then
                    local refKey = kind .. ":" .. tostring(group) .. ":" .. tostring(c.profile)
                    if kind == "MELEE_WEAPON" then refKey = kind .. ":" .. tostring(c.profile) end
                    if not references[refKey] then references[refKey]=true; reference=true end
                    if kind == "FIREARM" then
                        local absoluteKey = "FIREARM_ABSOLUTE:" .. tostring(c.profile)
                        if not references[absoluteKey] then references[absoluteKey]=true; absoluteReference=true end
                    end
                end
                local finalScore, policy = data.firearmFinalScore, "TIER_MATRIX_NO_SCALAR"
                if kind == "FIREARM" then policy="FIREARM_SCORE"
                elseif kind == "CLOTHING" then finalScore=data.clothingAdjustedScore; policy="CLOTHING_C1_IF_AVAILABLE"
                elseif kind == "FOOD" then finalScore=data.foodFinalScore; policy="FOOD_SCORE" end
                if kind=="MAGAZINE" then finalScore=c.magazineFinalScore; policy="MAGAZINE_CONTEXTUAL"
                elseif kind=="FISH" then finalScore=c.utility; policy="FISH_YIELD_AND_POSITION"
                elseif kind=="LITERATURE" then finalScore=c.utility; policy="LITERATURE_STRUCTURAL_OR_ABSOLUTE"
                elseif kind=="AMMO" then finalScore=nil; policy="AMMO_TIER_INHERITANCE_NO_SCORE" end
                if selected==batch4Kinds then
                    finalScore=c.utility;policy="ABSOLUTE_EFFECT_OR_LIGHTFIRE"
                    if kind=="ACCESSORY" then finalScore=c.accessoryMechanicalValue;policy="ACCESSORY_STRUCTURAL_POLICY" end
                end
                local slot = nil
                if type(c.equipmentGraph) == "table" then slot=c.equipmentGraph.slotId end
                local oldDefer = priorClothingDefer(c)
                local classification = "OTHER"
                if policyResolved and not c.isolationStatus then classification="STRUCTURAL_POLICY_RESOLVED"
                elseif kind == "ACCESSORY" or data.category == "ACCESSORY" or c.accessoryMechanicalCandidate then classification="ACCESSORY"
                elseif data.category and data.category ~= "CLOTHING" and data.category ~= "UNKNOWN" then classification="OTHER"
                elseif c.isolationStatus then classification="MECHANICAL_RANKING_INCOMPLETE"
                elseif member then classification="MECHANICAL_RANKING_ELIGIBLE" end
                if oldDefer then
                    deferAudit[oldDefer]=deferAudit[oldDefer] or {}
                    deferAudit[oldDefer][classification]=(deferAudit[oldDefer][classification] or 0)+1
                end
                rows[id] = {
                    fullType=id,utilityKind=c.kind,comparisonKind=kind,candidateState=state,utilityState=state,
                    structuralPolicy=policyResolved,rankingEligible=member,rankingMembership=member,
                    rankingExcludedByPolicy=c.structuralPolicy ~= nil,
                    priorDeferReason=oldDefer,deferClassification=classification,
                    classifier=data.category,
                    isolated=c.isolationStatus ~= nil,admittedBeforeFailure=everAdmitted[c] == true,
                    population={admitted=member,group=group,profile=c.profile,reference=reference,absoluteReference=absoluteReference,
                        normalization=c.normalizationGroup,slot=slot,
                        comparisonGroup=c.functionalComparisonGroup,comparisonProfiles=c.functionalComparisonProfileCount},
                    utilityScore=c.utility, publishedUtility=data.utility,
                    -- Container/Melee choose tiers through a matrix. They do
                    -- not have a final scalar; do not invent one for this audit.
                    finalScore=finalScore, finalScorePolicy=policy,
                    finalTier=data.finalRarityTier,
                    baseScarcityTier=data.baseScarcityTier,
                    metrics=copy(c.metrics), components=copy(c.utilityComponents),
                    percentiles=copy(c.metricPercentiles), profileCount=c.profileCount,
                    relationships=copy(c.ammoCompatibleFirearms),
                    fishReferences=kind=="FISH" and copy(fishReferences) or nil,
                }
            end
        end
    end
    return { rows=rows, missing=missing,batch=batch,deferAudit=deferAudit,
        report=copy(ItemRarityUtilityCalculator.lastItemIsolationReport),
        signature=ItemRarityScanner.lastScanSignature,
        fingerprint=ItemRarityScanner.lastScanSignatureFingerprint }
end

function D.compare(beforeLabel, afterLabel)
    local a, b = D.snapshots[beforeLabel], D.snapshots[afterLabel]
    assert(a and b, "Both in-memory snapshots are required")
    assert(a.batch == b.batch,"Cannot compare different batches")
    local selected = a.batch==4 and batch4Kinds or a.batch == 3 and batch3Kinds or a.batch == 2 and batch2Kinds or kinds
    local all, compared, changed, membership, counts, perKindChanges = {}, 0, 0, 0, {}, {}
    local trivialRegressions=0
    for id in pairs(a.rows) do all[id] = true end
    for id in pairs(b.rows) do all[id] = true end
    for _, id in ipairs(keys(all)) do
        local old, new = a.rows[id], b.rows[id]
        local delta, popDelta = {}, {}
        diff(old, new, "row", delta)
        diff(old and old.population, new and new.population, "population", popDelta)
        if #popDelta > 0 then membership = membership + 1 end
        -- Losing a healthy item (or changing it to PARTIAL) is a regression too.
        if old and (old.candidateState == "SAFE" or old.candidateState == "STRUCTURAL_POLICY_RESOLVED") then
            compared = compared + 1
            local kind=old.comparisonKind or old.utilityKind
            counts[kind] = (counts[kind] or 0) + 1
            if #delta > 0 then changed = changed + 1; perKindChanges[kind]=(perKindChanges[kind] or 0)+1 end
        end
        if new and (new.structuralPolicy == "CLOTHING_TRIVIAL" or new.structuralPolicy == "ACCESSORY_TRIVIAL_COSMETIC")
            and new.finalTier ~= "COMMON" then trivialRegressions=trivialRegressions+1 end
        if old and old.structuralPolicy and (not new or new.structuralPolicy ~= old.structuralPolicy) then trivialRegressions=trivialRegressions+1 end
        if #delta > 0 then print("[ItemRarity][BATCH_DIFF] " .. id .. " | " .. table.concat(delta, " | ")) end
    end
    local contamination = "UNKNOWN"
    -- With no isolated/partial failures, no invalid item can contaminate this
    -- run. If failure paths were exercised, reconstructing membership alone
    -- cannot prove that private anchors were rebuilt: never print a false zero.
    if a.missing == 0 and b.missing == 0
        and a.report.isolatedItemFailures == 0 and b.report.isolatedItemFailures == 0
        and a.report.partialItems == 0 and b.report.partialItems == 0 then contamination = 0 end
    -- Clothing admission is directly observed. A candidate rejected BEFORE
    -- ever joining a population cannot contaminate its ranks. Late failures
    -- still require rebuild evidence and remain UNKNOWN, not a false pass.
    local clothingContamination = 0
    local mechanicalCompared, structuralCompared = 0, 0
    for _,row in pairs(a.rows) do
        if row.comparisonKind == "CLOTHING" then
            if row.candidateState == "SAFE" then mechanicalCompared=mechanicalCompared+1
            elseif row.candidateState == "STRUCTURAL_POLICY_RESOLVED" then structuralCompared=structuralCompared+1 end
        end
    end
    for _, snapshot in ipairs({a,b}) do
        if snapshot.missing > 0 then clothingContamination="UNKNOWN" end
        for _,row in pairs(snapshot.rows) do
            if row.comparisonKind == "CLOTHING" then
                if row.isolated and row.admittedBeforeFailure then clothingContamination="UNKNOWN" end
                if (row.isolated or row.rankingExcludedByPolicy) and row.rankingMembership then clothingContamination="UNKNOWN" end
            end
        end
    end
    local result = { HEALTHY_ITEMS_COMPARED=compared, HEALTHY_ITEM_REGRESSION=changed,
        POPULATION_MEMBERSHIP_CHANGES=membership, POPULATION_CONTAMINATION=contamination,
        OBSERVATION_MISSING=a.missing+b.missing }
    if a.missing+b.missing > 0 then result.HEALTHY_ITEM_REGRESSION="UNKNOWN" end
    for _, name in ipairs(keys(result)) do print("[ItemRarity][BATCH] " .. name .. "=" .. tostring(result[name])) end
    for _, kind in ipairs(keys(selected)) do
        result[kind.."_HEALTHY_COMPARED"]=counts[kind] or 0
        print("[ItemRarity][BATCH] " .. kind .. "_HEALTHY_COMPARED=" .. tostring(counts[kind] or 0))
    end
    if a.batch==3 or a.batch==4 then
        for _,kind in ipairs(keys(selected)) do
            local status=0
            if (counts[kind] or 0)==0 then status="NOT_VALIDATED_NO_HEALTHY_ITEMS" end
            if a.missing+b.missing>0 then status="UNKNOWN" end
            for _,snapshot in ipairs({a,b}) do
                for _,row in pairs(snapshot.rows) do
                    if row.comparisonKind==kind and row.isolated and row.admittedBeforeFailure then status="UNKNOWN" end
                end
                for _,entry in ipairs(snapshot.report.entries or {}) do
                    if kind=="FISH" and entry.utility=="FISH" and (entry.stage=="Fish:Score" or entry.stage=="Fish:Assignment") then
                        status="UNKNOWN" -- late rebuild evidence is covered by fixtures, not inferred from A/B
                    end
                end
            end
            result[kind.."_POPULATION_CONTAMINATION"]=status
            local regression=(counts[kind] or 0)>0 and (perKindChanges[kind] or 0) or "NOT_VALIDATED_NO_HEALTHY_ITEMS"
            result[kind.."_HEALTHY_ITEM_REGRESSION"]=regression
            print("[ItemRarity][BATCH] "..kind.."_POPULATION_CONTAMINATION="..tostring(status))
            print("[ItemRarity][BATCH] "..kind.."_HEALTHY_ITEM_REGRESSION="..tostring(regression))
        end
    end
    if a.batch == 2 then
        result.CLOTHING_HEALTHY_COMPARED=counts.CLOTHING or 0
        result.CLOTHING_HEALTHY_REGRESSION=perKindChanges.CLOTHING or 0
        result.CLOTHING_POPULATION_CONTAMINATION=clothingContamination
        result.TRIVIAL_POLICY_REGRESSION=trivialRegressions
        print("[ItemRarity][BATCH] CLOTHING_MECHANICAL_COMPARED="..mechanicalCompared.."; CLOTHING_STRUCTURAL_COMPARED="..structuralCompared)
        print("[ItemRarity][BATCH] CLOTHING_HEALTHY_REGRESSION="..tostring(perKindChanges.CLOTHING or 0))
        print("[ItemRarity][BATCH] CLOTHING_POPULATION_CONTAMINATION="..tostring(clothingContamination))
        print("[ItemRarity][BATCH] TRIVIAL_POLICY_REGRESSION="..trivialRegressions)
        for _, reason in ipairs(keys(b.deferAudit)) do
            local total=0
            for _, classification in ipairs(keys(b.deferAudit[reason])) do
                print("[ItemRarity][CLOTHING_DEFER_AUDIT] "..reason.." -> "..classification.."="..b.deferAudit[reason][classification])
                total=total+b.deferAudit[reason][classification]
            end
            print("[ItemRarity][CLOTHING_DEFER_AUDIT] "..reason.." TOTAL="..total)
        end
        -- Sanity references only; never used by classification or scoring.
        for _, id in ipairs({"Base.Briefs_SmallTrunks_Black","Base.Boxers_Hearts"}) do
            local row=b.rows[id]
            print("[ItemRarity][CLOTHING_SANITY] "..id.." tier="..tostring(row and row.finalTier).." policy="..tostring(row and row.structuralPolicy))
        end
    end
    local match = a.signature ~= nil and b.signature ~= nil and a.signature == b.signature
    print("[ItemRarity][BATCH] SECOND_RESCAN=" .. (match and "MATCH" or "MISMATCH"))
    print("[ItemRarity][BATCH] COMPARISON_SCOPE=SAME_SESSION_A_B; REFERENCES=RECONSTRUCTED_FROM_OBSERVED_ADMISSION")
    D.lastComparison = result
    return result
end

function D.run(label, batch)
    assert(label == "A" or label == "B", "Use A or B")
    assert(not D.running, "Batch comparison already running")
    if label == "B" then assert(D.snapshots.A, "Run A first") end
    batch = batch or (label == "B" and D.snapshots.A.batch) or 1
    assert(batch == 1 or batch == 2 or batch==3 or batch==4,"Use batch 1, 2, 3 or 4")
    if label == "B" then assert(batch == D.snapshots.A.batch,"Use the same batch for A and B") end
    local selected = batch==4 and batch4Kinds or batch == 3 and batch3Kinds or batch == 2 and batch2Kinds or kinds
    local I = assert(ItemRarityUtilityIsolation, "Isolation module unavailable")
    assert(ItemRarityScanner and ItemRarityScanner.rescan, "Scanner unavailable")
    local originalRun, originalDiscover = I.run, I.discover
    local oldReport = ItemRarityUtilityCalculator.lastItemIsolationReport
    local observed, admitted, everAdmitted = {}, {}, {}
    local fishReferences={}
    D.running = true
    if label == "A" then D.snapshots = {}; D.lastComparison = nil end
    D.snapshots[label] = nil
    I.run = function(candidate, stage, action)
        local ok, value = originalRun(candidate, stage, action)
        -- Augmentation creates reference proxies with the SAME fullType but
        -- a different data table. Never let a proxy replace the actual row.
        if candidate.data then observed[candidate.data] = candidate end
        if candidate.data and (candidate.kind=="FISH" or candidate.failedUtilityKind=="FISH") then
            if candidate.isolationStatus then fishReferences[candidate.data.fullType]=nil
            elseif stage=="Fish:Score" and ok then
                fishReferences[candidate.data.fullType]={metrics=copy(candidate.metrics),components=copy(candidate.utilityComponents),
                    utility=candidate.utility,tier=candidate.fishFinalTier,profileCount=candidate.profileCount}
            end
        end
        if admissions[stage] then
            -- Melee admission returns nil on success; the other two return true.
            admitted[candidate] = ok and not candidate.isolationStatus
                and (stage == "Melee:ReferenceAdmission" or stage == "Medical:ReferenceAdmission" or value == true
                    or ((stage=="Magazine:Score" or stage=="Ammo:Inheritance" or stage=="Fish:CandidateAdmission") and candidate.utilityEligible==true))
            if admitted[candidate] then everAdmitted[candidate]=true end
        end
        return ok, value
    end
    I.discover = function(data, action)
        local candidate = originalDiscover(data, action)
        observed[data] = candidate
        return candidate
    end
    -- Cleanup only: global errors are rethrown, not isolated or swallowed.
    local ok, err = pcall(ItemRarityScanner.rescan, "DEV batch " .. label)
    I.run, I.discover = originalRun, originalDiscover
    D.running = false
    if not ok then
        print("[ItemRarity][BATCH] GLOBAL_SCAN_COMPLETED=no; GLOBAL_SCAN_FATALS=1")
        error(err)
    end
    local report = ItemRarityUtilityCalculator.lastItemIsolationReport
    assert(report and report ~= oldReport and report.calculateCompleted, "No fresh completed calculation")
    D.snapshots[label] = capture(observed, admitted, everAdmitted, selected, batch, fishReferences)
    print("[ItemRarity][BATCH] LOT="..batch.."; SNAPSHOT=" .. label .. "; GLOBAL_SCAN_COMPLETED=yes; GLOBAL_SCAN_FATALS=0")
    if label == "B" then return D.compare("A", "B") end
    return true
end

-- Read-only follow-up: inspects existing facts/snapshots, never constructs an
-- InventoryItem, invokes discovery/scoring, or changes the live registry.
function D.auditEffects()
    local function call(object,name)
        if object==nil then return nil end
        local ok,fn=pcall(function() return object[name] end)
        if not ok or type(fn)~="function" then return nil end
        local worked,value=pcall(fn,object)
        if worked then return value end
        return nil
    end
    local function positive(v) return type(v)=="number" and v>0 end
    local manager=assert(getScriptManager(),"ScriptManager unavailable")
    local all=assert(call(manager,"getAllItems"),"ScriptItems unavailable")
    local scripts={}
    local function add(item)
        local id=call(item,"getFullName")
        if id then scripts[tostring(id)]=item end
    end
    if type(all)=="table" then for _,item in pairs(all) do add(item) end
    else for index=0,all:size()-1 do add(all:get(index)) end end
    local results=assert(ItemRarityScanner.results)
    local snapshot=D.snapshots.B or D.snapshots.A
    assert(snapshot and snapshot.batch==4,"Run batch 4 A/B first")
    -- Names below select audit sanity rows only; never determine eligibility.
    local sanity={['Base.Firecracker']=true,['Base.Firecracker_Crafted']=true,['Base.NoiseTrap']=true,['Base.SmokeBomb']=true}
    local counts={}
    for _,kind in ipairs({'EXPLOSIVE','INCENDIARY','NOISE_MAKER'}) do
        counts[kind]={detected=0,gatePass=0,built=0,admitted=0,scored=0,published=0}
    end
    for _,id in ipairs(keys(scripts)) do
        local item=scripts[id]
        local power,range,fire,noise=call(item,'getExplosionPower'),call(item,'getExplosionRange'),call(item,'getFireRange'),call(item,'getNoiseRange')
        local category=ItemRarityItemClassifier.getFunctionalCategory(id)
        local display=call(item,'getDisplayCategory')
        local row=results[id]
        local observed=snapshot.rows[id]
        local kind=row and (row.failedUtilityKind or row.utilityKind)
        local gate=category=='AMMO' and string.lower(tostring(display))=='explosives'
        local detected={EXPLOSIVE=positive(power) and positive(range),INCENDIARY=positive(fire),NOISE_MAKER=positive(noise)}
        local relevant=sanity[id] or counts[kind]~=nil or string.lower(tostring(display))=='explosives' or string.lower(tostring(display))=='wepbomb'
        for family,yes in pairs(detected) do
            if yes then
                relevant=true
                local n=counts[family];n.detected=n.detected+1
                if gate then n.gatePass=n.gatePass+1 end
            end
        end
        if counts[kind] then
            local n=counts[kind];n.built=n.built+1
            if observed and observed.rankingMembership then n.admitted=n.admitted+1 end
            if row.utility~=nil and not row.utilityIsolationStatus then n.scored=n.scored+1 end
            if ItemRarity.registry[id] then n.published=n.published+1 end
        end
        if relevant then
            local reason=not gate and 'PREEXISTING_CATEGORY_DISPLAY_GATE' or 'INSPECT_EFFECT_EXCLUSIONS_OR_PRECEDENCE'
            if observed and observed.candidateState=='SAFE' then reason='SCORED_OBSERVED' end
            print('[ItemRarity][BATCH4_PIPELINE] '..id..' | display='..tostring(display)..' | classifier='..tostring(category)
                ..' | lootClassifier='..tostring(row and row.category)..' | power/range/fire/noise='..tostring(power)..'/'..tostring(range)..'/'..tostring(fire)..'/'..tostring(noise)
                ..' | candidateKind='..tostring(kind)..' | admitted='..tostring(observed and observed.rankingMembership)
                ..' | score='..tostring(row and row.utility)..' | finalTier='..tostring(row and row.finalRarityTier)
                ..' | diagnosticState='..tostring(observed and observed.candidateState)..' | registryPublished='..tostring(ItemRarity.registry[id]~=nil)
                ..' | reason='..reason)
        end
    end
    for _,kind in ipairs(keys(counts)) do
        local n=counts[kind]
        print('[ItemRarity][BATCH4_PIPELINE_TOTAL] '..kind..' | positiveScriptEffects='..n.detected..' | staticGatePass='..n.gatePass
            ..' | finalCandidateRows='..n.built..' | admitted='..n.admitted..' | scored='..n.scored..' | published='..n.published)
    end
    print('[ItemRarity][BATCH4_PIPELINE] SCOPE=EXISTING_RESULTS_AND_SNAPSHOTS; RUNTIME_CREATIONS=0; MISSING_SCRIPT_GETTERS=UNKNOWN_NOT_ZERO')
    return counts
end

return D
