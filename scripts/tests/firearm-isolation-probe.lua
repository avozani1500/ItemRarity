local I=ItemRarityUtilityIsolation
local function firearm(id,n)
    return {data={fullType=id,displayName=id,module=id:match("^([^%.]+)"),category="WEAPON",rarityTier="RARE",
        tableAvailability={routeWeightedPercentile=40}},kind="FIREARM",profile=id,subgroup="SHOTGUN",utilityEligible=true,
        firearmAmmoType="fixture:ammo",metrics={averageDamage=1+n,maxHitCount=1,criticalChance=10+n,criticalMultiplier=2,
            maxRange=8+n,maxAmmo=4+n,weight=2+n*.2,recoilDelay=20+n,aimingTime=10+n,reloadTime=15+n,soundRadius=30+n}}
end
local function controls()
    return {firearm("Base.ControlA",1),firearm("Base.ControlB",2),firearm("Base.ControlC",3),firearm("Fixture.Control",2)}
end
local function run(list,legacy)
    local results,byId={},{}
    for _,c in ipairs(list) do results[c.data.fullType]=c.data; byId[c.data.fullType]=c end
    FIXTURE_DISCOVERY=function(data) return byId[data.fullType] end
    if legacy then LEGACY_CALCULATE(results) else ItemRarityUtilityCalculator.calculate(results) end
    FIXTURE_DISCOVERY=nil
    return results,ItemRarityUtilityCalculator.lastFirearmNormalizationBounds,ItemRarityUtilityCalculator.lastItemIsolationReport
end
local function equal(a,b,path)
    path=path or "root"
    assert(type(a)==type(b),path.." type changed")
    if type(a)=="table" then
        for k,v in pairs(a) do equal(v,b[k],path.."."..tostring(k)) end
        for k in pairs(b) do assert(a[k]~=nil,path.." unexpected key "..tostring(k)) end
    else assert(a==b,path.." changed") end
end
local baseline,bounds=run(controls())
local committed,committedBounds=run(controls(),true)
equal(committed,baseline,"committed healthy rows")
equal(committedBounds,bounds,"committed healthy anchors")
-- A reference may pass admission and then fail in item-local evaluation.
-- The final reference universe must still match the clean control exactly.
for _,stage in ipairs({"components","final"}) do
    local cohort=controls()
    local late=firearm("Base.LateFailure",900)
    table.insert(cohort,late)
    local function fail(candidate) if candidate.data.fullType=="Base.LateFailure" then error("late reference failure") end end
    if stage=="components" then FIREARM_COMPONENT_HOOK=fail else FIREARM_FINAL_HOOK=fail end
    local rows,lateBounds=run(cohort)
    FIREARM_COMPONENT_HOOK,FIREARM_FINAL_HOOK=nil,nil
    assert(late.isolationStatus=="ERROR_ISOLATED","Late failure escaped")
    for id,row in pairs(baseline) do equal(row,rows[id],"late "..stage.." "..id) end
    equal(bounds,lateBounds,"late reference anchors")
end
local trial=controls()
local bad={}
local fields={"averageDamage","maxHitCount","criticalChance","criticalMultiplier","maxRange","maxAmmo",
    "weight","recoilDelay","aimingTime","reloadTime","soundRadius"}
for index,field in ipairs(fields) do
    local c=firearm("Base.Missing"..index,900)
    c.metrics[field]=nil
    bad[#bad+1]=c
end
for index,value in ipairs({"bad",false,UNEXPECTED_USERDATA,math.huge,0/0}) do
    local c=firearm("Base.Invalid"..index,900)
    c.metrics.maxAmmo=value
    bad[#bad+1]=c
end
local getter=firearm("Base.Getter",900)
getter.metrics.maxAmmo=nil
setmetatable(getter.metrics,{__index=function() error("fixture metric getter") end})
bad[#bad+1]=getter
local scarcity=firearm("Base.BadScarcity",900)
scarcity.data.tableAvailability.routeWeightedPercentile=false
bad[#bad+1]=scarcity
local identity=firearm("Base.BadFamily",900)
identity.subgroup=nil
bad[#bad+1]=identity
for _,c in ipairs(bad) do table.insert(trial,c) end
local actual,actualBounds,report=run(trial)
for id,row in pairs(baseline) do equal(row,actual[id],id) end
equal(bounds,actualBounds,"normalization anchors")
for _,c in ipairs(bad) do
    assert(c.isolationStatus,c.data.fullType.." escaped isolation")
    assert(actual[c.data.fullType].utility==nil,"Invalid firearm published Utility")
    assert(actual[c.data.fullType].firearmFinalScore==nil,"Invalid firearm published score")
end
-- No item-local pcall may swallow malformed global coefficients.
local old=UTILITY.firearm.offense.damage
UTILITY.firearm.offense.damage=false
local ok=pcall(function() run(controls()) end)
UTILITY.firearm.offense.damage=old
assert(not ok,"Global configuration failure swallowed")
return "UTILITY=FIREARM", "ITEM_FAILURE_ISOLATED=yes", "GLOBAL_FATAL=0 (item fixtures)",
    "HEALTHY_CONTROL_REGRESSION=0", "POPULATION_CONTAMINATION=0",
    "ISOLATED_ITEM_FAILURES="..report.isolatedItemFailures,"PARTIAL_ITEMS="..report.partialItems,
    "INVALID_FIXTURES="..#bad,"GLOBAL_CONFIGURATION_ERROR_PROPAGATES=yes"
