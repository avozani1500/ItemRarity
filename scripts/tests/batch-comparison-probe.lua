-- Diagnostic transport/observer fixtures. No Java items, files or OnCreate.
local D, I = ItemRarityBatchComparison, ItemRarityUtilityIsolation
local originalRun, originalDiscover = I.run, I.discover
local mode, scans = "stable", 0
getFileWriter = function() error("Writer must not be used") end
local function cleanHooks()
    assert(I.run == originalRun and I.discover == originalDiscover and not D.running, "observer leaked")
end
assert(D.snapshots.A == nil, "diagnostic ran on load")
ItemRarityScanner = {results={}}
function ItemRarityScanner.rescan()
    scans = scans + 1
    if mode == "fatal" then error("global scanner fixture") end
    if mode == "stale" then return end
    I.beginScan()
    local results = {}
    for _, kind in ipairs({"CONTAINER", "FIREARM", "MELEE_WEAPON", "CLOTHING", "FOOD", "MEDICAL","MAGAZINE","AMMO","FISH","LITERATURE"}) do
        local id = "Base.Test_" .. kind
        local data = {fullType=id,utilityKind=kind,finalRarityTier="UNCOMMON",utility=50}
        results[id] = data
        local c = I.discover(data, function()
            return {data=data,kind=kind,utilityEligible=kind ~= "CLOTHING",metrics={weight=1},profile="profile",
                subgroup="group",utility=50,profileCount=1,metricPercentiles={weight=50},
                functionalGroup="MAP",literatureFinalTier="RARE",mapId="RosewoodMap"}
        end)
        local stage = ({CONTAINER="Container:ReferenceAdmission",FIREARM="Firearm:ReferenceAdmission",MELEE_WEAPON="Melee:ReferenceAdmission",
            CLOTHING="Clothing:ReferenceAdmission",FOOD="Food:ReferenceAdmission",MEDICAL="Medical:ReferenceAdmission",
            MAGAZINE="Magazine:Score",AMMO="Ammo:Inheritance",FISH="Fish:CandidateAdmission",LITERATURE="Literature:PolicyAdmission"})[kind]
        I.run(c, stage, function()
            if kind=="AMMO" then c.utility=nil; data.utility=nil; c.ammoInheritedFirearmTier="UNCOMMON"; c.ammoCompatibleFirearms={"Base.MockGun"} end
            if kind == "CLOTHING" then c.utilityEligible=true end
            if mode == "invalid" and kind == "CONTAINER" then
                I.mark(c, "fixture", "ERROR_ISOLATED", "invalid fixture")
                data.failedUtilityKind, data.utilityKind = kind, c.kind
                return false
            end
            if mode == "weight" and kind == "CONTAINER" then c.metrics.weight=2 end
            if mode == "score" and kind == "CONTAINER" then c.utility=51; data.utility=51 end
            if mode == "population" and kind == "CONTAINER" then c.profile="other" end
            if mode == "tier" and kind == "CONTAINER" then data.finalRarityTier="RARE" end
            if mode == "partial" and kind == "CONTAINER" then c.utilityEligible=false; return false end
            if kind ~= "MELEE_WEAPON" and kind ~= "MEDICAL" then return true end
        end)
        if kind=="FISH" then
            local reference={data={fullType="Base.SpeciesReference"},kind="FISH",metrics={expectedHunger=10},utility=50,fishFinalTier="UNCOMMON"}
            I.run(reference,"Fish:Score",function()
                if mode=="fish-reference" then reference.metrics.expectedHunger=11 end
            end)
        end
        if mode == "removed" and kind == "CONTAINER" then results[id]=nil end
        -- Same-fullType augmentation proxy must not shadow the real candidate.
        local proxy={data={fullType=id},kind=kind,utilityEligible=true,metrics={weight=999}}
        I.run(proxy, "Proxy", function() end)
        if mode=="coverage" and kind=="FIREARM" then
            c.firearmAmmoType="fixture:valid"
            proxy.firearmAmmoType=""
            I.run(proxy,"Ammo:FirearmReference",function()
                I.mark(proxy,"Ammo:FirearmReference","PARTIAL_DEFER","empty proxy key")
            end)
        end
    end
    if mode == "missing" then
        results["Base.Unobserved"]={fullType="Base.Unobserved",utilityKind="CONTAINER"}
    end
    ItemRarityScanner.results = results
    I.report.calculateCompleted=true
    ItemRarityUtilityCalculator.lastItemIsolationReport=I.report
    ItemRarityScanner.lastScanSignature="unchanged"
