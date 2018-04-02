#Requires -Version 5.0
#Requires -Module AzureRM.Resources
#Requires -Module AzureRM.Compute
#Requires -Module AzureRM.Network

[CmdletBinding()]
Param(
    # REQUIRED input:
    [string]$sourceResourceGroupName = 'My-RG',
    [string]$sourceVmName = 'MyWindowsVM', # VM to be cloned.
    [string]$vnetName = 'MyVNet', # Existing VNet name. Make sure it's in the same region as destination RG.
    [string]$vnetResourceGroupName = '', # Leave empty if same as sourceResourceGroupName.

    # OPTIONAL input:
    [bool]$keepSourceComputerNameInOsProfile = $false, # Default is $false. Set to $true to keep the computer name the same as the source. The default is to specify a new name (up to 15 characters long).
    [bool]$setAcceleratedNetworking = $false, # Default is $false. Set to $true to force accelerated networking to be set on the cloned NIC(s). If accelerated networking is already configured on the source NIC, then it will be created on the target regardless of this setting.
    [bool]$useExistingAvailabilitySet = $true, # Default is $true. Set to $false to have a new availability set created for the cloned VM. Default is to add the cloned VM to the same availability set as the original VM if the destination RG is same as source or add it to the $existingAvailabilitySetName if destination RG is different and $existingAvailabilitySetName is specified, otherwise create a new availability set in destination RG.
    [bool]$copyTags = $false, # Default is $false. Set to $true to have resource tags copied over to the cloned resource.
    [string]$existingAvailabilitySetName = '', # Relevant only when $useExistingAvailabilitySet is $true. Leave empty to use the source availability set if the destination RG is the same as source RG. Set to an existing availability set's name to add the cloned VM to.
    [string]$sourceVmOsDiskSnapshotName = '', # Optional. If specified, it must be in sourceVmSnapshotResourceGroup. If left empty, a snapshot will be created for every disk. Example: 'snapshot-os-1039651728'.
    [string]$sourceVmDataDiskSnapshotName = '', # Optional. If specified, it must be in sourceVmSnapshotResourceGroup. Specify with sourceVmOsDiskSnapshotName. Example: 'snapshot-data0-1039651728'.
    [string]$sourceVmSnapshotResourceGroup = '', # Optional. If specified, it must be an existing resource group. If left empty, sourceResourceGroupName is used.
    [string]$destinationResourceGroupName = '', # Optional. If specified and non-exiting, it will be created in the same region as the source RG. If left empty, sourceResourceGroupName is used.
    [string]$destinationVmName = '' # Optional. Leave empty to assign a unique name.
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$error.Clear()

# Step 1: Get the source resource group.
$sourceResourceGroup = Get-AzureRmResourceGroup -Name $sourceResourceGroupName -ErrorAction SilentlyContinue
if ($sourceResourceGroup -eq $null)
{
    Write-Host "Error: Resource group '$sourceResourceGroupName' not found: $error" -ForegroundColor Red
    exit 1
}
$sourceResourceGroupName = $sourceResourceGroup.ResourceGroupName

# Step 2: Get destination resource group.
if($destinationResourceGroupName -eq $null -or $destinationResourceGroupName -eq '')
{
    $destinationResourceGroup = $sourceResourceGroup
}
else
{
    $destinationResourceGroup = Get-AzureRmResourceGroup -Name $destinationResourceGroupName -ErrorAction SilentlyContinue
    if ($destinationResourceGroup -eq $null)
    {
        Write-Host "Warning: Resource group '$destinationResourceGroupName' not found. It will be created: $error" -ForegroundColor Yellow
        Write-Host "Creating resource group '$destinationResourceGroupName'..."
        $destinationResourceGroup = New-AzureRmResourceGroup -Name $destinationResourceGroupName -Location $sourceResourceGroup.Location -Verbose -Force -ErrorAction SilentlyContinue
        if ($destinationResourceGroup -eq $null -or $destinationResourceGroup -eq '')
        {
            Write-Host "Error: Failed to created resource group '$destinationResourceGroupName': $error" -ForegroundColor Red
            exit 1
        }
    }
}
$destinationResourceGroupName = $destinationResourceGroup.ResourceGroupName

# Step 3: Get source VM to be cloned.
$sourceVm = Get-AzureRmVM -ResourceGroupName $sourceResourceGroupName -Name $sourceVmName -ErrorAction SilentlyContinue
if ($sourceVm -eq $null)
{
    Write-Host "Error: VM '$sourceVmName' not found in Resource Group '$destinationResourceGroupName': $error" -ForegroundColor Red
    exit 1
}

# Step 4: Get the VNet.
if ($vnetResourceGroupName -eq $null -or $vnetResourceGroupName -eq '')
{
    $vnetResourceGroupName = $sourceResourceGroupName
}

$vnet = Get-AzureRmVirtualNetwork -Name $vnetName -ResourceGroupName $vnetResourceGroupName -ErrorAction SilentlyContinue
if ($vnet -eq $null)
{
    Write-Host "Error: VNet '$vnetName' not found in Resource Group '$vnetResourceGroupName'." -ForegroundColor Red
    exit 1
}

# Location where cloned resources will be created.
$destinationLocation = $destinationResourceGroup.Location
Write-Host "Destination resource group: '$destinationResourceGroupName'. Location: '$destinationLocation'."

# Random number suffix used in unique resource naming.
$randomNumber = Get-Random -Minimum 100000000 -Maximum 999999999

# Step 5: Get existing snapshot or create snapshots now.
$snapshots = @()
if ($sourceVmOsDiskSnapshotName -eq $null -or $sourceVmOsDiskSnapshotName -eq '')
{
    # Compare the destination RG's region to the region of the source VM (which is also the region on the source VM's disks).
    # They must be the same for creating a snapshot in the destination RG.
    if ($destinationLocation -ne $sourceVm.Location)
    {
        $snapshotLocation = $sourceVm.Location
        Write-Host "Snapshots will be created in '$snapshotLocation' since destination RG '$destinationResourceGroupName' is in a different region ('$destinationLocation')."
    }
    else
    {
        $snapshotLocation = $destinationLocation
        Write-Host "Snapshots will be created in destination RG ($destinationResourceGroupName)."
    }

    # Step 5-a-1: Create a snapshot of the OS disk (in the destination Resource Group, in case you have limited IAM in source).
    $osDiskName = $sourceVm.StorageProfile.OsDisk.Name
    Write-Host "OS Disk found: $osDiskName"
    $sourceVmOsDiskSnapshotName = "snapshot-os-$randomNumber"  
    Write-Host "Creating snapshot '$sourceVmOsDiskSnapshotName' in '$destinationResourceGroupName'..."

    $snapshotConfig = New-AzureRmSnapshotConfig -Location $snapshotLocation -AccountType StandardLRS -OsType $sourceVm.StorageProfile.OsDisk.OsType -CreateOption Copy -EncryptionSettingsEnabled $false -SourceResourceId $sourceVm.StorageProfile.OsDisk.ManagedDisk.Id -ErrorAction SilentlyContinue
    if ($snapshotConfig -eq $null)
    {
        Write-Host "Error: Cannot create OS disk snapshot config '$sourceVmOsDiskSnapshotName' in Resource Group '$destinationResourceGroupName'. $error" -ForegroundColor Red
        exit 1
    }

    $snapshot = New-AzureRmSnapshot -SnapshotName $sourceVmOsDiskSnapshotName -ResourceGroupName $destinationResourceGroupName -Snapshot $snapshotConfig -ErrorAction SilentlyContinue
    if ($snapshot -eq $null)
    {
        Write-Host "Error: Cannot create OS disk snapshot '$sourceVmOsDiskSnapshotName' in Resource Group '$destinationResourceGroupName'. $error" -ForegroundColor Red
        exit 1
    }

    Write-Output 'Snapshot created: ', $snapshot
    $snapshotName = $snapshot.Name
    Write-Host "Snapshot successfully created for OS disk: $snapshotName"
    
    $snapshots += $snapshot

    # Step 5-a-2: For each data disk in the source VM, create a snapshot.
    foreach($disk in $sourceVm.StorageProfile.DataDisks)
    {
        $lun = $disk.Lun
        $diskName = $disk.Name
        Write-Host "Data Disk found (lun $lun): $diskName"
        $sourceVmDataDiskSnapshotName = "snapshot-data$lun-$randomNumber"
        Write-Host "Creating snapshot '$sourceVmDataDiskSnapshotName' in '$destinationResourceGroupName'..."

        $snapshotConfig = New-AzureRmSnapshotConfig -Location $snapshotLocation -AccountType StandardLRS -CreateOption Copy -EncryptionSettingsEnabled $false -SourceResourceId $disk.ManagedDisk.Id -ErrorAction SilentlyContinue
        $snapshot = New-AzureRmSnapshot -SnapshotName $sourceVmDataDiskSnapshotName -ResourceGroupName $destinationResourceGroupName -Snapshot $snapshotConfig -ErrorAction SilentlyContinue
        if ($snapshot -eq $null)
        {
            Write-Host "Error: Cannot create data disk snapshot '$sourceVmDataDiskSnapshotName' in Resource Group '$destinationResourceGroupName'. $error" -ForegroundColor Red
            exit 1
        }

        Write-Output 'Snapshot created: ', $snapshot
        $snapshotName = $snapshot.Name
        Write-Host "Snapshot successfully created for data disk: $snapshotName"

        $snapshots += $snapshot
    }
}
else
{
    if ($sourceVmSnapshotResourceGroup -eq $null -or $sourceVmSnapshotResourceGroup -eq '')
    {
        $sourceVmSnapshotResourceGroup = $sourceResourceGroupName
    }

    # Step 5-b-1: Get the existing snapshot of the source VM's OS disk.
    $snapshot = Get-AzureRmSnapshot -SnapshotName $sourceVmOsDiskSnapshotName -ResourceGroupName $sourceVmSnapshotResourceGroup -ErrorAction SilentlyContinue
    if ($snapshot -eq $null)
    {
        Write-Host "Error: OS disk snapshot '$sourceVmOsDiskSnapshotName' not found in Resource Group '$sourceVmSnapshotResourceGroup'." -ForegroundColor Red
        exit 1
    }

    Write-Host "Snapshot found: $sourceVmOsDiskSnapshotName"
    Write-Output 'Snapshot: ', $snapshot

    $snapshots += $snapshot

    if ($sourceVmDataDiskSnapshotName -ne $null -and $sourceVmDataDiskSnapshotName -ne '')
    {
        # Step 5-b-2: Get the existing snapshot of the source VM's data disk.
        $snapshot = Get-AzureRmSnapshot -SnapshotName $sourceVmDataDiskSnapshotName -ResourceGroupName $sourceVmSnapshotResourceGroup -ErrorAction SilentlyContinue
        if ($snapshot -eq $null)
        {
            Write-Host "Error: Data disk snapshot '$sourceVmDataDiskSnapshotName' not found in Resource Group '$sourceVmSnapshotResourceGroup'." -ForegroundColor Red
            exit 1
        }

        Write-Host "Snapshot found: $sourceVmDataDiskSnapshotName"
        Write-Output 'Snapshot: ', $snapshot

        $snapshots += $snapshot
    }
}

if ($snapshots.Length -eq 0)
{
    Write-Host "Error: No snapshots found or created." -ForegroundColor Red
    exit 1
}

# Step 6: Give the new VM a unique name.
if ($destinationVmName -eq $null -or $destinationVmName -eq '')
{
    $destinationVmName = "$sourceVmName-clone-$randomNumber"
}

# Step 7: Clone the availability set if found, or join an existing one.
$availabilitySetId = ''
if ($sourceVm.AvailabilitySetReference -ne $null)
{
    $createNewAvailabilitySet = $false
    if ($useExistingAvailabilitySet -eq $true)
    {
        if ($destinationResourceGroupName -eq $sourceResourceGroupName)
        {
            $availabilitySetId = $sourceVm.AvailabilitySetReference.Id
        }
        else
        {
            $destinationAvailabilitySet = Get-AzureRmAvailabilitySet -ResourceGroupName $destinationResourceGroupName -Name $existingAvailabilitySetName -ErrorAction SilentlyContinue
            if ($destinationAvailabilitySet -ne $null)
            {
                Write-Host "Found the specified existing availability set '$existingAvailabilitySetName' in '$destinationResourceGroupName'. Assigning VM reference to it."
                $availabilitySetId = $destinationAvailabilitySet.Id
            }
            else
            {
                Write-Host "Warning: Failed to get the specified existing availability set '$existingAvailabilitySetName' in '$destinationResourceGroupName'. A new availability set will be created for the VM with source settings."
                $createNewAvailabilitySet = $true
            }
        }
    }
    else
    {
        $createNewAvailabilitySet = $true
    }

    if ($createNewAvailabilitySet -eq $true)
    {
        # Get existing availability set reference.
        $sourceAvailabilitySetId = $sourceVm.AvailabilitySetReference.Id
        $sourceAvailabilitySet = Get-AzureRmAvailabilitySet -ResourceGroupName $sourceResourceGroupName -ErrorAction SilentlyContinue | Where {$_.Id -eq $sourceAvailabilitySetId}

        # Create a new availability set.
        $availabilitySetName = "avset-clone-$randomNumber"

        if ($sourceAvailabilitySet -eq $null)
        {
            Write-Host "Warning: Failed to get the source availability set whose id is '$sourceAvailabilitySet' in '$sourceResourceGroupName'. A new availability set will be created for the VM with default settings."
            $newAvailabilitySet = New-AzureRmAvailabilitySet -ResourceGroupName $destinationResourceGroupName -Name $availabilitySetName -Location $destinationLocation
        }
        else
        {
            $sourceAvailabilitySetName = $sourceAvailabilitySet.Name
            Write-Host "Found the source availability set '$sourceAvailabilitySetName' whose id is '$sourceAvailabilitySet' in '$sourceResourceGroupName'. Copying setting to new availability set '$availabilitySetName'."
            $newAvailabilitySet = New-AzureRmAvailabilitySet -ResourceGroupName $destinationResourceGroupName -Name $availabilitySetName -Location $destinationLocation -PlatformUpdateDomainCount $sourceAvailabilitySet.PlatformUpdateDomainCount -PlatformFaultDomainCount $sourceAvailabilitySet.PlatformFaultDomainCount -Sku $sourceAvailabilitySet.Sku
            if ($copyTags -eq $true)
            {
                $newAvailabilitySet.Tags = $sourceAvailabilitySet.Tags
                $newAvailabilitySet | Set-AzureRmResource -Force -ErrorAction SilentlyContinue
            }
        }
        $availabilitySetId = $newAvailabilitySet.Id
    }
}

# Step 8: Build the clone's parts.
$clonedVmSize = $sourceVm.HardwareProfile.VmSize
if ($availabilitySetId -eq '')
{
    $clonedVm = New-AzureRmVMConfig -VMName $destinationVmName -VMSize $clonedVmSize -Tags $sourceVm.Tags
}
else
{
    $clonedVm = New-AzureRmVMConfig -VMName $destinationVmName -VMSize $clonedVmSize -AvailabilitySetId $availabilitySetId -Tags $sourceVm.Tags
}

# Step 9: Clone each NIC on the source VM.
[int]$nicIndex = 0
foreach ($nic in $sourceVm.NetworkProfile.NetworkInterfaces)
{
    $clonedNicName = "nic$nicIndex-clone-$randomNumber"
    $enableAcceleratedNetworking = $false
    $enableIPForwarding = $false
    $sourceNicId = $nic.Id
    $sourceNic = Get-AzureRmNetworkInterface -ResourceGroupName $sourceResourceGroupName -ErrorAction SilentlyContinue | Where {$_.Id -eq $sourceNicId}
    if ($sourceNic -eq $null)
    {
        Write-Host "Warning: Failed to get the source NIC whose id is '$sourceNicId' in '$sourceResourceGroupName'."
    }
    else
    {
        $enableAcceleratedNetworking = ($sourceNic.EnableAcceleratedNetworking -eq $true -or $setAcceleratedNetworking -eq $true)
        $enableIPForwarding = $sourceNic.EnableIPForwarding
        
        #TODO: Create an NSG if one exists for the Nics.
        $destinationIpConfigurations = $sourceNic.IpConfigurations

        [int]$ipConfigIndex = 0
        foreach ($ipConfig in $sourceNic.IpConfigurations)
        {
            $ipConfigName = $ipConfig.Name
            $ipConfigId = $ipConfig.Id
            Write-Host "Info: [$ipConfigIndex]: Found IP Configuration. Name: '$ipConfigName'. Id: '$ipConfigId'."
            #$sourceNic.IpConfigurations[$ipConfigIndex]
            
            if ($sourceNic.IpConfigurations[$ipConfigIndex].PublicIpAddress -ne $null)
            {
                $sourcePipId = $sourceNic.IpConfigurations[$ipConfigIndex].PublicIpAddress.Id
                $sourcePublicIpAddress = Get-AzureRmPublicIpAddress -ResourceGroupName $sourceResourceGroupName -ErrorAction SilentlyContinue | Where {$_.Id -eq $sourcePipId}
                if ($sourcePublicIpAddress -ne $null)
                {
                    $sourcePipName = $sourcePublicIpAddress.Name
                    Write-Host "Info: [$ipConfigIndex]: IP Configuration '$ipConfigName' has public ip '$sourcePipName'."
                    $clonedPublicIpName = "pip-$sourcePipName-clone-$randomNumber"
                    Write-Host "Creating public IP '$clonedPublicIpName'..."
                    if ($copyTags -eq $true)
                    {
                        $clonedPublicIp = New-AzureRmPublicIpAddress -Name $clonedPublicIpName -ResourceGroupName $destinationResourceGroupName -Location $destinationLocation -AllocationMethod $sourcePublicIpAddress.PublicIpAllocationMethod -Tag $sourcePublicIpAddress.Tag
                    }
                    else
                    {
                        $clonedPublicIp = New-AzureRmPublicIpAddress -Name $clonedPublicIpName -ResourceGroupName $destinationResourceGroupName -Location $destinationLocation -AllocationMethod $sourcePublicIpAddress.PublicIpAllocationMethod
                    }
                    $destinationIpConfigurations[$ipConfigIndex].PublicIpAddress = $clonedPublicIp
                }
                else
                {
                    Write-Host "Warning: [$ipConfigIndex]: Failed to get the source Public IP whose id is '$sourcePipId' in '$sourceResourceGroupName'. Skipping PIP creation for IP Config '$ipConfigName'."
                }
            }
            $destinationIpConfigurations[$ipConfigIndex].Id = ''
            $destinationIpConfigurations[$ipConfigIndex].Etag = ''
            $ipConfigIndex++
        }
    }

    Write-Host "Creating NIC '$clonedNicName'..."
    $clonedNic = New-AzureRmNetworkInterface -Name $clonedNicName -ResourceGroupName $destinationResourceGroupName -Location $destinationLocation -IpConfiguration $destinationIpConfigurations[0]
    $clonedNic.IpConfigurations = $destinationIpConfigurations
    if ($copyTags -eq $true)
    {
        $clonedNic.Tag = $sourceNic.Tag
    }
    $clonedNic.Primary = $nic.Primary
    $clonedNic.EnableAcceleratedNetworking = $enableAcceleratedNetworking
    $clonedNic.EnableIPForwarding = $enableIPForwarding
    $clonedNic | Set-AzureRmNetworkInterface -ErrorAction SilentlyContinue
    $clonedVm = Add-AzureRmVMNetworkInterface -VM $clonedVm -Id $clonedNic.Id

    #Write-Host "clonedNic.IpConfigurations[0]:"
    #$clonedNic.IpConfigurations[0]
    #Write-Host "clonedNic.IpConfigurations[1]:"
    #$clonedNic.IpConfigurations[1]
}

# Step 10: Create the disk configurations.
$managedDiskAccountType = $sourceVm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
$managedDiskCreateOption = 'Copy'
$vmDiskCreateOption = 'Attach'

if ($snapshots.Length -eq 1)
{
    # Single snapshot of the OS disk.
    $diskName = "osdisk-clone-$randomNumber"
    Write-Host "Creating cloned VM OS disk '$diskName'..."
    $diskConfig = New-AzureRmDiskConfig -AccountType $managedDiskAccountType -Location $destinationLocation -CreateOption $managedDiskCreateOption -SourceResourceId $snapshots[0].Id
    $osDisk = New-AzureRmDisk -DiskName $diskName -Disk $diskConfig -ResourceGroupName $destinationResourceGroupName
    if ($sourceVm.OSProfile.WindowsConfiguration -ne $null)
    {
        Write-Host "Setting Windows OS disk..."
        $clonedVm = Set-AzureRmVMOSDisk -VM $clonedVm -Name $diskName -ManagedDiskId $osDisk.Id -CreateOption $vmDiskCreateOption -Caching $sourceVm.StorageProfile.OsDisk.Caching -Windows
    }
    else
    {
        Write-Host "Setting Linux OS disk..."
        $clonedVm = Set-AzureRmVMOSDisk -VM $clonedVm -Name $diskName -ManagedDiskId $osDisk.Id -CreateOption $vmDiskCreateOption -Caching $sourceVm.StorageProfile.OsDisk.Caching -Linux
    }
}
else
{
    # A snapshot of each disk.
    for($i=0; $i -lt $snapshots.Length; $i++)
    {
        if ($i -eq 0)
        {
            $diskName = "osdisk-clone-$randomNumber"
            Write-Host "Creating cloned VM OS disk '$diskName'..."
            $diskConfig = New-AzureRmDiskConfig -AccountType $managedDiskAccountType -Location $destinationLocation -CreateOption $managedDiskCreateOption -SourceResourceId $snapshots[$i].Id
            $osDisk = New-AzureRmDisk -DiskName $diskName -Disk $diskConfig -ResourceGroupName $destinationResourceGroupName

            if ($sourceVm.OSProfile.WindowsConfiguration -ne $null)
            {
                Write-Host "Setting Windows OS disk..."
                $clonedVm = Set-AzureRmVMOSDisk -VM $clonedVm -Name $diskName -ManagedDiskId $osDisk.Id -CreateOption $vmDiskCreateOption -Caching $sourceVm.StorageProfile.OsDisk.Caching -Windows
            }
            else
            {
                Write-Host "Setting Linux OS disk..."
                $clonedVm = Set-AzureRmVMOSDisk -VM $clonedVm -Name $diskName -ManagedDiskId $osDisk.Id -CreateOption $vmDiskCreateOption -Caching $sourceVm.StorageProfile.OsDisk.Caching -Linux
            }
        }
        else
        {
            $dataDiskIndex = $i-1
            $diskName = "datadisk$dataDiskIndex-clone-$randomNumber"
            Write-Host "Creating cloned VM data disk '$diskName'..."
            $diskConfig = New-AzureRmDiskConfig -AccountType $managedDiskAccountType -Location $destinationLocation -CreateOption $managedDiskCreateOption -SourceResourceId $snapshots[$i].Id
            $dataDisk = New-AzureRmDisk -DiskName $diskName -Disk $diskConfig -ResourceGroupName $destinationResourceGroupName
            $clonedVm = Add-AzureRmVMDataDisk -VM $clonedVm -Name $diskName -ManagedDiskId $dataDisk.Id -CreateOption $vmDiskCreateOption -Caching $sourceVm.StorageProfile.DataDisks[$dataDiskIndex].Caching -Lun $sourceVm.StorageProfile.DataDisks[$dataDiskIndex].Lun
        }
    }
}

# Step 11: Clone the Plan if found.
if ($sourceVm.Plan -ne $null)
{
    $clonedVm.Plan = $sourceVm.Plan
}

# Step 12: Create the VM clone.
Write-Host "Creating cloned VM '$destinationVmName' in '$destinationResourceGroupName'..."
if ($copyTags -eq $true)
{
    New-AzureRmVM -ResourceGroupName $destinationResourceGroupName -Location $destinationLocation -VM $clonedVm -Tag $sourceVm.Tags -Verbose -ErrorVariable CreateVmErrors
}
else
{
    New-AzureRmVM -ResourceGroupName $destinationResourceGroupName -Location $destinationLocation -VM $clonedVm -Verbose -ErrorVariable CreateVmErrors
}

if ($CreateVmErrors)
{
    Write-Host "Failed to create cloned VM '$destinationVmName'." -ForegroundColor Red
    exit 1
}
else
{
    Write-Host "Successfully created cloned VM '$destinationVmName'." -ForegroundColor DarkGreen
}

Write-Host "Done."
exit 0
