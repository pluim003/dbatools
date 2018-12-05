function Update-DbaInstance {
    <#
    .SYNOPSIS
        Invokes installation of SQL Server Service Packs and Cumulative Updates on local and remote servers.

    .DESCRIPTION
        Starts and automated process of updating SQL Server installation to a specific version defined in the parameters.
        The command will:

        * Search for SQL Server installations in a remote registry
        * Check if current settings are applicable to the current SQL Server versions
        * Search for a KB executable in a folder specified in -Path
        * Establish a PSRemote connection to the target machine if necessary
        * Extract KB to a temporary folder in a current user's profile
        * Run the installation from the temporary folder updating all instances on the computer at once
        * Remove temporary files
        * Restart the computer (if -Restart is specified)
        * Repeat for each consequent KB and computer

        The impact of this function is set to High, if you don't want to receive interactive prompts, set -Confirm to $false.
        Credentials are a required parameter for remote machines. Without specifying -Credential, the installation will fail due to lack of permissions.

        CredSSP is a recommended transport for running the updates remotely. Update-DbaInstance will attempt to reconfigure
        local and remote hosts to support CredSSP, which is why it is desirable to run this command in an elevated console at all times.
        CVE-2018-0886 security update is required for both local and remote hosts. If CredSSP connections are failing, make sure to
        apply recent security updates prior to doing anything else.

        Always backup databases and configurations prior to upgrade.

    .PARAMETER ComputerName
        Target computer with SQL instance or instsances.

    .PARAMETER Credential
        Windows Credential with permission to log on to the remote server. Must be specified for any remote connection.

    .PARAMETER Type
        Type of the update: All | ServicePack | CumulativeUpdate.
        Default: All
        Use -Version to limit upgrade to a certain Major version of SQL Server.

    .PARAMETER KB
        Install a specific update or list of updates. Can be a number of a string KBXXXXXXX.

    .PARAMETER Version
        A target version of the installation you want to reach. If not specified, a latest available version would be used by default.
        Can be defined using the following general pattern: <MajorVersion><SPX><CUX>.
        Any part of the pattern can be ommitted if needed:
        2008R2SP1 - will update SQL 2008R2 to SP1
        2016CU3 - will update SQL 2016 to CU3 of current Service Pack installed
        SP0CU3 - will update all existing SQL Server versions to RTM CU3 without installing any service packs
        SP1CU7 - will update all existing SQL Server versions to SP1 and then (after restart if -Restart is specified) to SP1CU7
        CU7 - will update all existing SQL Server versions to CU7 of current Service Pack installed

    .PARAMETER Path
        Path to the folder(s) with SQL Server patches downloaded. It will be scanned recursively for available patches.
        Path should be available from both server with SQL Server installation and client that runs the command.
        All file names should match the pattern used by Microsoft: SQLServer####*-KB###-*x##*.exe
        If a file is missing in the repository, the installation will fail.
        Consider setting the following configuration if you want to omit this parameter: `Set-DbatoolsConfig -Name Path.SQLServerUpdates -Value '\\path\to\updates'`

    .PARAMETER Restart
        Restart computer automatically after a successful installation of a patch and wait until it comes back online.
        Using this parameter is the only way to chain-install more than 1 patch on a computer, since every single patch will require a restart of said computer.

    .PARAMETER Continue
        Continues a failed installation attempt when specified. Will abort a previously failed installation otherwise.

    .PARAMETER InstanceName
        Only updates a specific instance(s).

    .PARAMETER Throttle
        Maximum number of computers updated in parallel. Once reached, the update operations will queue up.
        Default: 50

    .PARAMETER WhatIf
        Shows what would happen if the command were to run. No actions are actually performed.

    .PARAMETER Confirm
        Prompts you for confirmation before executing any changing operations within the command.


    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: Install, Patching, SP, CU, Instance
        Author: Kirill Kravtsov (@nvarscar) https://nvarscar.wordpress.com/

        Website: https://dbatools.io
        Copyright: (c) 2018 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

        Requires Local Admin rights on destination computer(s).

    .EXAMPLE
        PS C:\> Update-DbaInstance -ComputerName SQL1 -Version SP3 -Path \\network\share

        Updates all applicable SQL Server installations on SQL1 to SP3.
        Binary files for the update will be searched among all files and folders recursively in \\network\share.
        Prompts for confirmation before the update.

    .EXAMPLE
        PS C:\> Update-DbaInstance -ComputerName SQL1, SQL2 -Restart -Path \\network\share -Confirm:$false

        Updates all applicable SQL Server installations on SQL1 and SQL2 with the most recent patch.
        It will install latest ServicePack, restart the computers, install latest Cumulative Update, and finally restart the computer once again.
        Binary files for the update will be searched among all files and folders recursively in \\network\share.
        Does not prompt for confirmation.

    .EXAMPLE
        PS C:\> Update-DbaInstance -ComputerName SQL1 -Version 2012 -Type ServicePack -Path \\network\share

        Updates SQL Server 2012 on SQL1 with the most recent ServicePack found in your patch repository.
        Binary files for the update will be searched among all files and folders recursively in \\network\share.
        Prompts for confirmation before the update.

    .EXAMPLE
        PS C:\> Update-DbaInstance -ComputerName SQL1 -KB 123456 -Restart -Path \\network\share -Confirm:$false

        Installs KB 123456 on SQL1 and restarts the computer.
        Binary files for the update will be searched among all files and folders recursively in \\network\share.
        Does not prompt for confirmation.

    .EXAMPLE
        PS C:\> Update-DbaInstance -ComputerName Server1 -Version SQL2012SP3, SQL2016SP2CU3 -Path \\network\share -Restart -Confirm:$false

        Updates SQL 2012 to SP3 and SQL 2016 to SP2CU3 on Server1. Each update will be followed by a restart.
        Binary files for the update will be searched among all files and folders recursively in \\network\share.
        Does not prompt for confirmation.

    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Version')]
    Param (
        [parameter(ValueFromPipeline, Position = 1)]
        [Alias("cn", "host", "Server")]
        [DbaInstanceParameter[]]$ComputerName = $env:COMPUTERNAME,
        [pscredential]$Credential,
        [Parameter(ParameterSetName = 'Version')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Version,
        [Parameter(ParameterSetName = 'Version')]
        [ValidateSet('All', 'ServicePack', 'CumulativeUpdate')]
        [string[]]$Type = @('All'),
        [Parameter(Mandatory, ParameterSetName = 'KB')]
        [ValidateNotNullOrEmpty()]
        [string[]]$KB,
        [Alias("Instance")]
        [string]$InstanceName,
        [string[]]$Path,
        [switch]$Restart,
        [switch]$Continue,
        [ValidateNotNull()]
        [int]$Throttle = 50,
        [switch]$EnableException
    )
    begin {
        #Validating parameters
        if ($PSCmdlet.ParameterSetName -eq 'Version') {
            foreach ($v in $Version) {
                if ($v -notmatch '^((SQL)?\d{4}(R2)?)?\s*(RTM|SP\d+)?\s*(CU\d+)?$') {
                    Stop-Function -Category InvalidArgument -Message "$Version is an incorrect Version value, please refer to Get-Help Update-DbaInstance -Parameter Version"
                    return
                }
            }
        } elseif ($PSCmdlet.ParameterSetName -eq 'KB') {
            $kbList = @()
            foreach ($kbItem in $KB) {
                if ($kbItem -match '^(KB)?(\d+)$') {
                    $kbList += $Matches[2]
                } else {
                    Stop-Function -Category InvalidArgument -Message "$kbItem is an incorrect KB value, please refer to Get-Help Update-DbaInstance -Parameter KB"
                    return
                }
            }
        }
        $actions = @()
        $actionTemplate = @{}
        if ($InstanceName) { $actionTemplate.InstanceName = $InstanceName }
        if ($Continue) { $actionTemplate.Continue = $Continue }
        #Putting together list of actions based on current ParameterSet
        if ($PSCmdlet.ParameterSetName -eq 'Version') {
            if ($Type -contains 'All') { $typeList = @('ServicePack', 'CumulativeUpdate') }
            else { $typeList = $Type | Sort-Object -Descending }
            foreach ($ver in $Version) {
                $currentAction = $actionTemplate.Clone()
                if ($ver -and $ver -match '^(SQL)?(\d{4}(R2)?)?\s*(RTM|SP)?(\d+)?(CU)?(\d+)?') {
                    $majorV, $spV, $cuV = $Matches[2, 5, 7]
                    Write-Message -Level Debug -Message "Parsed Version as Major $majorV SP $spV CU $cuV"
                    # Add appropriate fields to the splat
                    # Add version to every field
                    if ($null -ne $majorV) {
                        $currentAction += @{
                            MajorVersion = $majorV
                        }
                        # When version is the only thing that is specified, we want all the types added
                        if ($null -eq $spV -and $null -eq $cuV) {
                            foreach ($currentType in $typeList) {
                                $actions += $currentAction.Clone() + @{ Type = $currentType }
                            }
                        }
                    }
                    #when SP# is specified
                    if ($null -ne $spV) {
                        $currentAction += @{
                            ServicePack = $spV
                        }
                        # ignore SP0 and trigger only when SP is in Type
                        if ($spV -ne '0' -and 'ServicePack' -in $typeList) {
                            $actions += $currentAction.Clone()
                        }
                    }
                    # When CU# is specified, but ignore CU0 and trigger only when CU is in Type
                    if ($null -ne $cuV -and $cuV -ne '0' -and 'CumulativeUpdate' -in $typeList) {
                        $actions += $currentAction.Clone() + @{ CumulativeUpdate = $cuV }
                    }
                } else {
                    Stop-Function -Category InvalidArgument -Message "$ver is an incorrect Version value, please refer to Get-Help Update-DbaInstance -Parameter Version"
                    return
                }
            }
            # If no version specified, simply apply latest $currentType
            if (!$Version) {
                foreach ($currentType in $typeList) {
                    $currentAction = $actionTemplate.Clone() + @{
                        Type = $currentType
                    }
                    $actions += $currentAction
                }
            }
        } elseif ($PSCmdlet.ParameterSetName -eq 'KB') {
            foreach ($kbItem in $kbList) {
                $currentAction = $actionTemplate.Clone() + @{
                    KB = $kbItem
                }
                $actions += $currentAction
            }
        }
        # debug message
        foreach ($a in $actions) {
            Write-Message -Level Debug -Message "Added installation action $($a | ConvertTo-Json -Depth 1 -Compress)"
        }
        # defining how to process the final results
        $outputHandler = {
            $_ | Select-DefaultView -Property ComputerName, MajorVersion, TargetLevel, KB, Successful, Restarted, InstanceName, Installer, Message
            if ($_.Successful -eq $false) {
                Write-Message -Level Warning -Message $_.$message
            }
        }
    }
    process {
        if (Test-FunctionInterrupt) { return }

        #Resolve all the provided names
        $resolvedComputers = @()
        foreach ($computer in $ComputerName) {
            $null = Test-ElevationRequirement -ComputerName $computer -Continue
            if ($resolvedComputer = Resolve-DbaNetworkName -ComputerName $computer.ComputerName) {
                $resolvedComputers += $resolvedComputer.FullComputerName
            }
        }
        #Leave only unique computer names
        $resolvedComputers = $resolvedComputers | Sort-Object -Unique
        #Process planned actions and gather installation actions
        $installActions = @()
        :computers foreach ($resolvedName in $resolvedComputers) {
            $activity = "Preparing to update SQL Server on $resolvedName"
            ## Find the current version on the computer
            Write-ProgressHelper -ExcludePercent -Activity $activity -StepNumber 0 -Message "Gathering all SQL Server instance versions"
            $components = Get-SQLInstanceComponent -ComputerName $resolvedName -Credential $Credential
            if (!$components) {
                Stop-Function -Message "No SQL Server installations found on $resolvedName" -Continue
            }
            Write-Message -Level Debug -Message "Found $(($components | Measure-Object).Count) existing SQL Server instance components: $(($components | Foreach-Object { "$($_.InstanceName)($($_.InstanceType))" }) -join ',')"
            # Filter for specific instance name
            if ($InstanceName) {
                $components = $components | Where-Object {$_.InstanceName -eq $InstanceName }
            }
            $upgrades = @()
            :actions foreach ($currentAction in $actions) {
                if (Test-PendingReboot -ComputerName $resolvedName) {
                    #Exit the actions loop altogether - nothing can be installed here anyways
                    Stop-Function -Message "$resolvedName is pending a reboot. Reboot the computer before proceeding." -Continue -ContinueLabel computers
                }
                # Pass only relevant components
                if ($currentAction.MajorVersion) {
                    $components = $components | Where-Object { $_.Version.NameLevel -in $currentAction.MajorVersion }
                    $currentAction.Remove('MajorVersion')
                }
                Write-ProgressHelper -ExcludePercent -Activity $activity -Message "Looking for a KB file for a chosen version"
                Write-Message -Level Verbose -Message "Looking for appropriate KB file on $resolvedName with following params: $($currentAction | ConvertTo-Json -Depth 1 -Compress)"
                $upgradeDetails = Get-SqlServerUpdate @currentAction -ComputerName $resolvedName -Credential $Credential -Restart $Restart -Path $Path -Component $components
                if ($upgradeDetails.Successful -contains $false) {
                    #Exit the actions loop altogether - upgrade cannot be performed
                    $upgradeDetails
                    Stop-Function -Message "Update cannot be applied to $resolvedName | $($upgradeDetails.Message)" -Continue -ContinueLabel computers
                } else {
                    # update components to mirror the updated version - will be used for multi-step upgrades
                    foreach ($component in $components) {
                        if ($component.Version.NameLevel -in $upgradeDetails.TargetVersion.NameLevel) {
                            $component.Version = $upgradeDetails.TargetVersion | Where-Object NameLevel -eq $component.Version.NameLevel
                        }
                    }
                    $upgrades += $upgradeDetails
                }
            }
            if ($upgrades) {
                Write-ProgressHelper -ExcludePercent -Activity $activity -Message "Preparing installation"
                $chosenVersions = ($upgrades | ForEach-Object { "$($_.MajorVersion) to $($_.TargetLevel) ($($_.KB))" }) -join ', '
                if ($PSCmdlet.ShouldProcess($resolvedName, "Update $chosenVersions")) {
                    $installActions += [pscustomobject]@{
                        ComputerName = $resolvedName
                        Actions      = $upgrades
                    }
                } else {
                    $whatIfMode = $true
                }
            }
            Write-Progress -Activity $activity -Completed
        }
        # Declare the installation script
        $installScript = {
            $computer = $_.ComputerName
            Write-Message -Level Debug -Message "Processing $($computer) with $(($_.Actions | Measure-Object).Count) actions" -FunctionName Update-DbaInstance
            $activity = "Updating SQL Server components on $computer"
            #foreach action passed to the script for this particular computer
            foreach ($currentAction in $_.Actions) {
                $output = $currentAction
                $output.Successful = $false
                ## Start the installation sequence
                Write-ProgressHelper -ExcludePercent -Activity $activity -Message "Launching installation of $($currentAction.TargetLevel) KB$($currentAction.KB) ($($currentAction.Installer)) for SQL$($currentAction.MajorVersion) ($($currentAction.Build))"
                $execParams = @{
                    ComputerName = $computer
                    ErrorAction  = 'Stop'
                }
                if ($Credential) { $execParams += @{ Credential = $Credential }
                }
                # Find a temporary folder to extract to - the drive that has most free space
                $chosenDrive = (Get-DbaDiskSpace -ComputerName $computer -Credential $Credential | Sort-Object -Property Free -Descending | Select-Object -First 1).Name
                if (!$chosenDrive) {
                    # Fall back to the system drive
                    $chosenDrive = Invoke-Command2 -ComputerName $computer -Credential $Credential -ScriptBlock { $env:SystemDrive } -Raw -ErrorAction Stop
                }
                $spExtractPath = $chosenDrive.TrimEnd('\') + "\dbatools_KB$($currentAction.KB)_Extract"
                if ($spExtractPath) {
                    $output.ExtractPath = $spExtractPath
                    try {
                        # Extract file
                        Write-ProgressHelper -ExcludePercent -Activity $activity -Message "Extracting $($currentAction.Installer) to $spExtractPath"
                        Write-Message -Level Verbose -Message "Extracting $($currentAction.Installer) to $spExtractPath" -FunctionName Update-DbaInstance
                        $extractResult = Invoke-Program @execParams -Path $currentAction.Installer -ArgumentList "/x`:`"$spExtractPath`" /quiet" -EnableException $true
                        if (-not $extractResult.Successful) {
                            $output.Message = "Extraction failed with exit code $($extractResult.ExitCode)"
                            Stop-Function -Message $output.Message -FunctionName Update-DbaInstance
                            return $output
                        }
                        # Install the patch
                        if ($currentAction.InstanceName) {
                            $instanceClause = "/instancename=$($currentAction.InstanceName)"
                        } else {
                            $instanceClause = '/allinstances'
                        }
                        Write-ProgressHelper -ExcludePercent -Activity $activity -Message "Now installing update SQL$($currentAction.MajorVersion)$($currentAction.TargetLevel) from $spExtractPath"
                        Write-Message -Level Verbose -Message "Starting installation from $spExtractPath" -FunctionName Update-DbaInstance
                        $updateResult = Invoke-Program @execParams -Path "$spExtractPath\setup.exe" -ArgumentList @('/quiet', $instanceClause, '/IAcceptSQLServerLicenseTerms') -WorkingDirectory $spExtractPath -EnableException $true
                        if ($updateResult.Successful) {
                            $output.Successful = $true
                        } else {
                            $output.Message = "Update failed with exit code $($updateResult.ExitCode)"
                            Stop-Function -Message $output.Message -FunctionName Update-DbaInstance
                            return $output
                        }
                        $output.Log = $updateResult.stdout
                    } catch {
                        Stop-Function -Message "Upgrade failed" -ErrorRecord $_ -FunctionName Update-DbaInstance
                        $output.Message = $_.Exception.Message
                        return $output
                    } finally {
                        ## Cleanup temp
                        Write-ProgressHelper -ExcludePercent -Activity $activity -Message "Cleaning up extracted files from $spExtractPath"
                        try {
                            Write-ProgressHelper -ExcludePercent -Activity $activity -Message "Removing temporary files"
                            $null = Invoke-Command2 @execParams -ScriptBlock {
                                if ($args[0] -like '*\dbatools_KB*_Extract' -and (Test-Path $args[0])) {
                                    Remove-Item -Recurse -Force -LiteralPath $args[0] -ErrorAction Stop
                                }
                            } -Raw -ArgumentList $spExtractPath
                        } catch {
                            $message = "Failed to cleanup temp folder on computer $($computer)`: $($_.Exception.Message)"
                            Write-Message -Level Verbose -Message $message -FunctionName Update-DbaInstance
                            $output.Message += $message
                        }
                    }
                }
                if ($Restart) {
                    # Restart the computer
                    Write-ProgressHelper -ExcludePercent -Activity $activity -Message "Restarting computer $($computer) and waiting for it to come back online"
                    Write-Message -Level Verbose "Restarting computer $($computer) and waiting for it to come back online" -FunctionName Update-DbaInstance
                    try {
                        $null = Restart-Computer @execParams -Wait -For WinRm -Force
                        $output.Restarted = $true
                    } catch {
                        Stop-Function -Message "Failed to restart computer" -ErrorRecord $_ -FunctionName Update-DbaInstance
                        return $output
                    }
                } else {
                    $output.Message = "Restart is required for computer $($computer) to finish the installation of SQL$($currentAction.MajorVersion)$($currentAction.TargetLevel)"
                }
                $output
                Write-Progress -Activity $activity -Completed
            }
        }
        # check how many computers we are looking at and decide upon parallelism
        if ($installActions.Count -eq 1) {
            $installActions | ForEach-Object -Process $installScript | ForEach-Object -Process $outputHandler
        } elseif ($installActions.Count -ge 2) {
            $installActions | Invoke-Parallel -ImportModules -ImportVariables -ScriptBlock $installScript -Throttle $Throttle | ForEach-Object -Process $outputHandler
        } elseif (-not $whatIfMode) {
            Write-Message -Level Warning -Message "No applicable updates were found"
        }
    }
}