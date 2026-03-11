<?php
// cli/extract_oauth2_nextcloud.php
// Usage: php cli/extract_oauth2_nextcloud.php

define('CLI_SCRIPT', true);

echo "Step 1: Loading config.php...\n";
require(__DIR__ . '/../../config.php');

echo "Step 2: Loading necessary libraries...\n";
require_once($CFG->libdir . '/adminlib.php');
require_once($CFG->libdir . '/authlib.php');

echo "Step 3: Fetching all OAuth2 issuers...\n";
$issuers = \core\oauth2\api::get_all_issuers();

if (empty($issuers)) {
    echo "ERROR: No OAuth2 issuers found in the database. Exiting.\n";
    exit(1);
}

echo "Step 4: Found " . count($issuers) . " issuer(s):\n";
foreach ($issuers as $issuer) {
    echo "  - ID: " . $issuer->get('id') . 
         " | Name: " . $issuer->get('name') . 
         " | Type: " . $issuer->get('servicetype') . 
         " | Enabled: " . $issuer->get('enabled') . "\n";
}

echo "\nStep 5: Select issuer to extract.\n";
echo "Enter the ID of the issuer you want to extract: ";
$handle = fopen("php://stdin", "r");
$input = trim(fgets($handle));
fclose($handle);

if (!is_numeric($input)) {
    echo "ERROR: Invalid input. Please enter a numeric ID.\n";
    exit(1);
}

$selectedid = (int)$input;
$selectedissuer = null;

foreach ($issuers as $issuer) {
    if ($issuer->get('id') === $selectedid) {
        $selectedissuer = $issuer;
        break;
    }
}

if (!$selectedissuer) {
    echo "ERROR: No issuer found with ID: {$selectedid}\n";
    exit(1);
}

echo "Step 6: Extracting issuer data for: " . $selectedissuer->get('name') . "\n";

$issuerdata = [
    'name'               => $selectedissuer->get('name'),
    'clientid'           => $selectedissuer->get('clientid'),
    'clientsecret'       => $selectedissuer->get('clientsecret'),
    'baseurl'            => $selectedissuer->get('baseurl'),
    'loginscopes'        => $selectedissuer->get('loginscopes'),
    'loginscopesoffline' => $selectedissuer->get('loginscopesoffline'),
    'loginparams'        => $selectedissuer->get('loginparams'),
    'loginparamsoffline' => $selectedissuer->get('loginparamsoffline'),
    'alloweddomains'     => $selectedissuer->get('alloweddomains'),
    'image'              => $selectedissuer->get('image'),
    'basicauth'          => $selectedissuer->get('basicauth'),
    'showonloginpage'    => $selectedissuer->get('showonloginpage'),
    'servicetype'        => $selectedissuer->get('servicetype'),
    'enabled'            => $selectedissuer->get('enabled'),
    'sortorder'          => $selectedissuer->get('sortorder'),
];

echo "  Issuer data extracted.\n";

echo "Step 7: Fetching endpoints...\n";
$endpoints = \core\oauth2\api::get_endpoints($selectedissuer);
$endpointdata = [];

if (empty($endpoints)) {
    echo "  WARNING: No endpoints found for this issuer.\n";
} else {
    echo "  Found " . count($endpoints) . " endpoint(s):\n";
    foreach ($endpoints as $endpoint) {
        echo "    - " . $endpoint->get('name') . ": " . $endpoint->get('url') . "\n";
        $endpointdata[] = [
            'name' => $endpoint->get('name'),
            'url'  => $endpoint->get('url'),
        ];
    }
}

echo "Step 8: Fetching user field mappings...\n";
$mappings = \core\oauth2\api::get_user_field_mappings($selectedissuer);
$mappingdata = [];

if (empty($mappings)) {
    echo "  WARNING: No user field mappings found for this issuer.\n";
} else {
    echo "  Found " . count($mappings) . " mapping(s):\n";
    foreach ($mappings as $mapping) {
        echo "    - " . $mapping->get('externalfield') . " -> " . $mapping->get('internalfield') . "\n";
        $mappingdata[] = [
            'externalfield' => $mapping->get('externalfield'),
            'internalfield' => $mapping->get('internalfield'),
        ];
    }
}

echo "Step 9: Building config array...\n";
$config = [
    'issuer'    => $issuerdata,
    'endpoints' => $endpointdata,
    'mappings'  => $mappingdata,
];

echo "Step 10: Encoding to JSON...\n";
$json = json_encode($config, JSON_PRETTY_PRINT);

if (!$json) {
    echo "ERROR: Failed to encode configuration to JSON. Error: " . json_last_error_msg() . "\n";
    exit(1);
}

echo "\n========== EXTRACTED CONFIGURATION ==========\n";
echo $json;
echo "\n==============================================\n";

echo "\nStep 11: Saving to file...\n";
$filename = __DIR__ . '/nextcloud_oauth2_config.json';
$result = file_put_contents($filename, $json);

if ($result === false) {
    echo "ERROR: Failed to write config file to: {$filename}\n";
    echo "Check directory permissions.\n";
    exit(1);
}

echo "Configuration saved to: {$filename}\n";
echo "\nExtraction complete.\n";
