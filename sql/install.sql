-- =============================================================================
--  pr-redzone — database schema
--  pr
--
--  Idempotent. Safe to run repeatedly and safe to run on a live database.
--
--  The resource creates these same tables at boot (Db.EnsureSchema for the six
--  gameplay tables, Db.EnsureAdminSchema for the three admin tables). This file
--  is the reviewable, version-controlled copy of that DDL — keep the two in sync.
--
--  No USE statement: apply it against an already-selected database.
--      mysql -u root -p your_database < sql/install.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
--  OPTIONAL MIGRATION — only for a server upgrading from the previous release,
--  where the three admin tables carried the old resource prefix. Run these THREE
--  statements FIRST, before the CREATE TABLE blocks below AND before the resource's
--  first start — the boot-time Db.EnsureAdminSchema would otherwise create the new
--  tables empty, which both fails the RENAME and strands the published overrides.
--  Then delete this block. Skip it entirely on a fresh install.
--
--      RENAME TABLE `aba_redzone_runtime_config` TO `redzone_runtime_config`;
--      RENAME TABLE `aba_redzone_config_history` TO `redzone_config_history`;
--      RENAME TABLE `aba_redzone_admin_audit`    TO `redzone_admin_audit`;
-- -----------------------------------------------------------------------------


-- RedZone entry lockouts. The deadline is stored ABSOLUTE, not as a countdown, so a
-- lockout survives disconnect, character reload, resource restart and full server
-- restart untouched. The composite key is the one-lockout-per-player-per-zone guarantee.
CREATE TABLE IF NOT EXISTS `redzone_cooldowns` (
    `citizenid`  VARCHAR(64) NOT NULL,
    `zone_id`    VARCHAR(64) NOT NULL,
    `expires_at` BIGINT      NOT NULL COMMENT 'epoch milliseconds',
    `updated_at` BIGINT      NOT NULL COMMENT 'epoch milliseconds',
    PRIMARY KEY (`citizenid`, `zone_id`),
    KEY `idx_redzone_cooldowns_expires` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- Elimination records — the single source of truth for teammate DNA. The item is only
-- a pointer: it is valid solely while a row here carries its serial in the right status,
-- so a duplicated, edited or hand-crafted item fails validation at the reboot station.
-- `gang_id` holds the full combat group id (`gang:<id>` or `solo_squad:<session>:<squad>`);
-- the session embedded in the solo form is why a head from a previous night can never
-- authorise a reboot today. UNIQUE on `item_serial` makes two items claiming the same
-- serial impossible at the database level, not merely in Lua.
CREATE TABLE IF NOT EXISTS `redzone_deaths` (
    `death_id`    VARCHAR(96)  NOT NULL,
    `citizenid`   VARCHAR(64)  NOT NULL COMMENT 'the eliminated player',
    `license`     VARCHAR(128) NULL     COMMENT 'server-side only, never sent to a client',
    `char_name`   VARCHAR(128) NOT NULL,
    `gang_id`     VARCHAR(64)  NOT NULL COMMENT 'combat group id (gang:... or solo_squad:...)',
    `zone_id`     VARCHAR(64)  NOT NULL,
    `pos_x`       DOUBLE       NOT NULL,
    `pos_y`       DOUBLE       NOT NULL,
    `pos_z`       DOUBLE       NOT NULL,
    `status`      VARCHAR(16)  NOT NULL DEFAULT 'pending' COMMENT 'pending|acquired|rebooted|expired',
    `item_serial` VARCHAR(96)  NULL,
    `acquired_by` VARCHAR(64)  NULL,
    `created_at`  BIGINT       NOT NULL,
    `acquired_at` BIGINT       NULL,
    `rebooted_at` BIGINT       NULL,
    `expires_at`  BIGINT       NULL,
    PRIMARY KEY (`death_id`),
    UNIQUE KEY `uniq_redzone_deaths_serial` (`item_serial`),
    KEY `idx_redzone_deaths_status` (`status`),
    KEY `idx_redzone_deaths_citizen` (`citizenid`),
    KEY `idx_redzone_deaths_zone_status` (`zone_id`, `status`),
    KEY `idx_redzone_deaths_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- Solo Squads — persistent rosters.
CREATE TABLE IF NOT EXISTS `redzone_squads` (
    `squad_id`         VARCHAR(96) NOT NULL,
    `name`             VARCHAR(64) NOT NULL,
    `leader_citizenid` VARCHAR(64) NOT NULL,
    `created_at`       BIGINT      NOT NULL,
    `updated_at`       BIGINT      NOT NULL,
    `disbanded_at`     BIGINT      NULL,
    PRIMARY KEY (`squad_id`),
    KEY `idx_redzone_squads_leader` (`leader_citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- Solo Squad membership. `citizenid` as the primary key is the hard database guarantee
-- of one active squad per player: two players racing to accept invitations for the final
-- slot cannot both succeed, because the second INSERT is rejected here and not merely in
-- Lua, and the application rolls its in-memory change back when that happens. The
-- 15-member cap is enforced in application code under a per-squad lock, since MySQL
-- cannot express it without a trigger.
CREATE TABLE IF NOT EXISTS `redzone_squad_members` (
    `citizenid` VARCHAR(64) NOT NULL,
    `squad_id`  VARCHAR(96) NOT NULL,
    `joined_at` BIGINT      NOT NULL,
    PRIMARY KEY (`citizenid`),
    KEY `idx_redzone_squad_members_squad` (`squad_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- Immutable session roster snapshots, written the moment the first squad member enters
-- the RedZone during a session and never modified afterwards. All combat logic reads
-- these, so a squad cannot swap in fresh players mid-fight, and a resource or server
-- restart during an active session restores the locked roster instead of allowing a new
-- lock. The composite key is one snapshot per squad per session; members are a JSON
-- array of citizen ids, de-duplicated by the application on load.
CREATE TABLE IF NOT EXISTS `redzone_squad_snapshots` (
    `session_id`       VARCHAR(32) NOT NULL COMMENT 'YYYY-MM-DD of the session opening, Israel time',
    `squad_id`         VARCHAR(96) NOT NULL,
    `leader_citizenid` VARCHAR(64) NOT NULL COMMENT 'leader at lock time',
    `members`          TEXT        NOT NULL COMMENT 'JSON array of citizen ids',
    `locked_at`        BIGINT      NOT NULL,
    `revision`         INT         NOT NULL DEFAULT 1,
    PRIMARY KEY (`session_id`, `squad_id`),
    KEY `idx_redzone_snapshots_session` (`session_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- Character name cache, so the squad UI can show offline members by name without
-- reading another resource's player table at request time.
CREATE TABLE IF NOT EXISTS `redzone_name_cache` (
    `citizenid`  VARCHAR(64)  NOT NULL,
    `char_name`  VARCHAR(128) NOT NULL,
    `updated_at` BIGINT       NOT NULL,
    PRIMARY KEY (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- Published runtime configuration. config.lua remains the DEFAULT and the emergency
-- fallback and is never rewritten; this single row, pinned to id = 1, holds only the
-- admin-edited overrides as JSON, deep-merged over the defaults at boot and on every
-- publish. `revision` increments on every publish and is what concurrent editors are
-- checked against, so a stale draft cannot silently clobber another change.
-- `config_json` may contain server-only secrets (the Discord webhook); it is never sent
-- to a client, and the serializer masks it before anything leaves the server.
CREATE TABLE IF NOT EXISTS `redzone_runtime_config` (
    `id`                 INT          NOT NULL DEFAULT 1,
    `schema_version`     INT          NOT NULL,
    `revision`           INT          NOT NULL DEFAULT 1,
    `config_json`        LONGTEXT     NOT NULL,
    `updated_by_discord` VARCHAR(32)  NOT NULL,
    `updated_by_name`    VARCHAR(100) NULL,
    `updated_at`         TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                                      ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- Configuration history — one row per published revision, never deleted. A rollback does
-- NOT remove history: it creates a new revision whose content matches an older one.
-- `diff_json` stores a human-readable field-level diff with sensitive values already
-- masked (the webhook appears as Configured or Replaced, never as a URL).
-- `full_config_json` stores the complete override set so any revision can be restored,
-- and it is only ever read server-side.
CREATE TABLE IF NOT EXISTS `redzone_config_history` (
    `id`                 BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `revision`           INT             NOT NULL,
    `previous_revision`  INT             NULL,
    `changed_by_discord` VARCHAR(32)     NOT NULL,
    `changed_by_name`    VARCHAR(100)    NULL,
    `change_reason`      VARCHAR(255)    NULL,
    `diff_json`          LONGTEXT        NOT NULL,
    `full_config_json`   LONGTEXT        NOT NULL,
    `created_at`         TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    INDEX `idx_arz_hist_revision` (`revision`),
    INDEX `idx_arz_hist_changed_by` (`changed_by_discord`),
    INDEX `idx_arz_hist_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- Operational audit log — administrative ACTIONS that are not configuration publishes:
-- menu opens, rejected access attempts, runtime zone overrides, crate timer control,
-- test spawns, diagnostics runs, webhook replacement. Kept separate from the
-- configuration history so the history view stays readable. `action` is free-form.
CREATE TABLE IF NOT EXISTS `redzone_admin_audit` (
    `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    `discord_id`    VARCHAR(32)     NOT NULL,
    `player_name`   VARCHAR(100)    NULL,
    `citizenid`     VARCHAR(64)     NULL,
    `action`        VARCHAR(64)     NOT NULL,
    `zone_id`       VARCHAR(64)     NULL,
    `detail`        TEXT            NULL,
    `success`       TINYINT(1)      NOT NULL DEFAULT 1,
    `failure_reason` VARCHAR(255)   NULL,
    `revision`      INT             NULL,
    `created_at`    TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    INDEX `idx_arz_audit_discord` (`discord_id`),
    INDEX `idx_arz_audit_action` (`action`),
    INDEX `idx_arz_audit_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
