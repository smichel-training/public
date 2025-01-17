# Get all subscriptions
$subscriptions = az account list | ConvertFrom-Json

# Array to store all assignments
$allAssignments = @()

foreach ($sub in $subscriptions) {
    Write-Host "Getting assignments for subscription: $($sub.name)" -ForegroundColor Cyan
    
    # Set subscription context
    az account set --subscription $sub.id

    # Get all role assignments including inherited ones at subscription level
    try {
        $assignments = az role assignment list --all --include-inherited | ConvertFrom-Json
        if ($assignments) {
            $allAssignments += $assignments | Select-Object @{
                Name='SubscriptionName';Expression={$sub.name}
            }, scope, principalName, roleDefinitionName, principalType
        }
    }
    catch {
        Write-Warning "Error getting assignments for subscription: $($sub.name)"
        Write-Warning $_.Exception.Message
    }
}

# Export results to CSV
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$exportPath = ".\AzureRoleAssignments_$timestamp.csv"
$allAssignments | Export-Csv -Path $exportPath -NoTypeInformation

Write-Host "Export completed to: $exportPath" -ForegroundColor Green
