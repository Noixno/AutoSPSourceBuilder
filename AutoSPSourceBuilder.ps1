<#
.SYNOPSIS
    Builds a SharePoint 2010/2013 Service Pack + Cumulative Update slipstreamed installation source.
.DESCRIPTION
    Starting from existing (user-provided) SharePoint 2010/2013 installation media/files (and optionally Office Web Apps media/files),
    the script downloads the Service Pack executable and CU/hotfix packages for SharePoint/OWA, along with specified language packs then extracts them to a destination path structure.
    Uses the AutoSPSourceBuilder.XML file as the source of product information (URLs, naming, etc.) and requires it to be present in the same folder as the AutoSPSourceBuilder.ps1 script.
.EXAMPLE
    AutoSPSourceBuilder.ps1 -UpdateLocation "C:\Users\brianl\Downloads\SP" -Destination "D:\SP2010"
.EXAMPLE
    AutoSPSourceBuilder.ps1 -SourceLocation E: -Destination "C:\Source\SP2010" -CumulativeUpdate Dec2011 -Languages fr-fr
.PARAMETER SourceLocation
    The location (path, drive letter, etc.) where the SharePoint binary files are located.
    You can specify a UNC path (\\server\share\SP2010), a drive letter (E:) or a local/mapped folder (Z:\SP2010).
    If you don't provide a value, the sript will check every possible drive letter for a mounted DVD/ISO.
.PARAMETER UpdateLocation
    The file path where the downloaded service pack and cumulative update files are located, or where they should be saved in case they need to be downloaded.
    The default value is the temp directory $env:TEMP.
.PARAMETER Destination
    The file path for the final slipstreamed SP2010/SP2013 installation files.
    The default value is $env:SystemDrive\SP2010 (so in most cases, C:\SP2010).
.PARAMETER GetPrerequisites
    Specifies whether to attempt to download all prerequisite files for the selected product, which can be subsequently used to perform an offline installation.
    The default value is $false.
.PARAMETER CumulativeUpdate
    The name of the cumulative update (CU) you'd like to integrate.
    The format should be e.g. "Dec2011" (without quotes).
    If no value is provided, the script will prompt for a valid CU name.
.PARAMETER OWASourceLocation
    The location (path, drive letter, etc.) where the Office Web Apps binary files are located.
    You can specify a UNC path (\\server\share\SP2010), a drive letter (E:) or a local/mapped folder (Z:\OWA).
    If no value is provided, the script will simply skip the OWA integration altogether.
.PARAMETER Languages
    A comma-separated list of languages (in the culture ID format, e.g. de-de).
    If no languages are provided, the script will simply skip language pack integration altogether.
.LINK 
    
.NOTES
    Created by Brian Lalancette (@brianlala), 2012.
#>
param
(
    ##[Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    ##[String]$Product,
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [String]$SourceLocation,
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [String]$UpdateLocation = "$env:TEMP",
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [String]$Destination = $env:SystemDrive+"\SP2010",
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [Bool]$GetPrerequisites = $false,
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [String]$CumulativeUpdate,
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [String]$OWASourceLocation,
    [Parameter(Mandatory=$false)][ValidateNotNullOrEmpty()]
    [Array]$Languages
)
$oldTitle = $Host.UI.RawUI.WindowTitle
$Host.UI.RawUI.WindowTitle = " -- AutoSPSlipstream --"
$0 = $myInvocation.MyCommand.Definition
$dp0 = [System.IO.Path]::GetDirectoryName($0)

Write-Host -ForegroundColor Green " -- SharePoint Update Slipstreaming Utility --"

[xml]$xml = (Get-Content -Path "$dp0\AutoSPSourceBuilder.xml")

