local I=ItemRarityUtilityIsolation
local function food(id,n,group)
    group=group or "FOOD"
    return {data={fullType=id,module="Base",category="FOOD",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
        kind="FOOD",utilityEligible=true,profile=id,subgroup=group,functionalGroup=group,foodValueStatus="MECHANICAL_VALUE_KNOWN",
        metrics={hungerChange=-.1*n,thirstChange=-.05*n,hungerBenefit=.1*n,thirstBenefit=.05*n,calories=100*n,
            daysTotallyRotten=3*n,unhappyChange=-n,boredomChange=-n,stressChange=-.01*n,foodSicknessChange=0,
            cookable=false,dangerousUncooked=false,poison=false,minutesToCook=60}}
end
local function controls() return {food("Base.ControlA",1),food("Base.ControlB",2),food("Fixture.Control",3),food("Base.Drink",2,"DRINK")} end
local function run(cohort,legacy,failStage)
    local rows,byId={},{}
    for _,c in ipairs(cohort) do rows[c.data.fullType]=c.data; byId[c.data.fullType]=c end
    FIXTURE_DISCOVERY=function(data) return byId[data.fullType] end
    local original=I.run
    if failStage then I.run=function(c,stage,action)
        return original(c,stage,function()
            if stage==failStage and c.data.fullType=="Base.Late" then error("late food fixture") end
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
for _,stage in ipairs({"Food:Samples","Food:Score","Food:Assignment"}) do
    local cohort=controls(); local bad=food("Base.Late",900); cohort[#cohort+1]=bad
    local rows=run(cohort,false,stage)
    assert(bad.isolationStatus,"late failure escaped "..stage)
    for id,data in pairs(baseline) do equal(data,rows[id],stage..":"..id) end
    local function warnings() local n=0; for _ in pairs(I.warningKeys) do n=n+1 end; return n end
    local before=warnings(); local again=controls(); again[#again+1]=food("Base.Late",900)
    run(again,false,stage); assert(warnings()==before,"warning not deduplicated")
end
local cohort=controls(); local bad={}
for _,field in ipairs({"hungerChange","thirstChange","hungerBenefit","thirstBenefit","calories","daysTotallyRotten",
    "unhappyChange","boredomChange","stressChange","foodSicknessChange","cookable","dangerousUncooked","poison"}) do
    local c=food("Base.Missing_"..field,900); c.metrics[field]=nil; bad[#bad+1]=c
end
for i,value in ipairs({"bad",false,UNEXPECTED_USERDATA,math.huge,0/0}) do
    local c=food("Base.Bad"..i,900); c.metrics.calories=value; bad[#bad+1]=c
end
local cooking=food("Base.Cooking",900); cooking.metrics.cookable=true; cooking.metrics.minutesToCook=nil; bad[#bad+1]=cooking
local scarcity=food("Base.BadScarcity",900); scarcity.data.tableAvailability.routeWeightedPercentile=false; bad[#bad+1]=scarcity
for _,c in ipairs(bad) do cohort[#cohort+1]=c end
local rows,report=run(cohort)
for id,data in pairs(baseline) do equal(data,rows[id],id) end
for _,c in ipairs(bad) do assert(c.isolationStatus and rows[c.data.fullType].utility==nil,c.data.fullType) end
local saved=ItemRarityConfig.utility.food.energyHalfSaturationCalories
ItemRarityConfig.utility.food.energyHalfSaturationCalories=false
local ok=pcall(function() run(controls()) end)
ItemRarityConfig.utility.food.energyHalfSaturationCalories=saved
assert(not ok,"global Food configuration swallowed")
return "UTILITY=FOOD", "ITEM_FAILURE_ISOLATED=yes", "GLOBAL_FATAL=0", "HEALTHY_CONTROL_REGRESSION=0",
    "POPULATION_CONTAMINATION=0", "ISOLATED_ITEM_FAILURES="..report.isolatedItemFailures,"PARTIAL_ITEMS="..report.partialItems
