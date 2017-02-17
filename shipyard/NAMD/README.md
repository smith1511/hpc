
# NAMD Batch Shipyard

This project provides support for running NAMD with Batch Shipyard from a Windows machine.

## Installation

* Clone repo into a local drive, say C:\NAMD-Shipyard
* Install Azure Batch Shipyard into C:\NAMD-Shipyard\shipyard
** Apply the convoy.patch
* Install Python 3.5 into C:\NAMD-Shipyard\shipyard\Python35
* 

## Running

* Update credentials.json in the various recipes with your Batch and Storage account
* Execute "namd.cmd <path to NAMD conf>"
** e.g. C:\NAMD-Shipyard\namd.cmd c:\namd\models\domain.namd
