<?php

// Force OPcache reset if used, we do not want any stale caches
// when detecting if upgrade necessary or when running upgrade.
if (function_exists('opcache_reset') and !isset($_SERVER['REMOTE_ADDR'])) {
    opcache_reset();
}

define('CLI_SCRIPT', true);
define('CACHE_DISABLE_ALL', true);

require(__DIR__.'/../../config.php');
require_once($CFG->libdir.'/upgradelib.php');     // general upgrade/install related functions

$installable = core_plugin_manager::instance()->filter_installable(core_plugin_manager::instance()->available_updates());
if (!empty($installable)) {
   if (!core_plugin_manager::instance()->install_plugins($installable, true, true)) {
       throw new moodle_exception('install_plugins_failed', 'core_plugin', $return);
   }
}

// unconditionally upgrade
upgrade_noncore(true);

$installable = core_plugin_manager::instance()->filter_installable(core_plugin_manager::instance()->available_updates());

if (!empty($installable)) {
   if (!core_plugin_manager::instance()->install_plugins($installable, true, true)) {
       throw new moodle_exception('install_plugins_failed', 'core_plugin', $return);
   }
}

// unconditionally upgrade
upgrade_noncore(true);


exit(count($installable)); // 0 means success
