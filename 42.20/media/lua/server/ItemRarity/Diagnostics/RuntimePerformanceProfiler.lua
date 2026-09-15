-- Explicit development-only performance profiler. It is never required by
-- normal startup or rescan paths. All measurements are aggregate only.
require "ItemRarity/RarityUtils"

ItemRarityRuntimePerformanceProfiler = ItemRarityRuntimePerformanceProfiler or {}

local Profiler = ItemRarityRuntimePerformanceProfiler
Profiler.active = false
Profiler.currentRun = nil
Profiler.runs = nil

local function nowNs()
    if System and type(System.nanoTime) == "function" then
        local ok, value = pcall(function() return System.nanoTime() end)
        if ok and tonumber(value) then return tonumber(value), "System.nanoTime" end
    end
    -- B42 fallback only protects the diagnostic from an unavailable Java
    -- binding. In the supported runtime System.nanoTime is used.
    return math.floor((getTimestampMs and getTimestampMs() or 0) * 1000000), "getTimestampMs fallback"
end

local function sortedKeys(values)
    local keys = {}
    for key in pairs(values or {}) do table.insert(keys, key) end
    table.sort(keys)
    return keys
end

local function median(values)
    local copy = {}
    for _, value in ipairs(values or {}) do table.insert(copy, value) end
    table.sort(copy)
    if #copy == 0 then return 0 end
    local mid = math.floor((#copy + 1) / 2)
    return #copy % 2 == 1 and copy[mid] or (copy[mid] + copy[mid + 1]) / 2
end

function Profiler.isActive()
    return Profiler.active == true and type(Profiler.currentRun) == "table"
end

function Profiler.nowNs()
    return nowNs()
end

function Profiler.beginPhase(name, calls, items)
    if not Profiler.isActive() then return nil end
    local value = nowNs()
    return { name = name, startedNs = value, calls = calls or 1, items = items or 0 }
end

function Profiler.record(name, elapsedNs, calls, items)
    if not Profiler.isActive() then return end
    local phases = Profiler.currentRun.phases
    local phase = phases[name] or { calls = 0, items = 0, elapsedNs = 0 }
    phase.calls = phase.calls + (calls or 1)
    phase.items = phase.items + (items or 0)
    phase.elapsedNs = phase.elapsedNs + math.max(0, tonumber(elapsedNs) or 0)
    phases[name] = phase
end

function Profiler.endPhase(token)
    if not token or not Profiler.isActive() then return end
    local value = nowNs()
    Profiler.record(token.name, value - token.startedNs, token.calls, token.items)
end

function Profiler.beginCandidate()
    if not Profiler.isActive() then return nil end
    local candidate = { builders = {} }
    Profiler.currentRun.activeCandidate = candidate
    return candidate
end

function Profiler.beginCandidateBuilder(name)
    if not Profiler.isActive() then return nil end
    local token = { name = name, startedNs = nowNs(), runtimeInstances = 0 }
    local candidate = Profiler.currentRun.activeCandidate
    if candidate then table.insert(candidate.builders, token) end
    Profiler.currentRun.activeCandidateBuilder = token
    return token
end

function Profiler.runtimeInstanceCreated()
    local token = Profiler.isActive() and Profiler.currentRun.activeCandidateBuilder or nil
    if token then token.runtimeInstances = token.runtimeInstances + 1 end
end

function Profiler.endCandidateBuilder(token, accepted)
    if not token or not Profiler.isActive() then return end
    token.elapsedNs = math.max(0, nowNs() - token.startedNs)
    token.accepted = accepted == true
    local builders = Profiler.currentRun.candidateBuilders
    local row = builders[token.name] or { calls=0, accepted=0, rejected=0, runtimeInstances=0, elapsedNs=0, unsupportedCalls=0, unsupportedRuntimeInstances=0 }
    row.calls = row.calls + 1
    row.accepted = row.accepted + (token.accepted and 1 or 0)
    row.rejected = row.rejected + (token.accepted and 0 or 1)
    row.runtimeInstances = row.runtimeInstances + token.runtimeInstances
    row.elapsedNs = row.elapsedNs + token.elapsedNs
    builders[token.name] = row
    Profiler.currentRun.activeCandidateBuilder = nil
end

function Profiler.endCandidate(finalKind)
    if not Profiler.isActive() then return end
    local candidate = Profiler.currentRun.activeCandidate
    if candidate and finalKind == "UNSUPPORTED" then
        for _, token in ipairs(candidate.builders or {}) do
            local row = Profiler.currentRun.candidateBuilders[token.name]
            if row then
                row.unsupportedCalls = row.unsupportedCalls + 1
                row.unsupportedRuntimeInstances = row.unsupportedRuntimeInstances + (token.runtimeInstances or 0)
            end
        end
    end
    Profiler.currentRun.activeCandidate, Profiler.currentRun.activeCandidateBuilder = nil, nil
end

function Profiler.beginRun(index)
    local _, clock = nowNs()
    Profiler.currentRun = { index = index, clock = clock, startedNs = nowNs(), phases = {}, candidateBuilders = {} }
end

function Profiler.endRun(signature, matched)
    if not Profiler.isActive() then return end
    local finished = nowNs()
    local run = Profiler.currentRun
    run.totalNs = math.max(0, finished - run.startedNs)
    run.signature = signature or "-"
    run.matched = matched == true
    table.insert(Profiler.runs, run)
    Profiler.currentRun = nil
end

local function writeReport()
    local runs = Profiler.runs or {}
    if not getFileWriter then return false end
    local writer = getFileWriter("ItemRarity_PerformanceProfile.txt", true, false)
    if not writer then return false end

    local totals, builderTotals, runMs, signatures = {}, {}, {}, {}
    for _, run in ipairs(runs) do
        local ms = run.totalNs / 1000000
        table.insert(runMs, ms)
        signatures[run.signature] = true
        writer:write(string.format("run %d | total=%.3f ms | deterministic=%s | signature=%s\n", run.index, ms,
            run.matched and "MATCH" or "SEED/CHANGED", tostring(run.signature)))
        for name, phase in pairs(run.phases) do
            local total = totals[name] or { calls=0, items=0, elapsedNs=0 }
            total.calls = total.calls + phase.calls
            total.items = total.items + phase.items
            total.elapsedNs = total.elapsedNs + phase.elapsedNs
            totals[name] = total
        end
        for name, builder in pairs(run.candidateBuilders or {}) do
            local total = builderTotals[name] or { calls=0, accepted=0, rejected=0, runtimeInstances=0, elapsedNs=0, unsupportedCalls=0, unsupportedRuntimeInstances=0 }
            for _, field in ipairs({ "calls", "accepted", "rejected", "runtimeInstances", "elapsedNs", "unsupportedCalls", "unsupportedRuntimeInstances" }) do
                total[field] = total[field] + (builder[field] or 0)
            end
            builderTotals[name] = total
        end
    end
    local min, max, sum = math.huge, 0, 0
    for _, value in ipairs(runMs) do min=math.min(min,value); max=math.max(max,value); sum=sum+value end
    writer:write(string.format("\nrun stats | min=%.3f ms | max=%.3f ms | mean=%.3f ms | median=%.3f ms\n", min == math.huge and 0 or min, max, #runMs > 0 and sum/#runMs or 0, median(runMs)))
    writer:write("\n[ItemRarity][PERF]\n")
    writer:write("Phase | Calls | Items processed | Total ms (5 runs) | Mean ms/run | Mean ms/item\n")
    writer:write("--------------------------------------------------------------------------------\n")
    for _, name in ipairs(sortedKeys(totals)) do
        local phase = totals[name]
        local totalMs = phase.elapsedNs / 1000000
        writer:write(string.format("%s | %d | %d | %.3f | %.3f | %.6f\n", name, phase.calls, phase.items,
            totalMs, #runs > 0 and totalMs/#runs or 0, phase.items > 0 and totalMs/phase.items or 0))
    end
    writer:write("\n[ItemRarity][CANDIDATE DISCOVERY]\n")
    writer:write("Builder | Calls | Accepted | Rejected | Runtime instances | Total ms | Avg ms/call | Avg ms/rejected | Calls ending UNSUPPORTED | Runtime instances on UNSUPPORTED paths\n")
    writer:write("------------------------------------------------------------------------------------------------------------------------------------------------\n")
    for _, name in ipairs(sortedKeys(builderTotals)) do
        local row = builderTotals[name]
        local totalMs = row.elapsedNs / 1000000
        writer:write(string.format("%s | %d | %d | %d | %d | %.3f | %.6f | %.6f | %d | %d\n", name, row.calls, row.accepted, row.rejected,
            row.runtimeInstances, totalMs, row.calls > 0 and totalMs / row.calls or 0,
            row.rejected > 0 and totalMs / row.rejected or 0, row.unsupportedCalls, row.unsupportedRuntimeInstances))
    end
    writer:write("--------------------------------------------------------------------------------\n")
    writer:write(string.format("TOTAL | %d runs | - | %.3f | %.3f | -\n", #runs, sum, #runMs > 0 and sum/#runMs or 0))
    writer:write("clock="..tostring((runs[1] or {}).clock or "-").." | distinct signatures="..tostring(#sortedKeys(signatures)).."\n")
    writer:close()
    return true
end

-- Called only by the explicit client-command action in ItemRarityBootstrap.
function Profiler.runFiveScans()
    if not ItemRarityScanner or ItemRarityScanner.isScanning then return false, "scanner unavailable or busy" end
    Profiler.runs, Profiler.currentRun, Profiler.active = {}, nil, true
    local ok, err = pcall(function()
        for index = 1, 5 do
            Profiler.beginRun(index)
            ItemRarityScanner.rescanForPerformance("performance profile run "..tostring(index))
            if Profiler.currentRun then Profiler.endRun("aborted", false) end
        end
    end)
    Profiler.active = false
    if not ok then
        ItemRarityUtils.warn("Performance profile failed: "..tostring(err))
        return false, err
    end
    local wrote = writeReport()
    ItemRarityUtils.info("[PERF] aggregate five-run profile "..(wrote and "written: Zomboid/Lua/ItemRarity_PerformanceProfile.txt" or "completed (report writer unavailable)"))
    return wrote
end
