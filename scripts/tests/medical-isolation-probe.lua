local I=ItemRarityUtilityIsolation
local function medical(id,n,group)
    group=group or "WOUND_TREATMENT"
    return {data={fullType=id,module="Base",category="MEDICAL",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
        kind="MEDICAL",utilityEligible=true,profile=id,subgroup=group,functionalGroup=group,
        medicalValueStatus="MECHANICAL_VALUE_KNOWN",medicalDominantEffect=n,medicalUses=n,
        metrics={bandagePower=n,weight=.1}}
end
local function controls() return {medical("Base.ControlA",1),medical("Base.ControlB",2),medical("Fixture.Control",3),medical("Base.Pain",2,"PAIN_MEDICINE")} end
local function run(cohort,legacy,failStage)
    local rows,byId={},{}
    for _,c in ipairs(cohort) do rows[c.data.fullType]=c.data; byId[c.data.fullType]=c end
    FIXTURE_DISCOVERY=function(data) return byId[data.fullType] end
    local original=I.run
    if failStage then I.run=function(c,stage,action)
        return original(c,stage,function()
            if stage==failStage and c.data.fullType=="Base.Late" then error("late medical fixture") end
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
for _,stage in ipairs({"Medical:Score","Medical:Assignment"}) do
    local cohort=controls(); local bad=medical("Base.Late",900); cohort[#cohort+1]=bad
    local rows=run(cohort,false,stage)
    assert(bad.isolationStatus,"late failure escaped "..stage)
    for id,data in pairs(baseline) do equal(data,rows[id],stage..":"..id) end
    local function warnings() local n=0; for _ in pairs(I.warningKeys) do n=n+1 end; return n end
    local before=warnings(); local again=controls(); again[#again+1]=medical("Base.Late",900)
    run(again,false,stage); assert(warnings()==before,"warning not deduplicated")
end
local cohort=controls(); local bad={}
for _,field in ipairs({"medicalDominantEffect","medicalUses"}) do
    local c=medical("Base.Missing_"..field,900); c[field]=nil; bad[#bad+1]=c
    for i,value in ipairs({"bad",false,UNEXPECTED_USERDATA,math.huge,0/0,-1}) do
        local invalid=medical("Base.Bad_"..field..i,900); invalid[field]=value; bad[#bad+1]=invalid
    end
end
for _,c in ipairs(bad) do cohort[#cohort+1]=c end
local rows,report=run(cohort)
for id,data in pairs(baseline) do equal(data,rows[id],id) end
for _,c in ipairs(bad) do assert(c.isolationStatus and rows[c.data.fullType].utility==nil,c.data.fullType) end
local saved=ItemRarityConfig.utility.medical.efficacyWeight
ItemRarityConfig.utility.medical.efficacyWeight=false
local ok=pcall(function() run(controls()) end)
ItemRarityConfig.utility.medical.efficacyWeight=saved
assert(not ok,"global Medical configuration swallowed")
return "UTILITY=MEDICAL", "ITEM_FAILURE_ISOLATED=yes", "GLOBAL_FATAL=0", "HEALTHY_CONTROL_REGRESSION=0",
    "POPULATION_CONTAMINATION=0", "ISOLATED_ITEM_FAILURES="..report.isolatedItemFailures,"PARTIAL_ITEMS="..report.partialItems
