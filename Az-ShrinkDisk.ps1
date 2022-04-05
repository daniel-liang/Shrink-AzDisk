# Variables
$DiskID = "" # eg. "/subscriptions/203bdbf0-69bd-1a12-a894-a826cf0a34c8/resourcegroups/rg-server1-prod-1/providers/Microsoft.Compute/disks/Server1-Server1"
$VMName = " " # Name of Source VM
$DiskSizeGB = 1024 # The disk size will be shrinked to
$AzSubscription = " " # Azure Subscription Name
$storageAccountName = " " # Storage account name used for temp storage, Premium_LRS is recommended for shorten run time.
$storageContainerName = " " # Storage Account container name
$sargname = " " # Storage Account Resource Group name


# Script
# Provide your Azure admin credentials
Connect-AzAccount

#Provide the subscription Id of the subscription where snapshot is created
Select-AzSubscription -Subscription $AzSubscription

#Retrive the context for the storage account which will be used to copy snapshot to the storage account 
$StorageAccount = Get-AzStorageAccount -ResourceGroupName $sargname -Name $storageAccountName
$destinationContext = $StorageAccount.Context
$container = Get-AzStorageContainer -Name $storageContainerName -Context $destinationContext

# VM to resize disk of
$VM = Get-AzVm | ? Name -eq $VMName
$VM | Stop-AzVM -Force

#Provide the name of your resource group where snapshot is created
$resourceGroupName = $VM.ResourceGroupName

# Get Disk from ID
$Disk = Get-AzDisk | ? Id -eq $DiskID

# Get VM/Disk generation from Disk
$HyperVGen = $Disk.HyperVGeneration

# Get Disk Details from Source Disk
$DiskName = $Disk.Name
$originalLUN = ($VM.StorageProfile.DataDisks | ? Name -eq $DiskName).Lun
$originalCaching = ($VM.StorageProfile.DataDisks | ? Name -eq $DiskName).Caching

#Check for exisiting disks LUN
$VMdiskCapacity = ($VM.StorageProfile.DataDisks).Capacity
$existinglun = @()
$i=0
$j=0
for($i = 0; $i -lt $VMdiskCapacity; $i++) {
    $existinglun += ($VM.StorageProfile.DataDisks)[$i].Lun
}

if ($existinglun -eq $VMdiskCapacity) {

Write-Host "VM disk capacity reach out the limit of total disk count!" -ForegroundColor Red  -BackgroundColor White
Write-Host "Please resize VM, and re-run" -ForegroundColor Red  -BackgroundColor White

break
}

#Calculate next available LUN index
for ($j = 0; $j -lt $VMdiskCapacity; $j++) {
    if ( $null -eq $existinglun[$j] ) {
        $nextLunIndex
        for ($k = 0; $k -lt $VMdiskCapacity; $k++ ) {
            $nextLunIndex = $k
            for ( $m = 0; $m -lt $VMdiskCapacity; $m++ ) {
                if ( $k -eq $existinglun[$m] ) {
                    $nextLunIndex = -1 
                    break 
                }
            }
            if ($nextLunIndex -ne -1 ) {
                break
            }
        }
        $existinglun[$j] = $nextLunIndex
        break
    } 
}

# Get SAS URI for the Source disk
$SAS = Grant-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $DiskName -Access 'Read' -DurationInSecond 600000;

#Provide the name of the VHD file to which snapshot will be copied.
$destinationVHDFileName = "$($Disk.Name).vhd"

#Copy the snapshot to the storage account and wait for it to complete
Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $storageContainerName -DestBlob $destinationVHDFileName -DestContext $destinationContext
while(($state = Get-AzStorageBlobCopyState -Context $destinationContext -Blob $destinationVHDFileName -Container $storageContainerName).Status -ne "Success") { $state; Start-Sleep -Seconds 20 }
$state

# Revoke SAS token
Revoke-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $DiskName

# Create and attach emtpy disk to get footer from
$emptydiskforfootername = "$($Disk.Name)-empty.vhd"

