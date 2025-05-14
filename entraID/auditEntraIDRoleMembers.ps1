# Technical memo for maintenance
################################
# Goals of this script:
# Goal #1 (audit the current state)
#   For each EntraID role, get the list of active and elligible members
#   Members can be any EntraID security principal: User, Group or Enterprise Application (service Principal)
#   Verify the scope of the assignment for each member
#   Scope assignement can be Tenant directory, Administrative unit, Enterprise application (service principal) or Registered Application
#   Save the result in a file and upload it to Azure Storage account
# 
# Goal #2 (compare)
#   Get the latest audit file if it exists
#   If it exists, use it with the new audit file to build comparaison based on the following attribute : 
#       - Entra ID role name
#       - Security Principal Type
#       - Security Principal Object ID
#       - Security Prinicipal Display Name
#       - Assignment type
#   Comparaison status are :
#       - NO CHANGE : The assignement exists in the previous and the current audit file
#       - ADDED : The assignement exists only in the current audit file
#       - REMOVED : The assignement exists only in the previous audit file
#
# Goal #3 (communicate)
#   Build a simple HTML report and send it by email
#
# [IMPORTANT] [REQUIRED PERMISSIONS]
# This script has been build in order to be deployed in Azure Automation Account
# Create a User Managed Identity (MI) for script execution
# MI should have the following application permissions
# MgGraph :
#   - User.Read.All
#   - RoleManagement.Read.Directory
#   - Directory.Read.All
#   - RoleEligibilitySchedule.Read.Directory
#   - RoleAssignmentSchedule.Read.Directory
#   - Mail.send
#
# Azure
#   - RBAC Role "Reader and Data Access" on Azure Storage Account
#   - RBAC Role "Storage Blob Data Contributor" on Azure Storage Account
#
# Usage : This script aims to be used with Azure Automation and a dedicated Managed Identity



# VARIABLES
$managedIdentityID = "1d7c17b5-cc18-xxxx-xxxx-5b2e41ddde74"     # ID of the managed identity used for script execution
$StorageAccountName = "staaprdfrc01"                            # Azure storage account for files upload
$ContainerName = "auditadminroles"                              # Name of the blob container for ile upload
$blobName = "EntraID_RoleMembers_Audit.csv"                     # Blob name
$ToEmail = "user@domain.fr"                                     # Email address  (to)
$FromEmail = "user@domain.fr"                                   # Email address (from)
$Subject = "Weekly Entra ID Roles Access Review"                # Email subject
 
# Files
$currentAuditFile = ".\EntraID_RoleMembers_Audit.csv"         # File that will store the list of membership for the current script
$previousAuditFile = ".\EntraID_RoleMembers_Previous_Audit.csv"      # File that will store the list of membership from the previous 
$htmlOutputFile = ".\EntraID_RoleMembers_AuditComparaison_$(Get-Date -Format 'yyyyMMdd').html"     # HTML file that will store the audit comparaison result between previous files


# CONNECTION
try {
    Connect-AzAccount -Identity -AccountId $managedIdentityID | Out-Null
}
catch {
    Write-Error "Failed to connect to Azure using managed identity. $_"
    Exit
}
 
# Connect to Microsoft Graph API
$token = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com"
$secureToken = ConvertTo-SecureString -String $token.Token -AsPlainText -Force
try {
    Connect-MgGraph -AccessToken $secureToken
}
catch {
    Write-Error "Failed to connect to Microsoft Graph API using managed identity token $_"
    Exit
}


#######################################
## STEP 1 : RETRIEVE MEMBERSHIP
#######################################
 
$roleMembers = @()              # Object to store the list of EntraID role
$activeMembers = @()            # Object to store the list of active Members
$eligibleMembers = @()          # Object to store the list of eligible Members
 
# Get all directory roles
$builtInRoles = Get-MgDirectoryRole
$customRoles = Get-MgRoleManagementDirectoryRoleDefinition -Filter "isBuiltIn eq false"
$allRoles = $builtInRoles + $customRoles
 
