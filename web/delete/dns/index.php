<?php
// Init
error_reporting(NULL);
ob_start();
session_start();
include($_SERVER['DOCUMENT_ROOT']."/inc/main.php");

if ($_SESSION['user'] == 'admin') {
    // DNS domain
    if ((!empty($_GET['domain'])) && (empty($_GET['record_id'])))  {
        $v_username = escapeshellarg($user);
        $v_domain = escapeshellarg($_GET['domain']);
        exec (VESTA_CMD."v_delete_dns_domain ".$v_username." ".$v_domain, $output, $return_var);
        unset($output);
        header("Location: /list/dns/");
        exit;
    }

    // DNS record
    if ((!empty($_GET['domain'])) && (!empty($_GET['record_id'])))  {
        $v_username = escapeshellarg($user);
        $v_domain = escapeshellarg($_GET['domain']);
        $v_record_id = escapeshellarg($_GET['record_id']);
        exec (VESTA_CMD."v_delete_dns_domain_record ".$v_username." ".$v_domain." ".$v_record_id, $output, $return_var);
        unset($output);
        header("Location: /list/dns/?domain=".$_GET['domain']);
        exit;
    }
}

header("Location: /list/dns/");
