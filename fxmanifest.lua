fx_version 'cerulean'
games { 'gta5' }
lua54 'yes'
use_experimental_fxv2_oal 'yes'

author 'pr'
description 'pr REDZONE'
version '2.0.0'

ox_lib 'locale'

ui_page 'ui/dist/index.html'

shared_scripts {
    '@ox_lib/init.lua',
    'configs/sh.config.lua',
    'escrowed/sh.util.lua',
    'escrowed/sh.defaults.lua',
    'escrowed/sh.const.lua',
    'escrowed/sh.schema.lua',
}

client_scripts {
    'escrowed/client/c.util.lua',
    'escrowed/client/c.main.lua',
    'escrowed/client/c.world.lua',
    'escrowed/client/c.combat.lua',
    'escrowed/client/c.squad.lua',
    'escrowed/client/c.admin.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'configs/s.secrets.lua',
    'escrowed/server/s.util.lua',
    'escrowed/server/s.lib.framework.lua',
    'escrowed/server/s.lib.db.lua',
    'escrowed/server/s.lib.state.lua',
    'escrowed/server/s.lib.squads.lua',
    'escrowed/server/s.lib.access.lua',
    'escrowed/server/s.lib.combat.lua',
    'escrowed/server/s.lib.economy.lua',
    'escrowed/server/s.lib.admin.lua',
    'escrowed/server/s.main.lua',
    'escrowed/server/s.events.lua',
}

files {
    'locales/*.json',
    'ui/dist/**/*',
}

escrow_ignore {
    'configs/*.lua',
    'locales/*.json',
    'sql/*.sql',
}

dependencies {
    'ox_lib',
    'oxmysql',
    'ox_inventory',
}