#### TEST ONLY ####
# Scope to only one role for test purpose
#$namedRole = "Password Administrator"
# $roles = Get-MgDirectoryRole | Where-Object { $_.DisplayName -eq $namedRole }
 
# Iterate through each role
foreach ($role in $allRoles) {

    # Stange behaviour to be checked
    # For BuiltIn Role, you use $Role.RoleTemplateID
    # For Custom Role, you use $Role.id. Custom Role does not have the paramater RoleTemplateId
    if ($null -eq $role.RoleTemplateID) {
        $roleDefinitionId = $role.id
    }
    else {
        $roleDefinitionId = $role.RoleTemplateID
    }



    # Construct URIs for retrieving active and eligible assignments
    $activeUri = "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignmentScheduleInstances" + "?`$filter=roleDefinitionId eq '$roleDefinitionId'" + "&`$expand=principal,directoryScope"

    $eligibleUri = "https://graph.microsoft.com/beta/roleManagement/directory/roleEligibilityScheduleInstances" + "?`$filter=roleDefinitionId eq '$roleDefinitionId'" + "&`$expand=principal,directoryScope"

 
    write-output "Processing Entra ID Role $($role.DisplayName) with ID $($role.Id)"
 
    # Retrieve active members for the current role
    try {
        $activeMembersResult = Invoke-MgGraphRequest -Method GET -Uri $activeUri
        $activeMembers = $activeMembersResult.value
        write-output "`tActive Members count $($activeMembers.count)"
    }
    catch {
        Write-Warning "`tFailed to retrieve active members for role $($role.DisplayName): $($_.Exception.Message)"
 
    }
 
    # Retrieve eligible members for the current role
    try {
        $eligibleMembersResult = Invoke-MgGraphRequest -Method GET -Uri $eligibleUri
        $eligibleMembers = $eligibleMembersResult.value
        write-output "`tEligible Member count $($eligibleMembers.count)"
    }
    catch {
        Write-Warning "`tFailed to retrieve eligible members for role $($role.DisplayName): $($_.Exception.Message)" 
    }
 
 
    ### MANAGE ACTIVE MEMBERS
    # Iterate through each active members
    foreach ($member in $activeMembers) {
        # Determine the principal type based on the @odata.type property
        $odataType = $member.principal.'@odata.type'
        if ($odataType -match '#microsoft.graph.(user|group|servicePrincipal)') {
            $principalType = $Matches[1]
        }
        else {
            $principalType = 'directoryObject'  # Default to directoryObject if type is unknown
        }
 
        # Get additional details based on the principal type
        try {
            switch ($principalType) {
                'user' {
                    $principalObject = Get-MgUser -UserId $member.PrincipalId
                }
                'group' {
                    $principalObject = Get-MgGroup -GroupId $member.PrincipalId
                }
                'servicePrincipal' {
                    $principalObject = Get-MgServicePrincipal -ServicePrincipalId $member.PrincipalId
                }
                default {
                    # If the principal type is not user, group, or service principal, fetch as a generic directory object
                    $principalObject = Get-MgDirectoryObject -DirectoryObjectId $member.PrincipalId
                }
            }
 
            # Extract the display name
            $displayName = $principalObject.DisplayName ?? "N/A"
 
            #Manage Scope

            # Extract scope details with GUID isolation

            $scopeString = $member.directoryScopeId

            # If scope is "/" it means that there is no specific scope and the assignation is global (all directory)
            if ($scopeString -eq "/") {
                $scopeType = "Directory-wide"
                $scopeID = ""
                $scopeName = "Entire organization"
            }

            # If scope is "/GUID" it means that the assignation is scoped to a specific enterprise application or a Registered application
            # The GUID is the ObjectID of the Enterprise Application
            elseif ($scopeString -match "^/([0-9a-fA-F-]{36})$") {
                $scopeID = $matches[1]
                if ($member.DirectoryScope.'@odata.type' -eq "#microsoft.graph.servicePrincipal") {
                    $scopeType = "Enterprise Application"
                    # As the scope type is an Enterprise Application, you can get the display name with get-MgServicePrincipal cmdlet
                    $scopeName = (Get-MgServicePrincipal -ServicePrincipalId $scopeID).DisplayName
                }
                elseif ($member.DirectoryScope.'@odata.type' -eq "#microsoft.graph.application") {
                    $scopeType = "Registered Application"
                    
                    # As the scope type is an Enterprise Application, you can get the display name with get-MgServicePrincipal cmdlet
                    $scopeName = (Get-MgApplication -ApplicationID $scopeID).DisplayName
                }
                else {
                    $scopeType = "Unknow Scope Type with GUID $($scopeID)"
                    $scopeName = "Unknow Scope Name with GUID $($scopeID)"

                }

            }
            # If scope is "/administrativeUnits/GUID" it means that the assignation is scoped to a specific EntraID Administrative Unit 
            # The GUID is the ObjectID of the Administrative Unit
            elseif ($scopeString -match "^/AdministrativeUnits/([0-9a-fA-F-]{36})$") {
                $scopeType = "Administrative Unit"
                $scopeID = $matches[1]
                # As the scope type is an Administrative Unit, you can get the display name with get-MgDirectoryAdministrativeUnit cmdlet
                $scopeName = (Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId $scopeID).DisplayName
            }
            else {
                $scopeType = "Unknown scope type"
                $scopeID = ""
                $scopeName = "Unknown scope name"
            }


            # Create a custom object and add it to the array
            $roleMembers += [PSCustomObject]@{
                'Entra_ID_Role_Name'              = $role.DisplayName ?? "Unknown value"
                'Security_Principal_Type'         = $principalType ?? "Unknown value"
                'Security_Principal_Object'       = $principalObject.Id ?? "Unknown value"
                'Security_Principal_Display_Name' = $displayName
                'Assignment_Type'                 = "Active"
                'Scope_Type'                      = $scopeType
                'Scope_Name'                      = $scopeName
            }
        }
        catch {
            Write-Warning "Failed to retrieve details for member $($member.Id) of type $($principalType): $($_.Exception.Message)"
            # Still create a record, but include the error
            $roleMembers += [PSCustomObject]@{
                'Entra_ID_Role_Name'              = $role.DisplayName ?? "Unknown value"
                'Security_Principal_Type'         = $principalType ?? "Unknown value"
                'Security_Principal_Object'       = $member.Id ?? "Unknown value"
                'Security_Principal_Display_Name' = "Error retrieving details"
                'Assignment_Type'                 = "Active"
                'Scope_Type'                      = $scopeType ?? "Unknown value"
                'Scope_Name'                      = $scopeName ?? "Unknown value"
            }
            continue  # Skip to the next member if there's an error
        }
    }
 
    ### MANAGE ELIGIBLE MEMBERS
    # Iterate through each eligible members

    foreach ($member in $eligibleMembers) {
        # Determine the principal type based on the @odata.type property
        $odataType = $member.principal.'@odata.type'
        if ($odataType -match '#microsoft.graph.(user|group|servicePrincipal)') {
            $principalType = $Matches[1]
        }
        else {
            $principalType = 'directoryObject'  # Default to directoryObject if type is unknown
        }

        # Get additional details based on the principal type
        try {
            switch ($principalType) {
                'user' {
                    $principalObject = Get-MgUser -UserId $member.PrincipalId
                }
                'group' {
                    $principalObject = Get-MgGroup -GroupId $member.PrincipalId
                }
                'servicePrincipal' {
                    $principalObject = Get-MgServicePrincipal -ServicePrincipalId $member.PrincipalId
                }
                default {
                    # If the principal type is not user, group, or service principal, fetch as a generic directory object
                    $principalObject = Get-MgDirectoryObject -DirectoryObjectId $member.PrincipalId
                }
            }

            # Extract the display name
            $displayName = $principalObject.DisplayName ?? "N/A"

            #Manage Scope

            # Extract scope details with GUID isolation

            $scopeString = $member.directoryScopeId

            # If scope is "/" it means that there is no specific scope and the assignation is global (all directory)
            if ($scopeString -eq "/") {
                $scopeType = "Directory-wide"
                $scopeID = ""
                $scopeName = "Entire organization"
            }

            # If scope is "/GUID" it means that the assignation is scoped to a specific enterprise application or a Registered application
            # The GUID is the ObjectID of the Enterprise Application
            elseif ($scopeString -match "^/([0-9a-fA-F-]{36})$") {
                $scopeID = $matches[1]
                if ($member.DirectoryScope.'@odata.type' -eq "#microsoft.graph.servicePrincipal") {
                    $scopeType = "Enterprise Application"
                    # As the scope type is an Enterprise Application, you can get the display name with get-MgServicePrincipal cmdlet
                    $scopeName = (Get-MgServicePrincipal -ServicePrincipalId $scopeID).DisplayName
                }
                elseif ($member.DirectoryScope.'@odata.type' -eq "#microsoft.graph.application") {
                    $scopeType = "Registered Application"
                    
                    # As the scope type is an Enterprise Application, you can get the display name with get-MgServicePrincipal cmdlet
                    $scopeName = (Get-MgApplication -ApplicationID $scopeID).DisplayName
                }
                else {
                    $scopeType = "Unknow Scope Type with GUID $($scopeID)"
                    $scopeName = "Unknow Scope Name with GUID $($scopeID)"

                }

            }
            # If scope is "/administrativeUnits/GUID" it means that the assignation is scoped to a specific EntraID Administrative Unit 
            # The GUID is the ObjectID of the Administrative Unit
            elseif ($scopeString -match "^/AdministrativeUnits/([0-9a-fA-F-]{36})$") {
                $scopeType = "Administrative Unit"
                $scopeID = $matches[1]
                # As the scope type is an Administrative Unit, you can get the display name with get-MgDirectoryAdministrativeUnit cmdlet
                $scopeName = (Get-MgDirectoryAdministrativeUnit -AdministrativeUnitId $scopeID).DisplayName
            }
            else {
                $scopeType = "Unknown scope type"
                $scopeID = ""
                $scopeName = "Unknown scope name"
            }


            # Create a custom object and add it to the array
            $roleMembers += [PSCustomObject]@{
                'Entra_ID_Role_Name'              = $role.DisplayName ?? "Unknown value"
                'Security_Principal_Type'         = $principalType ?? "Unknown value"
                'Security_Principal_Object'       = $principalObject.Id ?? "Unknown value"
                'Security_Principal_Display_Name' = $displayName
                'Assignment_Type'                 = "Eligible"
                'Scope_Type'                      = $scopeType
                'Scope_Name'                      = $scopeName
            }
        }
        catch {
            Write-Warning "Failed to retrieve details for member $($member.Id) of type $($principalType): $($_.Exception.Message)"
            # Still create a record, but include the error
            $roleMembers += [PSCustomObject]@{
                'Entra_ID_Role_Name'              = $role.DisplayName ?? "Unknown value"
                'Security_Principal_Type'         = $principalType ?? "Unknown value"
                'Security_Principal_Object'       = $member.Id ?? "Unknown value"
                'Security_Principal_Display_Name' = "Error retrieving details"
                'Assignment_Type'                 = "Eligible"
                'Scope_Type'                      = $scopeType ?? "Unknown value"
                'Scope_Name'                      = $scopeName ?? "Unknown value"
            }
            continue  # Skip to the next member if there's an error
        }
    }
}

