local I=ItemRarityUtilityIsolation
local function gun(id,n)
    return {data={fullType=id,module="Base",category="WEAPON",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
        kind="FIREARM",profile=id,subgroup="SHOTGUN",utilityEligible=true,firearmAmmoType="fixture:ammo",
        metrics={averageDamage=1+n,maxHitCount=1,criticalChance=10+n,criticalMultiplier=2,maxRange=8+n,maxAmmo=4+n,
            weight=2+n*.2,recoilDelay=20+n,aimingTime=10+n,reloadTime=15+n,soundRadius=30+n}}
end
local function ammo(id,key)
    return {data={fullType=id,module="Fixture",category="AMMO",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
        kind="AMMO",profile=id,utilityEligible=true,metrics={ammoType=key}}
end
local function controls() return {gun("Base.GunA",1),gun("Base.GunB",2),ammo("Fixture.A","fixture:ammo"),ammo("Fixture.B","fixture:ammo")} end
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
        if c.data.fullType=="Fixture.Late" and stage=="Ammo:Inheritance" then error("injected ammo failure") end
        return action()
    end) end end
    local ok,err=pcall(legacy and LEGACY_CALCULATE or ItemRarityUtilityCalculator.calculate,rows)
    I.run=original; FIXTURE_DISCOVERY=nil; assert(ok,tostring(err)); return rows
end
local baseline=run(controls())
equal(run(controls(),true),baseline,"pre-containment")
local warnings
-- The reference boundary itself, not just malformed ammo candidates.
-- No weapon discovery or AmmoType resolver participates in this fixture.
local function reference(id,key)
    return {data={fullType=id},kind="FIREARM",utilityEligible=true,
        firearmFinalTier="RARE",firearmAmmoType=key}
end
local scorer=assert(ItemRarityUtilityCalculator.fixtureAmmoInheritance)
local good=ammo("Fixture.ReferenceControl","fixture:ammo")
scorer({reference("Fixture.Reference","fixture:ammo"),good})
assert(good.ammoInheritedFirearmTier=="RARE")
for _,badKey in ipairs({"",false,UNEXPECTED_USERDATA}) do
    local control=ammo("Fixture.ReferenceControl","fixture:ammo")
    local invalid=reference("Fixture.InvalidReference",badKey)
    scorer({reference("Fixture.Reference","fixture:ammo"),invalid,control})
    equal(good,control,"valid reference control")
    assert(invalid.isolationStatus,"invalid reference not isolated")
end
local missing=reference("Fixture.MissingReference",nil)
local onlyInvalid=ammo("Fixture.NoUsableReference","fixture:ammo")
scorer({missing,onlyInvalid})
assert(missing.isolationStatus and not onlyInvalid.utilityEligible and onlyInvalid.ammoInheritedFirearmTier==nil)
for repetition=1,2 do
    local cohort=controls(); local bad={ammo("Fixture.Missing",nil),ammo("Fixture.Empty","")}
    for n,value in ipairs({false,UNEXPECTED_USERDATA,12}) do bad[#bad+1]=ammo("Fixture.Bad"..n,value) end
    for _,c in ipairs(bad) do cohort[#cohort+1]=c end
    local unmatched=ammo("Fixture.Unmatched","fixture:unmatched"); cohort[#cohort+1]=unmatched
    local late=ammo("Fixture.Late","fixture:ammo"); cohort[#cohort+1]=late
    local rows=run(cohort,false,true)
    for id,row in pairs(baseline) do equal(row,rows[id],id) end
    for _,c in ipairs(bad) do assert(c.isolationStatus and c.ammoInheritedFirearmTier==nil,c.data.fullType) end
    assert(late.isolationStatus and late.ammoInheritedFirearmTier==nil)
    assert(unmatched.ammoInheritedFirearmTier==nil and not unmatched.utilityEligible,"invented compatible tier")
    local count=0; for _ in pairs(I.warningKeys) do count=count+1 end
    if repetition==1 then warnings=count else assert(count==warnings,"warning spam") end
end
return "UTILITY=AMMO","HEALTHY_COMPARED=2","ITEM_FAILURE_ISOLATED=yes","HEALTHY_ITEM_REGRESSION=0",
    "POPULATION_CONTAMINATION=0 (no ranking; compatibility references unchanged)","GLOBAL_FATAL=0 (item fixtures)","WARNINGS_DEDUPLICATED=yes"
