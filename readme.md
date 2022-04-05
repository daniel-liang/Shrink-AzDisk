# Shrink Azure VM Data Disk

Microsoft Azure does not support to reduce/shrink the disk (managed or unmanaged) size of an Azure VM. For cost saving (and performance) reasons you may want to reduce the size of the Disk that are already assigned to a running VM - **if there is sufficient space within the volume** to first shrink the volume within the OS.

The technique used to the reduce the disk in this post is creating a new Disk and change the footer.

The Powershell Script will:
*  Create a new temp disk in the Storage Account to read the footer from
*  Copy the Source  Disk into the temp Storage Account
*  Change the footer (size) so the disk shrinks
*  Convert the disk back to a new Managed Disk
*  Detach original data disk
*  Attach shrinked disk
*  Power up souce VM
*  Tidy/Delete the temp storage account

**Original Disk will be detached, avialablty for rollback.**


## Prerequisites

* Powershell version 7.0
* Az PowerShell module 
* VM Contributor and Storage Account Contributor
* Disk/Volume/Partition is shrinked within OS
* Storage account and container as temp storage
* Source VM can attach at least one more disk

## How to Use

1. Create tempolary Storage Account
   
   *Sample script*
```
$storageAccountName = "shrinktempstore"
$storageContainerName = $storageAccountName
$sargname = "shrinkrg"
$saLocation = "australiaeast"

$StorageAccount = Set-AzStorageAccount -ResourceGroupName $sargname -Name $storageAccountName -SkuName Premium_LRS -Location $saLocation
$destinationContext = $StorageAccount.Context
$container = New-AzStorageContainer -Name $storageContainerName -Permission Off -Context $destinationContext

```

2. Shrink volume size inside OS, shut down source VM
    
3. Run scirpt 


