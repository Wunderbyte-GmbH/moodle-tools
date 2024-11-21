<?php
// Set the maximum execution time and memory limit to prevent timeouts
set_time_limit(0);
ini_set('memory_limit', '-1');

// Include the Moodle config.php file to get database connection details
require_once('config.php');

// Define the path where the dump file will be saved
$backupDir = $CFG->dataroot . '/backup/';
$backupFile = $backupDir . 'moodle_db_backup_' . date('Y-m-d_H-i-s') . '.sql.gz';

// Ensure the backup directory exists
if (!file_exists($backupDir)) {
    mkdir($backupDir, 0777, true);
}

// Construct the mysqldump command
$mysqldumpCmd = sprintf(
    'mysqldump --user=%s --password=%s --host=%s %s | gzip > %s',
    escapeshellarg($CFG->dbuser),
    escapeshellarg($CFG->dbpass),
    escapeshellarg($CFG->dbhost),
    escapeshellarg($CFG->dbname),
    escapeshellarg($backupFile)
);

// Execute the command
exec($mysqldumpCmd, $output, $returnVar);

// Check if the dump was successful
if ($returnVar === 0) {
    echo "Database dump was successful. The backup file is located at: $backupFile\n";
} else {
    echo "Error: Database dump failed. Return code: $returnVar\n";
    echo "Output: " . implode("\n", $output) . "\n";
}
?>
