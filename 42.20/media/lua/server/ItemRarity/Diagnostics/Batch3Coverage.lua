-- Explicit forensic observer. No OnCreate, runtime construction, file writer,
-- formula, relationship resolver or registry changes. Uses the existing A/B scan.
ItemRarityBatch3Coverage=ItemRarityBatch3Coverage or {}
local A=ItemRarityBatch3Coverage
local function call(object,method)
    if object==nil then return nil end
    local found,fn=pcall(function() return object[method] end)
    if not found or type(fn)~="function" then return nil end
    local ok,value=pcall(fn,object)
    if ok then return value end
    return nil
end
local function show(value)
    local ok,text=pcall(tostring,value)
    return (ok and text or "<unprintable>").." ["..type(value).."]"
end
local function scripts()
    local result={}
    local manager=getScriptManager and getScriptManager()
    local collection=call(manager,"getAllItems") or call(manager,"getAllScriptItems")
    local function add(item)
        local id=call(item,"getFullName") or call(item,"getFullType")
        if id then result[tostring(id)]=item end
    end
    if type(collection)=="table" then for _,item in pairs(collection) do add(item) end
    elseif collection then
        local size=call(collection,"size") or call(collection,"getSize")
        if type(size)=="number" then for index=0,size-1 do
            local ok,item=pcall(function() return collection:get(index) end)
            if ok then add(item) end
        end end
    end
    return result
