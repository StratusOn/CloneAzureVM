# CloneAzureVM
A PowerShell script to help clone an Azure VM that uses managed disks.

## Current Features
* DOES support cloning all the NIC's associated with a source VM (along with their IPConfigs).
* DOES support cloning all the managed disks associated with a source VM.
* DOES support cloning the source VM size.
* DOES create a public IP and associates with the primary NIC of the cloned VM (and creates additional public IPs if specified in the IPConfigs).
* DOES support supplying existing snapshots for an OS disk and up to 1 data disk.
* DOES support optionally copying the resource tags from the source.
* DOES **NOT** support cloning a VM whose disks are based on a standard storage account (*only managed disks!*)
* DOES **NOT** support encrypted disks.
* DOES **NOT** support creating a new VNet or associating with a specific subnet or creating a new one in the VNet.
* DOES **NOT** support classic Azure VMs.
* DOES **NOT** support creating VM from existing snapshots for a VM with more than 1 data disk. In that case, not supplying snapshot names results in taking a snapshot of each disk associated with the VM and then creating a VM from those snapshots.
* DOES **NOT** support cloning Network Security Groups (NSG).

## Revision History
* v0.5.0 - June 1st, 2017

  * Initial version.
* v0.6.0 - April 2nd, 2018

  * Added support for cloning availability sets, cloning IPConfigs, copying resource tags, and setting accelerated networking on the cloned NIC even if the source does not have it enabled.
* v0.7.0 - Nov 7th, 2019

  * Added support for cross-subscription cloning.
  * Fixed a bug with reading the OS configuration.
