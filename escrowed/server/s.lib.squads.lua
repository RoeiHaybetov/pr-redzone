RZ = RZ or {}
RZ.Squads = {}
RZ.Groups = {}

local Squads, Groups = RZ.Squads, RZ.Groups
local Store, Session, Schedule = RZ.Store, RZ.Session, RZ.Schedule
local Fw, Gangs, Db = RZ.Fw, RZ.Gangs, RZ.Db
local Log, Lock, Now, Mono = RZ.Log, RZ.Lock, RZ.Now, RZ.Mono

local squads, memberIndex, invites = {}, {}, {}
local lastInviteAt, renameHistory, snapshots = {}, {}, {}

local LEADER_ONLY = {
    squadInvite = 'non-leader tried to invite',
    squadKick = 'non-leader tried to kick',
    squadTransfer = 'non-leader tried to transfer leadership',
    squadRename = 'non-leader tried to rename',
    squadDisband = 'non-leader tried to disband',
}

local function lockKey(squadId)
    return 'squad:' .. tostring(squadId)
end

local function withLock(key, owner, ttlMs, fn)
    if not Lock.Acquire(key, owner, ttlMs) then return false, 'error.locked' end
    local ok, err = fn()
    Lock.Release(key, owner)
    return ok, err
end

local function newSquad(id, name, leaderCitizenId, createdAt, updatedAt)
    return {
        id = id,
        name = name,
        leaderCitizenId = leaderCitizenId,
        members = {},
        memberOrder = {},
        createdAt = createdAt,
        updatedAt = updatedAt,
    }
end

local function newSnapshot(sessionId, squadId, leaderCitizenId, members, order, lockedAt, revision)
    return {
        sessionId = sessionId,
        squadId = squadId,
        leaderCitizenId = leaderCitizenId,
        members = members,
        memberOrder = order,
        lockedAt = lockedAt,
        revision = revision,
    }
end

function Squads.SanitizeName(raw)
    if type(raw) ~= 'string' then return nil, 'squad.name_invalid' end
    local cleaned = raw:gsub('[%z\1-\31\127]', ''):gsub('[<>&"\'`\\]', '')
    cleaned = cleaned:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    local cfg = Config.SoloSquads.name
    if #cleaned < cfg.minLength then return nil, 'squad.name_too_short' end
    if #cleaned > cfg.maxLength then
        cleaned = cleaned:sub(1, cfg.maxLength):gsub('%s+$', '')
        if #cleaned < cfg.minLength then return nil, 'squad.name_too_short' end
    end
    local lowered = cleaned:lower()
    for i = 1, #cfg.blockedWords do
        local word = tostring(cfg.blockedWords[i]):lower()
        if word ~= '' and lowered:find(word, 1, true) then return nil, 'squad.name_blocked' end
    end
    return cleaned
end

function Squads.GetSquad(squadId)
    if type(squadId) ~= 'string' then return nil end
    return squads[squadId]
end

function Squads.GetSquadByCitizenId(citizenid)
    if type(citizenid) ~= 'string' then return nil end
    local squadId = memberIndex[citizenid]
    return squadId and squads[squadId] or nil
end

function Squads.MemberCount(squad)
    return #squad.memberOrder
end

function Squads.IsLeader(squad, citizenid)
    return squad.leaderCitizenId == citizenid
end

local function sourceOf(citizenid)
    local record = Store.GetByCitizenId(citizenid)
    if record and GetPlayerName(record.src) ~= nil then return record.src end
    return nil
end

Squads.SourceOf = sourceOf

function Squads.IsEligible(source)
    if not Config.SoloSquads.enabled then return false, RZ.Reject.UNVERIFIABLE end
    if not Fw.IsLoaded(source) then return false, RZ.Reject.UNVERIFIABLE end
    if Gangs.IsValidGangMember(source) then return false, RZ.Reject.NOT_SOLO end
    if not Gangs.IsSolo(source) then return false, RZ.Reject.NOT_SOLO end
    return true
end

local function requireLeader(source, citizenid, action)
    local squad = Squads.GetSquadByCitizenId(citizenid)
    if not squad then return nil, 'squad.not_in_squad' end
    if not Squads.IsLeader(squad, citizenid) then
        Log.Suspicious(source, action, LEADER_ONLY[action])
        return nil, 'squad.not_leader'
    end
    return squad