$diskConfig = New-AzDiskConfig `
    -Location $VM.Location `
    -CreateOption Empty `
    -DiskSizeGB $DiskSizeGB `
    -HyperVGeneration $HyperVGen

$dataDisk = New-AzDisk `
    -ResourceGroupName $resourceGroupName `
    -DiskName $emptydiskforfootername `
    -Disk $diskConfig

$VM = Add-AzVMDataDisk `
    -VM $VM `
    -Name $emptydiskforfootername `
    -CreateOption Attach `
    -ManagedDiskId $dataDisk.Id `
    -Lun $nextLunIndex

Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

# Get SAS token for the empty disk
$SAS = Grant-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfootername -Access 'Read' -DurationInSecond 600000;

# Copy the empty disk to blob storage
Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $storageContainerName -DestBlob $emptydiskforfootername -DestContext $destinationContext
while(($state = Get-AzStorageBlobCopyState -Context $destinationContext -Blob $emptydiskforfootername -Container $storageContainerName).Status -ne "Success") { $state; Start-Sleep -Seconds 20 }
$state

# Revoke SAS token
Revoke-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfootername

# Remove temp empty disk
Remove-AzVMDataDisk -VM $VM -DataDiskNames $emptydiskforfootername
Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

# Delete temp disk
Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfootername -Force;

# Get the blobs
$emptyDiskblob = Get-AzStorageBlob -Context $destinationContext -Container $storageContainerName -Blob $emptydiskforfootername
$Shrinkeddisk = Get-AzStorageBlob -Context $destinationContext -Container $storageContainerName -Blob $destinationVHDFileName

$footer = New-Object -TypeName byte[] -ArgumentList 512
write-output "Get footer of empty disk"

$downloaded = $emptyDiskblob.ICloudBlob.DownloadRangeToByteArray($footer, 0, $emptyDiskblob.Length - 512, 512)
$Shrinkeddisk.ICloudBlob.Resize($emptyDiskblob.Length)
$footerStream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (,$footer)
write-output "Write footer of empty disk to ShrinkedDisk"

$Shrinkeddisk.ICloudBlob.WritePages($footerStream, $emptyDiskblob.Length - 512)
Write-Output -InputObject "Removing empty disk blobs"

$emptyDiskblob | Remove-AzStorageBlob -Force

#Provide the name of the Managed Disk
$NewDiskName = "$DiskName" + "-new"

#Create the new disk with the same SKU as the current one
$accountType = $Disk.Sku.Name

# Get the new disk URI
$vhdUri = $Shrinkeddisk.ICloudBlob.Uri.AbsoluteUri


# Specify the disk options
$diskConfig = New-AzDiskConfig -AccountType $accountType -Location $VM.location -DiskSizeGB $DiskSizeGB -SourceUri $vhdUri -CreateOption Import -StorageAccountId $StorageAccount.Id -HyperVGeneration $HyperVGen

# Handle Trusted Launch VMs/Disks
If($Disk.SecurityProfile.SecurityType -eq "TrustedLaunch"){
    $diskconfig = Set-AzDiskSecurityProfile -Disk $diskconfig -SecurityType "TrustedLaunch"
}

#Create Managed disk
$NewManagedDisk = New-AzDisk -DiskName $NewDiskName -Disk $diskConfig -ResourceGroupName $resourceGroupName

# Set the VM configuration to point to the new disk
$VM = Get-AzVm | ? Name -eq $VMName

Remove-AzVMDataDisk -VM $VM -DataDiskNames $DiskName
Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

$VM = Add-AzVMDataDisk `
    -VM $VM `
    -Name $NewManagedDisk.Name`
    -CreateOption Attach `
    -ManagedDiskId $NewManagedDisk.Id `
    -Lun $originalLUN `
    -Caching $originalCaching

Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

$VM | Start-AzVM

Start-Sleep 180


# Please check the VM is running before proceeding with the below tidy-up steps

# Delete old blob storage
#$Shrinkeddisk | Remove-AzStorageBlob -Force

# Delete temp storage account
#$StorageAccount | Remove-AzStorageAccount -Force

# Delete old Managed Disk
#Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $DiskName -Force;

