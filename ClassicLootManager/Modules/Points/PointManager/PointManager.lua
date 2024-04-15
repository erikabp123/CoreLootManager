-- ------------------------------- --
local  _, CLM = ...
-- ------ CLM common cache ------- --
local LOG       = CLM.LOG
local CONSTANTS = CLM.CONSTANTS
local UTILS     = CLM.UTILS
-- ------------------------------- --

local typeof = UTILS.typeof
local getGuidFromInteger = UTILS.getGuidFromInteger


CONSTANTS.POINT_MANAGER_ACTION = {
    MODIFY = 0,
    SET = 1,
    DECAY = 2
}

CONSTANTS.POINT_MANAGER_ACTIONS = UTILS.Set({ 0, 1, 2 })

local function strsub32(s)
    return strsub(tostring(s or ""), 1, 32)
end

local function update_profile_standings(mutate, roster, targets, value, reason, changeType, timestamp, pointHistoryEntry, isGUID, alreadyApplied)
    alreadyApplied = alreadyApplied or {}
    local getGUID
    if isGUID then
        getGUID = (function(i) return i end)
    else
        getGUID = (function(i) return getGuidFromInteger(i) end)
    end
    for _,target in ipairs(targets) do
        local mainProfile = nil
        local GUID = getGUID(target)
        if not roster:IsProfileInRoster(GUID) then
            LOG:Debug("PointManager update_profile_standings(): Unknown profile guid [%s] in roster [%s]", GUID, roster:UID())
        else
            local targetProfile = CLM.MODULES.ProfileManager:GetProfileByGUID(GUID)
            if targetProfile and not targetProfile:IsLocked() then
                if roster:IsProfileInRoster(GUID) and pointHistoryEntry then
                    roster:AddProfilePointHistory(pointHistoryEntry, targetProfile)
                end
                -- Check if we have main-alt linking
                if targetProfile:Main() == "" then -- is main
                    if targetProfile:HasAlts() then -- has alts
                        mainProfile = targetProfile
                    end
                else -- is alt
                    mainProfile = CLM.MODULES.ProfileManager:GetProfileByGUID(targetProfile:Main())
                end
                -- Check if we should schedule it for alert
                CLM.MODULES.EventManager:DispatchEvent(
                    CONSTANTS.EVENTS.USER_RECEIVED_POINTS,
                    {
                        value = value,
                        reason = reason,
                        changeType = changeType,
                        rosterType = roster:GetPointType()
                    }, timestamp, GUID)
                -- If we have a linked case then we alter the GUID to mains guid
                if mainProfile then
                    GUID = mainProfile:GUID()
                end
                if roster:IsProfileInRoster(GUID) then
                    if not alreadyApplied[GUID] then
                        mutate(roster, GUID, value, timestamp)
                        alreadyApplied[GUID] = true
                        if mainProfile then
                            -- if we have a linked case then we need to mirror the change to all alts
                            roster:MirrorStandings(GUID, mainProfile:Alts(), true)
                        end
                    end
                else
                    LOG:Debug("PointManager apply_mutator(): Unknown profile guid [%s] in roster [%s]", GUID, roster:UID())
                    return
                end
            end
        end
    end
end

local function apply_mutator(entry, mutate)
    local roster = CLM.MODULES.RosterManager:GetRosterByUid(entry:rosterUid())
    if not roster then
        LOG:Debug("PointManager apply_mutator(): Unknown roster uid %s", entry:rosterUid())
        return
    end

    local pointHistoryEntry = CLM.MODELS.PointHistory:New(entry)
    roster:AddRosterPointHistory(pointHistoryEntry)

    update_profile_standings(mutate, roster, entry:targets(), entry:value(), entry:reason(), entry:type(), entry:time(), pointHistoryEntry)
end

