local function melee(id,n)
    return {data={fullType=id,module="Fixture",category="WEAPON",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
        kind="MELEE_WEAPON",subgroup="AXE",utilityEligible=true,metrics={averageDamage=n+1,attackTempo=.5+n/10,runtimeCritical=n*10,
            multiHit=n,weight=n+1,strainProxy=(n+1)*.5,range=1+n/10,knockdown=n,durability=n+3,endurance=.5}}
end
local function controls() return {melee("Base.ControlA",1),melee("Base.ControlB",2),melee("Fixture.ControlC",3)} end
local function run(list,legacy)
    local results,map={},{}
    for _,c in ipairs(list) do results[c.data.fullType]=c.data; map[c.data.fullType]=c end
    FIXTURE_DISCOVERY=function(data) return map[data.fullType] end
    if legacy then LEGACY_CALCULATE(results) else ItemRarityUtilityCalculator.calculate(results) end
    FIXTURE_DISCOVERY=nil
    return results,ItemRarityUtilityCalculator.lastItemIsolationReport
end
local function equal(a,b,path)
    if type(a)=="table" then
        assert(type(b)=="table",path)
        for k,v in pairs(a) do equal(v,b[k],path.."."..tostring(k)) end
        for k in pairs(b) do assert(a[k]~=nil,path.." added key") end
    else assert(a==b,path.." changed") end
end
local baseline=run(controls())
local committed=run(controls(),true)
equal(committed,baseline,"committed healthy rows")
local cohort=controls()
local bad={}
for index,field in ipairs({"averageDamage","attackTempo","runtimeCritical","multiHit","strainProxy","weight","range","knockdown","durability"}) do
    local c=melee("Base.Missing"..index,900); c.metrics[field]=nil; bad[#bad+1]=c
end
for index,value in ipairs({"bad",false,UNEXPECTED_USERDATA,math.huge,0/0}) do
    local c=melee("Base.Invalid"..index,900); c.metrics.weight=value; bad[#bad+1]=c
end
local late=melee("Base.LateFailure",900); bad[#bad+1]=late
MELEE_FINAL_HOOK=function(candidate) if candidate.data.fullType=="Base.LateFailure" then error("late melee failure") end end
for _,c in ipairs(bad) do table.insert(cohort,c) end
local actual,report=run(cohort)
MELEE_FINAL_HOOK=nil
for id,data in pairs(baseline) do equal(data,actual[id],id) end
for _,c in ipairs(bad) do assert(c.isolationStatus and actual[c.data.fullType].utility==nil,c.data.fullType.." escaped") end
local saved=ItemRarityConfig.utility.meleeWeapon.v2.offense.averageDamage
ItemRarityConfig.utility.meleeWeapon.v2.offense.averageDamage=false
local ok=pcall(function() run(controls()) end)
ItemRarityConfig.utility.meleeWeapon.v2.offense.averageDamage=saved
assert(not ok,"Global configuration error swallowed")
return "UTILITY=MELEE", "ITEM_FAILURE_ISOLATED=yes", "GLOBAL_FATAL=0 (item fixtures)",
    "HEALTHY_CONTROL_REGRESSION=0", "POPULATION_CONTAMINATION=0",
    "ISOLATED_ITEM_FAILURES="..report.isolatedItemFailures,"PARTIAL_ITEMS="..report.partialItems,
    "INVALID_FIXTURES="..#bad,"GLOBAL_CONFIGURATION_ERROR_PROPAGATES=yes"
