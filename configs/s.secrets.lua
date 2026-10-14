--[[
    pr — REDZONE secrets

    ==========================================================================================
    THIS FILE IS IN `server_scripts` ONLY. IT IS NEVER SENT TO A CLIENT.
    Everything secret belongs here. Nothing secret belongs in sh.config.lua.
    ==========================================================================================

    `sh.config.lua` is a SHARED file. FiveM downloads every shared script to every connecting
    client, where it sits in the game cache as readable plaintext — so a webhook URL or an
    admin whitelist written there is handed to every player who joins. Both live here instead.

    A Discord webhook URL is a bearer credential: holding it is enough to post to that channel
    or delete the hook. If yours has ever been in a shared file, create a new one, paste it
    here, and delete the old one.

    The administration menu can replace the webhook at runtime; that value is persisted in
    `redzone_runtime_config` and applied over the top of whatever is set here. This file is
    the DEFAULT, used until an admin changes it and again if the override is cleared.
]]

-- Shared scripts load first, so both tables already exist. Created here anyway so a future
-- reorder degrades into "no secrets" rather than a nil index crash.
Config = Config or {}
Config.AdminMenu = Config.AdminMenu or {}
Config.Logging = Config.Logging or {}

--- Raw Discord user IDs, no `discord:` prefix. This is the administration whitelist, and it
--- is the ONLY thing that grants access to /redzonemenu — not ACE, not god, not a job.
Config.AdminMenu.allowedDiscordIds = {
    '720720916354564199',
}

--- Discord webhook for RedZone logs. Empty string disables Discord logging entirely.
Config.Logging.webhook = ''
