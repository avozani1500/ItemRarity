local I=ItemRarityUtilityIsolation
local function c(id,light,fire,n)
 return {data={fullType=id,module="Fixture",category="MISC",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
 kind="LIGHTFIRE",profile=id,subgroup="LIGHTFIRE",utilityEligible=true,lightFunction=light,fireFunction=fire,
 metrics={lightStrength=n,lightDistance=n*10,estimatedUses=n*20,useDelta=.01}}
end
local function controls() return {c("Fixture.LightA",true,false,1),c("Fixture.LightB",true,false,2),
 c("Fixture.Fire",false,true,1),c("Fixture.Dual",true,true,1.5)} end
local function eq(a,b,p)
 assert(type(a)==type(b),p.." type")
 if type(a)=="table" then for k,v in pairs(a) do eq(v,b[k],p.."."..tostring(k)) end; for k in pairs(b) do assert(a[k]~=nil,p.." extra") end
 else assert(a==b,p.." value") end
end
local function run(cs,legacy,stage)
 local rows,by={},{}; for _,v in ipairs(cs) do rows[v.data.fullType]=v.data;by[v.data.fullType]=v end
 FIXTURE_DISCOVERY=function(d) return by[d.fullType] end
 local saved=I.run
 if stage then I.run=function(v,s,action) return saved(v,s,function()
  if v.data.fullType=="Fixture.Late" and s==stage then error("late failure") end;return action()
 end) end end
 local ok,err=pcall(legacy and LEGACY_CALCULATE or ItemRarityUtilityCalculator.calculate,rows)
 I.run=saved; FIXTURE_DISCOVERY=nil;assert(ok,tostring(err));return rows
end
local baseline=run(controls());eq(run(controls(),true),baseline,"PRE_POST")
local builder=assert(ItemRarityUtilityCalculator.fixtureBatch4Builders.LIGHTFIRE)
local unlit={lightStrength=0,lightDistance=0,useDelta=.01}
unlit.InstanceItem=function(self) return self end
assert(builder({fullType="Fixture.UnlitBuilder",displayCategory="LightSource"},unlit)==nil,"unlit state promoted")
local lit={lightStrength=1,lightDistance=10,useDelta=.01}
lit.InstanceItem=function(self) return self end
assert(builder({fullType="Fixture.LitBuilder",displayCategory="LightSource"},lit).utilityEligible)
lit.useDelta=nil
assert(not builder({fullType="Fixture.PartialBuilder",displayCategory="LightSource"},lit).utilityEligible,"missing duration promoted")
local warnings
for repetition=1,2 do
 local cs=controls(); local bad={}
 for index,value in ipairs({false,"bad",UNEXPECTED_USERDATA,math.huge,0/0}) do
  local v=c("Fixture.Bad"..index,true,false,99);v.metrics.lightStrength=value;bad[#bad+1]=v
 end
 local missing=c("Fixture.Missing",true,false,99);missing.metrics.estimatedUses=nil;bad[#bad+1]=missing
 for _,v in ipairs(bad) do cs[#cs+1]=v end
 local partial=c("Fixture.Unlit",true,false,99);partial.utilityEligible=false;partial.metrics.estimatedUses=nil;cs[#cs+1]=partial
 local rows=run(cs)
 for id,row in pairs(baseline) do eq(row,rows[id],id) end
 for _,v in ipairs(bad) do assert(v.isolationStatus and v.utility==nil) end
 assert(not partial.utilityEligible and partial.utility==nil,"partial promoted")
 local n=0;for _ in pairs(I.warningKeys) do n=n+1 end;if warnings then assert(n==warnings,"warning spam") end;warnings=n
end
for _,stage in ipairs({"LightFire:LightScore","LightFire:FireScore","LightFire:Final"}) do
 local cs=controls();cs[#cs+1]=c("Fixture.Late",true,true,1e8)
 local rows=run(cs,false,stage);for id,row in pairs(baseline) do eq(row,rows[id],stage..id) end
end
local prior=ItemRarityConfig.utility.lightFire.light.illumination
ItemRarityConfig.utility.lightFire.light.illumination=false
assert(not pcall(run,controls()),"global config error swallowed")
ItemRarityConfig.utility.lightFire.light.illumination=prior
return "UTILITY=LIGHTFIRE","HEALTHY_COMPARED=4","ITEM_FAILURE_ISOLATED=yes","HEALTHY_ITEM_REGRESSION=0",
 "POPULATION_CONTAMINATION=0","GLOBAL_FATAL=0 (item fixtures)","PARTIAL_STATES_NOT_PROMOTED=yes","WARNINGS_DEDUPLICATED=yes"