#Region Functions
Function Pause
{
    Write-Host "- Press any key to exit..."
    $null = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

Function WriteLine
{
	Write-Host -ForegroundColor White "--------------------------------------------------------------"
}

Function DownloadPackage ($url, $ExpandedFile, $DestinationFolder, $destinationFile)
{
    $ExpandedFileExists = $false
    $file = $url.Split('/')[-1]
    If (!$destinationFile) {$destinationFile = $file}
    If (!$expandedFile) {$expandedFile = $file}
    Try
    {
        # Check if destination file or its expanded version already exists
        If (Test-Path "$DestinationFolder\$expandedFile") # Check if the expanded file is already there
        {
            Write-Host " - File $expandedFile exists, skipping download."
            $expandedFileExists = $true
        }
    	ElseIf ((Test-Path "$DestinationFolder\$file") -and !((Get-Item $file -ErrorAction SilentlyContinue).Mode -eq "d----")) # Check if the packed downloaded file is already there (in case of a CU or Prerequisite)
    	{
    		Write-Host " - File $file exists, skipping download."
            If (!($file –like "*.zip"))
            {
                # Give the CU package a .zip extension so we can work with it like a compressed folder
                Rename-Item -Path "$DestinationFolder\$file" -NewName ($file+".zip") -Force -ErrorAction SilentlyContinue
            }
    	}
    	ElseIf (Test-Path "$DestinationFolder\$destinationFile") # Check if the packed downloaded file is already there (in case of a CU)
    	{
    		Write-Host " - File $destinationFile exists, skipping download."
        }
        Else # Go ahead and download the missing package
    	{
    		# Begin download
        	Import-Module BitsTransfer
            Write-Host " - Downloading $file..."
    		Start-BitsTransfer -Source $url -Destination "$DestinationFolder\$destinationFile" -DisplayName "Downloading `'$file`' to $DestinationFolder\$destinationFile" -Priority Foreground -Description "From $url..." -RetryInterval 60 -RetryTimeout 3600 -ErrorVariable err
    		If ($err) {Throw ""}
            Write-Host " - Done!"
    	}
    }
    Catch
    {
    	Write-Warning " - An error occurred downloading `'$file`'"
    	break
    }
}

Function Expand-Zip ($InputFile, $DestinationFolder)
{
    $Shell = New-Object -ComObject Shell.Application
    $fileZip = $Shell.Namespace($InputFile)
    $Location = $Shell.Namespace($DestinationFolder)
    $Location.Copyhere($fileZip.items())
}

Function Read-Log()
{
	$log = Get-ChildItem $env:TEMP | Where-Object {$_.Name -like "opatchinstall*.log"} | Sort-Object -Descending -Property "LastWriteTime" | Select-Object -first 1
	If ($log -eq $null) 
	{
		Write-Host `n
        Throw " - Could not find extraction log file!"
	}
	# Get error(s) from log
	$lastError = $log | select-string -SimpleMatch -Pattern "OPatchInstall: The extraction of the files failed" | Select-Object -Last 1
	If ($lastError)
	{
		Write-Host `n
        Write-Warning $lastError.Line
		Invoke-Item $log.FullName
		Throw " - Review the log file and try to correct any error conditions."
	}
    Remove-Variable -Name log
}
Function Remove-ReadOnlyAttribute ($Path)
{
    ForEach ($item in (Get-ChildItem -Path $Path -Recurse -ErrorAction SilentlyContinue))
    {
        $attributes = @((Get-ItemProperty -Path $item.FullName).Attributes)
        If ($attributes -match "ReadOnly")
        {
            # Set the file to just have the 'Archive' attribute
            Write-Host "  - Removing Read-Only attribute from file: $item"
            Set-ItemProperty -Path $item.FullName -Name Attributes -Value "Archive"
        }
    }
}

# ====================================================================================
# Func: EnsureFolder
# Desc: Checks for the existence and validity of a given path, and attempts to create if it doesn't exist.
# From: Modified from patch 9833 at http://autospinstaller.codeplex.com/SourceControl/list/patches by user timiun
# ====================================================================================
Function EnsureFolder ($Path)
{
		If (!(Test-Path -Path $Path -PathType Container))
		{
			Write-Host -ForegroundColor White " - $Path doesn't exist; creating..."
			Try 
			{
				New-Item -Path $Path -ItemType Directory | Out-Null
			}
			Catch
			{				
				Write-Warning " - $($_.Exception.Message)"
				Throw " - Could not create folder $Path!"
			}
		}
}

#EndRegion

#Region Determine product version
if ($SourceLocation) 
{
    $sourceDir = $SourceLocation
    Write-Host " - Checking for $sourceDir\Setup.exe and $sourceDir\PrerequisiteInstaller.exe..."
    $sourceFound = ((Test-Path -Path "$sourceDir\Setup.exe") -and (Test-Path -Path "$sourceDir\PrerequisiteInstaller.exe"))
}
# Inspired by http://vnucleus.com/2011/08/alphabet-range-sequences-in-powershell-and-a-usage-example/
while (!$sourceFound)
{
    foreach ($driveLetter in 68..90) # Letters from D-Z
    {
    	# Check for the SharePoint DVD in all possible drive letters
        $sourceDir = "$([char]$driveLetter):"
		Write-Host " - Checking for $sourceDir\Setup.exe and $sourceDir\PrerequisiteInstaller.exe..."
        $sourceFound = ((Test-Path -Path "$sourceDir\Setup.exe") -and (Test-Path -Path "$sourceDir\PrerequisiteInstaller.exe"))
        If ($sourceFound -or $driveLetter -ge 90) {break}
    }
    break
}
if (!$sourceFound)
{
    Write-Warning " - The correct SharePoint source files/media were not found!"
    Write-Warning " - Please insert/mount the correct media, or specify a valid path."
    break
    Pause
    exit
}
else
{
    Write-Host " - Source found in $sourceDir."
    $spVer,$null = (Get-Item -Path "$sourceDir\setup.exe").VersionInfo.ProductVersion -split "\."
    If (!$sourceDir) {Write-Warning " - Cannot determine version of SharePoint setup binaries."; break; Pause; exit}
    # Create a hash table with 'wave' to product year mappings
    $spYear = @{"14" = "2010"; "15" = "2013"}
    Write-Host " - SharePoint $($spYear.$spVer) detected."
}
<#While ([string]::IsNullOrEmpty($Product))
{
    Write-Host " - Available Products:"
    foreach ($prod in $xml.Products.Product)
    {
        Write-Host "  - "$prod.Name
    }
    $Product = Read-Host -Prompt " - Please type the name of a product"
    if (!($xml.Products.Product | Where-Object {$_.Name -eq $Product}))
    {
        Write-Warning " - Invalid entry `"$Product`""
        $Product = $null
    }
}#>
#EndRegion

$spNode = $xml.Products.Product | Where-Object {$_.Name -eq "SP$($spYear.$spVer)"}
$spServicePack = $spNode.ServicePacks.ServicePack | Where-Object {$_.Name -eq "SP1"} # Currently we only have SP1 to choose from so it's hard-coded
$owaNode = $xml.Products.Product | Where-Object {$_.Name -eq "OfficeWebApps$($spYear.$spVer)"}
$owaServicePack = $owaNode.ServicePacks.ServicePack | Where-Object {$_.Name -eq $spServicePack.Name} # To match the chosen SharePoint service pack
# Figure out which CU we want, but only if there are any available
While (([string]::IsNullOrEmpty($CumulativeUpdate)) -and (($spNode.CumulativeUpdates.ChildNodes | Where-Object {$_.NodeType -ne "Comment"}).Count -ge 1))
{
    Write-Host " - Available Cumulative Updates:"
    foreach ($cu in $spNode.CumulativeUpdates.CumulativeUpdate)
    {
        Write-Host "  - "$cu.Name
    }
    $CumulativeUpdate = Read-Host -Prompt " - Please type the name of an available CU"
    if (!($spNode.CumulativeUpdates.CumulativeUpdate | Where-Object {$_.Name -eq $CumulativeUpdate}))
    {
        Write-Warning " - Invalid entry `"$CumulativeUpdate`""
        Remove-Variable -Name CumulativeUpdate
    }
}
$spCU = $spNode.CumulativeUpdates.CumulativeUpdate | Where-Object {$_.Name -eq $CumulativeUpdate}
$owaCU = $owaNode.CumulativeUpdates.CumulativeUpdate | Where-Object {$_.Name -eq $spCU.Name}

#Region SharePoint Source Binaries
if (!($sourceDir -eq "$Destination\SharePoint"))
{
    WriteLine
    Write-Host " - (Robo-)copying files from $sourceDir to $Destination\SharePoint..."
    Start-Process -FilePath robocopy.exe -ArgumentList "$sourceDir $Destination\SharePoint /E /Z /ETA /NDL /NFL /NJH /XO /A-:R" -Wait -NoNewWindow
    Write-Host " - Done copying original files to $Destination\SharePoint."
    WriteLine
}
#EndRegion

#Region SharePoint Prerequisites
If ($GetPrerequisites)
{
    WriteLine
    $spPrerequisiteNode = $spNode.Prerequisites
    foreach ($prerequisite in $spPrerequisiteNode.Prerequisite)
    {
        Write-Host " - Getting prerequisite `"$($prerequisite.Name)`"..."
        DownloadPackage -Url $($prerequisite.Url) -DestinationFolder "$Destination\SharePoint\prerequisiteinstallerfiles"
        ##Write-Host " - Done!"
    }
    WriteLine
}
#EndRegion

#Region SharePoint Service Pack
If ($spServicePack)
{
    WriteLine
    # Check if SP1 already appears to be included in the source
    If ((Get-ChildItem "$sourceDir\Updates" -Filter *.msp).Count -lt 40) # Checking for 40 MSP patch files in the \Updates folder
    {
        Write-Host " - $($spServicePack.Name) seems to be missing, or incomplete in $sourceDir\; downloading..."
        EnsureFolder $UpdateLocation
        DownloadPackage -Url $($spServicePack.Url) -DestinationFolder $UpdateLocation
        # Extract SharePoint service pack patch files
        Write-Host " - Extracting SharePoint $($spServicePack.Name) patch files..." -NoNewline
        $spServicePackExpandedFile = $($spServicePack.Url).Split('/')[-1]
        Remove-ReadOnlyAttribute -Path "$Destination\SharePoint\Updates"
        Start-Process -FilePath "$UpdateLocation\$spServicePackExpandedFile" -ArgumentList "/extract:$Destination\SharePoint\Updates /passive" -Wait -NoNewWindow
        Read-Log
        Write-Host "done!"
    }
    Else {Write-Host " - $($spServicePack.Name) appears to be already slipstreamed into the SharePoint binary source location."}

    ## Extract SharePoint w/SP1 files
    #Start-Process -FilePath "$UpdateLocation\en_sharepoint_server_2010_with_service_pack_1_x64_759775.exe" -ArgumentList "/extract:$Destination\SharePoint /passive" -NoNewWindow -Wait -NoNewWindow
WriteLine
}
#EndRegion

#Region SharePoint CU
If ($spCU)
{
    WriteLine 
    Write-Host " - Getting SharePoint SP$($spYear.$spVer) $($spCU.Name) CU:"
    $spCuFileZip = $($spCU.Url).Split('/')[-1] +".zip"
    EnsureFolder $UpdateLocation
    DownloadPackage -Url $($spCU.Url) -ExpandedFile $($spCU.ExpandedFile) -DestinationFolder $UpdateLocation -destinationFile $spCuFileZip
    # Expand CU executable to $UpdateLocation
    If (!(Test-Path "$UpdateLocation\$($spCU.ExpandedFile)")) # Check if the expanded file is already there
    {
        $spCuFileZipPath = Join-Path -Path $UpdateLocation -ChildPath $spCuFileZip
        Write-Host " - Expanding Cumulative Update (single file)..."
        Expand-Zip -InputFile $spCuFileZipPath -DestinationFolder $UpdateLocation
    }
    # Extract SharePoint CU files to $Destination\SharePoint\Updates
    Write-Host " - Extracting Cumulative Update patch files..." -NoNewline
    Remove-ReadOnlyAttribute -Path "$Destination\SharePoint\Updates"
    Start-Process -FilePath "$UpdateLocation\$($spCU.ExpandedFile)" -ArgumentList "/extract:$Destination\SharePoint\Updates /passive" -Wait -NoNewWindow
    ##Start-Process -FilePath "cmd.exe" -ArgumentList "/C $UpdateLocation\$($spCU.ExpandedFile) /extract:$Destination\SharePoint\Updates /passive" -Wait -NoNewWindow
    Read-Log
    Write-Host "done!"
    WriteLine
}
#EndRegion

#Region Office Web Apps
if ($OWASourceLocation) 
{
    WriteLine
    # Download Office Web Apps?

	# Download Office Web Apps 2013 Prerequisites
	
	If ($GetPrerequisites -and $spYear.$spVer -eq "2013")
	{
	    WriteLine
	    $owaPrerequisiteNode = $owaNode.Prerequisites
		New-Item -ItemType Directory -Name "prerequisiteinstallerfiles" -Path "$Destination\OfficeWebApps" -ErrorAction SilentlyContinue | Out-Null
	    foreach ($prerequisite in $owaPrerequisiteNode.Prerequisite)
	    {
	        Write-Host " - Getting OWA prerequisite `"$($prerequisite.Name)`"..."
	        DownloadPackage -Url $($prerequisite.Url) -DestinationFolder "$Destination\OfficeWebApps\prerequisiteinstallerfiles"
	        ##Write-Host " - Done!"
	    }
	    WriteLine
	}
	
    # Extract Office Web Apps files to $Destination\OfficeWebApps

    $sourceDirOWA = $OWASourceLocation
    Write-Host " - Checking for $sourceDirOWA\XLSERVERWAC.en-us\..."
    $sourceFoundOWA = (Test-Path -Path "$sourceDirOWA\XLSERVERWAC.en-us")
    if (!$sourceFoundOWA)
    {
        Write-Warning " - The correct Office Web Apps source files/media were not found!"
        Write-Warning " - Please specify a valid path."
        break
        Pause
        exit
    }
    else
    {
        Write-Host " - Source found in $sourceDirOWA."
    }
    if (!($sourceDirOWA -eq "$Destination\OfficeWebApps"))
    {
        Write-Host " - (Robo-)copying files from $sourceDirOWA to $Destination\OfficeWebApps..."
        Start-Process -FilePath robocopy.exe -ArgumentList "$sourceDirOWA $Destination\OfficeWebApps /E /Z /ETA /NDL /NFL /NJH /XO /A-:R" -Wait -NoNewWindow
        Write-Host " - Done copying original files to $Destination\OfficeWebApps."
    }

    # Check if OWA SP1 already appears to be included in the source
    If ((Get-ChildItem "$sourceDirOWA\Updates" -Filter *.msp).Count -lt 16) # Checking for 40 MSP patch files in the \Updates folder
    {
        Write-Host " - OWA $($owaServicePack.Name) seems to be missing or incomplete in $sourceDirOWA; downloading..."
        # Download Office Web Apps service pack
        Write-Host " - Getting Office Web Apps $($owaServicePack.Name):"
        EnsureFolder $UpdateLocation
        DownloadPackage -Url $($owaServicePack.Url) -DestinationFolder $UpdateLocation
        # Extract Office Web Apps service pack files to $Destination\OfficeWebApps\Updates
        Write-Host " - Extracting Office Web Apps $($owaServicePack.Name) patch files..." -NoNewline
        $owaServicePackExpandedFile = $($owaServicePack.Url).Split('/')[-1]
        Remove-ReadOnlyAttribute -Path "$Destination\OfficeWebApps\Updates"
        Start-Process -FilePath "$UpdateLocation\$owaServicePackExpandedFile" -ArgumentList "/extract:$Destination\OfficeWebApps\Updates /passive" -Wait -NoNewWindow
        Read-Log
        Write-Host "done!"
    }
    Else {Write-Host " - OWA $($owaServicePack.Name) appears to be already slipstreamed into the SharePoint binary source location."}

    # Download Office Web Apps CU
    Write-Host " - Getting latest Office Web Apps CU:"
    $owaCuFileZip = $($owaCU.Url).Split('/')[-1] +".zip"
    EnsureFolder $UpdateLocation
    DownloadPackage -Url $($owaCU.Url) -ExpandedFile $($owaCU.ExpandedFile) -DestinationFolder $UpdateLocation -destinationFile $owaCuFileZip

    # Expand Office Web Apps CU executable to $UpdateLocation
    If (!(Test-Path "$UpdateLocation\$($owaCU.ExpandedFile)")) # Check if the expanded file is already there
    {
        $owaCuFileZipPath = Join-Path -Path $UpdateLocation -ChildPath $owaCuFileZip
        Write-Host " - Expanding OWA Cumulative Update (single file)..."
        EnsureFolder $UpdateLocation
        Expand-Zip -InputFile $owaCuFileZipPath -DestinationFolder $UpdateLocation
    }

    # Extract Office Web Apps CU files to $Destination\OfficeWebApps\Updates
    Write-Host " - Extracting Office Web Apps Cumulative Update patch files..." -NoNewline
    Remove-ReadOnlyAttribute -Path "$Destination\OfficeWebApps\Updates"
    Start-Process -FilePath "$UpdateLocation\$($owaCU.ExpandedFile)" -ArgumentList "/extract:$Destination\OfficeWebApps\Updates /passive" -Wait -NoNewWindow
    Write-Host "done!"
    WriteLine
}
#EndRegion

