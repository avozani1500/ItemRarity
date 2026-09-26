local I=ItemRarityUtilityIsolation
local function script(properties)
    local s={unhappyChange=0,boredomChange=0,stressChange=0}
    for k,v in pairs(properties or {}) do s[k]=v end
    s.InstanceItem=function(self) return self end -- mock only; no Java item or OnCreate
    s.getLearnedRecipes=function(self) return self.recipes end
    return s
end
local function controls()
    return {
        Skill=script({skillTrained="Carpentry",lvlSkillTrained=3}),
        Map=script({map="RosewoodMap"}),
        Recipes=script({recipes="[RecipeA, RecipeB, RecipeA]"}),
        Mood=script({boredomChange=-25}),
        Trivial=script(),
        Special=script({onRead="fixture:callback"}),
    }
end
-- Exercise the existing recognized DisplayCategory, without adding LitE/LitS.
local previousManager=getScriptManager
local recognized=script({skillTrained="Carpentry",lvlSkillTrained=3})
recognized.getDisplayCategory=function() return "SkillBook" end
getScriptManager=function() return {FindItem=function() return recognized end} end
assert(ItemRarityItemClassifier.getFunctionalCategory("Fixture.Skill")=="LITERATURE")
recognized.getDisplayCategory=function() return "LitS" end
assert(ItemRarityItemClassifier.getFunctionalCategory("Fixture.Skill")=="UNKNOWN","coverage gap accidentally changed")
getScriptManager=previousManager
local function equal(a,b,path)
    assert(type(a)==type(b),path.." type")
    if type(a)=="table" then
        for k,v in pairs(a) do equal(v,b[k],path.."."..tostring(k)) end
        for k in pairs(b) do assert(a[k]~=nil,path.." extra "..tostring(k)) end
    else assert(a==b,path.." value "..tostring(a).." -> "..tostring(b)) end
end
local function run(scripts,legacy,scarcity)
    local rows,byId={},{}
    for id,s in pairs(scripts) do
        local fullType="Fixture."..id
        rows[fullType]={fullType=fullType,module="Fixture",category="LITERATURE",rarityTier="RARE",tableAvailability={routeWeightedPercentile=40}}
        if id=="BadScarcity" then rows[fullType].tableAvailability.routeWeightedPercentile=scarcity end
        byId[fullType]=s
    end
    FIXTURE_DISCOVERY=function(data)
        return (legacy and LEGACY_LITERATURE or ItemRarityUtilityCalculator.fixtureLiterature)(data,byId[data.fullType])
    end
    local ok,err=pcall(legacy and LEGACY_CALCULATE or ItemRarityUtilityCalculator.calculate,rows)
    FIXTURE_DISCOVERY=nil; assert(ok,tostring(err)); return rows
end
local baseline=run(controls())
equal(run(controls(),true),baseline,"pre-containment actual builders")
assert(baseline["Fixture.Trivial"].finalRarityTier=="COMMON")
assert(baseline["Fixture.Map"].finalRarityTier=="RARE")
local previous
for repetition=1,2 do
    local scripts=controls()
    for index,value in ipairs({false,"bad",UNEXPECTED_USERDATA,math.huge,0/0}) do scripts["Bad"..index]=script({boredomChange=value}) end
    local missing=script(); missing.boredomChange=nil; scripts.Missing=missing
    scripts.Throw=script(); scripts.Throw.getBoredomChange=function() error("getter failure") end
    scripts.BadScarcity=script({recipes="[RecipeA]"})
    local rows=run(scripts,false,false)
    for id,row in pairs(baseline) do equal(row,rows[id],id) end
    for id in pairs(scripts) do if not baseline["Fixture."..id] then
        assert(rows["Fixture."..id].utility==nil and rows["Fixture."..id].utilityEligible==false,id.." not isolated")
    end end
    local count=0; for _ in pairs(I.warningKeys) do count=count+1 end
    if previous then assert(count==previous,"literature warning spam") end; previous=count
end
local scripts=controls(); scripts.BadScarcity=script({recipes="[RecipeA]"})
local rows=run(scripts,false,nil)
assert(rows["Fixture.BadScarcity"].utility==nil,"missing scarcity invented")
local old=ItemRarityConfig.utility.literature.entertainment.boredomCap
ItemRarityConfig.utility.literature.entertainment.boredomCap=false
assert(not pcall(run,controls()),"global Literature config swallowed")
ItemRarityConfig.utility.literature.entertainment.boredomCap=old
return "UTILITY=LITERATURE","HEALTHY_COMPARED=5 (+1 SPECIAL_PARTIAL preserved)","ITEM_FAILURE_ISOLATED=yes",
    "HEALTHY_ITEM_REGRESSION=0","POPULATION_CONTAMINATION=0 (structural/absolute; no relative population)",
    "GLOBAL_FATAL=0 (item fixtures)","WARNINGS_DEDUPLICATED=yes","LEARNED_RECIPES_MAP_TRIVIAL_UNCHANGED=yes"
