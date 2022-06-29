# /=======================================================================
# /=
# /=  Add VC tags as NSX tags using NsxtPolicyService.ps1
# /=
# /=  AUTHOR: Jake Bentz
# /=  DATE:	04/20/2022
# /=
# /=  DESCRIPTION: This script reads vCenter tags and tag category and assigns them as NSXT tags and scope respectively
# /=  NOTE: The NSX-T cmdlet "Get-NsxtPolicyService" has a limitation of 1000 VMs.
# /=
# /=  REVISION HISTORY
# /=   VER  DATE        AUTHOR/EDITOR   COMMENT
# /=   1.0  04/20/2022  Jake Bentz      Created script
# /=   1.1  04/21/2022  Jake Bentz      Release to production
# /=   1.2  06/03/2022  Jake Bentz      Debugged and added logging
# /=
# /=======================================================================#
#
#
<#
.SYNOPSIS
This script reads vCenter tags and tag category and assigns them as NSXT tags and scope respectively
#>
[CmdletBinding()]param(
    [Parameter(Mandatory=$false)][string[]]$VmName,
    [Parameter(Mandatory=$true)][string]$VCenterServer,
    [Parameter(Mandatory=$true)][string]$NSXManager,
    [Parameter(Mandatory=$true)][string]$UserName,
    [Parameter(Mandatory=$true)][Securestring]$Password
)

#Create logfile
$logpath = ".\Logs"
If ((Test-Path -Path $logpath) -ne $true) { New-Item -ItemType Directory -Path $logpath}
$logFile = ".\Logs\NSX_Tagging_$(Get-Date -Format 'yyyyMMddHHmmss').log"
If ((Test-Path -Path $logfile) -ne $true) { New-Item -ItemType File -Path $logfile}

#Build credential object
try {
    "$(get-date -format 'dd-MMM-yyy hh:mm')`tBuilding credential object..."  | Tee-Object $logFile -Append
    $credential = New-Object System.Management.Automation.PsCredential -ArgumentList $UserName,$Password -ErrorAction 'Stop'
} catch {
    "$(get-date -format 'dd-MMM-yyy hh:mm')`tError while creating credentials!"  | Tee-Object $logFile -Append
    exit 1
}

#Connect to vCenter server and NSX Manager
try{
    "$(get-date -format 'dd-MMM-yyy hh:mm')`tImporting PowerCLI module..." | Tee-Object $logFile -Append
    Import-Module VMware.VimAutomation.Core -ErrorAction 'Stop' -Verbose:$false

    "$(get-date -format 'dd-MMM-yyy hh:mm')`tConnecting to vCenter server $VCenterServer..." | Tee-Object $logFile -Append
    Connect-ViServer -Server $VCenterServer -Credential $credential -ErrorAction 'Stop' | Out-Null
} catch {
    $_.Exception.Message | Tee-Object $logFile -Append
    exit 1
}

try{
"$(get-date -format 'dd-MMM-yyy hh:mm')`tConnecting to NSX Manger server $NSXManager..." | Tee-Object $logFile -Append
    Connect-NsxtServer -Server $NSXManager -Credential $credential -ErrorAction 'Stop' | Out-Null
} catch {
    $_.Exception.Message | Tee-Object $logFile -Append
    exit 1
}


#script

if ($VmName){
    $vms = get-vm $VmName
} else {
    $vms = get-vm
}

foreach ($vm in $vms){
$tags = Get-TagAssignment -Entity $vm

"$(get-date -format 'dd-MMM-yyy hh:mm')`tUpdating tags on $vm" | Tee-Object $logFile -Append

foreach($tag in $tags){
    $tagname = $tag.tag.Name
    $tagcategory = $tag.tag.Category
    "$(get-date -format 'dd-MMM-yyy hh:mm')`tTag Name: $tagname" | Tee-Object $logFile -Append
    "$(get-date -format 'dd-MMM-yyy hh:mm')`tTag Category: $tagcategory" | Tee-Object $logFile -Append

#Assign tags as NSX-T tags
<#$display_name = Read-Host -Prompt 'VM Name'
$SecTag = Read-Host -Prompt 'SecTag'
$secscope = Read-Host -Prompt 'secscope'
#>

$display_name = $vm
$SecTag = $tag.tag.name
$secscope = $tag.tag.Category

if ($vmdataentrytags) {Remove-Variable vmdataentrytags}

$vmdata = Get-NsxtPolicyService -Name com.vmware.nsx_policy.infra.realized_state.enforcement_points.virtual_machines
$vmdatavmid = @([PSCustomObject]$vmdata.list("default").results | select-object -property display_name, external_id | select-string "display_name=$display_name")
$vmdatavmid = $vmdatavmid -replace ("@{display_name=$display_name; ") -replace ("}")
$vmdataid=$vmdatavmid|ConvertFrom-StringData
$vmdataentry = @([PSCustomObject]$vmdata.list("default").results | select-object -property display_name, tags | select-string "display_name=$display_name")

if ($vmdataentry -like '*scope*') {
	$vmdataentrytags=$vmdataentry-replace ("@{display_name=$display_name; tags=(\[)struct ") -replace'(\])'
	$vmdataentrytags = $vmdataentrytags -replace ("struct ") -replace ("'") -replace ("}}"),("}") -replace (":"),("=") -replace (" ") -replace ("},"),("};")
	#$vmdataentrytags = $vmdataentrytags -replace ("{scope=$secscope,tag=$SecTag};") -replace (";{scope=$secscope,tag=$SecTag}")
	$vmdataentrytags = @($vmdataentrytags.split(";"))
	$vmdataentrytags = $vmdataentrytags -replace ("{") -replace ("}")
}

$vmdataentrytags+="scope=$secscope,tag=$SecTag"
$vmdatacontent = $vmdata.Help.updatetags.virtual_machine_tags_update.Create()
$vmdatacontent.virtual_machine_id = $vmdataid.external_id

foreach ($item in $vmdataentrytags) {
	$item=@($item.split(","))
	$vmdatatags1=$item|ConvertFrom-StringData
	$vmdatatags=$vmdata.Help.updatetags.virtual_machine_tags_update.tags.Element.Create()
	$vmdatatags.tag=$vmdatatags1.tag
	$vmdatatags.scope=$vmdatatags1.scope
	$vmdatacontent.tags.Add($vmdatatags) |Out-Null
}
$vmdata.updatetags("default", $vmdatacontent)

  }
}

#disconnect

try{Disconnect-VIServer $VCenterServer -Confirm:$false
} catch {
    $_.Exception.Message | Tee-Object $logFile -Append
}

try{Disconnect-NSXTserver $NSXManager -Confirm:$false
} catch {
    $_.Exception.Message | Tee-Object $logFile -Append
}
