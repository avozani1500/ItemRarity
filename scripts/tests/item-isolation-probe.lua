local I = ItemRarityUtilityIsolation
local config = UTILITY.container.v2.groups.BACK
local function item(fullType, capacity)
    return {
        data={fullType=fullType,displayName=fullType,module=fullType:match("^([^%.]+)")},
        kind="CONTAINER", utilityEligible=true, containerV2Group="BACK", config=config,
        profile=fullType, metrics={capacity=capacity, weightReduction=70, emptyWeight=1, attachments=0},
        directions={capacity=false,weightReduction=false,emptyWeight=true,attachments=false},
    }
end
local function references()
    return {item("Base.ReferenceA",10),item("Base.ReferenceB",20)}
end
I.beginScan()
local controls=references()
scoreContainerV2(controls)
assert(controls[1].utility and controls[2].utility, "Healthy controls must score")

I.beginScan()
local trial=references()
local bad={
    item("Fixture.MissingPercentile",15),
    item("Fixture.String", "bad-number"),
    item("Fixture.Boolean",true),
    item("Fixture.Userdata",UNEXPECTED_USERDATA),
    item("Fixture.MissingField",nil),
    item("Fixture.ThrowingObserver",10),
}
assert(type(UNEXPECTED_USERDATA)=="userdata", "Fixture must be real Java userdata")
for _,candidate in ipairs(bad) do table.insert(trial,candidate) end
local ok,err=pcall(function()
    scoreContainerV2(trial,function(candidate)
        if candidate.data.fullType=="Fixture.ThrowingObserver" then error("fixture callback failure") end
    end)
end)
assert(ok, tostring(err))
for index=1,2 do assert(trial[index].utility==controls[index].utility,"Unrelated score changed") end
for _,candidate in ipairs(bad) do
    assert(candidate.isolationStatus and candidate.utility==nil and not candidate.utilityEligible,
        "Bad item escaped: "..candidate.data.fullType)
end
assert(bad[1].isolationStatus=="PARTIAL_DEFER")
assert(bad[5].isolationStatus=="PARTIAL_DEFER")
assert(I.report.isolatedItemFailures==4 and I.report.partialItems==2)

-- Discovery failures are item-local, not a whole-scan pcall.
local failed=I.discover({fullType="Fixture.Discovery",module="Fixture"},function() error("callback failure") end)
assert(failed.isolationStatus=="ERROR_ISOLATED" and failed.utility==nil)
local good=I.discover({fullType="Fixture.Healthy"},function() return item("Fixture.Healthy",10) end)
assert(good.utilityEligible and not good.isolationStatus)

-- Invalid global configuration must propagate, not be labelled a bad item.
local saved=config.weights.capacity
config.weights.capacity=false
local configOK=pcall(function() scoreContainerV2(references()) end)
config.weights.capacity=saved
assert(not configOK, "Global configuration failure swallowed")
local fixtureFailures,fixturePartials=I.report.isolatedItemFailures,I.report.partialItems
-- Invalid Base.* entries must not change ANY comparable population/anchor.
-- Include a valid modded control and a reference that throws only at scoring.
local clean=references()
table.insert(clean,item("Fixture.HealthyMod",20))
scoreContainerV2(clean)
local contaminated=references()
table.insert(contaminated,item("Fixture.HealthyMod",20))
local missing=item("Base.Missing",nil)
missing.metrics.emptyWeight=900
local invalid=item("Base.Invalid","900")
local late=item("Base.LateFailure",900)
local metamethod=item("Base.MetricGetter",nil)
setmetatable(metamethod.metrics,{__index=function() error("invalid metric getter") end})
for _,badReference in ipairs({missing,invalid,late,metamethod}) do table.insert(contaminated,badReference) end
scoreContainerV2(contaminated,function(candidate)
    if candidate.data.fullType=="Base.LateFailure" then error("reference scoring exception") end
end)
for index=1,3 do
    local a,b=clean[index],contaminated[index]
    assert(a.utility==b.utility,"Population contaminated healthy score")
    assert(a.profileCount==b.profileCount,"Population contaminated profile count")
    assert(a.containerRankingConfidence==b.containerRankingConfidence,"Population contaminated confidence")
    for metric,value in pairs(a.metricPercentiles) do assert(b.metricPercentiles[metric]==value,"Population contaminated percentile") end
end
for _,badReference in ipairs({missing,invalid,late,metamethod}) do assert(badReference.isolationStatus) end

local printBefore=print
local warningCount=0
print=function() warningCount=warningCount+1 end
for attempt=1,2 do
    I.mark(item("Fixture.Dedup",10),"test-stage","ERROR_ISOLATED","same reason",{value=false})
end
print=printBefore
assert(warningCount==1,"Duplicate warnings")
local function calculateFixture(withBad,legacy)
    local list=references()
    if withBad then
        table.insert(list,item("Fixture.NilRank",15))
        table.insert(list,item("Fixture.BadType",false))
        table.insert(list,item("Fixture.Discovery",10))
    end
    local results,candidates={},{}
    for _,c in ipairs(list) do
        c.data.rarityTier="COMMON"
        c.data.category="CONTAINER"
        c.data.tableAvailability={routeWeightedPercentile=90}
        results[c.data.fullType]=c.data
        candidates[c.data.fullType]=c
    end
    FIXTURE_DISCOVERY=function(data)
        if data.fullType=="Fixture.Discovery" then error("fixture discovery callback") end
        return candidates[data.fullType]
    end
    if legacy then LEGACY_CALCULATE(results) else ItemRarityUtilityCalculator.calculate(results) end
    FIXTURE_DISCOVERY=nil
    return results
end
local calculateTested=ItemRarityUtilityCalculator and ItemRarityUtilityCalculator.calculate ~= nil
if calculateTested then
local before=calculateFixture(false)
local committed=calculateFixture(false,true)
for fullType,data in pairs(committed) do
    assert(before[fullType].utility==data.utility,"Healthy committed Utility changed")
    assert(before[fullType].finalRarityTier==data.finalRarityTier,"Healthy committed tier changed")
end
local after=calculateFixture(true)
for fullType,data in pairs(before) do
    assert(after[fullType].utility==data.utility,"Unrelated published Utility changed")
    assert(after[fullType].finalRarityTier==data.finalRarityTier,"Unrelated final tier changed")
end
for _,fullType in ipairs({"Fixture.NilRank","Fixture.BadType","Fixture.Discovery"}) do
    assert(after[fullType].utility==nil and after[fullType].utilitySupport=="UTILITY_PARTIAL")
    assert(after[fullType].finalRarityTier=="COMMON", "Existing Scarcity fallback changed")
end
end
return "CONTAINER_BATCH_COMPLETES=yes", "UNRELATED_CONTAINER_SCORES_UNCHANGED=yes",
    "ISOLATED_ITEM_FAILURES="..fixtureFailures,
    "PARTIAL_ITEMS="..fixturePartials, "ITEM_INDUCED_FATALS_IN_FIXTURES=0",
    "GLOBAL_CONFIGURATION_ERROR_PROPAGATES=yes", "CALCULATE_WITH_CONTAINER_FIXTURES="..(calculateTested and "yes" or "NOT_RUN"),
    "UNRELATED_FINAL_TIERS_UNCHANGED="..(calculateTested and "yes" or "NOT_RUN"), "POPULATION_CONTAMINATION=0",
    "WARNING_DEDUPLICATION=yes", "WORLD_SCAN_VALIDATION=NOT_RUN"
