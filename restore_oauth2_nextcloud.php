<?php
// cli/restore_oauth2_nextcloud.php
// Usage: php admin/cli/restore_oauth2_nextcloud.php
// Usage with custom config file: php admin/cli/restore_oauth2_nextcloud.php --config=/path/to/config.json

define('CLI_SCRIPT', true);

echo "Step 1: Loading config.php...\n";
require(__DIR__ . '/../../config.php');

echo "Step 2: Loading necessary libraries...\n";
require_once($CFG->libdir . '/adminlib.php');
require_once($CFG->libdir . '/authlib.php');

// =========================================================
// Load config file
// =========================================================
echo "Step 3: Loading OAuth2 configuration file...\n";

$options = getopt('', ['config:']);
$configfile = isset($options['config']) ? $options['config'] : __DIR__ . '/nextcloud_oauth2_config.json';

echo "  Looking for config file at: {$configfile}\n";

if (!file_exists($configfile)) {
    echo "ERROR: Config file not found at: {$configfile}\n";
    exit(1);
}

$json = file_get_contents($configfile);
if (!$json) {
    echo "ERROR: Could not read config file.\n";
    exit(1);
}

$config = json_decode($json, true);
if (!$config) {
    echo "ERROR: Could not parse JSON config file. Error: " . json_last_error_msg() . "\n";
    exit(1);
}

echo "  Config file loaded successfully.\n";

// =========================================================
// Validate config structure
// =========================================================
echo "Step 4: Validating config structure...\n";

if (empty($config['issuer'])) {
    echo "ERROR: Config file is missing 'issuer' section.\n";
    exit(1);
}
if (!isset($config['endpoints'])) {
    echo "ERROR: Config file is missing 'endpoints' section.\n";
    exit(1);
}
if (!isset($config['mappings'])) {
    echo "ERROR: Config file is missing 'mappings' section.\n";
    exit(1);
}

echo "  Config structure is valid.\n";
echo "  Issuer name    : " . $config['issuer']['name'] . "\n";
echo "  Base URL       : " . $config['issuer']['baseurl'] . "\n";
echo "  Client ID      : " . $config['issuer']['clientid'] . "\n";
echo "  Service type   : " . $config['issuer']['servicetype'] . "\n";
echo "  Endpoints      : " . count($config['endpoints']) . "\n";
echo "  Mappings       : " . count($config['mappings']) . "\n";

// =========================================================
// Check for existing issuer by name
// =========================================================
echo "\nStep 5: Checking for existing issuer...\n";

$issuers = \core\oauth2\api::get_all_issuers();
echo "  Found " . count($issuers) . " existing issuer(s) in database.\n";

$existingissuer = null;
foreach ($issuers as $issuer) {
    echo "  - ID: " . $issuer->get('id') . " | Name: " . $issuer->get('name') . "\n";
    if (strtolower($issuer->get('name')) === strtolower($config['issuer']['name'])) {
        $existingissuer = $issuer;
        echo "  >> Matched existing issuer: " . $issuer->get('name') . " (ID: " . $issuer->get('id') . ")\n";
    }
}

// =========================================================
// Update or Create Issuer
// =========================================================
echo "\nStep 6: ";

if ($existingissuer) {
    echo "Updating existing issuer...\n";

    foreach ($config['issuer'] as $key => $value) {
        echo "  Setting {$key} = {$value}\n";
        $existingissuer->set($key, $value);
    }

    try {
        \core\oauth2\api::update_issuer($existingissuer);
        $issuerid = $existingissuer->get('id');
        echo "  Issuer updated successfully. ID: {$issuerid}\n";
    } catch (Exception $e) {
        echo "ERROR: Failed to update issuer: " . $e->getMessage() . "\n";
        exit(1);
    }

} else {
    echo "Creating new issuer...\n";

    $record = (object) $config['issuer'];

    try {
        $newissuer = \core\oauth2\api::create_issuer($record);
        $issuerid = $newissuer->get('id');
        echo "  Issuer created successfully. ID: {$issuerid}\n";
    } catch (Exception $e) {
        echo "ERROR: Failed to create issuer: " . $e->getMessage() . "\n";
        exit(1);
    }
}

