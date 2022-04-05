# Variables
$DiskID = "/subscriptions/dd6bde2c-4319-4066-a69f-bb45f986e310/resourceGroups/POC-NETWORK-AUE/providers/Microsoft.Compute/disks/datadisk1-new"# eg. "/subscriptions/203bdbf0-69bd-1a12-a894-a826cf0a34c8/resourcegroups/rg-server1-prod-1/providers/Microsoft.Compute/disks/Server1-Server1"
$VMName = "TESTSQL"
$DiskSizeGB = 1024
$AzSubscription = "Visual Studio Enterprise Subscription"



# Script
# Provide your Azure admin credentials
Connect-AzAccount

#Provide the subscription Id of the subscription where snapshot is created
Select-AzSubscription -Subscription $AzSubscription

# VM to resize disk of
$VM = Get-AzVm | ? Name -eq $VMName

$VM | Stop-AzVM -Force


#Provide the name of your resource group where snapshot is created
$resourceGroupName = $VM.ResourceGroupName

# Get Disk from ID
$Disk = Get-AzDisk | ? Id -eq $DiskID

# Get VM/Disk generation from Disk
$HyperVGen = $Disk.HyperVGeneration

# Get Disk Name from Disk
$DiskName = $Disk.Name
$originalLUN = ($VM.StorageProfile.DataDisks | ? Name -eq $DiskName).Lun
$originalCaching = ($VM.StorageProfile.DataDisks | ? Name -eq $DiskName).Caching


#check for exisiting disks
$VMdiskCapacity = ($VM.StorageProfile.DataDisks).Capacity
$existinglun = @()
$i= 0
$j = 0
for($i = 0; $i -lt $VMdiskCapacity; $i++) {
    $existinglun += ($VM.StorageProfile.DataDisks)[$i].Lun
}

#calculate next available LUN index
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
        #Add-AzVMDataDisk -VM $vm -Name $DiskName -CreateOption Attach -ManagedDiskId $DataDisk.Id -Lun $nextLunIndex
        $existinglun[$j] = $nextLunIndex
        break
    } 
}



# Get SAS URI for the Managed disk
$SAS = Grant-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $DiskName -Access 'Read' -DurationInSecond 600000;

#Provide storage account name where you want to copy the snapshot - the script will create a new one temporarily
$storageAccountName = "shrink" + [system.guid]::NewGuid().tostring().replace('-','').substring(1,18)

#Name of the storage container where the downloaded snapshot will be stored
$storageContainerName = $storageAccountName

#Provide the name of the VHD file to which snapshot will be copied.
#$destinationVHDFileName = "$($VM.StorageProfile.OsDisk.Name).vhd"
$destinationVHDFileName = "$($Disk.Name).vhd"


#Create the context for the storage account which will be used to copy snapshot to the storage account 
$StorageAccount = New-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName -SkuName Standard_LRS -Location $VM.Location
$destinationContext = $StorageAccount.Context
$container = New-AzStorageContainer -Name $storageContainerName -Permission Off -Context $destinationContext

#Copy the snapshot to the storage account and wait for it to complete
Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $storageContainerName -DestBlob $destinationVHDFileName -DestContext $destinationContext
while(($state = Get-AzStorageBlobCopyState -Context $destinationContext -Blob $destinationVHDFileName -Container $storageContainerName).Status -ne "Success") { $state; Start-Sleep -Seconds 20 }
$state

# Revoke SAS token
Revoke-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $DiskName

# Emtpy disk to get footer from
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

#$VM | Stop-AzVM -Force


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
#$osdisk = Get-AzStorageBlob -Context $destinationContext -Container $storageContainerName -Blob $destinationVHDFileName
$Shrinkeddisk = Get-AzStorageBlob -Context $destinationContext -Container $storageContainerName -Blob $destinationVHDFileName


$footer = New-Object -TypeName byte[] -ArgumentList 512
write-output "Get footer of empty disk"

$downloaded = $emptyDiskblob.ICloudBlob.DownloadRangeToByteArray($footer, 0, $emptyDiskblob.Length - 512, 512)

#$osDisk.ICloudBlob.Resize($emptyDiskblob.Length)
$Shrinkeddisk.ICloudBlob.Resize($emptyDiskblob.Length)

$footerStream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (,$footer)
write-output "Write footer of empty disk to ShrinkedDisk"
#$osDisk.ICloudBlob.WritePages($footerStream, $emptyDiskblob.Length - 512)
$Shrinkeddisk.ICloudBlob.WritePages($footerStream, $emptyDiskblob.Length - 512)


Write-Output -InputObject "Removing empty disk blobs"
$emptyDiskblob | Remove-AzStorageBlob -Force


#Provide the name of the Managed Disk
$NewDiskName = "$DiskName" + "-new"

#Create the new disk with the same SKU as the current one
$accountType = $Disk.Sku.Name

# Get the new disk URI
#$vhdUri = $osdisk.ICloudBlob.Uri.AbsoluteUri
$vhdUri = $Shrinkeddisk.ICloudBlob.Uri.AbsoluteUri


# Specify the disk options
$diskConfig = New-AzDiskConfig -AccountType $accountType -Location $VM.location -DiskSizeGB $DiskSizeGB -SourceUri $vhdUri -CreateOption Import -StorageAccountId $StorageAccount.Id -HyperVGeneration $HyperVGen

# Handle Trusted Launch VMs/Disks
If($Disk.SecurityProfile.SecurityType -eq "TrustedLaunch"){
    $diskconfig = Set-AzDiskSecurityProfile -Disk $diskconfig -SecurityType "TrustedLaunch"
}

#Create Managed disk
$NewManagedDisk = New-AzDisk -DiskName $NewDiskName -Disk $diskConfig -ResourceGroupName $resourceGroupName

#$VM | Stop-AzVM -Force

# Set the VM configuration to point to the new disk
$VM = Get-AzVm | ? Name -eq $VMName

Remove-AzVMDataDisk -VM $VM -DataDiskNames $DiskName
Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

#Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM
$VM = Add-AzVMDataDisk `
    -VM $VM `
    -Name $NewManagedDisk.Name`
    -CreateOption Attach `
    -ManagedDiskId $NewManagedDisk.Id `
    -Lun $originalLUN `
    -Caching $originalCaching

Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM


#--ManagedDiskId $NewManagedDisk.Id -Name $NewManagedDisk.Name

# Update the VM with the new OS disk


$VM | Start-AzVM

get-date

start-sleep 180
# Please check the VM is running before proceeding with the below tidy-up steps

# Delete old Managed Disk
#Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $DiskName -Force;

# Delete old blob storage
#$osdisk | Remove-AzStorageBlob -Force
$Shrinkeddisk | Remove-AzStorageBlob -Force

# Delete temp storage account
$StorageAccount | Remove-AzStorageAccount -Force

