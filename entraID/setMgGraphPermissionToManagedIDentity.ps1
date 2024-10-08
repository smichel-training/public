# Parameters
# Managed Identity for Azure Automation account
$MSIName = "MI-NAME" 

# Attempt to connect to Microsoft Graph

try {
    # Check if there is an active Microsoft Graph session
    $currentMgGraphSession = Get-MgContext -ErrorAction Stop
}
catch {
    # Inform the user that there is no active Azure session
    Write-Host "No active Azure Session"
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.Exception.ItemName -ForegroundColor Red
}

$keepMSGraphSession = $null

if ($currentMgGraphSession) {
    # Display current session context details to the user
    Write-Host "You are connected to Microsoft Graph with the following session context"
    Write-Host "User Account: " $currentMgGraphSession.Account
    Write-Host "Your MS Graph API scopes are"
    Write-Host $currentMgGraphSession.Scopes
    
    # Prompt the user to decide whether to keep the current session
    while ($keepMSGraphSession -notin "y", "n") {
        $keepMSGraphSession = Read-Host "Do you want to keep current MS Graph session (y/n)"
    }
}
else {
    # Default choice if no active session is found
    $keepMSGraphSession = "n"
}

if ($keepMSGraphSession -eq "n") {
    # Disconnect from the current MS Graph session if any
    Write-Host "Cleaning current MS Graph session"
    try {
        Disconnect-MgGraph -ErrorAction Stop
    }
    catch {
        # Inform the user if there was no active session to disconnect from
        Write-Host "No active MS Graph session"
        Write-Host $_.Exception.Message -ForegroundColor Red
    }

    # Attempt to establish a new connection with specified scopes
    try {
        Connect-MgGraph -Scopes "User.Read.All", "Application.Read.All", "AppRoleAssignment.ReadWrite.All" -DeviceAuth -ErrorAction Stop
    }
    catch {
        # Handle connection errors and prompt the user to try again
        Write-Host "ERROR during connection - Try again"
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host $_.Exception.ItemName -ForegroundColor Red
    }
}

# Retrieve the service principal for Microsoft Graph using its AppId
# Usefull AppId 
# Microsoft Graph : 00000003-0000-0000-c000-000000000000
# Office 365 Exchange Online : 00000002-0000-0ff1-ce00-000000000000
$MSGraphSP = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

# Retrieve information about the specified Managed Identity (MI)
$MSI = Get-MgServicePrincipal -Filter "DisplayName eq '$MSIName'" 
if ($MSI.Count -gt 1) { 
    # Warn if multiple principals are found and advise on how to proceed
    Write-Output "More than 1 principal found with that name, please find your principal and copy its object ID. Replace the above line with the syntax $MSI = Get-MgServicePrincipal -ServicePrincipalId <your_object_id>"
    Exit
}

# Define required permissions for Microsoft Graph

$Permissions = @(
    "Application.Read.All"
    "Mail.Send"
)

# Identify app roles within Microsoft Graph that match required permissions
$MSGraphAppRoles = $MSGraphSP.AppRoles | Where-Object { ($_.Value -in $Permissions) }

# Assign the managed identity app roles for each required permission
foreach ($AppRole in $MSGraphAppRoles) {
    $AppRoleAssignment = @{
        principalId = $MSI.Id       # ID of the managed identity principal
        resourceId  = $MSGraphSP.Id # ID of the Microsoft Graph service principal
        appRoleId   = $AppRole.Id   # ID of the app role being assigned
    }

    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $AppRoleAssignment.PrincipalId `
        -BodyParameter $AppRoleAssignment -Verbose
}