end
local function sorted(t)
    local out={}; for k in pairs(t) do out[#out+1]=k end; table.sort(out); return out
end
function A.run(label)
    require "ItemRarity/Diagnostics/BatchComparison"
    assert(label=="A" or label=="B","Use A or B")
    local I=assert(ItemRarityUtilityIsolation)
    local originalRun,originalDiscover=I.run,I.discover
    local observed,refs={},{}
    I.run=function(candidate,stage,action)
        local before=candidate.firearmAmmoType
        local beforeKind=candidate.kind
        local ok,value=originalRun(candidate,stage,action)
        if candidate.data then observed[candidate.data]=candidate end
        if stage=="Ammo:FirearmReference" and candidate.data then
            local id=candidate.data.fullType
            refs[id]=refs[id] or {}
            refs[id][#refs[id]+1]={data=candidate.data,key=before,after=candidate.firearmAmmoType,
                kind=beforeKind,state=candidate.utilityState,reason=candidate.ineligibleReason,
                tier=candidate.publishedFirearmTier or candidate.firearmFinalTier,
                isolated=candidate.isolationStatus~=nil}
        end
        return ok,value
    end
    I.discover=function(data,action)
        local candidate=originalDiscover(data,action); observed[data]=candidate; return candidate
    end
    local ok,result=pcall(ItemRarityBatchComparison.run,label,3)
    I.run,I.discover=originalRun,originalDiscover
    if not ok then error(result) end
    local all=scripts()
    local rows=ItemRarityScanner.results
    local log={firearms={},literature={},counts={detected=0,structural=0,scored=0,partial=0,healthy=0,otherKind=0},ammo={}}
    for _,id in ipairs(sorted(refs)) do
        for index,ref in ipairs(refs[id]) do if ref.isolated then
            local row=rows[id]; local c=row and observed[row]
            local record={fullType=id,published=row~=nil,finalTier=row and row.finalRarityTier,
                scriptAmmoType=call(all[id],"getAmmoType"),candidateAmmoType=c and c.firearmAmmoType,
                referenceAmmoType=ref.key,referenceAfter=ref.after,referenceKind=ref.kind,
                referenceIsPublishedRow=row==ref.data,source=row and (row.source or "LOOT_BACKED"),
                reason=ref.reason,candidateSource=c and c.firearmAmmoTypeSource}
            log.firearms[#log.firearms+1]=record
            print("[ItemRarity][B3_REFERENCE] "..id.." | published="..tostring(record.published).." | FinalTier="..show(record.finalTier)
                .." | ScriptItem="..show(record.scriptAmmoType).." | Candidate="..show(record.candidateAmmoType)
                .." | Reference="..show(record.referenceAmmoType).." | source="..show(record.source)
                .." | samePublishedRow="..tostring(record.referenceIsPublishedRow).." | candidateSource="..show(record.candidateSource))
        end end
    end
    for _,id in ipairs(sorted(rows)) do
        local row=rows[id]; local c=observed[row]
        local scriptType=call(all[id],"getType")
        local itemType=call(all[id],"getItemType")
        local detected=row.category=="LITERATURE" or row.utilityKind=="LITERATURE" or (c and (c.kind=="LITERATURE" or c.failedUtilityKind=="LITERATURE"))
            or tostring(scriptType)=="Literature" or tostring(itemType)=="base:literature"
        if detected then
            log.counts.detected=log.counts.detected+1
            local healthy=c and c.kind=="LITERATURE" and not c.isolationStatus and c.utilityEligible==true
                and I.finite(c.utility) and c.literatureFinalTier~=nil
            local group=c and c.functionalGroup
            local structural=healthy and (group=="SKILLBOOK" or group=="MAP" or group=="TRIVIAL_LITERATURE")
            if healthy then log.counts.healthy=log.counts.healthy+1 end
            if structural then log.counts.structural=log.counts.structural+1
            elseif healthy then log.counts.scored=log.counts.scored+1
            elseif c and c.kind~="LITERATURE" and c.failedUtilityKind~="LITERATURE" then log.counts.otherKind=log.counts.otherKind+1
            else log.counts.partial=log.counts.partial+1 end
            log.literature[id]={classifier=row.category,kind=c and c.kind,publishedKind=row.utilityKind,group=group,
                eligible=c and c.utilityEligible,utility=c and c.utility,tier=row.finalRarityTier,healthy=healthy,
                state=c and c.utilityState,reason=c and c.ineligibleReason,scriptType=tostring(scriptType)}
            print("[ItemRarity][B3_LITERATURE] "..id.." | classifier="..show(row.category).." | candidate="..show(c and c.kind)
                .." | publishedKind="..show(row.utilityKind).." | group="..show(group).." | eligible="..show(c and c.utilityEligible)
                .." | utility="..show(c and c.utility).." | finalTier="..show(row.finalRarityTier).." | reason="..show(c and c.ineligibleReason))
        end
        if row.utilityKind=="AMMO" or (c and (c.kind=="AMMO" or c.failedUtilityKind=="AMMO")) then
            log.ammo[id]={kind=c and c.kind,eligible=c and c.utilityEligible,tier=c and c.ammoInheritedFirearmTier,
                ammoType=c and c.metrics and c.metrics.ammoType,reason=c and c.ineligibleReason}
            print("[ItemRarity][B3_AMMO] "..id.." | key="..show(log.ammo[id].ammoType).." | eligible="..show(log.ammo[id].eligible)
                .." | inheritedTier="..show(log.ammo[id].tier).." | reason="..show(log.ammo[id].reason))
        end
    end
    for _,key in ipairs(sorted(log.counts)) do print("[ItemRarity][B3_LITERATURE_COUNTS] "..key.."="..log.counts[key]) end
    A[label]=log
    print("[ItemRarity][B3_COVERAGE] SNAPSHOT="..label.."; runtimeCreationsByDiagnostic=0; BASELINE_ACCEPTED=no")
    return log
end
-- Historical gate replay only. The classifier and Literature category gate
-- are byte-identical to d660f37; this is NOT execution of an old calculator.
-- No scan, candidate construction, hooks, callbacks or registry writes.
function A.history()
    local all=scripts()
    local rows=assert(ItemRarityScanner and ItemRarityScanner.results,"No completed scan")
    local classifier=assert(ItemRarityItemClassifier)
    local snapshot=A.A or A.B
    local count={literatureDetected=0,preUnknown=0,postUnknown=0,preGate=0,postGate=0}
    for _,id in ipairs(sorted(rows)) do
        local row=rows[id]
        local scriptType=call(all[id],"getType")
        if row.category=="LITERATURE" or row.utilityKind=="LITERATURE" or tostring(scriptType)=="Literature" then
            count.literatureDetected=count.literatureDetected+1
            local category=classifier.getFunctionalCategory(id)
            if category=="UNKNOWN" then count.preUnknown=count.preUnknown+1 end
            if row.category=="UNKNOWN" then count.postUnknown=count.postUnknown+1 end
            if category=="LITERATURE" then count.preGate=count.preGate+1 end
            if row.category=="LITERATURE" then count.postGate=count.postGate+1 end
        end
    end
    for _,key in ipairs(sorted(count)) do
        print("[ItemRarity][B3_HISTORY_GATE] "..key.."="..count[key])
    end
    -- Names select sanity output only; never determine admission or policy.
    for _,id in ipairs({"Base.Book","Base.BookCarpentry1","Base.BookFirstAid1","Base.Magazine","Base.BookPotterySet"}) do
        local script=all[id]
        local category,metadata=classifier.getFunctionalCategory(id)
        local row=rows[id]
        local recorded=snapshot and snapshot.literature[id]
        print("[ItemRarity][B3_HISTORY_ITEM] "..id.." | enumerated="..tostring(script~=nil)
            .." | classifierScript="..show(metadata and metadata._scriptItem~=nil)
            .." | exactLookupSame="..tostring(metadata and metadata._scriptItem==script)
            .." | ScriptType="..show(call(script,"getType"))
            .." | DisplayCategory="..show(call(script,"getDisplayCategory"))
            .." | classifierDisplayCategory="..show(metadata and metadata.displayCategory)
            .." | tags="..show(call(script,"getTags"))
            .." | SkillTrained="..show(call(script,"getSkillTrained"))
            .." | LevelSkillTrained="..show(call(script,"getLvlSkillTrained"))
            .." | NumLevelsTrained="..show(call(script,"getNumLevelsTrained"))
            .." | LearnedRecipes="..show(call(script,"getLearnedRecipes"))
            .." | MapID="..show(call(script,"getMapID"))
            .." | classifier="..show(category).." | rowClassifier="..show(row and row.category)
            .." | utilityKind="..show(row and row.utilityKind)
            .." | candidate="..show(recorded and recorded.kind)
            .." | builderGroup="..show(recorded and recorded.group)
            .." | reason="..show(recorded and recorded.reason)
            .." | PRE_POST_category_gate="..(category=="LITERATURE" and "PASS" or "REJECT_BEFORE_METRICS"))
    end
    local restored,unchanged=0,0
    if snapshot then
        for _,ref in ipairs(snapshot.firearms) do
            local key=ref.candidateAmmoType
            local valid=type(key)=="string" and key~="" and key~="nil"
            if valid and ref.referenceAmmoType=="" then restored=restored+1 else unchanged=unchanged+1 end
            print("[ItemRarity][B3_HISTORY_REFERENCE] "..ref.fullType
                .." | PRE_key="..show(ref.referenceAmmoType).." | POST_key="..show(ref.referenceAmmoType)
                .." | simulated_key="..show(key).." | simulated_admitted="..tostring(valid)
                .." | publishedTier="..show(ref.finalTier))
        end
    end
    print("[ItemRarity][B3_HISTORY] reference_keys_restored="..restored.." | other_references="..unchanged
        .." | snapshotAvailable="..tostring(snapshot~=nil)
        .." | PRE_AMMO_HEALTHY=NOT_MEASURED | PRE_LITERATURE_SCORED=NOT_MEASURED"
        .." | mode=UNCHANGED_GATE_REPLAY_AND_REFERENCE_SIMULATION | registryWrites=0 | runtimeCreations=0 | rescans=0")
    return count
end
return A
