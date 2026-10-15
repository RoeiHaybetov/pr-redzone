RZ = RZ or {}
RZ.Db = {}

local Db = RZ.Db

local function affected(res)
    return (res and res.affectedRows) or 0
end

local function protect(label, fn)
    local ok, res = pcall(fn)
    if ok then return true, res end
    RZ.Log.Integration('database', label .. ' failed: ' .. tostring(res))
    return false
end

local function createTables(label, statements)
    return (protect(label, function()
        for i = 1, #statements do
            MySQL.query.await(statements[i])
        end
    end))
end

local SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS `redzone_cooldowns` (
        `citizenid` VARCHAR(64) NOT NULL, `zone_id` VARCHAR(64) NOT NULL,
        `expires_at` BIGINT NOT NULL, `updated_at` BIGINT NOT NULL,
        PRIMARY KEY (`citizenid`, `zone_id`), KEY `idx_redzone_cooldowns_expires` (`expires_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `redzone_squads` (
        `squad_id` VARCHAR(96) NOT NULL, `name` VARCHAR(64) NOT NULL,
        `leader_citizenid` VARCHAR(64) NOT NULL, `created_at` BIGINT NOT NULL,
        `updated_at` BIGINT NOT NULL, `disbanded_at` BIGINT NULL,
        PRIMARY KEY (`squad_id`), KEY `idx_redzone_squads_leader` (`leader_citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `redzone_squad_members` (
        `citizenid` VARCHAR(64) NOT NULL, `squad_id` VARCHAR(96) NOT NULL, `joined_at` BIGINT NOT NULL,
        PRIMARY KEY (`citizenid`), KEY `idx_redzone_squad_members_squad` (`squad_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `redzone_squad_snapshots` (
        `session_id` VARCHAR(32) NOT NULL, `squad_id` VARCHAR(96) NOT NULL,
        `leader_citizenid` VARCHAR(64) NOT NULL, `members` TEXT NOT NULL,
        `locked_at` BIGINT NOT NULL, `revision` INT NOT NULL DEFAULT 1,
        PRIMARY KEY (`session_id`, `squad_id`), KEY `idx_redzone_snapshots_session` (`session_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `redzone_name_cache` (
        `citizenid` VARCHAR(64) NOT NULL, `char_name` VARCHAR(128) NOT NULL,
        `updated_at` BIGINT NOT NULL, PRIMARY KEY (`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
}

local ADMIN_SCHEMA = {
    [[CREATE TABLE IF NOT EXISTS `redzone_runtime_config` (
        `id` INT NOT NULL DEFAULT 1, `schema_version` INT NOT NULL, `revision` INT NOT NULL DEFAULT 1,
        `config_json` LONGTEXT NOT NULL, `updated_by_discord` VARCHAR(32) NOT NULL,
        `updated_by_name` VARCHAR(100) NULL,
        `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `redzone_config_history` (
        `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, `revision` INT NOT NULL,
        `previous_revision` INT NULL, `changed_by_discord` VARCHAR(32) NOT NULL,
        `changed_by_name` VARCHAR(100) NULL, `change_reason` VARCHAR(255) NULL,
        `diff_json` LONGTEXT NOT NULL, `full_config_json` LONGTEXT NOT NULL,
        `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), INDEX `idx_arz_hist_revision` (`revision`),
        INDEX `idx_arz_hist_changed_by` (`changed_by_discord`),
        INDEX `idx_arz_hist_created` (`created_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
    [[CREATE TABLE IF NOT EXISTS `redzone_admin_audit` (
        `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, `discord_id` VARCHAR(32) NOT NULL,
        `player_name` VARCHAR(100) NULL, `citizenid` VARCHAR(64) NULL,
        `action` VARCHAR(64) NOT NULL, `zone_id` VARCHAR(64) NULL, `detail` TEXT NULL,
        `success` TINYINT(1) NOT NULL DEFAULT 1, `failure_reason` VARCHAR(255) NULL,
        `revision` INT NULL, `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (`id`), INDEX `idx_arz_audit_discord` (`discord_id`),
        INDEX `idx_arz_audit_action` (`action`), INDEX `idx_arz_audit_created` (`created_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]],
}

function Db.EnsureSchema()
    return createTables('schema creation', SCHEMA)
end

function Db.EnsureAdminSchema()
    return createTables('admin schema creation', ADMIN_SCHEMA)
end

function Db.FetchActiveCooldowns(nowMs)
    return MySQL.query.await(
        'SELECT `citizenid`, `zone_id`, `expires_at` FROM `redzone_cooldowns` WHERE `expires_at` > ?',
        { nowMs }) or {}
end

function Db.UpsertCooldown(citizenid, zoneId, expiresAt, nowMs)
    MySQL.query.await([[INSERT INTO `redzone_cooldowns` (`citizenid`, `zone_id`, `expires_at`, `updated_at`)
        VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE
        `expires_at` = GREATEST(`expires_at`, VALUES(`expires_at`)), `updated_at` = VALUES(`updated_at`)]],
        { citizenid, zoneId, expiresAt, nowMs })
end

function Db.ClearCooldown(citizenid, zoneId)
    MySQL.query.await('DELETE FROM `redzone_cooldowns` WHERE `citizenid` = ? AND `zone_id` = ?',
        { citizenid, zoneId })
end

function Db.PruneExpiredCooldowns(nowMs)
    return affected(MySQL.query.await('DELETE FROM `redzone_cooldowns` WHERE `expires_at` <= ?', { nowMs }))
end

function Db.InsertSquad(squad)
    MySQL.query.await([[INSERT INTO `redzone_squads`
        (`squad_id`, `name`, `leader_citizenid`, `created_at`, `updated_at`) VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE `name` = VALUES(`name`), `updated_at` = VALUES(`updated_at`)]],
        { squad.id, squad.name, squad.leaderCitizenId, squad.createdAt, squad.updatedAt })
end

function Db.UpdateSquadName(squadId, name, nowMs)
    MySQL.query.await('UPDATE `redzone_squads` SET `name` = ?, `updated_at` = ? WHERE `squad_id` = ?',
        { name, nowMs, squadId })
end

function Db.UpdateSquadLeader(squadId, leaderCitizenId, nowMs)
    MySQL.query.await('UPDATE `redzone_squads` SET `leader_citizenid` = ?, `updated_at` = ? WHERE `squad_id` = ?',
        { leaderCitizenId, nowMs, squadId })
end

function Db.TouchSquad(squadId, nowMs)
    MySQL.query.await('UPDATE `redzone_squads` SET `updated_at` = ? WHERE `squad_id` = ?', { nowMs, squadId })
end

function Db.DeleteSquad(squadId)
    MySQL.query.await('DELETE FROM `redzone_squad_members` WHERE `squad_id` = ?', { squadId })
    MySQL.query.await('DELETE FROM `redzone_squads` WHERE `squad_id` = ?', { squadId })
end

function Db.InsertSquadMember(squadId, citizenid, nowMs)
    local res = MySQL.query.await(
        'INSERT IGNORE INTO `redzone_squad_members` (`citizenid`, `squad_id`, `joined_at`) VALUES (?, ?, ?)',
        { citizenid, squadId, nowMs })
    return affected(res) > 0
end

function Db.DeleteSquadMember(squadId, citizenid)
    MySQL.query.await('DELETE FROM `redzone_squad_members` WHERE `citizenid` = ? AND `squad_id` = ?',
        { citizenid, squadId })
end

function Db.FetchSquads()
    return MySQL.query.await('SELECT * FROM `redzone_squads` WHERE `disbanded_at` IS NULL') or {}
end

function Db.FetchSquadMembers()
    return MySQL.query.await('SELECT * FROM `redzone_squad_members` ORDER BY `joined_at` ASC') or {}
end

function Db.UpsertSnapshot(snapshot)
    MySQL.query.await([[INSERT INTO `redzone_squad_snapshots`
        (`session_id`, `squad_id`, `leader_citizenid`, `members`, `locked_at`, `revision`)
        VALUES (?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE `revision` = `revision`]], {
        snapshot.sessionId, snapshot.squadId, snapshot.leaderCitizenId,
        json.encode(snapshot.memberOrder), snapshot.lockedAt, snapshot.revision,
    })
end

function Db.FetchSnapshots()
    return MySQL.query.await('SELECT * FROM `redzone_squad_snapshots`') or {}
end

function Db.DeleteSnapshotsForSession(sessionId)
    MySQL.query.await('DELETE FROM `redzone_squad_snapshots` WHERE `session_id` = ?', { sessionId })
end

function Db.DeleteSnapshotsNotIn(liveSessions)
    local rows = MySQL.query.await('SELECT DISTINCT `session_id` FROM `redzone_squad_snapshots`') or {}
    for i = 1, #rows do
        local sessionId = rows[i].session_id
        if not liveSessions[sessionId] then
            Db.DeleteSnapshotsForSession(sessionId)
        end
    end
end

local nameCache = {}

function Db.CacheCharName(citizenid, charName, nowMs)
    MySQL.query.await([[INSERT INTO `redzone_name_cache` (`citizenid`, `char_name`, `updated_at`)
        VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE
        `char_name` = VALUES(`char_name`), `updated_at` = VALUES(`updated_at`)]],
        { citizenid, charName, nowMs })
end

function Db.GetCachedCharName(citizenid)
    local cached = nameCache[citizenid]
    if cached ~= nil then return cached or nil end

    local row = MySQL.single.await('SELECT `char_name` FROM `redzone_name_cache` WHERE `citizenid` = ?',
        { citizenid })
    nameCache[citizenid] = row and row.char_name or false
    return row and row.char_name or nil
end

function Db.PrimeNameCache(citizenid, charName)
    nameCache[citizenid] = charName
end

function Db.FetchRuntimeConfig()
    local ok, row = protect('FetchRuntimeConfig', function()
        return MySQL.single.await('SELECT * FROM `redzone_runtime_config` WHERE `id` = 1')
    end)
    return ok and row or nil
end

function Db.SaveRuntimeConfig(schemaVersion, revision, configJson, discordId, name)
    return (protect('SaveRuntimeConfig', function()
        MySQL.query.await([[INSERT INTO `redzone_runtime_config`
            (`id`, `schema_version`, `revision`, `config_json`, `updated_by_discord`, `updated_by_name`)
            VALUES (1, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE
            `schema_version` = VALUES(`schema_version`), `revision` = VALUES(`revision`),
            `config_json` = VALUES(`config_json`), `updated_by_discord` = VALUES(`updated_by_discord`),
            `updated_by_name` = VALUES(`updated_by_name`)]],
            { schemaVersion, revision, configJson, discordId, name })
    end))
end

function Db.InsertConfigHistory(row)
    return (protect('InsertConfigHistory', function()
        MySQL.query.await([[INSERT INTO `redzone_config_history`
            (`revision`, `previous_revision`, `changed_by_discord`, `changed_by_name`,
             `change_reason`, `diff_json`, `full_config_json`)
            VALUES (?, ?, ?, ?, ?, ?, ?)]], {
            row.revision, row.previous_revision, row.changed_by_discord, row.changed_by_name,
            row.change_reason, row.diff_json, row.full_config_json,
        })
    end))
end

function Db.FetchConfigHistory(limit)
    local n = math.min(math.max(tonumber(limit) or 25, 1), 100)
    local ok, rows = protect('FetchConfigHistory', function()
        return MySQL.query.await([[SELECT `id`, `revision`, `previous_revision`, `changed_by_discord`,
            `changed_by_name`, `change_reason`, `diff_json`, `created_at`
            FROM `redzone_config_history` ORDER BY `id` DESC LIMIT ?]], { n })
    end)
    return ok and rows or {}
end

function Db.FetchConfigRevision(revision)
    local ok, row = protect('FetchConfigRevision', function()
        return MySQL.single.await([[SELECT `full_config_json` FROM `redzone_config_history`
            WHERE `revision` = ? ORDER BY `id` DESC LIMIT 1]], { revision })
    end)
    return ok and row and row.full_config_json or nil
end

function Db.FetchLatestGoodHistory()
    local ok, rows = pcall(function()
        return MySQL.query.await([[SELECT `revision`, `full_config_json`
            FROM `redzone_config_history` ORDER BY `id` DESC LIMIT 10]])
    end)
    if not ok or type(rows) ~= 'table' then return nil end

    for i = 1, #rows do
        local decoded = rows[i].full_config_json and json.decode(rows[i].full_config_json) or nil
        if type(decoded) == 'table' then
            return rows[i].full_config_json, rows[i].revision
        end
    end

    return nil
end

function Db.InsertAdminAudit(row)
    pcall(function()
        MySQL.query.await([[INSERT INTO `redzone_admin_audit`
            (`discord_id`, `player_name`, `citizenid`, `action`, `zone_id`,
             `detail`, `success`, `failure_reason`, `revision`)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
            row.discord_id, row.player_name, row.citizenid, row.action, row.zone_id,
            row.detail, row.success and 1 or 0, row.failure_reason, row.revision,
        })
    end)
end