end

local function touch(squad)
    squad.updatedAt = Now()
end

local function addMemberLocal(squad, citizenid, joinedAt)
    if squad.members[citizenid] then return end
    squad.members[citizenid] = { citizenid = citizenid, joinedAt = joinedAt or Now() }
    squad.memberOrder[#squad.memberOrder + 1] = citizenid
    memberIndex[citizenid] = squad.id
    touch(squad)
end

local function removeMemberLocal(squad, citizenid)
    if not squad.members[citizenid] then return end
    squad.members[citizenid] = nil
    for i = #squad.memberOrder, 1, -1 do
        if squad.memberOrder[i] == citizenid then table.remove(squad.memberOrder, i) end
    end
    if memberIndex[citizenid] == squad.id then memberIndex[citizenid] = nil end
    touch(squad)
end

local function dropMember(squad, source, targetCitizenId)
    return withLock(lockKey(squad.id), source, 5000, function()
        removeMemberLocal(squad, targetCitizenId)
        if Config.SoloSquads.persistSquads then
            Db.DeleteSquadMember(squad.id, targetCitizenId)
            Db.TouchSquad(squad.id, Now())
        end
        return true
    end)
end

function Squads.GetSnapshot(sessionId, squadId)
    local bySession = snapshots[sessionId]
    return bySession and bySession[squadId] or nil
end

function Squads.CreateSnapshot(sessionId, squad)
    local key = lockKey(squad.id)
    if not Lock.Acquire(key, 'snapshot', 10000) then return nil end
    local snapshot = Squads.GetSnapshot(sessionId, squad.id)
    if not snapshot then
        local members, order, seen = {}, {}, {}
        for i = 1, #squad.memberOrder do
            local citizenid = squad.memberOrder[i]
            if #order >= Config.SoloSquads.maxMembers then break end
            if not seen[citizenid] then
                seen[citizenid] = true
                local src = sourceOf(citizenid)
                if not src or Squads.IsEligible(src) then
                    members[citizenid] = true
                    order[#order + 1] = citizenid
                end
            end
        end

        snapshot = newSnapshot(sessionId, squad.id, squad.leaderCitizenId, members, order, Now(), 1)
        snapshots[sessionId] = snapshots[sessionId] or {}
        snapshots[sessionId][squad.id] = snapshot
        if Config.SoloSquads.persistSquads then Db.UpsertSnapshot(snapshot) end
        Log.SquadSnapshot(squad.id, sessionId, #order)
    end
    Lock.Release(key, 'snapshot')
    return snapshot
end

function Squads.ClearSnapshotsForSession(sessionId)
    snapshots[sessionId] = nil
    if Config.SoloSquads.persistSquads then Db.DeleteSnapshotsForSession(sessionId) end
    Log.Info(('squads: cleared session snapshots for %s'):format(sessionId))
end

function Squads.Create(source, citizenid, rawName)
    local eligible, reason = Squads.IsEligible(source)
    if not eligible then
        Log.Suspicious(source, 'squadCreate', 'not solo: ' .. tostring(reason))
        return false, 'squad.not_solo'
    end
    if memberIndex[citizenid] then return false, 'squad.already_in_squad' end
    local name, nameErr = Squads.SanitizeName(rawName)
    if not name then return false, nameErr end

    local createdId
    local ok, err = withLock('squadcreate:' .. citizenid, source, 5000, function()
        if memberIndex[citizenid] then return false, 'squad.already_in_squad' end
        local now = Now()
        local squad = newSquad(RZ.Id.New('sq'), name, citizenid, now, now)
        squads[squad.id] = squad
        addMemberLocal(squad, citizenid, now)
        createdId = squad.id
        if Config.SoloSquads.persistSquads then
            Db.InsertSquad(squad)
            Db.InsertSquadMember(squad.id, citizenid, now)
        end
        return true
    end)
    if not ok then return false, err end
    Log.SquadCreated(source, createdId, name)
    return true
end

function Squads.Invite(source, citizenid, targetSrc)
    local squad, leaderErr = requireLeader(source, citizenid, 'squadInvite')
    if not squad then return false, leaderErr end
    if not Squads.IsEligible(source) then return false, 'squad.not_solo' end
    if type(targetSrc) ~= 'number' or targetSrc <= 0 then return false, 'squad.invite_bad_id' end
    if targetSrc == source then return false, 'squad.invite_self' end
    if GetPlayerName(targetSrc) == nil then return false, 'squad.invite_bad_id' end
    local now = Now()
    local last = lastInviteAt[citizenid]
    if last and (now - last) < (Config.SoloSquads.inviteCooldownSeconds * 1000) then
        return false, 'squad.invite_cooldown'
    end
    local targetCitizenId = Fw.Identity(targetSrc)
    if not targetCitizenId then return false, 'squad.invite_not_loaded' end
    local targetEligible, targetReason = Squads.IsEligible(targetSrc)
    if not targetEligible then
        Log.Debug(('squad invite refused: target %s is not solo (%s)'):format(targetSrc, tostring(targetReason)))
        return false, 'squad.invite_not_solo'
    end
    local heldBy = memberIndex[targetCitizenId]
    if heldBy == squad.id then return false, 'squad.invite_already_member' end
    if heldBy then return false, 'squad.invite_in_other_squad' end
    if Squads.MemberCount(squad) >= Config.SoloSquads.maxMembers then return false, 'squad.full' end
    for _, pending in pairs(invites) do
        if pending.squadId == squad.id and pending.targetCitizenId == targetCitizenId and pending.expiresAt > now then
            return false, 'squad.invite_duplicate'
        end
    end

    local expiresInMs = Config.SoloSquads.inviteExpirationSeconds * 1000
    local invite = {
        id = RZ.Id.New('inv'),
        squadId = squad.id,
        inviterCitizenId = citizenid,
        targetCitizenId = targetCitizenId,
        createdAt = now,
        expiresAt = now + expiresInMs,
    }
    invites[invite.id] = invite
    lastInviteAt[citizenid] = now
    Log.SquadInvite(source, targetSrc, squad.id)
    TriggerClientEvent(RZ.SquadEvent.INVITE, targetSrc, {
        inviteId = invite.id,
        squadName = squad.name,
        expiresInMs = expiresInMs,
    })
    return true
end

function Squads.RespondToInvite(source, citizenid, inviteId, accept)
    if type(inviteId) ~= 'string' then return false, 'squad.invite_invalid' end
    local invite = invites[inviteId]
    if not invite then return false, 'squad.invite_invalid' end
    if invite.targetCitizenId ~= citizenid then
        Log.Suspicious(source, 'squadRespond', 'tried to consume an invite addressed to someone else')
        return false, 'squad.invite_invalid'
    end
    local function consume(ok, err)
        invites[inviteId] = nil
        return ok, err
    end
    if Now() > invite.expiresAt then return consume(false, 'squad.invite_expired') end
    if not accept then return consume(true) end
    local squad = squads[invite.squadId]
    if not squad then return consume(false, 'squad.invite_invalid') end
    if not Squads.IsEligible(source) then return consume(false, 'squad.not_solo') end
    if memberIndex[citizenid] then return consume(false, 'squad.already_in_squad') end

    local ok, err = withLock(lockKey(squad.id), source, 5000, function()
        if Squads.MemberCount(squad) >= Config.SoloSquads.maxMembers then
            return consume(false, 'squad.full')
        end
        consume(true)
        local now = Now()
        addMemberLocal(squad, citizenid, now)
        if Config.SoloSquads.persistSquads then
            if not Db.InsertSquadMember(squad.id, citizenid, now) then
                removeMemberLocal(squad, citizenid)
                return false, 'squad.already_in_squad'
            end
            Db.TouchSquad(squad.id, now)
        end
        return true
    end)
    if not ok then return false, err end
    Log.SquadJoin(source, squad.id)
    Squads.BroadcastState(squad)
    return true
end

function Squads.Kick(source, citizenid, targetCitizenId)
    if type(targetCitizenId) ~= 'string' then return false, 'error.generic' end
    local squad, leaderErr = requireLeader(source, citizenid, 'squadKick')
    if not squad then return false, leaderErr end
    if targetCitizenId == citizenid then return false, 'squad.cannot_kick_self' end
    if not squad.members[targetCitizenId] then return false, 'squad.not_member' end
    local ok, err = dropMember(squad, source, targetCitizenId)
    if not ok then return false, err end
    Log.SquadKick(source, squad.id, targetCitizenId)
    local kickedSrc = sourceOf(targetCitizenId)
    if kickedSrc then
        RZ.Notify(kickedSrc, 'squad.you_were_kicked', nil, 'error')
        Squads.PushState(kickedSrc)
    end
    Squads.BroadcastState(squad)
    return true
end

function Squads.Leave(source, citizenid)
    local squad = Squads.GetSquadByCitizenId(citizenid)
    if not squad then return false, 'squad.not_in_squad' end
    if Squads.IsLeader(squad, citizenid) then
        if Squads.MemberCount(squad) > 1 then return false, 'squad.leader_must_transfer' end
        return Squads.Disband(source, citizenid)
    end
    local ok, err = dropMember(squad, source, citizenid)
    if not ok then return false, err end
    Log.SquadLeave(source, squad.id)
    if Squads.MemberCount(squad) == 0 then
        Squads.DeleteSquad(squad.id)
    else
        Squads.BroadcastState(squad)
    end
    Squads.PushState(source)
    return true
end

function Squads.TransferLeadership(source, citizenid, targetCitizenId)
    if type(targetCitizenId) ~= 'string' then return false, 'error.generic' end
    local squad, leaderErr = requireLeader(source, citizenid, 'squadTransfer')
    if not squad then return false, leaderErr end
    if targetCitizenId == citizenid then return false, 'error.generic' end
    if not squad.members[targetCitizenId] then return false, 'squad.not_member' end
    local ok, err = withLock(lockKey(squad.id), source, 5000, function()
        squad.leaderCitizenId = targetCitizenId
        touch(squad)
        if Config.SoloSquads.persistSquads then
            Db.UpdateSquadLeader(squad.id, targetCitizenId, Now())
        end
        return true
    end)
    if not ok then return false, err end
    Log.SquadTransfer(source, squad.id, targetCitizenId)
    Squads.BroadcastState(squad)
    return true
end

function Squads.Rename(source, citizenid, rawName)
    local squad, leaderErr = requireLeader(source, citizenid, 'squadRename')
    if not squad then return false, leaderErr end
    local cfg = Config.SoloSquads.name
    local now = Mono()
    local hist = renameHistory[citizenid]
    if not hist or (now - hist.windowStart) >= cfg.renameWindowMs then
        renameHistory[citizenid] = { count = 1, windowStart = now }
    elseif hist.count >= cfg.renameLimit then
        return false, 'squad.rename_limited'
    else
        hist.count = hist.count + 1
    end
    local name, nameErr = Squads.SanitizeName(rawName)
    if not name then return false, nameErr end
    squad.name = name
    touch(squad)
    if Config.SoloSquads.persistSquads then Db.UpdateSquadName(squad.id, name, Now()) end
    Log.SquadRename(source, squad.id, name)
    Squads.BroadcastState(squad)
    return true
end

function Squads.Disband(source, citizenid)
    local squad, leaderErr = requireLeader(source, citizenid, 'squadDisband')
    if not squad then return false, leaderErr end
    local affected = {}
    local ok, err = withLock(lockKey(squad.id), source, 5000, function()
        for i = 1, #squad.memberOrder do affected[#affected + 1] = squad.memberOrder[i] end
        return true
    end)
    if not ok then return false, err end
    local squadId = squad.id
    Squads.DeleteSquad(squadId)
    Log.SquadDisband(source, squadId)
    for i = 1, #affected do
        local memberSrc = sourceOf(affected[i])
        if memberSrc then
            if affected[i] ~= citizenid then
                RZ.Notify(memberSrc, 'squad.disbanded', nil, 'error')
            end
            Squads.PushState(memberSrc)
        end
    end
    return true
end

function Squads.DeleteSquad(squadId)
    local squad = squads[squadId]
    if not squad then return end
    for i = 1, #squad.memberOrder do
        local citizenid = squad.memberOrder[i]
        if memberIndex[citizenid] == squadId then memberIndex[citizenid] = nil end
    end
    squads[squadId] = nil
    for inviteId, invite in pairs(invites) do
        if invite.squadId == squadId then invites[inviteId] = nil end
    end
    if Config.SoloSquads.persistSquads then Db.DeleteSquad(squadId) end
end

function Squads.PruneInvites()
    local now = Now()
    for inviteId, invite in pairs(invites) do
        if invite.expiresAt <= now then invites[inviteId] = nil end
    end
end

function Squads.GetPendingInvitesFor(citizenid)
    local out, now = {}, Now()
    for _, invite in pairs(invites) do
        if invite.targetCitizenId == citizenid and invite.expiresAt > now then
            local squad = squads[invite.squadId]
            out[#out + 1] = {
                inviteId = invite.id,
                squadName = squad and squad.name or '?',
                expiresAt = invite.expiresAt,
            }
        end
    end
    return out
end

local function promoteToLeader(squad, candidate, now, minutes)
    squad.leaderCitizenId = candidate
    squad.leaderOfflineSince = nil
    touch(squad)
    if Config.SoloSquads.persistSquads then Db.UpdateSquadLeader(squad.id, candidate, now) end
    Log.Info(('squads: auto-transferred leadership of %s to %s after %d minutes offline')
        :format(squad.id, candidate, minutes))
    Squads.BroadcastState(squad)
end

function Squads.CheckLeaderInactivity()
    local minutes = Config.SoloSquads.autoTransferLeaderAfterMinutes
    if not minutes or minutes <= 0 then return end
    local threshold, now = minutes * 60 * 1000, Now()
    for _, squad in pairs(squads) do
        if sourceOf(squad.leaderCitizenId) then
            squad.leaderOfflineSince = nil
        else
            squad.leaderOfflineSince = squad.leaderOfflineSince or now
            if (now - squad.leaderOfflineSince) >= threshold then
                for i = 1, #squad.memberOrder do
                    local candidate = squad.memberOrder[i]
                    if candidate ~= squad.leaderCitizenId and sourceOf(candidate) then
                        promoteToLeader(squad, candidate, now, minutes)
                        break
                    end
                end
            end
        end
    end
end

local function decodeSnapshotMembers(raw)
    local members, order = {}, {}
    local decoded = raw and json.decode(raw) or nil
    if type(decoded) == 'table' then
        for i = 1, #decoded do
            local citizenid = decoded[i]
            if type(citizenid) == 'string' and not members[citizenid] then
                members[citizenid] = true
                order[#order + 1] = citizenid
            end
        end
    end
    return members, order
end

function Squads.LoadAll()
    squads, memberIndex, invites, snapshots = {}, {}, {}, {}
    if not Config.SoloSquads.enabled or not Config.SoloSquads.persistSquads then
        Log.Info('squads: persistence disabled, starting with an empty roster')
        return
    end
    local squadRows = Db.FetchSquads()
    for i = 1, #squadRows do
        local row = squadRows[i]
        squads[row.squad_id] = newSquad(row.squad_id, row.name, row.leader_citizenid, row.created_at, row.updated_at)
    end

    local memberRows = Db.FetchSquadMembers()
    for i = 1, #memberRows do
        local row = memberRows[i]
        local squad = squads[row.squad_id]
        if squad then addMemberLocal(squad, row.citizenid, row.joined_at) end
    end
    for squadId, squad in pairs(squads) do
        if #squad.memberOrder == 0 then
            squads[squadId] = nil
            Db.DeleteSquad(squadId)
        elseif not squad.members[squad.leaderCitizenId] then
            squad.leaderCitizenId = squad.memberOrder[1]
            Db.UpdateSquadLeader(squadId, squad.leaderCitizenId, Now())
            Log.Info(('squads: repaired orphaned leader for %s'):format(squadId))
        end
    end

    local snapshotRows = Db.FetchSnapshots()
    for i = 1, #snapshotRows do
        local row = snapshotRows[i]
        snapshots[row.session_id] = snapshots[row.session_id] or {}
        local members, order = decodeSnapshotMembers(row.members)
        snapshots[row.session_id][row.squad_id] = newSnapshot(row.session_id, row.squad_id,
            row.leader_citizenid, members, order, row.locked_at, row.revision or 1)
    end
    local squadCount = 0
    for _ in pairs(squads) do squadCount = squadCount + 1 end
    Log.Info(('squads: loaded %d squad(s) and %d session snapshot(s)'):format(squadCount, #snapshotRows))
end

function Squads.PruneStaleSnapshots()
    local liveSessions = {}
    for zoneId in pairs(Config.Zones) do
        local sessionId = Session.GetId(zoneId)
        if sessionId then liveSessions[sessionId] = true end
    end
    for sessionId in pairs(snapshots) do
        if not liveSessions[sessionId] then Squads.ClearSnapshotsForSession(sessionId) end
    end
    if Config.SoloSquads.persistSquads then Db.DeleteSnapshotsNotIn(liveSessions) end
end

local function memberName(memberSrc, memberCid)
    if not memberSrc then return Db.GetCachedCharName(memberCid) or '—' end
    local name = (Fw.Name(memberSrc) or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then name = GetPlayerName(memberSrc) or '—' end
    return name
end

function Squads.BuildState(source, citizenid)
    local eligible, reason = Squads.IsEligible(source)
    local state = {
        eligible = eligible,
        reason = eligible and nil or reason,
        maxMembers = Config.SoloSquads.maxMembers,
        requireSquadForEntry = Config.SoloSquads.requireSquadForEntry,
        squad = nil,
        invites = {},
        session = nil,
    }
    if not eligible then return state end
    state.invites = Squads.GetPendingInvitesFor(citizenid)
    for zoneId, zone in pairs(Config.Zones) do
        if zone.enabled then
            state.session = {
                zoneId = zoneId,
                sessionId = Session.GetId(zoneId),
                open = Schedule.IsOpen(zoneId),
                closeHour = zone.schedule.closeHour,
            }
            break
        end
    end
    local squad = Squads.GetSquadByCitizenId(citizenid)
    if not squad then return state end
    local isLeader = Squads.IsLeader(squad, citizenid)
    local locked, lockedMembers = false, nil
    if state.session and state.session.sessionId then
        local snapshot = Squads.GetSnapshot(state.session.sessionId, squad.id)
        if snapshot then locked, lockedMembers = true, snapshot.members end
    end
    local function inActiveRoster(cid)
        return (not locked) or (lockedMembers and lockedMembers[cid] == true) or false
    end

    local members = {}
    for i = 1, #squad.memberOrder do
        local memberCid = squad.memberOrder[i]
        local memberSrc = sourceOf(memberCid)
        members[#members + 1] = {
            citizenid = memberCid,
            name = memberName(memberSrc, memberCid),
            online = memberSrc ~= nil,
            isLeader = memberCid == squad.leaderCitizenId,
            inActiveRoster = inActiveRoster(memberCid),
        }
    end

    state.squad = {
        id = squad.id,
        name = squad.name,
        leaderCitizenId = squad.leaderCitizenId,
        isLeader = isLeader,
        memberCount = #squad.memberOrder,
        members = members,
        rosterLocked = locked,
        selfInActiveRoster = inActiveRoster(citizenid),
    }
    return state
end

function Squads.PushState(source)
    if type(source) ~= 'number' or GetPlayerName(source) == nil then return end
    local identity = Fw.Identity(source)
    if not identity then return end
    TriggerClientEvent(RZ.SquadEvent.STATE, source, Squads.BuildState(source, identity))
end

function Squads.BroadcastState(squad)
    for i = 1, #squad.memberOrder do
        local memberSrc = sourceOf(squad.memberOrder[i])
        if memberSrc then Squads.PushState(memberSrc) end
    end
end

Groups.TYPE_GANG = 'gang'
Groups.TYPE_SOLO_SQUAD = 'solo_squad'

local function soloSquadGroup(sessionId, squadId)
    return {
        id = ('%s:%s:%s'):format(Groups.TYPE_SOLO_SQUAD, sessionId, squadId),
        type = Groups.TYPE_SOLO_SQUAD,
        squadId = squadId,
        sessionId = sessionId,
    }
end

function Groups.GetPlayerGroup(source, zoneId)
    if type(source) ~= 'number' or GetPlayerName(source) == nil then
        return nil, RZ.Reject.UNVERIFIABLE
    end
    local record = Store.Get(source)
    if not record then return nil, RZ.Reject.UNVERIFIABLE end
    local valid, gangReason, gangId = Gangs.IsValidGangMember(source)
    if valid and gangId then
        return { id = Groups.TYPE_GANG .. ':' .. gangId, type = Groups.TYPE_GANG, gangId = gangId }
    end
    if not Config.SoloSquads.enabled then return nil, gangReason or RZ.Reject.NO_GANG end
    if not Gangs.IsSolo(source) then return nil, gangReason or RZ.Reject.INVALID_GANG end
    local sessionId = Session.GetId(zoneId)
    if not sessionId then return nil, RZ.Reject.ZONE_CLOSED end

    local squad = Squads.GetSquadByCitizenId(record.citizenid)
    if not squad then
        if Config.SoloSquads.requireSquadForEntry then return nil, RZ.Reject.NO_SQUAD end
        return soloSquadGroup(sessionId, 'solo_' .. record.citizenid)
    end
    if Config.SoloSquads.lockRosterAfterFirstEntry then
        local snapshot = Squads.GetSnapshot(sessionId, squad.id)
        if not snapshot then return nil, RZ.Reject.SQUAD_NOT_LOCKED end
        if not snapshot.members[record.citizenid] then
            return nil, RZ.Reject.SQUAD_JOINED_AFTER_LOCK
        end
    end
    return soloSquadGroup(sessionId, squad.id)
end

function Groups.GetStableGroupId(source, zoneId)
    local group = Groups.GetPlayerGroup(source, zoneId)
    return group and group.id or nil
end

function Groups.IsGangGroup(group)
    return group ~= nil and group.type == Groups.TYPE_GANG
end

function Groups.IsSoloSquadGroup(group)
    return group ~= nil and group.type == Groups.TYPE_SOLO_SQUAD
end

function Groups.AreTeammates(sourceA, sourceB, zoneId)
    if sourceA == sourceB then return false end
    local a = Groups.GetStableGroupId(sourceA, zoneId)
    local b = a and Groups.GetStableGroupId(sourceB, zoneId)
    return a ~= nil and a == b
end

local function hasGroupPrefix(groupId, kind)
    return type(groupId) == 'string' and groupId:sub(1, #kind + 1) == (kind .. ':')
end

function Groups.IsSoloSquadGroupId(groupId)
    return hasGroupPrefix(groupId, Groups.TYPE_SOLO_SQUAD)
end

function Groups.IsGangGroupId(groupId)
    return hasGroupPrefix(groupId, Groups.TYPE_GANG)
end

function Groups.GangIdFromGroupId(groupId)
    if not Groups.IsGangGroupId(groupId) then return nil end
    return groupId:match('^gang:(.+)$')
end

function Groups.GetAliveGroupsInZone(zoneId)
    local seen, ids, counts = {}, {}, {}
    for source, record in pairs(Store.All()) do
        if record.zoneId == zoneId and RZ.CountsForControl[record.state] then
            local groupId = record.groupId or Groups.GetStableGroupId(source, zoneId)
            if groupId then
                if not seen[groupId] then
                    seen[groupId] = true
                    ids[#ids + 1] = groupId
                    counts[groupId] = 0
                end
                counts[groupId] = counts[groupId] + 1
            end
        end
    end
    return ids, counts
end

function Groups.GetAliveGroupCount(zoneId)
    local ids = Groups.GetAliveGroupsInZone(zoneId)
    return #ids
end

function Groups.IsExactlyOneGroupControlling(zoneId)
    local ids = Groups.GetAliveGroupsInZone(zoneId)
    if #ids == 1 then return true, ids[1] end
    return false, nil
end

exports('GetAliveGroupsInZone', function(zoneId)
    return RZ.Util.CopyArray((Groups.GetAliveGroupsInZone(zoneId)))
end)

exports('GetAliveGroupCount', function(zoneId)
    return Groups.GetAliveGroupCount(zoneId)
end)

exports('IsExactlyOneGroupControlling', function(zoneId)
    return (Groups.IsExactlyOneGroupControlling(zoneId))
end)

exports('AreTeammates', function(sourceA, sourceB, zoneId)
    return Groups.AreTeammates(sourceA, sourceB, zoneId)
end)
