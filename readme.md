# Shrink Azure VM Data Disk

Microsoft Azure does not support to reduce/shrink the disk (managed or unmanaged) size of an Azure VM. For cost saving (and performance) reasons you may want to reduce the size of the Disk that are already assigned to a running VM - **if there is sufficient space within the volume** to first shrink the volume within the OS.

The technique used to the reduce the disk in this post is 

The Script will:
-- Create a temporary Storage Acccount
-- Create a new temp disk in the new Storage Account to read the footer from
-- Copy the Managed  Disk into the temp Storage Account
-- Change the footer (size) so the disk shrinks
-- Convert the disk back to a Managed Disk
-- Swap the VM’s current Data disk with the new smaller Disk
-- Tidy/Delete the temp storage account and the old managed disk


identical to that of the Microsoft post mentioned above, except that here we use only PowerShell without relying on an opensource tool.


Powershell script for shrink Azure VM data disk. 


Shrinked disk will be re-attached to original VM under the same LUN number. Original Disk will be deattached and avialablty for rollback.

## Prerequisites

Powershell version 7.0

Az PowerShell module 

VM Contributor and Storage Account Contributor