local function apply_roster_mutator(entry, mutate)
    local roster = CLM.MODULES.RosterManager:GetRosterByUid(entry:rosterUid())
    if not roster then
        LOG:Debug("PointManager apply_roster_mutator(): Unknown roster uid %s", entry:rosterUid())
        return
    end

    local profiles = roster:Profiles()
    if entry:ignoreNegatives() then
        local positiveProfiles = {}
        for _, GUID in ipairs(profiles) do
            local standings = roster:Standings(GUID)
            if standings and standings >= 0 then
                positiveProfiles[#positiveProfiles+1] = GUID
            end
        end
        profiles = positiveProfiles
    end

    local pointHistoryEntry = CLM.MODELS.PointHistory:New(entry, profiles)
    roster:AddRosterPointHistory(pointHistoryEntry)

    update_profile_standings(mutate, roster, profiles, entry:value(), entry:reason(), entry:type(), entry:time(), pointHistoryEntry, true)
end

local function apply_raid_mutator(self, entry, mutate)
    local raid = CLM.MODULES.RaidManager:GetRaidByUid(entry:raidUid())
    if not raid then
        LOG:Debug("PointManager apply_raid_mutator(): Unknown raid uid %s", entry:raidUid())
        return
    end
    local roster = raid:Roster()
    if not roster then
        LOG:Debug("PointManager apply_raid_mutator(): Unknown roster")
        return
    end

    local players = raid:Players()
    local pointHistoryEntry = CLM.MODELS.PointHistory:New(entry, players)
    self:AddPointHistory(roster, players, pointHistoryEntry)
    local playersOnStandby = raid:PlayersOnStandby()
    if entry:standby() and (#playersOnStandby > 0) then
        local alreadyApplied = {}
        -- Regular players
        update_profile_standings(mutate, roster, players, entry:value(), entry:reason(), entry:type(), entry:time(), nil, true, alreadyApplied)
        -- Standby players
        local config = raid:Configuration()
        local newValue = UTILS.round(config:Get("benchMultiplier") * entry:value(), config:Get("roundDecimals"))
        pointHistoryEntry = CLM.MODELS.PointHistory:New(entry, playersOnStandby, nil, newValue, CONSTANTS.POINT_CHANGE_REASON.STANDBY_BONUS)
        pointHistoryEntry.note = CONSTANTS.POINT_CHANGE_REASONS.ALL[entry:reason()] or ""
        self:AddPointHistory(roster, playersOnStandby, pointHistoryEntry)
        update_profile_standings(mutate, roster, playersOnStandby, newValue, entry:reason(), entry:type(), entry:time(), nil, true, alreadyApplied)
    else
        update_profile_standings(mutate, roster, raid:Players(), entry:value(), entry:reason(), entry:type(), entry:time(), nil, true)
    end
end

local function mutate_update_standings(roster, GUID, value, timestamp)
    roster:UpdateStandings(GUID, value, timestamp)
end

local function mutate_update_spent(roster, GUID, value, timestamp)
    roster:UpdateSpent(GUID, value)
end

local function mutate_set_standings(roster, GUID, value, timestamp)
    roster:SetStandings(GUID, value)
end

local function mutate_set_spent(roster, GUID, value, timestamp)
    roster:SetSpent(GUID, value)
end

local function mutate_decay_total(roster, GUID, value, timestamp)
    roster:DecayTotal(GUID, value)
end

local function mutate_decay_standings(roster, GUID, value, timestamp)
    roster:DecayStandings(GUID, value)
end

local function mutate_decay_spent(roster, GUID, value, timestamp)
    roster:DecaySpent(GUID, value)
end

local function verify_modify_point_change_type(roster, pointChangeType, functionName)
    local success = false
    if (roster:GetPointType() == CONSTANTS.POINT_TYPE.EPGP) then
        if CONSTANTS.POINT_AWARD_TYPES[pointChangeType] then
            success = true
        end
    else
        if pointChangeType == CONSTANTS.POINT_CHANGE_TYPE.POINTS then
            success = true
        end
    end
    if not success then
        LOG:Error("%s: Invalid point award type (%s)", functionName, pointChangeType)
    end
    return success
end

local function verify_set_point_change_type(roster, pointChangeType, functionName)
    local success = false
    if CONSTANTS.POINT_AWARD_TYPES[pointChangeType] then
        success = true
    end
    if not success then
        LOG:Error("%s: Invalid point set type (%s)", functionName, pointChangeType)
    end
    return success
end

local function verify_decay_point_change_type(roster, pointChangeType, functionName)
    local success = false
    if (roster:GetPointType() == CONSTANTS.POINT_TYPE.EPGP) then
        if CONSTANTS.POINT_DECAY_TYPES[pointChangeType] then
            success = true
        end
    else
        if pointChangeType == CONSTANTS.POINT_CHANGE_TYPE.POINTS then
            success = true
        end
    end
    if not success then
        LOG:Error("%s: Invalid point decay type (%s)", functionName, pointChangeType)
    end
    return success
end

local verify_point_change_type = {
    [CONSTANTS.POINT_MANAGER_ACTION.MODIFY ] = verify_modify_point_change_type,
    [CONSTANTS.POINT_MANAGER_ACTION.SET ] = verify_set_point_change_type,
    [CONSTANTS.POINT_MANAGER_ACTION.DECAY ] = verify_decay_point_change_type,
}

local PointManager = {}
function PointManager:Initialize()
    LOG:Trace("PointManager:Initialize()")

    CLM.MODULES.LedgerManager:RegisterEntryType(
        CLM.MODELS.LEDGER.POINTS.Modify,
        (function(entry)
            LOG:TraceAndCount("mutator(PointsModify)")
            local mutator = mutate_update_standings
            if entry:spent() then
                mutator = mutate_update_spent
            end
            apply_mutator(entry, mutator)
        end))

    CLM.MODULES.LedgerManager:RegisterEntryType(
        CLM.MODELS.LEDGER.POINTS.Set,
        (function(entry)
            LOG:TraceAndCount("mutator(PointsSet)")
            local mutator = mutate_set_standings
            if entry:spent() then
                mutator = mutate_set_spent
            end
            apply_mutator(entry, mutator)
        end))

    CLM.MODULES.LedgerManager:RegisterEntryType(
        CLM.MODELS.LEDGER.POINTS.Decay,
        (function(entry)
            LOG:TraceAndCount("mutator(PointsDecay)")
            if entry:type() == CONSTANTS.POINT_CHANGE_TYPE.POINTS then
                apply_mutator(entry, mutate_decay_standings)
            elseif entry:type() == CONSTANTS.POINT_CHANGE_TYPE.SPENT then
                apply_mutator(entry, mutate_decay_spent)
            else
                apply_mutator(entry, mutate_decay_total)
            end
        end))

    CLM.MODULES.LedgerManager:RegisterEntryType(
        CLM.MODELS.LEDGER.POINTS.ModifyRoster,
        (function(entry)
            LOG:TraceAndCount("mutator(PointsModifyRoster)")

            local mutator = mutate_update_standings
            if entry:spent() then
                mutator = mutate_update_spent
            end
            apply_roster_mutator(entry, mutator)
        end))

    CLM.MODULES.LedgerManager:RegisterEntryType(
        CLM.MODELS.LEDGER.POINTS.DecayRoster,
        (function(entry)
            LOG:TraceAndCount("mutator(PointsDecayRoster)")
            if entry:type() == CONSTANTS.POINT_CHANGE_TYPE.POINTS then
                apply_roster_mutator(entry, mutate_decay_standings)
            elseif entry:type() == CONSTANTS.POINT_CHANGE_TYPE.SPENT then
                apply_roster_mutator(entry, mutate_decay_spent)
            else
                apply_roster_mutator(entry, mutate_decay_total)
            end
        end))

    CLM.MODULES.LedgerManager:RegisterEntryType(
        CLM.MODELS.LEDGER.POINTS.ModifyRaid,
        (function(entry)
            LOG:TraceAndCount("mutator(PointsModifyRaid)")
            local mutator = mutate_update_standings
            if entry:spent() then
                mutator = mutate_update_spent
            end
            apply_raid_mutator(self, entry, mutator)
        end))


end

function PointManager:UpdatePoints(roster, targets, value, reason, action, note, pointChangeType, forceInstant)
    LOG:Trace("PointManager:UpdatePoints()")
    if not CONSTANTS.POINT_MANAGER_ACTIONS[action] then
        LOG:Error("PointManager:UpdatePoints(): Unknown action")
        return
    end
    if targets == nil then
        LOG:Error("PointManager:UpdatePoints(): Missing targets")
        return
    end
    if type(value) ~= "number" then
        LOG:Error("PointManager:UpdatePoints(): Value is not a number")
        return
    end
    if not typeof(roster, CLM.MODELS.Roster) then
        LOG:Error("PointManager:UpdatePoints(): Missing valid roster")
        return
    end
    if not verify_point_change_type[action](roster, pointChangeType, "PointManager:UpdatePoints()") then
        LOG:Error("123")
        return
    end

    -- Ok what happened here is that originaly there was a boolean parameter isSpent
    -- which was denoting if point change was for current or spent Points
    -- With move to Enum we now need to translate the enum to boolean
    -- As still the change can only be between Points / Spent
    -- This will be true for all isSpent changes
    local isSpent = (pointChangeType == CONSTANTS.POINT_CHANGE_TYPE.SPENT)
    local uid = roster:UID()

    -- Always a list, even for single entry
    if typeof(targets, CLM.MODELS.Profile) or type(targets) == "number" or type(targets) == "string" then
        targets = { targets }
    elseif type(targets) ~= "table" then
        LOG:Error("PointManager:UpdatePoints(): Invalid targets list")
        return
    end

    note = strsub32(note)
    local entry
    if action == CONSTANTS.POINT_MANAGER_ACTION.MODIFY then
        entry = CLM.MODELS.LEDGER.POINTS.Modify:new(uid, targets, value, reason, note, isSpent)
    elseif action == CONSTANTS.POINT_MANAGER_ACTION.SET then
        entry = CLM.MODELS.LEDGER.POINTS.Set:new(uid, targets, value, reason, note, isSpent)
    elseif action == CONSTANTS.POINT_MANAGER_ACTION.DECAY then
        if CONSTANTS.POINT_DECAY_TYPES[pointChangeType] == nil then
            LOG:Error("PointManager:UpdatePoints(): Unknown point change type")
            return
        end
        entry = CLM.MODELS.LEDGER.POINTS.Decay:new(uid, targets, value, reason, note, pointChangeType)
    end

    local t = entry:targets()
    if not t or (#t == 0) then
        LOG:Error("PointManager:UpdatePoints(): Empty targets list")
        return
    end

    CLM.MODULES.LedgerManager:Submit(entry, forceInstant)
end

function PointManager:UpdateRosterPoints(roster, value, reason, action, ignoreNegatives, note, pointChangeType, forceInstant)
    LOG:Trace("PointManager:UpdateRosterPoints()")
    if not CONSTANTS.POINT_MANAGER_ACTIONS[action] then
        LOG:Error("PointManager:UpdateRosterPoints(): Unknown action")
        return
    end
    if type(value) ~= "number" then
        LOG:Error("PointManager:UpdateRosterPoints(): Value is not a number")
        return
    end
    if not typeof(roster, CLM.MODELS.Roster) then
        LOG:Error("PointManager:UpdateRosterPoints(): Missing valid roster")
        return
    end
    if not verify_point_change_type[action](roster, pointChangeType, "PointManager:UpdatePoints()") then
        return
    end
    local uid = roster:UID()

    note = strsub32(note)
    local entry
    if action == CONSTANTS.POINT_MANAGER_ACTION.MODIFY then
        local isSpent = (pointChangeType == CONSTANTS.POINT_CHANGE_TYPE.SPENT)
        entry = CLM.MODELS.LEDGER.POINTS.ModifyRoster:new(uid, value, reason, note, isSpent)
    -- elseif action == CONSTANTS.POINT_MANAGER_ACTION.SET then
    --     entry = LEDGER.POINTS.Set:new(uid, targets, value, reason)
    elseif action == CONSTANTS.POINT_MANAGER_ACTION.DECAY then
        if CONSTANTS.POINT_DECAY_TYPES[pointChangeType] == nil then
            LOG:Error("PointManager:UpdateRosterPoints(): Unknown point change type")
            return
        end
        entry = CLM.MODELS.LEDGER.POINTS.DecayRoster:new(uid, value, reason, ignoreNegatives, note, pointChangeType)
    end

    CLM.MODULES.LedgerManager:Submit(entry, forceInstant)
end

function PointManager:UpdateRaidPoints(raid, value, reason, action, note, pointChangeType, forceInstant)
    LOG:Trace("PointManager:UpdateRaidPoints()")
    if not CONSTANTS.POINT_MANAGER_ACTIONS[action] then
        LOG:Error("PointManager:UpdateRaidPoints(): Unknown action")
        return
    end
    if type(value) ~= "number" then
        LOG:Error("PointManager:UpdateRaidPoints(): Value is not a number")
        return
    end
    if not typeof(raid, CLM.MODELS.Raid) then
        LOG:Error("PointManager:UpdateRaidPoints(): Missing valid raid")
        return
    end
    if not verify_point_change_type[action](raid:Roster(), pointChangeType, "PointManager:UpdatePoints()") then
        return
    end

    note = strsub32(note)
    local uid = raid:UID()
    local includeBench = raid:Configuration():Get("autoAwardIncludeBench") and true or false
    local entry
    if action == CONSTANTS.POINT_MANAGER_ACTION.MODIFY then
        local isSpent = (pointChangeType == CONSTANTS.POINT_CHANGE_TYPE.SPENT)
        entry = CLM.MODELS.LEDGER.POINTS.ModifyRaid:new(uid, value, reason, note, includeBench, isSpent)
    end

    CLM.MODULES.LedgerManager:Submit(entry, forceInstant)
end

function PointManager:RemovePointChange(pointHistory, forceInstant)
    LOG:Trace("PointManager:RemovePointChange()")
    if not typeof(pointHistory, CLM.MODELS.PointHistory) then
        LOG:Error("PointManager:RemovePointChange(): Missing valid point history")
        return
    end

    CLM.MODULES.LedgerManager:Remove(pointHistory:Entry(), forceInstant)
end

function PointManager:UpdatePointsDirectly(roster, targets, value, reason, pointChangeType, timestamp, creator)
    LOG:Trace("PointManager:UpdatePointsDirectly()")
    if not roster then
        LOG:Debug("PointManager:UpdatePointsDirectly(): Missing roster")
        return
    end

    local pointHistoryEntry = CLM.MODELS.FakePointHistory:New(targets, timestamp, value, reason, creator, pointChangeType)
    roster:AddRosterPointHistory(pointHistoryEntry)

    update_profile_standings(mutate_update_standings, roster, targets, value, reason, pointChangeType, timestamp, pointHistoryEntry, true)
end

function PointManager:AddPointHistory(roster, targets, pointHistoryEntry)
    LOG:Trace("PointManager:AddPointHistory()")
    if not roster then
        LOG:Debug("PointManager:AddPointHistory(): Missing roster")
        return
    end

    roster:AddRosterPointHistory(pointHistoryEntry)
    for _,target in ipairs(targets) do
        if roster:IsProfileInRoster(target) then
            local targetProfile = CLM.MODULES.ProfileManager:GetProfileByGUID(target)
            if targetProfile then
                roster:AddProfilePointHistory(pointHistoryEntry, targetProfile)
            end
        end
    end
end

function PointManager:AddFakePointHistory(roster, targets, value, reason, timestamp, creator, note, pointChangeType)
    LOG:Trace("PointManager:AddFakePointHistory()")
    if not roster then
        LOG:Debug("PointManager:AddFakePointHistory(): Missing roster")
        return
    end

    -- local isSpent = (pointChangeType == CONSTANTS.POINT_CHANGE_TYPE.SPENT)
    local pointHistoryEntry = CLM.MODELS.FakePointHistory:New(targets, timestamp, value, reason, creator, note, pointChangeType)
    roster:AddRosterPointHistory(pointHistoryEntry)
    for _,target in ipairs(targets) do
        if roster:IsProfileInRoster(target) then
            local targetProfile = CLM.MODULES.ProfileManager:GetProfileByGUID(target)
            if targetProfile then
                roster:AddProfilePointHistory(pointHistoryEntry, targetProfile)
            end
        end
    end
end

-- DO NOT CHANGE THE ID VALUE MAPPING
CONSTANTS.POINT_CHANGE_REASON = {
    ON_TIME_BONUS = 1,
    BOSS_KILL_BONUS = 2,
    RAID_COMPLETION_BONUS = 3,
    PROGRESSION_BONUS = 4,
    STANDBY_BONUS = 5,
    UNEXCUSED_ABSENCE = 6,
    CORRECTING_ERROR = 7,
    MANUAL_ADJUSTMENT = 8,
    ZERO_SUM_AWARD = 9,
    IMPORT = 100,
    DECAY = 101,
    INTERVAL_BONUS = 102,
    LINKING_OVERRIDE = 103,
    ROSTER_JOIN = 104
}

CONSTANTS.POINT_CHANGE_REASONS = {
    GENERAL = {  -- Exposed through GUI dropdown, can be localized
        [CONSTANTS.POINT_CHANGE_REASON.ON_TIME_BONUS] = CLM.L["On Time Bonus"],
        [CONSTANTS.POINT_CHANGE_REASON.BOSS_KILL_BONUS] = CLM.L["Boss Kill Bonus"],
        [CONSTANTS.POINT_CHANGE_REASON.RAID_COMPLETION_BONUS] = CLM.L["Raid Completion Bonus"],
        [CONSTANTS.POINT_CHANGE_REASON.PROGRESSION_BONUS] = CLM.L["Progression Bonus"],
        [CONSTANTS.POINT_CHANGE_REASON.STANDBY_BONUS] = CLM.L["Standby Bonus"],
        [CONSTANTS.POINT_CHANGE_REASON.UNEXCUSED_ABSENCE] = CLM.L["Unexcused absence"],
        [CONSTANTS.POINT_CHANGE_REASON.CORRECTING_ERROR] = CLM.L["Correcting error"],
        [CONSTANTS.POINT_CHANGE_REASON.MANUAL_ADJUSTMENT] = CLM.L["Manual adjustment"],
        [CONSTANTS.POINT_CHANGE_REASON.ZERO_SUM_AWARD] = CLM.L["Zero-Sum award"],
    },
    INTERNAL = { -- Not exposed directly to GUI
        [CONSTANTS.POINT_CHANGE_REASON.IMPORT] = CLM.L["Import"],
        [CONSTANTS.POINT_CHANGE_REASON.DECAY] = CLM.L["Decay"],
        [CONSTANTS.POINT_CHANGE_REASON.INTERVAL_BONUS] = CLM.L["Interval Bonus"],
        [CONSTANTS.POINT_CHANGE_REASON.LINKING_OVERRIDE] = CLM.L["Linking override"],
        [CONSTANTS.POINT_CHANGE_REASON.ROSTER_JOIN] = CLM.L["Joining roster"],
    }
}

CONSTANTS.POINT_CHANGE_REASONS.ALL = UTILS.mergeDicts(CONSTANTS.POINT_CHANGE_REASONS.GENERAL, CONSTANTS.POINT_CHANGE_REASONS.INTERNAL)

CONSTANTS.POINT_CHANGE_TYPE = {
    TOTAL   = 0,
    POINTS  = 1,
    SPENT   = 2
}

CONSTANTS.POINT_AWARD_TYPES = UTILS.Set({    1, 2 })
CONSTANTS.POINT_DECAY_TYPES = UTILS.Set({ 0, 1, 2 })

CONSTANTS.EPGP_POINT_AWARD_TYPES_GUI = {
    [CONSTANTS.POINT_CHANGE_TYPE.POINTS]   = CLM.L["EP"],
    [CONSTANTS.POINT_CHANGE_TYPE.SPENT]    = CLM.L["GP"]
}


CONSTANTS.EPGP_POINT_DECAY_TYPES_GUI = {
    [CONSTANTS.POINT_CHANGE_TYPE.TOTAL]    = CLM.L["EP/GP"],
    [CONSTANTS.POINT_CHANGE_TYPE.POINTS]   = CLM.L["EP"],
    [CONSTANTS.POINT_CHANGE_TYPE.SPENT]    = CLM.L["GP"]
}

CLM.MODULES.PointManager = PointManager
--@do-not-package@
function PointManager:DebugAddPoints()
    local rosters = CLM.MODULES.RosterManager:GetRosters()
    for _=1,math.random(20,150) do
        for _, roster in pairs(rosters) do
            local rosterContext = (math.random(1,2) == 1)
            if rosterContext then
                PointManager:UpdateRosterPoints(roster, math.random(1, 1000), math.random(1,9), CONSTANTS.POINT_MANAGER_ACTION.MODIFY, false, UTILS.randomString(math.random(1,10)), CONSTANTS.POINT_CHANGE_TYPE.POINTS, false)
            else
                local all_profiles = roster:Profiles()
                local profiles = {}
                for _=1,math.random(1,50) do
                    profiles[#profiles+1] = all_profiles[math.random(1, #all_profiles)]
                end
                PointManager:UpdatePoints(roster, profiles, math.random(1, 1000), math.random(1,9), CONSTANTS.POINT_MANAGER_ACTION.MODIFY, UTILS.randomString(math.random(1,10)), CONSTANTS.POINT_CHANGE_TYPE.POINTS, false)
            end
        end
    end
end
--@end-do-not-package@