local I=ItemRarityUtilityIsolation
local function gun(id,n)
    return {data={fullType=id,module="Base",category="WEAPON",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
        kind="FIREARM",profile=id,subgroup="SHOTGUN",utilityEligible=true,firearmAmmoType="fixture:ammo",
        metrics={averageDamage=1+n,maxHitCount=1,criticalChance=10+n,criticalMultiplier=2,maxRange=8+n,maxAmmo=4+n,
            weight=2+n*.2,recoilDelay=20+n,aimingTime=10+n,reloadTime=15+n,soundRadius=30+n}}
end
local function magazine(id,n)
    return {data={fullType=id,module="Fixture",category="MAGAZINE",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
        kind="MAGAZINE",profile=id,utilityEligible=true,metrics={maxAmmo=n,gunType="Base.GunA",ammoType="fixture:ammo"}}
end
local function controls() return {gun("Base.GunA",1),gun("Base.GunB",2),magazine("Fixture.A",10),magazine("Fixture.B",20)} end
local function equal(a,b,path)
    assert(type(a)==type(b),path.." type")
    if type(a)=="table" then
        for k,v in pairs(a) do equal(v,b[k],path.."."..tostring(k)) end
        for k in pairs(b) do assert(a[k]~=nil,path.." extra "..tostring(k)) end
    else assert(a==b,path.." value") end
end
local function run(cohort,legacy,fail)
    local rows,byId={},{}
    for _,c in ipairs(cohort) do rows[c.data.fullType]=c.data; byId[c.data.fullType]=c end
    FIXTURE_DISCOVERY=function(data) return byId[data.fullType] end
    local original=I.run
    if fail then I.run=function(c,stage,action) return original(c,stage,function()
        if c.data.fullType=="Fixture.Late" and stage=="Magazine:Score" then error("injected magazine failure") end
        return action()
    end) end end
    local ok,err=pcall(legacy and LEGACY_CALCULATE or ItemRarityUtilityCalculator.calculate,rows)
    I.run=original; FIXTURE_DISCOVERY=nil; assert(ok,tostring(err)); return rows
end
local baseline=run(controls())
equal(run(controls(),true),baseline,"pre-containment")
local bad={}
for _,field in ipairs({"maxAmmo","gunType","ammoType"}) do
    local c=magazine("Fixture.Missing_"..field,10); c.metrics[field]=nil; bad[#bad+1]=c
end
for n,value in ipairs({"bad",false,UNEXPECTED_USERDATA,0/0,math.huge,-1}) do
    local c=magazine("Fixture.Bad"..n,10); c.metrics.maxAmmo=value; bad[#bad+1]=c
end
for repetition=1,2 do
    local cohort=controls()
    for _,c in ipairs(bad) do c.isolationStatus=nil; c.kind="MAGAZINE"; c.utilityEligible=true; cohort[#cohort+1]=c end
    local late=magazine("Fixture.Late",10000); cohort[#cohort+1]=late
    local rows=run(cohort,false,true)
    for id,row in pairs(baseline) do equal(row,rows[id],id) end
    for _,c in ipairs(bad) do assert(c.isolationStatus and rows[c.data.fullType].utility==nil,c.data.fullType) end
    assert(late.isolationStatus)
    local count=0; for _ in pairs(I.warningKeys) do count=count+1 end
    if repetition==1 then MAGAZINE_WARNING_COUNT=count else assert(count==MAGAZINE_WARNING_COUNT,"warning spam") end
end
local old=ItemRarityConfig.utility.magazine.capacitySaturation
ItemRarityConfig.utility.magazine.capacitySaturation=false
assert(not pcall(run,controls()),"global config swallowed")
ItemRarityConfig.utility.magazine.capacitySaturation=old
return "UTILITY=MAGAZINE","HEALTHY_COMPARED=2","ITEM_FAILURE_ISOLATED=yes","HEALTHY_ITEM_REGRESSION=0",
    "POPULATION_CONTAMINATION=0 (contextual firearms unchanged)","GLOBAL_FATAL=0 (item fixtures)","WARNINGS_DEDUPLICATED=yes"
