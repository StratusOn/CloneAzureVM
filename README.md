# CloneAzureVM
A PowerShell script to help clone an Azure VM that uses managed disks.

## Current Features
* DOES support cloning all the NIC's associated with a source VM.
* DOES support cloning all the managed disks associated with a source VM.
* DOES support cloning the source VM size.
* DOES create a public IP and associates with the primary NIC of the cloned VM.
* DOES **NOT** support cloning a VM whose disks are based on a standard storage account (*only managed disks!*)
* DOES **NOT** support cloning the IP Configurations of a NIC.
* DOES **NOT** support encrypted disks.
* DOES **NOT** support creating a new VNet or associating with a specific subnet or creating a new one in the VNet.
* DOES **NOT** support classic Azure VMs.

## Revision History
* v0.5.0 - June 1st, 2017

  * Initial version.
