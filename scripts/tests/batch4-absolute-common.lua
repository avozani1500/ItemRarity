local function runAbsoluteFixture(kind,stage,field,healthyMetrics)
 local I=ItemRarityUtilityIsolation
 local function c(id,n)
  local metrics={};for k,v in pairs(healthyMetrics) do metrics[k]=v*n end
  return {data={fullType=id,module="Fixture",category="AMMO",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}},
   kind=kind,profile=id,subgroup=kind,utilityEligible=true,metrics=metrics}
 end
 local function controls() return {c("Fixture.One",1),c("Fixture.Two",2)} end
 local function equal(a,b,p)
  assert(type(a)==type(b),p.." type")
  if type(a)=="table" then for k,v in pairs(a) do equal(v,b[k],p.."."..tostring(k)) end;for k in pairs(b) do assert(a[k]~=nil,p.." extra") end
  else assert(a==b,p.." value") end
 end
 local function run(cs,legacy,late)
  local rows,by={},{};for _,v in ipairs(cs) do rows[v.data.fullType]=v.data;by[v.data.fullType]=v end
  FIXTURE_DISCOVERY=function(d) return by[d.fullType] end
  local saved=I.run
  if late then I.run=function(v,s,action) return saved(v,s,function()
   if v.data.fullType=="Fixture.Late" and s==stage..":Score" then error("late failure") end;return action()
  end) end end
  local ok,err=pcall(legacy and LEGACY_CALCULATE or ItemRarityUtilityCalculator.calculate,rows)
  I.run=saved;FIXTURE_DISCOVERY=nil;assert(ok,tostring(err));return rows
 end
 local baseline=run(controls());equal(run(controls(),true),baseline,"PRE_POST")
 local builder=assert(ItemRarityUtilityCalculator.fixtureBatch4Builders[kind])
 local function build(fields)
  local script={explosionPower=0,explosionRange=0,fireRange=0,noiseRange=0}
  for k,v in pairs(fields) do script[k]=v end
  script.InstanceItem=function(self) return self end
  return builder({fullType="Fixture.Builder",category="AMMO",displayCategory="Explosives"},script)
 end
 assert(build(healthyMetrics).kind==kind,"valid builder rejected")
 if kind=="NOISE_MAKER" then
  assert(build({noiseRange=20,fireRange=5})==nil,"fire exclusion removed")
  assert(build({noiseRange=20,explosionPower=5})==nil,"blast exclusion removed")
 elseif kind=="INCENDIARY" then
  assert(build({fireRange=5,explosionRange=2})==nil,"blast exclusion removed")
 end
 local warnings
 for repetition=1,2 do
  local cs=controls();local bad={}
  for index,value in ipairs({false,"bad",UNEXPECTED_USERDATA,math.huge,0/0,-1,0}) do
   local v=c("Fixture.Bad"..index,9);v.metrics[field]=value;bad[#bad+1]=v
  end
  local missing=c("Fixture.Missing",9);missing.metrics[field]=nil;bad[#bad+1]=missing
  for _,v in ipairs(bad) do cs[#cs+1]=v end
  cs[#cs+1]=c("Fixture.Late",100)
  local rows=run(cs,false,true);for id,row in pairs(baseline) do equal(row,rows[id],id) end
  for _,v in ipairs(bad) do assert(v.isolationStatus and v.utility==nil,"not isolated") end
  local n=0;for _ in pairs(I.warningKeys) do n=n+1 end;if warnings then assert(n==warnings,"warning spam") end;warnings=n
 end
 local config,key
 if kind=="EXPLOSIVE" then config=ItemRarityConfig.utility.explosive.weights;key="power"
 elseif kind=="INCENDIARY" then config=ItemRarityConfig.utility.incendiary.tiers;key="rare"
 else config=ItemRarityConfig.utility.noiseMaker.tiers;key="maxTier" end
 local previous=config[key];config[key]=false
 assert(not pcall(run,controls()),"global coefficient failure swallowed");config[key]=previous
 return "UTILITY="..kind,"HEALTHY_COMPARED=2","ITEM_FAILURE_ISOLATED=yes","HEALTHY_ITEM_REGRESSION=0",
  "POPULATION_CONTAMINATION=0","GLOBAL_FATAL=0 (item fixtures)","WARNINGS_DEDUPLICATED=yes"
end