end
assert(not pcall(D.run,"B"), "B accepted without A")
cleanHooks()
D.run("A"); cleanHooks()
local frozen=D.snapshots.A.rows["Base.Test_CONTAINER"].metrics.weight
ItemRarityScanner.results["Base.Test_CONTAINER"].utility=999
assert(D.snapshots.A.rows["Base.Test_CONTAINER"].publishedUtility==50,"snapshot aliases live data")
local r=D.run("B"); cleanHooks()
assert(r.HEALTHY_ITEMS_COMPARED==3 and r.HEALTHY_ITEM_REGRESSION==0 and r.POPULATION_CONTAMINATION==0)
assert(D.snapshots.A.rows["Base.Test_MELEE_WEAPON"].population.admitted,"nil success lost")
for _, change in ipairs({"weight","score","tier","population","partial","removed"}) do
    mode="stable"; D.run("A")
    mode=change; local delta=D.run("B"); cleanHooks()
    assert(delta.HEALTHY_ITEM_REGRESSION==1,"missed "..change)
    if change=="population" or change=="partial" or change=="removed" then
        assert(delta.POPULATION_MEMBERSHIP_CHANGES==1,"membership "..change)
    end
end
mode="stable"; D.run("A")
mode="invalid"; r=D.run("B"); cleanHooks()
assert(r.HEALTHY_ITEM_REGRESSION==1 and r.POPULATION_CONTAMINATION=="UNKNOWN","false contamination pass")
mode="stable"; D.run("A")
mode="missing"; r=D.run("B"); cleanHooks()
assert(r.OBSERVATION_MISSING==1 and r.HEALTHY_ITEM_REGRESSION=="UNKNOWN","incomplete audit passed")
mode="fatal"; assert(not pcall(D.run,"A"),"global error swallowed"); cleanHooks()
assert(not D.snapshots.A,"stale snapshot survived fatal")
mode="stable"; D.run("A")
mode="stale"; assert(not pcall(D.run,"B"),"stale report accepted"); cleanHooks()
assert(not D.snapshots.B)
mode="stable"; D.run("A",2)
assert(not pcall(D.run,"B",1),"mixed batch comparison accepted"); cleanHooks()
r=D.run("B",2); cleanHooks()
assert(r.HEALTHY_ITEMS_COMPARED==3 and r.HEALTHY_ITEM_REGRESSION==0,"batch2 scope failed")
assert(D.snapshots.A.rows["Base.Test_MEDICAL"].population.admitted,"Medical nil success lost")
assert(D.snapshots.A.rows["Base.Test_CLOTHING"].candidateState=="SAFE","Clothing discovery PARTIAL was not updated")
assert(r.CLOTHING_HEALTHY_COMPARED==1 and r.CLOTHING_HEALTHY_REGRESSION==0,"Clothing effective counters incorrect")
assert(D.snapshots.A.rows["Base.Test_CONTAINER"]==nil,"batch2 leaked batch1")
mode="stable"; D.run("A",3); r=D.run("B",3); cleanHooks()
assert(r.HEALTHY_ITEMS_COMPARED==4 and r.HEALTHY_ITEM_REGRESSION==0,"batch3 scope failed")
assert(D.snapshots.B.rows["Base.Test_AMMO"].candidateState=="SAFE","Ammo requires invented score")
assert(D.snapshots.B.rows["Base.Test_AMMO"].utilityScore==nil)
for _,kind in ipairs({"MAGAZINE","AMMO","FISH","LITERATURE"}) do assert(r[kind.."_POPULATION_CONTAMINATION"]==0,kind) end
mode="fish-reference"; r=D.run("B",3); cleanHooks()
assert(r.FISH_HEALTHY_ITEM_REGRESSION==1,"Fish API population change missed")
mode="coverage"
getScriptManager=function() return {getAllItems=function() return {{
    getFullName=function() return "Base.Test_FIREARM" end,
    getAmmoType=function() return "fixture:valid" end,
    getType=function() return "Weapon" end,
    -- Deliberately no getItemType/getFullType: absent getters must not be called.
}} end} end
local realPcall=pcall
local failedProtectedCalls=0
pcall=function(...)
    local result={realPcall(...)}
    if not result[1] then failedProtectedCalls=failedProtectedCalls+1 end
    return unpack(result)
end
local coverage=ItemRarityBatch3Coverage.run("A"); cleanHooks()
pcall=realPcall; getScriptManager=nil
assert(failedProtectedCalls==0,"diagnostic invoked absent getter under pcall")
assert(#coverage.firearms==1,"deferred reference not captured")
assert(coverage.firearms[1].candidateAmmoType=="fixture:valid" and coverage.firearms[1].referenceAmmoType=="","proxy shadowed real candidate")
assert(coverage.firearms[1].referenceIsPublishedRow==false)
assert(coverage.counts.detected==1 and coverage.counts.healthy==1,"Literature effective state lost")
assert(coverage.ammo["Base.Test_AMMO"].tier=="UNCOMMON","Ammo effective tier lost")
return "BATCH_DIAGNOSTIC_TESTS=PASS", "WRITER_CALLS=0", "OBSERVER_RESTORED=yes",
    "GLOBAL_ERRORS_RETHROWN=yes", "DEEP_SNAPSHOTS=yes", "DIFFERENCES_DETECTED=yes", "WORLD_SCAN=NOT_RUN"
