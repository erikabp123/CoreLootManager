local _, CLM = ...

local MODULES = CLM.MODULES
local LOG = CLM.LOG
local Comms = MODULES.Comms
local CONSTANTS = CLM.CONSTANTS
local ACL = MODULES.ACL
-- local UTILS = CLM.UTILS

local STATUS_SYNCED = "synced"
local STATUS_OUT_OF_SYNC = "out_of_sync"
-- local STATUS_UNKNOWN = "unknown"

-- local getGuidFromInteger = UTILS.getGuidFromInteger

local LedgerLib = LibStub("EventSourcing/LedgerFactory")

local LedgerManager = { _initialized = false}

local function authorize(entry, sender)
    return ACL:CheckLevel(CONSTANTS.ACL.LEVEL.ASSISTANT, sender)
end

local LEDGER_SYNC_COMM_PREFIX = "LedgerS001"
local LEDGER_DATA_COMM_PREFIX = "LedgerD001"

function LedgerManager:Initialize()
    self.ledger = LedgerLib.createLedger(
        MODULES.Database:Ledger(),
        (function(data, distribution, target, callbackFn, callbackArg)
            return Comms:Send(LEDGER_SYNC_COMM_PREFIX, data, distribution, target, "BULK")
        end), -- send
        (function(callback)
            Comms:Register(LEDGER_SYNC_COMM_PREFIX, callback, CONSTANTS.ACL.LEVEL.PLEBS)
            Comms:Register(LEDGER_DATA_COMM_PREFIX, callback, CONSTANTS.ACL.LEVEL.ASSISTANT)
        end), -- registerReceiveHandler
        authorize, -- authorizationHandler
        (function(data, distribution, target, progressCallback)
            return Comms:Send(LEDGER_DATA_COMM_PREFIX, data, distribution, target, "BULK")
        end), -- sendLargeMessage
        0, 100, LOG
    )
    self.ledger.addSyncStateChangedListener(function(_, status)
        self:UpdateSyncState(status) -- there is still something fishy about the Icon (securehook) and I don't know what
    end)
    self.entryExtensions = {}
    self._initialized = true

    MODULES.ConfigManager:RegisterUniversalExecutor("ledger", "LedgerManager", self)
end

function LedgerManager:IsInitialized()
    return self._initialized
end

function LedgerManager:Enable()
    self.ledger.getStateManager():setUpdateInterval(50)
    if ACL:CheckLevel(CONSTANTS.ACL.LEVEL.ASSISTANT) then
        self.ledger.enableSending()
    end
end

-- This is not reversable until reload
function LedgerManager:Cutoff()
    self.ledger.disableSending()
    Comms:Suspend(LEDGER_SYNC_COMM_PREFIX)
    Comms:Suspend(LEDGER_DATA_COMM_PREFIX)
end

function LedgerManager:DisableAdvertising()
    self.ledger.disableSending()
end

function LedgerManager:TimeTravel(timestamp)
    self.timeTravelTarget = timestamp
    self.ledger.getStateManager():travelToTime(timestamp)
    self:UpdateSyncState()
end

function LedgerManager:EndTimeTravel()
    self.ledger.getStateManager():stopTimeTravel()
    self.ledger.getStateManager():restart() -- Not done in this version in lib
    self:UpdateSyncState()
end

function LedgerManager:IsTimeTraveling()
    return self.ledger.getStateManager():isTimeTraveling()
end

function LedgerManager:GetTimeTravelTarget()
    return self.timeTravelTarget
end

function LedgerManager:EnableSandbox()
    self:UpdateSyncState()
end

function LedgerManager:DisableSandbox()
    self:UpdateSyncState()
end

function LedgerManager:RegisterEntryType(class, mutatorFn)
    if self.entryExtensions[class] then
        LOG:Error("Class %s already exists in Ledger Entries.", class)
        return
    end
    self.entryExtensions[class] = true

    self.ledger.registerMutator(class, mutatorFn)
end

function LedgerManager:RegisterOnRestart(callback)
    self.ledger.addStateRestartListener(callback)
end

function LedgerManager:RegisterOnUpdate(callback)
    self.ledger.addStateChangedListener(callback)
end

function LedgerManager:GetPeerStatus()
    return self.ledger.getPeerStatus()
end

function LedgerManager:RequestPeerStatusFromGuild()
    self.ledger.requestPeerStatusFromGuild()
end

function LedgerManager:UpdateSyncState(status)
    if self._initialized then
        if status == STATUS_SYNCED then
            self.inSync = true
            self.syncOngoing = false
        elseif status == STATUS_OUT_OF_SYNC then
            self.inSync = false
            self.syncOngoing = true
        else
            self.inSync = false
            self.syncOngoing = false
        end
    else
        self.inSync = false
        self.syncOngoing = false
    end
    -- CLM.MinimapDBI:UpdateState(self.inSync, self.syncOngoing)
end

function LedgerManager:IsInSync()
    return self.inSync
end

function LedgerManager:IsSyncOngoing()
    return self.syncOngoing
end

function LedgerManager:Lag()
    return self.ledger.getStateManager():lag()
end

function LedgerManager:Hash()
    return self.ledger.getStateManager():stateHash()
end
function LedgerManager:Length()
    return self.ledger.getSortedList():length()
end

function LedgerManager:RequestPeerStatusFromRaid()
    self.ledger.requestPeerStatusFromRaid()
end

function LedgerManager:Submit(entry, catchup)
    LOG:Trace("LedgerManager:Submit()")
    if not entry then return end
    self.lastEntry = entry
    self.ledger.submitEntry(entry)
    if catchup then
        self.ledger.catchup()
    end
end

function LedgerManager:Remove(entry, catchup)
    LOG:Trace("LedgerManager:Remove()")
    if not entry then return end
    self.ledger.ignoreEntry(entry)
    if catchup then
        self.ledger.catchup()
    end
end

function LedgerManager:CancelLastEntry()
    if not self._initialized then return end
    if self.lastEntry then
        self:Remove(self.lastEntry)
        self.lastEntry = nil
    end
end

function LedgerManager:Wipe()
    if not self._initialized then return end
    self:DisableAdvertising()
    local db = MODULES.Database:Ledger()
    wipe(db)
    collectgarbage()
    self:Enable()
end

--@do-not-package@
function LedgerManager:Reset()
    self.ledger.reset()
end
--@end-do-not-package@

MODULES.LedgerManager = LedgerManager