# sort results based on collumn Entra_Id_Role_Name
$roleMembers = $roleMembers | Sort-Object -Property 'Entra_ID_Role_Name'

$roleMembers | Format-Table -AutoSize
#########################################################################
## STEP 2 : PREPARE CSV FILES AND IMPORT TO STORAGE ACCOUNT
#########################################################################
 
# Create Storage Context
$storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount
 
# Check if the blob exists in Azure Storage
$blobExists = (Get-AzStorageBlob -Container $containerName -Blob $blobName -Context $storageContext -ErrorAction SilentlyContinue)
 
if ($blobExists) {
    write-output "Blob exists in Azure Storage."
 
    # Download the existing blob file to local storage as .\EntraID_RoleMembers_Previous_Audit.csv
    Get-AzStorageBlobContent -Container $containerName -Blob $blobName -Destination $previousAuditFile  -Context $storageContext -Force
    write-output "Downloaded blob as '$previousAuditFile '."
 
    # Export $roleMembers to local csv file as .\EntraID_RoleMembers_Audit.csv
    $roleMembers | Export-Csv -Path $currentAuditFile -NoTypeInformation -Force
    write-output "Exported role members to '$currentAuditFile'."
 
    # Upload .\EntraID_RoleMembers_Audit.csv file to Azure Storage, overwriting the existing blob
    Set-AzStorageBlobContent -Container $containerName -File $currentAuditFile -Blob $blobName -Context $storageContext -Force
    write-output "Uploaded new CSV file to Azure Storage as '$blobName'."
}
else {
    write-output "Blob does not exist in Azure Storage."
 
    # Export $roleMembers to local csv file as .\EntraID_RoleMembers_Audit.csv
    $roleMembers | Export-Csv -Path $currentAuditFile -NoTypeInformation -Force
    write-output "Exported role members to '$currentAuditFile'."
 
    # Upload .\EntraID_RoleMembers_Audit.csv file to Azure Storage
    Set-AzStorageBlobContent -Container $containerName -File $currentAuditFile -Blob $blobName -Context $storageContext -Force
    write-output "Uploaded new CSV file to Azure Storage as '$blobName'."
}
 
