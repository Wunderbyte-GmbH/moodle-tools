<?php

define('CLI_SCRIPT', true);
require_once("config.php");
require_once($CFG->libdir.'/clilib.php');

$path = $CFG->dataroot . "/stats";

$cfg = [];

$except = [
        'allversionshash',
        'backup_release', 'backup_version', 'digestmailtimelast',
        'fileslastcleanup', 'jsrev', 'langrev', 'localcachedirpurged',
        'maintenance_enabled', 'maintenance_message', 'scheduledtaskreset',
        'scorm_updatetimelast', 'statsfirstrun', 'statslastdaily', 'statslastmonthly',
        'statslastweekly', 'release', 'templaterev', 'themerev', 'version'
    ];
list($sql, $params) = $DB->get_in_or_equal($except);
$t = $DB->get_records_sql("SELECT id,name,value FROM mdl_config WHERE name NOT {$sql} ORDER BY name ASC", $params);

foreach ($t as $row){
    $name = $row->name;
    $value = str_replace("\$", "\\\$", addslashes($row->value));
    $cfg[] = "\$CFG->{$name} = \"{$value}\";";
}

$t = $DB->get_records_sql('SELECT id,plugin,name,value FROM mdl_config_plugins ORDER BY plugin ASC,name ASC');
$lastplugin = '';
foreach ($t as $row){
    $name = $row->name;
    $plugin = $row->plugin;
    $value = str_replace("\$", "\\\$", addslashes($row->value));

    if ($name == 'expirynotifylast') continue;
    if ($name == 'lastcron') continue;
    if ($name == 'themerev') continue;
    if ($name == 'version') continue;

    if (substr($name, 0, strlen('search_activity_')) == 'search_activity_') continue;
    if (substr($name, 0, strlen('search_chapter_')) == 'search_chapter_') continue;
    if (substr($name, 0, strlen('search_collaborative_')) == 'search_collaborative_') continue;
    if (substr($name, 0, strlen('search_entry_')) == 'search_entry_') continue;
    if (substr($name, 0, strlen('search_post_')) == 'search_post_') continue;
    if (substr($name, 0, strlen('search_question_')) == 'search_question_') continue;
    if (substr($name, 0, strlen('search_tags_')) == 'search_tags_') continue;


    if ($plugin == 'core_plugin') continue;
    if ($plugin == 'core_search') continue;
    if ($plugin == 'hub' && $name == 'site_regupdateversion') continue;
    if ($plugin == 'local_o365' && $name == 'apptokens') continue;
    if ($plugin == 'local_o365' && $name == 'calsyncinlastrun') continue;
    if ($plugin == 'local_o365' && $name == 'systemtokens') continue;
    if ($plugin == 'mnet' && $name == 'openssl') continue;
    if ($plugin == 'mnet' && $name == 'openssl_generations') continue;
    if ($plugin == 'mnet' && $name == 'openssl_history') continue;
    if ($plugin == 'mod_hvp' && $name == 'admin_notified') continue;
    if ($plugin == 'mod_hvp' && $name == 'content_type_cache_updated_at') continue;
    if ($plugin == 'mod_hvp' && $name == 'current_update') continue;
    if ($plugin == 'mod_hvp' && $name == 'update_available') continue;
    if ($plugin == 'mod_hvp' && $name == 'update_available_path') continue;
    if ($plugin == 'mod_lti' && $name == 'kid') continue;
    if ($plugin == 'mod_lti' && $name == 'privatekey') continue;
    if ($plugin == 'search_simpledb' && $name == 'lastschemacheck') continue;
    if ($plugin == 'tool_imageoptimize' && $name == 'lastprocessedfileid') continue;
    if ($plugin == 'tool_mobile') continue;
    if ($plugin == 'tool_task') continue;

    if ($lastplugin != $row->plugin) {
        if (!empty($plugin)) {
            $cfg[] = "];";
        }
        $lastplugin = $row->plugin;
        $cfg[] = "\$CFG->forced_plugin_settings['{$plugin}'] = [";
    }

    $cfg[] = "    '{$name}' => \"{$value}\",";
}

if (!empty($plugin)) {
    $cfg[] = "];";
}

file_put_contents("$path/config-moodle.php", "<?php" . PHP_EOL . PHP_EOL . implode(PHP_EOL, $cfg));
