<?php
define('NO_OUTPUT_BUFFERING', true);

// 1. Safely include Moodle config
try {
    require_once(__DIR__ . '/../../config.php');
} catch (Throwable $e) {
    http_response_code(500);
    die("[DB Cleanup] CRITICAL: Failed to load config.php: " . $e->getMessage() . "\n");
}

// 2. Shared Secret Key (Must match run-jmeter.sh), read from a file in moodledata
$secret_file = $CFG->dataroot . '/testingsecret.txt';

if (!is_readable($secret_file)) {
    http_response_code(500);
    die("[DB Cleanup] CRITICAL: Secret key file not found or not readable: $secret_file\n");
}

$secret_key = trim(file_get_contents($secret_file));

if ($secret_key === '') {
    http_response_code(500);
    die("[DB Cleanup] CRITICAL: Secret key file is empty: $secret_file\n");
}

// 3. Extract and sanitize provided token
$provided_token = isset($_GET['token']) ? trim($_GET['token']) : '';

// 4. Compute expected tokens for today and yesterday (UTC)
$today_utc = gmdate('Y-m-d');
$expected_token = hash_hmac('sha256', $today_utc, $secret_key);

$yesterday_utc = gmdate('Y-m-d', time() - 86400);
$fallback_token = hash_hmac('sha256', $yesterday_utc, $secret_key);

// 5. Validate security token
if (empty($provided_token) || (!hash_equals($expected_token, $provided_token) && !hash_equals($fallback_token, $provided_token))) {
    http_response_code(403);
    die("[DB Cleanup] FORBIDDEN: Invalid or missing security token.\n");
}

// 6. Execute DB Truncate with Throwable catch
try {
    global $DB;
    
    if (!$DB) {
        throw new Exception("Moodle \$DB object is not initialized.");
    }

    $DB->execute("TRUNCATE TABLE {booking_answers}");
    
    http_response_code(200);
    echo "[DB Cleanup] SUCCESS: mdl_booking_answers table truncated.\n";
} catch (Throwable $e) {
    http_response_code(500);
    echo "[DB Cleanup] ERROR: " . $e->getMessage() . "\n";
}

