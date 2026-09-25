-- Explicit DEV-only A/B command. Loading this file installs no observers and
-- performs no scans, writes, reloads, candidate construction or publication.
ItemRarityBatchComparison = ItemRarityBatchComparison or { snapshots={} }
local D = ItemRarityBatchComparison
local kinds = { CONTAINER=true, FIREARM=true, MELEE_WEAPON=true }
local admissions = {
    ["Container:ReferenceAdmission"]=true,
    ["Firearm:ReferenceAdmission"]=true,
    ["Melee:ReferenceAdmission"]=true,
}

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}; seen[value] = result
    for k, v in pairs(value) do result[k] = copy(v, seen) end
    return result
end

local function keys(t)
    local result = {}
    for k in pairs(t) do result[#result+1] = k end
    table.sort(result, function(a,b) return tostring(a) < tostring(b) end)
    return result
end

local function diff(a, b, path, out)
    if type(a) == "table" and type(b) == "table" then
        local all = {}
        for k in pairs(a) do all[k] = true end
        for k in pairs(b) do all[k] = true end
        for _, k in ipairs(keys(all)) do diff(a[k], b[k], path .. "." .. tostring(k), out) end
    elseif a ~= b then
        out[#out+1] = path .. " before=" .. tostring(a) .. " (" .. type(a) .. ") after=" .. tostring(b) .. " (" .. type(b) .. ")"
    end
end

local function capture(observed, admitted)
    local rows, references, missing = {}, {}, 0
    local results = ItemRarityScanner.results
    for _, id in ipairs(keys(results)) do
        local data = results[id]
        local c = observed[data]
        local kind = data.failedUtilityKind or data.utilityKind
        if kinds[kind] then
            if not c or c.data ~= data then
                missing = missing + 1
                print("[ItemRarity][BATCH_DIFF] " .. id .. " observation=missing")
            else
                local state = c.utilityState or "UNKNOWN"
                if c.isolationStatus then
                    state = c.isolationStatus == "ERROR_ISOLATED" and "ERROR_ISOLATED" or "PARTIAL"
                elseif c.utilityEligible == false then state = "PARTIAL" end
                local member = admitted[c] == true and not c.isolationStatus
                local group = c.containerV2Group or c.subgroup or kind
                local reference, absoluteReference = false, false
                -- Membership is observed at the real admission boundary.
                -- Representative identities below are RECONSTRUCTED using the
                -- existing deterministic fullType/profile deduplication rule;
                -- private percentile/anchor arrays are not directly exposed.
                if member and (kind == "MELEE_WEAPON" or id:match("^Base%.")) then
                    local refKey = kind .. ":" .. tostring(group) .. ":" .. tostring(c.profile)
                    if kind == "MELEE_WEAPON" then refKey = kind .. ":" .. tostring(c.profile) end
                    if not references[refKey] then references[refKey]=true; reference=true end
                    if kind == "FIREARM" then
                        local absoluteKey = "FIREARM_ABSOLUTE:" .. tostring(c.profile)
                        if not references[absoluteKey] then references[absoluteKey]=true; absoluteReference=true end
                    end
                end
                rows[id] = {
                    utilityKind=c.kind, candidateState=state,
                    population={admitted=member,group=group,profile=c.profile,reference=reference,absoluteReference=absoluteReference},
                    utilityScore=c.utility, publishedUtility=data.utility,
                    -- Container/Melee choose tiers through a matrix. They do
                    -- not have a final scalar; do not invent one for this audit.
                    finalScore=data.firearmFinalScore,
                    finalScorePolicy=kind == "FIREARM" and "FIREARM_SCORE" or "TIER_MATRIX_NO_SCALAR",
                    finalTier=data.finalRarityTier,
                    metrics=copy(c.metrics), components=copy(c.utilityComponents),
                    percentiles=copy(c.metricPercentiles), profileCount=c.profileCount,
                }
            end
        end
    end
    return { rows=rows, missing=missing,
        report=copy(ItemRarityUtilityCalculator.lastItemIsolationReport),
        signature=ItemRarityScanner.lastScanSignature,
        fingerprint=ItemRarityScanner.lastScanSignatureFingerprint }
end

function D.compare(beforeLabel, afterLabel)
    local a, b = D.snapshots[beforeLabel], D.snapshots[afterLabel]
    assert(a and b, "Both in-memory snapshots are required")
    local all, compared, changed, membership, counts = {}, 0, 0, 0, {}
    for id in pairs(a.rows) do all[id] = true end
    for id in pairs(b.rows) do all[id] = true end
    for _, id in ipairs(keys(all)) do
        local old, new = a.rows[id], b.rows[id]
        local delta, popDelta = {}, {}
        diff(old, new, "row", delta)
        diff(old and old.population, new and new.population, "population", popDelta)
        if #popDelta > 0 then membership = membership + 1 end
        -- Losing a healthy item (or changing it to PARTIAL) is a regression too.
        if old and old.candidateState == "SAFE" then
            compared = compared + 1
            counts[old.utilityKind] = (counts[old.utilityKind] or 0) + 1
            if #delta > 0 then changed = changed + 1 end
        end
        if #delta > 0 then print("[ItemRarity][BATCH_DIFF] " .. id .. " | " .. table.concat(delta, " | ")) end
    end
    local contamination = "UNKNOWN"
    -- With no isolated/partial failures, no invalid item can contaminate this
    -- run. If failure paths were exercised, reconstructing membership alone
    -- cannot prove that private anchors were rebuilt: never print a false zero.
    if a.missing == 0 and b.missing == 0
        and a.report.isolatedItemFailures == 0 and b.report.isolatedItemFailures == 0
        and a.report.partialItems == 0 and b.report.partialItems == 0 then contamination = 0 end
    local result = { HEALTHY_ITEMS_COMPARED=compared, HEALTHY_ITEM_REGRESSION=changed,
        POPULATION_MEMBERSHIP_CHANGES=membership, POPULATION_CONTAMINATION=contamination,
        OBSERVATION_MISSING=a.missing+b.missing }
    if a.missing+b.missing > 0 then result.HEALTHY_ITEM_REGRESSION="UNKNOWN" end
    for _, name in ipairs(keys(result)) do print("[ItemRarity][BATCH] " .. name .. "=" .. tostring(result[name])) end
    for _, kind in ipairs(keys(kinds)) do print("[ItemRarity][BATCH] " .. kind .. "_HEALTHY_COMPARED=" .. tostring(counts[kind] or 0)) end
    local match = a.signature ~= nil and b.signature ~= nil and a.signature == b.signature
    print("[ItemRarity][BATCH] SECOND_RESCAN=" .. (match and "MATCH" or "MISMATCH"))
    print("[ItemRarity][BATCH] COMPARISON_SCOPE=SAME_SESSION_A_B; REFERENCES=RECONSTRUCTED_FROM_OBSERVED_ADMISSION")
    D.lastComparison = result
    return result
end

function D.run(label)
    assert(label == "A" or label == "B", "Use A or B")
    assert(not D.running, "Batch comparison already running")
    if label == "B" then assert(D.snapshots.A, "Run A first") end
    local I = assert(ItemRarityUtilityIsolation, "Isolation module unavailable")
    assert(ItemRarityScanner and ItemRarityScanner.rescan, "Scanner unavailable")
    local originalRun, originalDiscover = I.run, I.discover
    local oldReport = ItemRarityUtilityCalculator.lastItemIsolationReport
    local observed, admitted = {}, {}
    D.running = true
    if label == "A" then D.snapshots = {}; D.lastComparison = nil end
    D.snapshots[label] = nil
    I.run = function(candidate, stage, action)
        local ok, value = originalRun(candidate, stage, action)
        -- Augmentation creates reference proxies with the SAME fullType but
        -- a different data table. Never let a proxy replace the actual row.
        if candidate.data then observed[candidate.data] = candidate end
        if admissions[stage] then
            -- Melee admission returns nil on success; the other two return true.
            admitted[candidate] = ok and not candidate.isolationStatus
                and (stage == "Melee:ReferenceAdmission" or value == true)
        end
        return ok, value
    end
    I.discover = function(data, action)
        local candidate = originalDiscover(data, action)
        observed[data] = candidate
        return candidate
    end
    -- Cleanup only: global errors are rethrown, not isolated or swallowed.
    local ok, err = pcall(ItemRarityScanner.rescan, "DEV batch " .. label)
    I.run, I.discover = originalRun, originalDiscover
    D.running = false
    if not ok then
        print("[ItemRarity][BATCH] GLOBAL_SCAN_COMPLETED=no; GLOBAL_SCAN_FATALS=1")
        error(err)
    end
    local report = ItemRarityUtilityCalculator.lastItemIsolationReport
    assert(report and report ~= oldReport and report.calculateCompleted, "No fresh completed calculation")
    D.snapshots[label] = capture(observed, admitted)
    print("[ItemRarity][BATCH] SNAPSHOT=" .. label .. "; GLOBAL_SCAN_COMPLETED=yes; GLOBAL_SCAN_FATALS=0")
    if label == "B" then return D.compare("A", "B") end
    return true
end

return D
