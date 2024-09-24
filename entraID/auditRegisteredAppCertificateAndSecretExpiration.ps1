# This script must be used within an automation runbook
# Audit all secret and certificate expiration date of all registered App
# Identify secret and certificate which have expired
# Identity secrets and certificates which will expire in $DaysUntilExpiration days
# Generate an HTML report
# Send HTML report to users
# Store HTML report in Azure storage account
######################################################################################

$managedIdentityID = "1d7c17b5-cc18-4041-a242-xxxxxxx"        # ClientID of the user managed Identity used by Azure Automation runbook
$storageAccountName = "staaprdfrc01"                          # Storage account name to save the results
$containerName = "auditregisteredapps"                        # Blob container name within the storage account to save the results
$ResourceGroupName = "rg-identity-auditautomation-prd-frc-01" # Name of the RG 
$DaysUntilExpiration = 30                                     # How many days before secret expiration
$userId = "userd@enterprise.com"                          # Email (UPN) of the mail box which will sent the email with results
 
## Connections (Azure & Microsoft Graph API)
 
# Azure Connection
try {
    Connect-AzAccount -Identity -AccountId  $managedIdentityID | Out-null
}
catch {
    Write-Error "Failed to connect to Azure using managed identity. $_"
    Exit
}
 
# Microsoft Graph API Connection
 
###### Use Microsoft Graph API to retrieve the managed identity token
$token = Get-AzAccessToken -ResourceUrl https://graph.microsoft.com
$secureToken = ConvertTo-SecureString -String $token.Token -AsPlainText -Force
 
###### Connect MgGraph with token
try {
    Connect-MgGraph -AccessToken $secureToken
}
catch {
    Write-Error "Failed to connect to Microsoft Graph API using managed identity token $_"
    Exit
}
 
$Now = Get-Date
 
Write-Output "The operation is running and will take longer the more applications the tenant has..."
Write-Output "Please wait..."
 
$Applications = Get-MgApplication -all
 
$Logs = @()
 