#Region Language Packs
If ($Languages.Count -gt 0)
{
    $lpNode = $spNode.LanguagePacks ##| Where-Object {$_.Name -eq "LanguagePacks"}
    ForEach ($language in $Languages)
    {
		WriteLine
        $spLanguagePack = $lpNode.LanguagePack | Where-Object {$_.Name -eq $language}
        # Download the language pack
        ##$lpUrl = Get-Variable -Name lpUrl_$language -ValueOnly
        if ($spver -eq "14")
        {
            $lpDestinationFile = $($spLanguagePack.Url).Split('/')[-1] -replace ".exe","_$language.exe"
        }
        else
        {
            $lpDestinationFile = $($spLanguagePack.Url).Split('/')[-1]
        }
        Write-Host " - Getting SharePoint SP$($spYear.$spVer) Language Pack ($language):"
        EnsureFolder $UpdateLocation
        DownloadPackage -Url $($spLanguagePack.Url) -DestinationFolder $UpdateLocation -DestinationFile $lpDestinationFile
        # Extract the language pack to $Destination\LanguagePacks\xx-xx (where xx-xx is the culture ID of the language pack, for example fr-fr)
        Write-Host " - Extracting Language Pack files ($language)..." -NoNewline
        Remove-ReadOnlyAttribute -Path "$Destination\LanguagePacks\$language"
        Start-Process -FilePath "$UpdateLocation\$lpDestinationFile" -ArgumentList "/extract:$Destination\LanguagePacks\$language /quiet" -Wait -NoNewWindow
        Write-Host "done!"
        if (($splanguagePack.Servicepacks.ChildNodes | Where-Object {$_.NodeType -ne "Comment"}).Count -ge 1)
        {
            # Download service pack for the language pack
            ##$lpSp1Url = Get-Variable -Name lpSp1Url_$language -ValueOnly
            $lpServicePack = $spLanguagePack.ServicePacks.ServicePack | Where-Object {$_.Name -eq $spServicePack.Name} # To match the chosen SharePoint service pack
            $lpServicePackDestinationFile = $($lpServicePack.Url).Split('/')[-1]
            Write-Host " - Getting SharePoint SP$($spYear.$spVer) Language Pack $($lpServicePack.Name) ($language):"
            EnsureFolder $UpdateLocation
            DownloadPackage -Url $($lpServicePack.Url) -DestinationFolder $UpdateLocation -DestinationFile $lpServicePackDestinationFile
            # Extract each language pack to $Destination\LanguagePacks\xx-xx (where xx-xx is the culture ID of the language pack, for example fr-fr)
            Write-Host " - Extracting Language Pack $($lpServicePack.Name) files ($language)..." -NoNewline
            Remove-ReadOnlyAttribute -Path "$Destination\LanguagePacks\$language\Updates"
            Start-Process -FilePath "$UpdateLocation\$lpServicePackDestinationFile" -ArgumentList "/extract:$Destination\LanguagePacks\$language\Updates /quiet" -Wait -NoNewWindow
            Write-Host "done!"
        }
        If ($spCU)
        {
            # Copy matching culture files from $Destination\SharePoint\Updates folder (e.g. spsmui-fr-fr.msp) to $Destination\LanguagePacks\$language\Updates
            Write-Host " - Updating $Destination\LanguagePacks\$language with the $($spCU.Name) SharePoint CU..."
            ForEach ($patch in (Get-ChildItem -Path $Destination\SharePoint\Updates -Filter *$language*))
            {
                Copy-Item -Path $patch.FullName -Destination "$Destination\LanguagePacks\$language\Updates" -Force
            }
        }
		WriteLine
    }
}
#EndRegion

#Region Create labeled ISO?
#WriteLine
#WriteLine
#EndRegion

#Region Wrap Up
WriteLine
Write-Host " - Adding a label file `"_SLIPSTREAMED.txt`"..."
Set-Content -Path "$Destination\_SLIPSTREAMED.txt" -Value "This media source directory has been slipstreamed with SharePoint SP$($spYear.$spVer) $($spServicePack.Name) and the $($spCU.Name) CU." -Force
Write-Host " - Done!"
Start-Sleep -Seconds 5
Invoke-Item -Path $Destination
WriteLine
Pause
$Host.UI.RawUI.WindowTitle = $oldTitle
#EndRegion