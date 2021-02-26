#########################################################
# XenApp Data Gathering Script for Grafana
# Author: Jared Shippy
# Date: 04/10/2017
#########################################################

# Config Source Data
$fileserver = "" #FQDN of File Server
$DeliveryControllers = "","" #Array of FQDN of Delivery Controllers
$DeliveryGroupRegex = "" # Regular Expression to match delivery groups. Multiple Groups can be seperated by a pipe, as in "DeliveryGroup1|DevGroupTest"

# Configure InfluxDB Target
$idbRootUrl = "" # Base URL of Influx Server and port, ex: http://192.168.2.2:8086
$idbstring = "" # Followup path for Influx URL, ex: /write?db=CVA


# Gather Metrics

# Get File Server Memory, convert to percentage
$fsMemory = Get-CimInstance Win32_OperatingSystem -ComputerName $fileserver | Select-Object *memory*
$fsMemoryPercent = 100 - [math]::Round(($fsMemory.FreePhysicalMemory/$fsMemory.TotalVisibleMemorySize)*100,2)
# Get File Server CPU
$fsCpu = (Get-CimInstance Win32_Processor -ComputerName $fileserver | measure-object -Property LoadPercentage -Average).average


# Check Delivery Controllers for Network Response
$chosenDeliveryController = foreach ($xdc in $DeliveryControllers){
    if (Test-Connection $xdc -quiet -count 1){$xdc}
}

$cf715 = Invoke-Command -computername $chosenDeliveryController[0] -ScriptBlock {
    Add-PSSnapin *citrix*
    $machineList = Get-BrokerMachine | Where-Object {$_.DesktopGroupName -match $DeliveryGroupRegex} | Select-Object sessioncount, InMaintenanceMode, summaryState, dnsname
    # Calculate Numbers
    #Total User Count
    $cfUserCount = ($machineList | Measure-Object -Property SessionCount -sum).sum
    # Number of Servers in Maintainence Mode
    $cfMaintenenceMode = ($machineList | Where-Object {$_.InMaintenanceMode -eq $true}).count
    # number of Servers in a down state
    $cfDown = ($machineList | Where-Object {$_.summaryState -notmatch "InUse|Available" -and $_.dnsname -notmatch "toolbox"}).count
    #Average User Count of Top third of Up Servers
    $cfLoad = [Math]::Round(($machineList | Sort-Object sessioncount | Select-Object -last (($machineList.count - $cfDown) / 3) | Measure-Object -property sessioncount -Average).average)
    $OBJ = New-Object psobject -Property @{
        cfUserCount = $cfUserCount
        cfMaintainenceMode = $cfMaintenenceMode
        cfDown = $cfDown
        cfLoad = $cfLoad
    }
    $obj
}

# Format data for InfluxDB
    $body = (
        "fsmemory,host=$fileserver,data=memoryUsedPercentage value=$fsMemoryPercent" + `
        "`n fscpu,host=$fileserver,data=cpuUsedPercentage value=$fscpu " + `
        "`n cfusercount,farm=715 value=$($cf715.cfUserCount) " + `
        "`n cfMaintainenceMode,farm=715 value=$($cf715.cfMaintainenceMode) " + `
        "`n cfdown,farm=715 value=$($cf715.cfdown) " + `
        "`n cfload,farm=715 value=$($cf715.cfload) "
    )
    Invoke-RestMethod -uri ($idbRootUrl + $idbstring) -Method Post -body $body