foreach ($App in $Applications) {
    $AppName = $App.DisplayName
    $AppID = $App.Id
    $ApplID = $App.AppId
 
    $AppCreds = Get-MgApplication -ApplicationId $AppID |
    Select-Object PasswordCredentials, KeyCredentials
 
    $Secrets = $AppCreds.PasswordCredentials
    $Certs = $AppCreds.KeyCredentials
 
    Write-Output "Auditing application : '$AppName'"
 
    foreach ($Secret in $Secrets) {
        $StartDate = $Secret.StartDateTime
        $EndDate = $Secret.EndDateTime
        $SecretName = $Secret.DisplayName
 
        $Owner = Get-MgApplicationOwner -ApplicationId $App.Id
        $Username = $Owner.AdditionalProperties.userPrincipalName -join ';'
        $OwnerID = $Owner.Id -join ';'
 
        if ($null -eq $Owner.AdditionalProperties.userPrincipalName) {
            $Username = @(
                $Owner.AdditionalProperties.displayName
                '**<This is an Application>**'
            ) -join ' '
        }
        if ($null -eq $Owner.AdditionalProperties.displayName) {
            $Username = '<<No Owner>>'
        }
 
        $RemainingDaysCount = ($EndDate - $Now).Days
 
        if ($RemainingDaysCount -le 30 -and $RemainingDaysCount -ge 1) {
            # Case 1: Remaining days is between 30 and 1 day
            $Logs += [PSCustomObject]@{
                'ApplicationName'  = $AppName
                'ApplicationID'    = $ApplID
                'Type'             = "Secret"
                'Name'             = $SecretName
                'Start Date'       = $StartDate
                'End Date'         = $EndDate
                'Owner'            = $Username
                'Owner_ObjectID'   = $OwnerID
                'Audit_message'    = "Secret will expire in $RemainingDaysCount days"
            }
        }
        elseif ($RemainingDaysCount -le 0) {
            # Case 2: Remaining days is 0 or below
            $Logs += [PSCustomObject]@{
                'ApplicationName'  = $AppName
                'ApplicationID'    = $ApplID
                'Type'             = "Secret"
                'Name'             = $SecretName
                'Start Date'       = $StartDate
                'End Date'         = $EndDate
                'Owner'            = $Username
                'Owner_ObjectID'   = $OwnerID
                'Audit_message'    = "Secret has expired"
            }
        }
    }
 
    foreach ($Cert in $Certs) {
        $StartDate = $Cert.StartDateTime
        $EndDate = $Cert.EndDateTime
        $CertName = $Cert.DisplayName
 
        $Owner = Get-MgApplicationOwner -ApplicationId $App.Id
        $Username = $Owner.AdditionalProperties.userPrincipalName -join ';'
        $OwnerID = $Owner.Id -join ';'
 
        if ($null -eq $Owner.AdditionalProperties.userPrincipalName) {
            $Username = @(
                $Owner.AdditionalProperties.displayName
                '**<This is an Application>**'
            ) -join ' '
        }
        if ($null -eq $Owner.AdditionalProperties.displayName) {
            $Username = '<<No Owner>>'
        }
 
        $RemainingDaysCount = ($EndDate - $Now).Days
 
        if ($RemainingDaysCount -le 30 -and $RemainingDaysCount -ge 1) {
            # Case 1: Remaining days is between 30 and 1 day
            $Logs += [PSCustomObject]@{
                'ApplicationName'  = $AppName
                'ApplicationID'    = $ApplID
                'Type'             = "Certificate"
                'Name'             = $CertName
                'Start Date'       = $StartDate
                'End Date'         = $EndDate
                'Owner'            = $Username
                'Owner_ObjectID'   = $OwnerID
                'Audit_message'    = "Certificate will expire in $RemainingDaysCount days"
            }
        }
        elseif ($RemainingDaysCount -le 0) {
            # Case 2: Remaining days is 0 or below
            $Logs += [PSCustomObject]@{
                'ApplicationName'  = $AppName
                'ApplicationID'    = $ApplID
                'Type'             = "Certificate"
                'Name'             = $CertName
                'Start Date'       = $StartDate
                'End Date'         = $EndDate
                'Owner'            = $Username
                'Owner_ObjectID'   = $OwnerID
                'Audit_message'    = "Secret has expired"
            }
        }
    }
}
 
write-output "RAW DATA"
write-output $logs
 
write-output ""
write-output "FORMATED DATA"
 
$formatedLogs = $Logs | Select-Object 'ApplicationName', 'Type', 'Name', 'Audit_message' | Format-Table -AutoSize
Write-Output $formatedLogs
 
$htmlformatedlogs = $Logs | Select-Object 'ApplicationName', 'Type', 'Name', 'Audit_message' | ConvertTo-Html -Fragment


# Create a complete HTML document with basic styling
$htmlContent = @"
<html>
<head>
    <style>
        table { width: 100%; border-collapse: collapse; }
        th, td { border: 1px solid black; padding: 8px; text-align: left; }
    </style>
</head>
<body>
    $htmlformatedlogs
</body>
</html>
"@

$params = @{
    message         = @{
        subject      = "[AZURE] Audit Registered Apps"
        body         = @{
            contentType = "HTML"
            content     = $htmlContent
        }
        toRecipients = @(
            @{
                emailAddress = @{
                    address = "user@enterprise.com"
                }
            }
        )
        ccRecipients = @(
            @{
                emailAddress = @{
                    address = "user@enterprise.com"
                }
            }
        )
    }
    saveToSentItems = "false"
}


# A UPN can also be used as -UserId.
Send-MgUserMail -UserId $userId -BodyParameter $params

# Stockage de l'audit sur le Blob Storage
$dateTimeStr = (Get-Date).ToString("yyyyMMdd_HHmmss")
$destinationBlobName = "AuditRegisteredApp_$dateTimeStr.html"
$tempFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),$destinationBlobName )
Set-Content -Path $tempFilePath -Value $htmlContent -Encoding UTF8

# Write the HTML content to the local file
$azStorageAccountContext = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $storageAccountName).Context
 
Set-AzStorageBlobContent -File $tempFilePath -Container $ContainerName -Blob $destinationBlobName -Context $azStorageAccountContext

Remove-Item -Path $tempFilePath -Force
