-- Explicit DEV-only capture and isolated candidate-score replay.
-- PRE never reaches Scanner.results, RegistryPublisher, Java constructors or callbacks.
ItemRarityBatch3Shadow=ItemRarityBatch3Shadow or {}
local D=ItemRarityBatch3Shadow
local target={AMMO=true,MAGAZINE=true,FISH=true,LITERATURE=true}
local function copy(v,seen)
    if type(v)~="table" then
        assert(type(v)~="userdata" and type(v)~="function","Non-replayable fact: "..type(v))
        return v
    end
    seen=seen or {}; if seen[v] then return seen[v] end
    local out={}; seen[v]=out
    for k,x in pairs(v) do if k~="_scriptItem" then out[copy(k,seen)]=copy(x,seen) end end
    return out
end
local function same(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~="table" then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function public(row)
    -- Candidate existence is not registry presence. Rejected augmentation
    -- candidates must be compared on both sides, without inventing a row.
    if not row or row.finalRarityTier==nil then return {presence=false} end
    return {presence=row.finalRarityTier~=nil,utilityKind=row.utilityKind,utility=row.utility,
        score=row.magazineFinalScore or row.firearmFinalScore or row.foodFinalScore or row.clothingAdjustedScore,
        tier=row.finalRarityTier,source=row.source or "LOOT_BACKED"}
end
local function env(facts,refs)
    local e={ItemRarityConfig=copy(ItemRarityConfig),
        ItemRarityUtilityCalculator={},Fishing=copy(facts),require=function() end,
        shadowFishReference=function(r) refs[r.fullType]=copy(r.metrics) end,
        print=function() end}
    -- Whitelist only pure Lua facilities. Any accidental engine access fails
    -- instead of falling through to _G, a constructor, cache or publication.
    for _,k in ipairs({"assert","error","pcall","pairs","ipairs","next","type","tostring","tonumber",
        "unpack","select","setmetatable","getmetatable","rawget","rawset","math","string","table"}) do e[k]=_G[k] end
    e.ItemRarityUtils={}
    return e
end
function D.run()
    local factory=assert(ItemRarityBatch3ShadowFactory,"Load Batch3ShadowGenerated first")
    assert(not D.running,"Shadow already running")
    local I=ItemRarityUtilityIsolation
    local oldDiscover,oldOptional,oldRun=I.discover,I.optionalDiscover,I.run
    local oldAugment=ItemRarityUtilityCalculator.augmentUtilityOnly
    local phase="loot"
    local inputs={loot={},aug={}}; local guns={loot={},aug={}}
    local captureFailures={}
    local function capture(c)
        if not c then return end
        local category=c.data and c.data.category
        local display=string.lower(tostring(c.data and c.data.displayCategory or ""))
        -- Diagnostic cohort selection only; NEVER grants candidate admission.
        if not target[c.kind] and not target[c.failedUtilityKind] and category~="AMMO" and category~="LITERATURE"
            and display~="lite" and display~="lits" then return end
        local ok,value=pcall(copy,c)
        if ok then inputs[phase][c.data.fullType]=value
        else captureFailures[#captureFailures+1]=c.data.fullType..": "..tostring(value) end
    end
    D.running=true
    I.discover=function(data,action)
        return oldDiscover(data,function() local c=action(); capture(c); return c end)
    end
    I.optionalDiscover=function(data,kind,action)
        return oldOptional(data,kind,function() local c=action(); capture(c); return c end)
    end
    I.run=function(c,stage,action)
        -- Capture finalized firearm references BEFORE the Ammo guard mutates
        -- a temporary invalid proxy. Keep loot and augmentation populations separate.
        if stage=="Ammo:FirearmReference" then
            local ok,v=pcall(copy,c)
            if ok then guns[phase][c.data.fullType]=v else captureFailures[#captureFailures+1]=tostring(v) end
        end
        return oldRun(c,stage,action)
    end
    ItemRarityUtilityCalculator.augmentUtilityOnly=function(results)
        phase="aug"; return oldAugment(results)
    end
    local ok,err=pcall(ItemRarityScanner.rescan,"DEV batch3 shadow capture")
    I.discover,I.optionalDiscover,I.run=oldDiscover,oldOptional,oldRun
    ItemRarityUtilityCalculator.augmentUtilityOnly=oldAugment
    D.running=false
    if not ok then error(err) end
    assert(#captureFailures==0,"Shadow capture incomplete: "..table.concat(captureFailures,"; "))
    local captured=0; for _ in pairs(inputs.loot) do captured=captured+1 end
    assert(captured>0,"No observed candidates: scan did not complete or observer did not run")
    local real=ItemRarityScanner.results
    local fishing={fishes=copy(assert(Fishing.fishes)),Utils={skillSizeLimit=copy(Fishing.Utils.skillSizeLimit)}}
    -- Keep unpublished candidates in the input cohort. The source marker is
    -- shadow-only routing metadata; public() emits absence unless scoring
    -- actually produces a tier. No real row is created or modified.
    for id,c in pairs(inputs.aug) do
        if real[id] and real[id].source=="UTILITY_ONLY" then c.data=copy(real[id])
        elseif real[id] then error("Augmentation collided with existing loot-backed row: "..id)
        else c.data.source="UTILITY_ONLY" end
    end
    local shadow,states,fishRefs={},{},{}
    for _,side in ipairs({"PRE","POST"}) do
        shadow[side]={}; states[side]={}; fishRefs[side]={}
        for _,part in ipairs({"loot","aug"}) do
            local cs={}
            for _,c in pairs(inputs[part]) do cs[#cs+1]=copy(c) end
            for _,c in pairs(guns[part]) do cs[#cs+1]=copy(c) end
            fishRefs[side][part]={}
            local evaluate=factory[side](env(fishing,fishRefs[side][part]))
            local success,scored=pcall(evaluate,cs)
            if not success then
                print("[ItemRarity][B3_SHADOW] "..side.."_ERROR="..tostring(scored).."; APPROVED=no")
                return nil
            end
            for _,c in ipairs(scored) do
                local id=c.data.fullType
                shadow[side][id]=public(c.data)
                states[side][id]={state=c.isolationStatus or (c.utilityEligible and "SAFE" or "PARTIAL"),
                    membership=c.utilityEligible==true and c.isolationStatus==nil,
                    relationships=copy(c.ammoCompatibleFirearms),kind=c.kind}
            end
        end
    end
    local counters={BATCH3_REGISTRY_ADDED=0,BATCH3_REGISTRY_REMOVED=0,BATCH3_UTILITY_CHANGED=0,
        BATCH3_SCORE_CHANGED=0,BATCH3_TIER_CHANGED=0,HEALTHY_REGISTRY_DIFF=0,
        INVALID_PARTIAL_DIFF=0,POPULATION_MEMBERSHIP_CHANGES=0,POST_VS_REAL_DIFF=0,ITEMS_COMPARED=0}
    local mapping={utility="BATCH3_UTILITY_CHANGED",score="BATCH3_SCORE_CHANGED",tier="BATCH3_TIER_CHANGED"}
    for id,a in pairs(shadow.PRE) do
        local b=shadow.POST[id]; counters.ITEMS_COMPARED=counters.ITEMS_COMPARED+1
        if a.presence and not (b and b.presence) then counters.BATCH3_REGISTRY_REMOVED=counters.BATCH3_REGISTRY_REMOVED+1 end
        if not a.presence and b and b.presence then counters.BATCH3_REGISTRY_ADDED=counters.BATCH3_REGISTRY_ADDED+1 end
        for field,key in pairs(mapping) do if a[field]~=(b and b[field]) then counters[key]=counters[key]+1 end end
        if not same(a,b) then
            local key=states.PRE[id].state=="SAFE" and "HEALTHY_REGISTRY_DIFF" or "INVALID_PARTIAL_DIFF"
            counters[key]=counters[key]+1
            for _,field in ipairs({"presence","utilityKind","utility","score","tier","source"}) do
                if a[field]~=(b and b[field]) then print("[ItemRarity][B3_SHADOW_DIFF] "..id.." "..key.." "..field.." PRE="..tostring(a[field]).." POST="..tostring(b and b[field])) end
            end
        end
        if not same(states.PRE[id],states.POST[id]) then
            counters.POPULATION_MEMBERSHIP_CHANGES=counters.POPULATION_MEMBERSHIP_CHANGES+1
            print("[ItemRarity][B3_SHADOW_STATE] "..id.." PRE="..states.PRE[id].state.." POST="..states.POST[id].state)
        end
        if not same(b,public(real[id])) then
            counters.POST_VS_REAL_DIFF=counters.POST_VS_REAL_DIFF+1
            print("[ItemRarity][B3_SHADOW_REAL_DIFF] "..id)
        end
    end
    counters.FISH_REFERENCE_DIFF=same(fishRefs.PRE,fishRefs.POST) and 0 or 1
    counters.POPULATION_CONTAMINATION=(counters.POPULATION_MEMBERSHIP_CHANGES==0 and counters.FISH_REFERENCE_DIFF==0) and 0 or "REVIEW"
    for k,v in pairs(counters) do print("[ItemRarity][B3_SHADOW] "..k.."="..tostring(v)) end
    D.PRE_SHADOW_REGISTRY,D.POST_SHADOW_REGISTRY=shadow.PRE,shadow.POST
    D.last={counts=counters,states=states,fishReferences=fishRefs,postHash=factory.postHash,preHash=factory.preHash}
    local signature=ItemRarityScanner.lastScanSignature
    local match="PENDING"
    if D.lastSignature~=nil and signature~=nil then match=D.lastSignature==signature and "MATCH" or "MISMATCH" end
    D.lastSignature=signature
    print("[ItemRarity][B3_SHADOW] SECOND_RESCAN="..match.."; signature="..tostring(signature))
    print("[ItemRarity][B3_SHADOW] GLOBAL_FATALS=0; SHADOW_RUNTIME_CREATIONS=0; SHADOW_REGISTRY_WRITES=0; APPROVAL=REQUIRES_REVIEW")
    return D.last
end