#########################################################################
## STEP 3 : COMPARE CSV FILES
#########################################################################
 
if ((Test-Path -Path $currentAuditFile) -and (Test-Path -Path $previousAuditFile)) {
 
    # Import the result of the current audit
    $currentAudit = Import-Csv -Path $currentAuditFile
 
    # Import the result of the previous audit
    $previousAudit = Import-Csv -Path $previousAuditFile
 
    # Initialize an array to store comparison results
    $comparisonResults = @()
 
    # Compare rows present in the latest file
    foreach ($row in $currentAudit) {
        if ($previousAudit | Where-Object { 
                $_.Entra_ID_Role_Name -eq $row.Entra_ID_Role_Name -and 
                $_.Security_Principal_Type -eq $row.Security_Principal_Type -and 
                $_.Security_Principal_Object -eq $row.Security_Principal_Object -and 
                $_.Security_Principal_Display_Name -eq $row.Security_Principal_Display_Name -and 
                $_.Assignment_Type -eq $row.Assignment_Type 
            }) {
            # Row exists in both files
            $comparisonResults += $row | Add-Member -MemberType NoteProperty -Name "Comparaison_status" -Value "NO CHANGE" -PassThru
        }
        else {
            # Row exists only in the latest file
            $comparisonResults += $row | Add-Member -MemberType NoteProperty -Name "Comparaison_status" -Value "ADDED" -PassThru
        }
    }
 
    # Compare rows present in the compare file but not in the latest file
    foreach ($row in $previousAudit) {
        if (-not ($currentAudit | Where-Object { 
                    $_.Entra_ID_Role_Name -eq $row.Entra_ID_Role_Name -and 
                    $_.Security_Principal_Type -eq $row.Security_Principal_Type -and 
                    $_.Security_Principal_Object -eq $row.Security_Principal_Object -and 
                    $_.Security_Principal_Display_Name -eq $row.Security_Principal_Display_Name -and 
                    $_.Assignment_Type -eq $row.Assignment_Type 
                })) {
            # Row exists only in the compare file
            $comparisonResults += $row | Add-Member -MemberType NoteProperty -Name "Comparaison_status" -Value "REMOVED" -PassThru
        }
    }

    # sort comparaison results based on collumn Entra_Id_Role_Name
    $comparisonResults = $comparisonResults | Sort-Object -Property 'Entra_ID_Role_Name'
 
    #########################################################################
    ## STEP 4 : STORE COMPARAISON INTO HTML REPORT
    #########################################################################
 
    $HtmlBody = "<h2>Weekly Entra ID role membership review</h2><table border='1'><tr><th>Entra ID Role Name</th><th>Security Principal Type</th>"
    $HtmlBody += "<th>Security Principal Object ID</th><th>Security Principal Display Name</th><th>Assignment type</th><th>Scope assignation type</th><th>Scope assignation name</th><th>Weekly Comparaison</th></tr>"
    foreach ($entry in $comparisonResults) {
        switch ($entry.Comparaison_status) {
            'ADDED' {
                $color = "red"
            }
            'REMOVED' {
                $color = "orange"
            }
            default {
                $color = "white"
            }
        }
 
        $HtmlBody += "<tr style='color: black'>"
        $HtmlBody += "<td>$($entry.Entra_ID_Role_Name)</td>"
        $HtmlBody += "<td>$($entry.Security_Principal_Type)</td>"
        $HtmlBody += "<td>$($entry.Security_Principal_Object)</td>"
        $HtmlBody += "<td>$($entry.Security_Principal_Display_Name)</td>"
        $HtmlBody += "<td>$($entry.Assignment_Type)</td>"
        $HtmlBody += "<td>$($entry.Scope_Type)</td>"
        $HtmlBody += "<td>$($entry.Scope_Name)</td>"
        $HtmlBody += "<td style='background-color: $color'>$($entry.Comparaison_status)</td>"
        $HtmlBody += "</tr>"
    }
    $HtmlBody += "</table>"
 
    Out-File -FilePath $htmlOutputFile -InputObject $HtmlBody
 
    write-output "Comparison completed. Results saved to '$htmlOutputFile'."
}
else {
    write-output "Comparison is not possible as one or both files are missing."
}