// =========================================================
// Reload issuer object
// =========================================================
echo "\nStep 7: Reloading issuer object...\n";

$issuerobject = \core\oauth2\api::get_issuer($issuerid);

if (!$issuerobject) {
    echo "ERROR: Could not reload issuer with ID: {$issuerid}\n";
    exit(1);
}

echo "  Issuer reloaded. Name: " . $issuerobject->get('name') . "\n";

// =========================================================
// Restore Endpoints
// =========================================================
echo "\nStep 8: Restoring endpoints...\n";

$existingendpoints = \core\oauth2\api::get_endpoints($issuerobject);
echo "  Found " . count($existingendpoints) . " existing endpoint(s) to delete.\n";

foreach ($existingendpoints as $ep) {
    echo "  Deleting endpoint: " . $ep->get('name') . "\n";
    try {
        \core\oauth2\api::delete_endpoint($ep->get('id'));
    } catch (Exception $e) {
        echo "  WARNING: Could not delete endpoint " . $ep->get('name') . ": " . $e->getMessage() . "\n";
    }
}

echo "  Creating " . count($config['endpoints']) . " endpoint(s)...\n";
foreach ($config['endpoints'] as $epdata) {
    $record = (object)[
        'issuerid' => $issuerid,
        'name'     => $epdata['name'],
        'url'      => $epdata['url'],
    ];
    try {
        \core\oauth2\api::create_endpoint($record);
        echo "  + Created endpoint: " . $epdata['name'] . " -> " . $epdata['url'] . "\n";
    } catch (Exception $e) {
        echo "  ERROR: Failed to create endpoint " . $epdata['name'] . ": " . $e->getMessage() . "\n";
        exit(1);
    }
}

// =========================================================
// Restore User Field Mappings
// =========================================================
echo "\nStep 9: Restoring user field mappings...\n";

$existingmappings = \core\oauth2\api::get_user_field_mappings($issuerobject);
echo "  Found " . count($existingmappings) . " existing mapping(s) to delete.\n";

foreach ($existingmappings as $mapping) {
    echo "  Deleting mapping: " . $mapping->get('externalfield') . " -> " . $mapping->get('internalfield') . "\n";
    try {
        \core\oauth2\api::delete_user_field_mapping($mapping->get('id'));
    } catch (Exception $e) {
        echo "  WARNING: Could not delete mapping: " . $e->getMessage() . "\n";
    }
}

echo "  Creating " . count($config['mappings']) . " mapping(s)...\n";
foreach ($config['mappings'] as $mapdata) {
    $record = (object)[
        'issuerid'      => $issuerid,
        'externalfield' => $mapdata['externalfield'],
        'internalfield' => $mapdata['internalfield'],
    ];
    try {
        \core\oauth2\api::create_user_field_mapping($record);
        echo "  + Created mapping: " . $mapdata['externalfield'] . " -> " . $mapdata['internalfield'] . "\n";
    } catch (Exception $e) {
        echo "  ERROR: Failed to create mapping: " . $e->getMessage() . "\n";
        exit(1);
    }
}

// =========================================================
// Done
// =========================================================
echo "\n------------------------------------------\n";
echo "Nextcloud OAuth2 restore complete.\n";
echo "------------------------------------------\n";
echo "Issuer ID    : " . $issuerid . "\n";
echo "Issuer Name  : " . $config['issuer']['name'] . "\n";
echo "Client ID    : " . $config['issuer']['clientid'] . "\n";
echo "Base URL     : " . $config['issuer']['baseurl'] . "\n";
echo "Enabled      : " . ($config['issuer']['enabled'] ? 'Yes' : 'No') . "\n";
echo "\nNext step - purge Moodle caches:\n";
echo "php admin/cli/purge_caches.php\n";
