local I=ItemRarityUtilityIsolation
local function garment(id,n)
    return {data={fullType=id,module="Base",category="CLOTHING",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
        -- Mirrors actual Clothing discovery: eligibility is established later.
        kind="CLOTHING",clothingUtilityCandidate=true,utilityEligible=false,profile=id,subgroup="LOWER_BODY",
        functionalGroup="LOWER_BODY_LAYER",equipmentGraph={resolved=true,slotId="base:pants",exclusive={}},
        clothingDiscovery={coveredRegions={"GROIN","THIGH","SHIN"}},
        metrics={biteDefense=10*n,scratchDefense=15*n,bulletDefense=0,durability=5+n,weight=1+n*.1,
            runSpeedModifier=1,combatSpeedModifier=1,visionModifier=1,hearingModifier=1,discomfortModifier=0,
            insulation=.2*n,windResistance=.1*n,waterResistance=.1*n}}
end
local function controls()
    local items={garment("Base.ControlA",1),garment("Base.ControlB",2),garment("Fixture.Control",3)}
    for _,spec in ipairs({
        {"Head","HEADGEAR","HEAD",{"HEAD","NECK"}},
        {"Feet","FOOTWEAR","FEET",{"FOOT","SHIN"}},
        {"Hands","PRIMARY_ARMOR","HANDS",{"HAND"}},
        {"Torso","TORSO_LAYER","UPPER_BODY",{"TORSO_UPPER","TORSO_LOWER"}},
        {"Jacket","TORSO_LAYER","OUTERWEAR",{"TORSO_UPPER","TORSO_LOWER","UPPER_ARM","FOREARM"}},
        {"FullBody","FULL_BODY_RESTRICTIVE","FULL_BODY",{"TORSO_UPPER","TORSO_LOWER","GROIN","THIGH","SHIN"}},
    }) do
        local c=garment("Base."..spec[1],2)
        c.functionalGroup=spec[2]; c.subgroup=spec[3]; c.clothingDiscovery.coveredRegions=spec[4]
        c.equipmentGraph.slotId="base:"..spec[1]
        items[#items+1]=c
    end
    return items
end
local function run(cohort,legacy,failStage)
    local rows,byId={},{}
    for _,c in ipairs(cohort) do rows[c.data.fullType]=c.data; byId[c.data.fullType]=c end
    FIXTURE_DISCOVERY=function(data) return byId[data.fullType] end
    local original=I.run
    if failStage then I.run=function(c,stage,action)
        return original(c,stage,function()
            if stage==failStage and c.data.fullType=="Base.Late" then error("late clothing fixture") end
            return action()
        end)
    end end
    local ok,err=pcall(legacy and LEGACY_CALCULATE or ItemRarityUtilityCalculator.calculate,rows)
    I.run=original; FIXTURE_DISCOVERY=nil
    assert(ok,tostring(err))
    return rows,ItemRarityUtilityCalculator.lastItemIsolationReport
end
local function equal(a,b,path)
    assert(type(a)==type(b),path.." type")
    if type(a)=="table" then
        for k,v in pairs(a) do equal(v,b[k],path.."."..tostring(k)) end
        for k in pairs(b) do assert(a[k]~=nil,path.." extra "..k) end
    else assert(a==b,path.." changed "..tostring(a).." -> "..tostring(b)) end
end
local baseline=run(controls())
equal(run(controls(),true),baseline,"pre-containment controls")
for _,stage in ipairs({"Clothing:Coverage","Clothing:MechanicalBenefit","Clothing:Grouping","Clothing:Preparation",
    "Clothing:SlotAdmission","Clothing:SlotScore","Clothing:SlotAssignment","Clothing:MechanicalPolicy"}) do
    local cohort=controls(); local bad=garment("Base.Late",9); cohort[#cohort+1]=bad
    local rows=run(cohort,false,stage)
    assert(bad.isolationStatus,"late failure escaped "..stage)
    for id,data in pairs(baseline) do equal(data,rows[id],stage..":"..id) end
    local function warnings() local n=0; for _ in pairs(I.warningKeys) do n=n+1 end; return n end
    local before=warnings(); local again=controls(); again[#again+1]=garment("Base.Late",9)
    run(again,false,stage); assert(warnings()==before,"warning not deduplicated")
end
local cohort=controls(); local bad={}
for _,field in ipairs({"biteDefense","scratchDefense","bulletDefense","durability","weight","runSpeedModifier",
    "combatSpeedModifier","visionModifier","hearingModifier","discomfortModifier","insulation","windResistance","waterResistance"}) do
    local c=garment("Base.Missing_"..field,9); c.metrics[field]=nil; bad[#bad+1]=c
end
for i,value in ipairs({"bad",false,UNEXPECTED_USERDATA,math.huge,0/0}) do
    local c=garment("Base.Bad"..i,9); c.metrics.weight=value; bad[#bad+1]=c
end
local region=garment("Base.BadRegion",9); region.clothingDiscovery.coveredRegions={false}; bad[#bad+1]=region
local slot=garment("Base.BadSlot",9); slot.equipmentGraph.slotId=false; bad[#bad+1]=slot
for _,c in ipairs(bad) do cohort[#cohort+1]=c end
local rows,report=run(cohort)
for id,data in pairs(baseline) do equal(data,rows[id],id) end
for _,c in ipairs(bad) do assert(c.isolationStatus and rows[c.data.fullType].utility==nil,c.data.fullType) end
-- Structural policy and mechanical comparison are different admission gates.
local structural=controls()
local zero=garment("Base.Briefs_SmallTrunks_Black",0); zero.clothingDiscovery.coveredRegions={}
local renamed=garment("Fixture.ArbitraryIdentity",0); renamed.clothingDiscovery.coveredRegions=nil
local boxers=garment("Base.Boxers_Hearts",0); boxers.clothingDiscovery.coveredRegions={}
local completeZero=garment("Fixture.CompleteZero",0)
for _,c in ipairs({zero,renamed,boxers,completeZero}) do structural[#structural+1]=c end
local unresolved=garment("Fixture.UnknownDefense",0); unresolved.metrics.biteDefense=nil; structural[#structural+1]=unresolved
local warm=garment("Fixture.WarmUnknownCoverage",1); warm.clothingDiscovery.coveredRegions={}; structural[#structural+1]=warm
local special=garment("Fixture.SpecialZero",0); special.mechanicalSpecialBehavior=true; special.clothingDiscovery.coveredRegions={}; structural[#structural+1]=special
local protectedRows=run(structural)
for id,data in pairs(baseline) do equal(data,protectedRows[id],"structural separation "..id) end
for _,c in ipairs({zero,renamed,boxers,completeZero}) do
    local row=protectedRows[c.data.fullType]
    assert(row.finalRarityTier=="COMMON" and row.clothingMechanicalValueStatus=="MECHANICALLY_TRIVIAL",c.data.fullType.." policy lost")
    assert(c.structuralPolicy=="CLOTHING_TRIVIAL" and not c.rankingEligible and not c.isolationStatus)
    assert(c.utility==nil and c.metricPercentiles==nil,"structural-only item entered scoring")
end
for _,c in ipairs({unresolved,warm,special}) do
    assert(c.isolationStatus and not c.structuralPolicy and protectedRows[c.data.fullType].utility==nil,"unsafe structural release")
end
-- Compare the known policy outcome with the pre-containment oracle, while
-- keeping these policy-only inputs out of the NEW mechanical populations.
local legacyCohort=controls(); local legacyZero=garment("Base.Briefs_SmallTrunks_Black",0)
legacyZero.clothingDiscovery.coveredRegions={}; legacyCohort[#legacyCohort+1]=legacyZero
assert(run(legacyCohort,true)[legacyZero.data.fullType].finalRarityTier=="COMMON","oracle policy mismatch")
local accessory=garment("Fixture.Cosmetic",0)
accessory.kind="ACCESSORY"; accessory.clothingUtilityCandidate=false; accessory.accessoryMechanicalCandidate=true
accessory.accessoryTrivialCosmeticEligible=true
local accessoryCohort=controls(); accessoryCohort[#accessoryCohort+1]=accessory
assert(run(accessoryCohort)[accessory.data.fullType].finalRarityTier=="COMMON","existing accessory policy lost")
local saved=ItemRarityConfig.utility.clothing.coverage.minimumFactor
ItemRarityConfig.utility.clothing.coverage.minimumFactor=false
local ok=pcall(function() run(controls()) end)
ItemRarityConfig.utility.clothing.coverage.minimumFactor=saved
assert(not ok,"global Clothing configuration swallowed")
return "UTILITY=CLOTHING", "ITEM_FAILURE_ISOLATED=yes", "GLOBAL_FATAL=0", "HEALTHY_CONTROL_REGRESSION=0",
    "POPULATION_CONTAMINATION=0", "TRIVIAL_POLICY_REGRESSION=0", "STRUCTURAL_ONLY_OUTSIDE_RANKING=yes",
    "ISOLATED_ITEM_FAILURES="..report.isolatedItemFailures,"PARTIAL_ITEMS="..report.partialItems