# SEND EMAIL VIA MICROSOFT GRAPH WITH ATTACHMENT

<#
$HtmlAttachmentContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($htmlOutputFile))

$Attachment = @{
    "@odata.type" = "#microsoft.graph.fileAttachment"
    Name          = [System.IO.Path]::GetFileName($htmlOutputFile)
    ContentType   = "text/html"
    ContentBytes  = $HtmlAttachmentContent
}

$MailBody = @{ 
    Message         = @{ 
        Subject      = $Subject 
        Body         = @{ 
            ContentType = "HTML"
            Content     = $HtmlBody
        }
        ToRecipients = @(@{
                EmailAddress = @{ Address = $ToEmail }
            })
        Attachments = @($Attachment)
    }
    SaveToSentItems = $true 
}
#>

# SEND EMAIL VIA MICROSOFT GRAPH WITHOUT ATTACHMENT
 
$MailBody = @{ 
    Message         = @{ 
        Subject      = $Subject 
        Body         = @{ 
            ContentType = "HTML"
            Content     = $HtmlBody
        }
        ToRecipients = @(@{
                EmailAddress = @{ Address = $ToEmail }
            })
    }
    SaveToSentItems = $true 
} 


$MailJson = $MailBody | ConvertTo-Json -Depth 10
$MailBytes = [System.Text.Encoding]::UTF8.GetBytes($MailJson)
 
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/users/$FromEmail/sendMail" -ContentType "application/json" -Body $MailBytes
 
