local I=ItemRarityUtilityIsolation
local function configuration(id,n) return {itemType=id,minLength=10,maxLength=20+n,maxWeight=2+n,weightFactor=2,lure={worm=1+n},isPredator=false} end
local function candidate(id) return {data={fullType=id,module="Fixture",category="FOOD",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
    kind="FISH",utilityEligible=true,profile=id,metrics={expectedHunger=10,expectedCalories=100,minimumFishingSkill=1,baitCount=1,conditionalSpeciesShare=.5,predator=false}} end
local function equal(a,b,path)
    assert(type(a)==type(b),path.." type")
    if type(a)=="table" then
        for k,v in pairs(a) do equal(v,b[k],path.."."..tostring(k)) end
        for k in pairs(b) do assert(a[k]~=nil,path.." extra "..tostring(k)) end
    else assert(a==b,path.." value "..tostring(a).." -> "..tostring(b)) end
end
local function run(extra,legacy,stage)
    Fishing={fishes={configuration("Fixture.FishA",1),configuration("Fixture.FishB",2)},Utils={skillSizeLimit={}}}
    for level=0,10 do Fishing.Utils.skillSizeLimit[level]=level+1 end
    local rows,byId={},{}
    for _,cfg in ipairs(extra or {}) do Fishing.fishes[#Fishing.fishes+1]=cfg end
    for _,cfg in ipairs(Fishing.fishes) do local c=candidate(cfg.itemType); rows[c.data.fullType]=c.data; byId[c.data.fullType]=c end
    FIXTURE_DISCOVERY=function(data) return byId[data.fullType] end
    local original=I.run
    if stage then I.run=function(c,s,action) return original(c,s,function()
        if c.data.fullType=="Fixture.Late" and s==stage then error("late fish fixture") end
        return action()
    end) end end
    local ok,err=pcall(legacy and LEGACY_CALCULATE or ItemRarityUtilityCalculator.calculate,rows)
    I.run=original; FIXTURE_DISCOVERY=nil; assert(ok,tostring(err)); return rows,byId
end
local baseline=run()
equal(run(nil,true),baseline,"pre-containment")
for _,stage in ipairs({"Fish:ReferenceAdmission","Fish:Score","Fish:Assignment"}) do
    local rows,byId=run({configuration("Fixture.Late",5)},false,stage)
    for id,row in pairs(baseline) do equal(row,rows[id],stage..":"..id) end
    assert(byId["Fixture.Late"].isolationStatus,"late fish escaped")
end
local bad={}
for _,field in ipairs({"maxWeight","maxLength","weightFactor","lure"}) do local c=configuration("Fixture.Missing_"..field,5); c[field]=nil; bad[#bad+1]=c end
for index,value in ipairs({false,"bad",UNEXPECTED_USERDATA,math.huge,0/0}) do local c=configuration("Fixture.Bad"..index,5); c.maxWeight=value; bad[#bad+1]=c end
local bait=configuration("Fixture.BadBait",5); bait.lure.worm=false; bad[#bad+1]=bait
local previous
for repetition=1,2 do
    local rows,byId=run(bad)
    for id,row in pairs(baseline) do equal(row,rows[id],id) end
    for _,c in ipairs(bad) do assert(byId[c.itemType].isolationStatus and rows[c.itemType].utility==nil,c.itemType) end
    local count=0; for _ in pairs(I.warningKeys) do count=count+1 end
    if previous then assert(count==previous,"fish warning spam") end; previous=count
end
local old=ItemRarityConfig.utility.fish.expectedYield.caloriesHalfSaturation
ItemRarityConfig.utility.fish.expectedYield.caloriesHalfSaturation=false
assert(not pcall(run),"global Fish config swallowed")
ItemRarityConfig.utility.fish.expectedYield.caloriesHalfSaturation=old
-- Exercise the actual no-loot augmentation, not just the normal scoring pass.
run()
local scripts={}
for _,cfg in ipairs(Fishing.fishes) do
    local id=cfg.itemType
    scripts[#scripts+1]={getFullName=function() return id end}
end
getScriptManager=function() return {getAllItems=function() return scripts end} end
ItemRarityItemClassifier={getModule=function() return "Fixture" end,getFunctionalCategory=function() return "FOOD",{module="Fixture"} end}
local noLoot={}
I.beginScan()
local stats=ItemRarityUtilityCalculator.augmentUtilityOnly(noLoot)
assert(stats.fish==2 and stats.withScarcity==0 and stats.routeWeighted==0,"Fish UTILITY_ONLY semantics changed")
for id,row in pairs(baseline) do
    assert(noLoot[id].utility==row.utility and noLoot[id].finalRarityTier==row.finalRarityTier,id.." no-loot mismatch")
    assert(noLoot[id].source=="UTILITY_ONLY" and noLoot[id].scarcityPercentile==nil)
end
getScriptManager=nil; ItemRarityItemClassifier=nil
assert(I.optionalDiscover({fullType="Fixture.Optional"},"FISH",function() return nil end)==nil)
local failed=I.optionalDiscover({fullType="Fixture.Callback"},"FISH",function() error("callback fixture") end)
assert(failed.isolationStatus=="ERROR_ISOLATED","optional discovery escaped")
return "UTILITY=FISH","HEALTHY_COMPARED=2","ITEM_FAILURE_ISOLATED=yes","HEALTHY_ITEM_REGRESSION=0",
    "POPULATION_CONTAMINATION=0","GLOBAL_FATAL=0 (item fixtures)","WARNINGS_DEDUPLICATED=yes","UTILITY_ONLY_UNCHANGED=yes"
