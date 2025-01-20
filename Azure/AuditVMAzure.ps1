# Output file with timestamp
$outputFile = "vm_audit_$(Get-Date -Format 'yyyyMMdd').csv"

# Create array to store VM information
$vmData = @()

# Get all subscriptions
$subscriptions = Get-AzSubscription

foreach ($sub in $subscriptions) {
    # Set subscription context
    Set-AzContext -Subscription $sub.Id | Out-Null
    Write-Host "Processing subscription: $($sub.Name)"
    
    # Get all VMs in subscription
    $vms = Get-AzVM -Status
    
    foreach ($vm in $vms) {
        # Get Network Interface details
        $nic = Get-AzNetworkInterface | Where-Object { $_.VirtualMachine.Id -eq $vm.Id }
        
        if ($nic) {
            # Get VNET and Subnet info
            $subnet = $nic.IpConfigurations[0].Subnet
            $vnetName = ($subnet.Id -split '/')[-3]
            $subnetName = ($subnet.Id -split '/')[-1]
            
            # Get Public IP if exists
            $publicIP = "None"
            if ($nic.IpConfigurations[0].PublicIpAddress) {
                $pipObject = Get-AzPublicIpAddress -ResourceGroupName $vm.ResourceGroupName -Name $nic.IpConfigurations[0].PublicIpAddress.Id.Split('/')[-1]
                $publicIP = $pipObject.IpAddress
            }
            
            # Get Private IP
            $privateIP = $nic.IpConfigurations[0].PrivateIpAddress
        }
        else {
            $vnetName = "None"
            $subnetName = "None"
            $publicIP = "None"
            $privateIP = "None"
        }
        
        # Get OS Details
        $osType = $vm.StorageProfile.OsDisk.OsType
        $osVersion = if ($vm.StorageProfile.ImageReference.ExactVersion) {
            $vm.StorageProfile.ImageReference.ExactVersion
        } else {
            "$($vm.StorageProfile.ImageReference.Offer) $($vm.StorageProfile.ImageReference.Sku)"
        }
        
        # Convert Tags to string
        $tagString = if ($vm.Tags) {
            ($vm.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
        } else {
            "None"
        }
        
        # Create custom object with VM details
        $vmInfo = [PSCustomObject]@{
            SubscriptionName = $sub.Name
            ResourceGroup    = $vm.ResourceGroupName
            VMName          = $vm.Name
            Location        = $vm.Location
            SKU            = $vm.HardwareProfile.VmSize
            PublicIP       = $publicIP
            VNET           = $vnetName
            Subnet         = $subnetName
            OSType         = $osType
            OSVersion      = $osVersion
            PowerState     = $vm.PowerState
            PrivateIP      = $privateIP
            Tags           = $tagString
            DataDisks      = ($vm.StorageProfile.DataDisks | Measure-Object).Count
            OSDiskSize     = $vm.StorageProfile.OsDisk.DiskSizeGB
            BootDiagnostics = $vm.DiagnosticsProfile.BootDiagnostics.Enabled
            AvailabilitySet = if ($vm.AvailabilitySetReference) { ($vm.AvailabilitySetReference.Id -split '/')[-1] } else { "None" }
        }
        
        $vmData += $vmInfo
    }
}

# Export to CSV
$vmData | Export-Csv -Path $outputFile -NoTypeInformation

Write-Host "Audit completed. Results saved to $outputFile"
