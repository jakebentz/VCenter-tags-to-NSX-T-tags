# /=======================================================================
# /=
# /=  Update_Tags_Using_Curl.ps1
# /=
# /=  AUTHOR: Jake Bentz
# /=  DATE:	04/20/2022
# /=
# /=  DESCRIPTION: This script reads vCenter tags and tag category and assigns them as NSXT tags and scope respectively
# /=
# /=  NOTE: The api call has a limit of 25 tags. The header is written for NSX-T integrated with vIDM authentication
# /=
# /=  USAGE: .\Update_Tags_Using_Curl.ps1 -VmName vm -VCenterServer vCenter -NSXManager NSXmanager -UserName username@domain.com
# /=
# /=  REVISION HISTORY
# /=   VER  DATE        AUTHOR/EDITOR   COMMENT
# /=   1.0  04/20/2022  Jake Bentz      Created script
# /=   1.1  04/21/2022  Jake Bentz      Release to production
# /=   1.2  06/03/2022  Jake Bentz      Debugged and added logging
# /=   1.3  06/03/2022  Jake Bentz      Updated to use curl instead of NsxTPolicyService
# /=   1.4  06/06/2022  Jake Bentz      Updated to call curl as a batch file for successful testing.
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

#Create temp path
$temppath = ".\Temp"
If ((Test-Path -Path $temppath) -ne $true) { New-Item -ItemType Directory -Path $temppath}

#Build credential object
try {
    "$(get-date -format 'dd-MMM-yyy hh:mm')`tBuilding credential object..."  | Tee-Object $logFile -Append
    $credential = New-Object System.Management.Automation.PsCredential -ArgumentList $UserName,$Password -ErrorAction 'Stop'
} catch {
    "$(get-date -format 'dd-MMM-yyy hh:mm')`tError while creating credentials!"  | Tee-Object $logFile -Append
    exit 1
}

#Build curl credential
#Decrypt password
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $plaintextPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    $unencodedCredential = "$UserName`:$plaintextPassword"

#Base64encode
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($unencodedCredential)
    $curlCredential = [System.Convert]::ToBase64String($bytes)

#Connect to vCenter server 
try{
    "$(get-date -format 'dd-MMM-yyy hh:mm')`tImporting PowerCLI module..." | Tee-Object $logFile -Append
    Import-Module VMware.VimAutomation.Core -ErrorAction 'Stop' -Verbose:$false

    "$(get-date -format 'dd-MMM-yyy hh:mm')`tConnecting to vCenter server $VCenterServer..." | Tee-Object $logFile -Append
    Connect-ViServer -Server $VCenterServer -Credential $credential -ErrorAction 'Stop' | Out-Null
} catch {
    $_.Exception.Message | Tee-Object $logFile -Append
    exit 1
}

#If no VmName is provided, run against all vms in vCenter
if ($VmName -ne ""){
    $vms = get-vm $VmName
} else {
    $vms = get-vm
}

#get the vCenter tags
foreach ($vm in $vms){
$tags = Get-TagAssignment -Entity $vm
$tagsNum = $tags.count

"$(get-date -format 'dd-MMM-yyy hh:mm')`tUpdating $tagsNum tags on $vm" | Tee-Object $logFile -Append
$vmid = $vm.PersistentId
"$(get-date -format 'dd-MMM-yyy hh:mm')`tNSX External ID $vmid" | Tee-Object $logFile -Append

#put the tags and tag categories from the VM into arrays
$tagArray = @()
$scopeArray = @()

foreach($tag in $tags){
    $tagname = $tag.tag.Name
    $tagcategory = $tag.tag.Category
    "$(get-date -format 'dd-MMM-yyy hh:mm')`tTag Name: $tagname" | Tee-Object $logFile -Append
    "$(get-date -format 'dd-MMM-yyy hh:mm')`tTag Category: $tagcategory" | Tee-Object $logFile -Append
 
    $tagArray += $tagname
    $scopeArray += $tagcategory
    
}
#Build curl api call with the correct quotation marks
$curlCommand = "curl -X POST https://"
$curlCommand += $NSXManager
$curlCommand += "/api/v1/fabric/virtual-machines?action=update_tags -H `"Authorization: Remote "
$curlCommand += $curlCredential
$curlCommand += "`" -H `"Content-type: application/json;charset=utf-8`" -d `"{`"`"`"external_id`"`"`":`"`"`""
$curlCommand += $vmid
$curlCommand += "`"`"`",`"`"`"tags`"`"`":["

for ( $index = 0; $index -lt $tagArray.count; $index++)
{
    $curlCommand += "{`"`"`"scope`"`"`":`"`"`""
    $curlCommand += $scopeArray[$index]
    $curlCommand += "`"`"`",`"`"`"tag`"`"`":`"`"`""
    $curlCommand += $tagArray[$index]
    $curlCommand += "`"`"`"}"
    if ($index -ne ($tagArray.count -1)){
        $curlCommand += ","
    }
}
$curlCommand +="]}`""
#"$(get-date -format 'dd-MMM-yyy hh:mm')`tRunning $curlCommand"
"$(get-date -format 'dd-MMM-yyy hh:mm')`tRunning curl command for $VmName`:" | Tee-Object $logFile -Append
"$(get-date -format 'dd-MMM-yyy hh:mm')`t$curlCommand" | Tee-Object $logFile -Append

#create batch file to successfull call curl command
echo $curlCommand >> $temppath\curl-command_$VmName.cmd
cmd.exe /c $temppath\curl-command_$VmName.cmd

#clean up temp file from working directory
Remove-Item $temppath\*
}

#clean up working directory
Remove-Item $temppath

#disconnect

try{Disconnect-VIServer $VCenterServer -Confirm:$false
} catch {
    $_.Exception.Message | Tee-Object $logFile -Append
}
