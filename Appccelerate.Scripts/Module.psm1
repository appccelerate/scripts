. "$PSScriptRoot\Common.ps1"

function GetStatus
{
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [ValidateSet("all")]
        [string[]]
        $Repositories="All"
    )
    
    Begin {
        $status = @()
    }

    Process {
        $repos = ResolveRepos $Repositories "GetStatus"

        Write-HeaderMessage "checking status..."

        foreach ($repo in $repos)
        {
            Write-Message "checking $repo"
            git -C "$SharedRepoRoot\$repo" fetch origin | Out-Null 

            $localchanges = git -C "$SharedRepoRoot\$repo" status --porcelain
            $ahead = git -C "$SharedRepoRoot\$repo" rev-list origin/master..master --count
            $behind = git -C "$SharedRepoRoot\$repo" rev-list master..origin/master --count
            
            $info = @{}
            $info.Repo = $repo
            $info.Modified = @{$true="modified"}[$localchanges.Length -gt 0]
            $info.Ahead = @{$true=$ahead}[$ahead -gt 0] 
            $info.Behind = @{$true=$behind}[$behind -gt 0] 
            $object = New-Object –TypeName PSObject –Prop $info
            
            $status += $object
        }        
    }
    
    End {
        Write-Output $status | Format-Table -Property Repo,Behind,Ahead,Modified -AutoSize
    }
}

function Pull {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [ValidateSet("all")]
        [string[]]
        $Repositories="All"
    )
    
    Begin {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $startTime = Get-Date
    }

    Process {
        Write-HeaderMessage "pulling"

        $repos = ResolveRepos $Repositories "Pull"

        foreach ($repo in $repos)
        {
            Write-Message "pulling $repo"
            Exec { git -C "$SharedRepoRoot\$repo" pull -n }
        }        
    }
    
    End {
        $sw.Stop()
        $endTime = Get-Date
        $elapsed = $sw.Elapsed

        Write-HeaderSuccess "PULL SUCCESSFUL"
        Write-Message " Start: $startTime"
        Write-Message " End:   $endTime"
        Write-Message " Took:  $elapsed"
    }
}

function CheckNugetDependenciesForConflictingVersions
{
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [ValidateSet("all")]
        [string[]]
        $Repositories="All",

        [Parameter()]
        [Switch]$skipDevelopmentDependencies
    )

    Begin {        
        $packages = @()
    }

    Process {
        $repos = ResolveRepos $Repositories "CheckNugetDependenciesForConflictingVersions"

        ForEach ($repo in $repos) {
            Write-HeaderMessage "Processing $repo"
            
            
            Get-ChildItem "$SharedRepoRoot\$repo" -Recurse -Filter "packages.config" | %{
                $projectName = $_.Directory.Name
                Write-Message "Processing $projectName"
                    
                [xml]$config = Get-Content $_.Fullname
                $config.packages.package | %{
                    $info = @{}
                    $info.Id = $_.id
                    $info.Version = $_.version
                    $info.DevelopmentDependency = if ($_.developmentDependency -eq $null) { "false" } else { $_.developmentDependency.ToString() }
                    $info.ReferencingProject = "$repo.$projectName"
                    $object = New-Object –TypeName PSObject –Prop $info
                    
                    $packages += $object
                }
            }
        }
    }

    End {
        Write-Output $packages

        if ($skipDevelopmentDependencies)
        {
            $packagesGroupedById = $packages | ?{ $_.DevelopmentDependency -ne "true" } | Sort Id,Version -Unique | Group Id
        }
        else
        {
            $packagesGroupedById = $packages | Sort Id,Version -Unique | Group Id
        }

        $conflictingPackages = $packagesGroupedById | ?{ $_.Count -gt 1 } | %{$_.Name}

        if($conflictingPackages.Count -gt 0)
        {
            Write-HeaderError "Conflicts found"
            $packages | ?{ $conflictingPackages -contains $_.Id } | Sort Id,Version,ReferencingProject | Format-Table -AutoSize -Property Version,ReferencingProject,DevelopmentDependency -GroupBy Id
            Write-HeaderError "Conflicts found"
        }
        else
        {
            Write-HeaderSuccess "No conflicts found"
        }
    }
}

function UpdatePackage
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=1)]
        [string]
        $Id,

        [Parameter()]
        [ValidateSet("all")]
        [string[]]
        $Repositories="all",

        [Parameter()]
        [string]
        $Source="https://www.nuget.org/api/v2;https://www.myget.org/F/appccelerate/"
    )

    $repos = ResolveRepos $Repositories "UpdatePackage"

    foreach ($repo in $repos)
    {
        Write-HeaderMessage "Updating $repo"
        
        $sourceDir = "$SharedRepoRoot\$repo\source"
        
        Get-ChildItem -Path $sourceDir -Filter packages.config -Recurse | %{
            $configFilePath = $_.FullName
            
            [xml]$configFile = Get-Content $configFilePath
            
            $packagesToUpdate = @()
            
            $configFile.packages.package | ? {$_.Id -like $Id} | %{
                $packageToUpdate = $_.Id
                
                if (($packagesToUpdate -notcontains  $packageToUpdate) -eq $true)
                {
                    $packagesToUpdate += $packageToUpdate.Trim()
                }
            }
            
            if ($packagesToUpdate.length -gt 0) {
                $packagesToUpdateOneLine = $packagesToUpdate -join ";" | Out-String
                $packagesToUpdateOneLine = $packagesToUpdateOneLine.Trim()
                
                Write-Message "Restoring packages: $configFilePath"
                Exec { nuget restore $configFilePath -SolutionDirectory $sourceDir }

                Write-Message "Updating packages: $configFilePath"
                Write-Message "  $packagesToUpdateOneLine"
                Exec { nuget update $configFilePath -Source "$Source" -Id "$packagesToUpdateOneLine" -NonInteractive -Verbose -Verbosity detailed }
            }
        }
    }
}

function UpdateLocally
{
    [CmdletBinding()]
    param(
      [Parameter(Mandatory=1)]
      [ValidateSet("?")]
      [string]$SourceRepo,

      [Parameter()]
      [ValidateSet("all")]
      [string[]]$Repositories="all",

      [Parameter()]
      [Switch]$skipAppccelerateVersionInstallation
    )

    $repo = "$SharedRepoRoot\$SourceRepo"
    $settings = $repoSettings[$SourceRepo]

    $solutionFile = "$SharedRepoRoot\$SourceRepo\source\Appccelerate.$SourceRepo.sln"
    $packageId = "Appccelerate.$SourceRepo"
    
    $nugetPackagesFolder = "$SharedRepoRoot\NugetPackages"

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $startTime = Get-Date

    $version = GetVersion $repo $skipAppccelerateVersionInstallation
    if ($version.IndexOf('-') -gt 0)
    {
        $versionPrefix = $version.Substring(0, $version.IndexOf('-'))
    }
    else
    {
        $versionPrefix = $version;
    }

    # find largest local version
    Write-Message "determining largest local package version"

    if (!(Test-Path $nugetPackagesFolder)) { New-Item $nugetPackagesFolder -type directory | Out-Null }

    $packages = Get-ChildItem -Path $nugetPackagesFolder | ?{ $_.Name -Like ($packageId + '.' + $versionPrefix + '-local*') }

    $max = 0
    foreach ($p in $packages)
    {
        $number = [int]$p.Name.SubString($p.Name.IndexOf('-') + 6, 4)
        
        if ($max -lt $number)
        {
            $max = $number
        }
    }

    # create new local version
    $localVersion = $versionPrefix + "-local" + ($max + 1).ToString("0000");

    Write-Message "version = $version"
    Write-Message "local version = $localVersion"

    ############################################
    ## Build nuget packages
    CreateLocalNugetPackages $SourceRepo $nugetPackagesFolder -skipAppccelerateVersionInstallation 


    ############################################
    ## update repos
    Write-HeaderMessage "Updating solutions with local package"
    
    $repos = ResolveRepos $Repositories "UpdateLocally"

    UpdatePackage -Id $packageId -Repositories $repos -Source $nugetPackagesFolder 

    ############################################
    ## Extro

    $sw.Stop()
    $endTime = Get-Date
    $elapsed = $sw.Elapsed
    
    Write-HeaderSuccess "SUCCESSFUL"
    Write-Message " Start: $startTime"
    Write-Message " End:   $endTime"
    Write-Message " Took:  $elapsed" 
}

# kind of experimental :-)
function GetNugetDependencyChains
{
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [ValidateSet("all")]
        [string[]]
        $Repositories="All",

        [Parameter()]
        [Switch]$skipDevelopmentDependencies
    )

    Begin {        
        $packageReferences = @()                
    }

    Process {
        $repos = ResolveRepos $Repositories "GetNugetDependencyChains"

        ForEach ($repo in $repos) {
            Write-HeaderMessage "Processing $repo"
            
            
            Get-ChildItem "$SharedRepoRoot\$repo" -Recurse -Filter "packages.config" | %{
                $projectName = $_.Directory.Name
                Write-Message "Processing $projectName"
                    
                [xml]$config = Get-Content $_.Fullname
                $config.packages.package | %{
                    $info = @{}
                    $info.ReferencingProject = "$projectName"
                    $info.ReferencedId = $_.id
                    $info.DevelopmentDependency = if ($_.developmentDependency -eq $null) { "false" } else { $_.developmentDependency.ToString() }
                    
                    $object = New-Object –TypeName PSObject –Prop $info
                    
                    $packageReferences += $object
                }
            }
        }
    }

    End {
        Write-Host $packageReferences

        if ($skipDevelopmentDependencies)
        {
            $packageReferences = $packageReferences | ?{ $_.DevelopmentDependency -ne "true" }
        }
        

        $packages = @()

        foreach ($package in $packageReferences)
        {
            if (!($packages -contains $package.ReferencingProject))
            {
                $packages += $package.ReferencingProject
            }

            if (!($packages -contains $package.ReferencedId))
            {
                $packages += $package.ReferencedId
            }
        }


        foreach ($package in $packages)
        {
            $i = [array]::indexof($packages, $package) + 1
            Write-Output  "$i $package"
        }
        Write-Output "#"
        foreach ($packageReference in $packageReferences)
        {
            $i = [array]::indexof($packages, $packageReference.ReferencingProject) + 1
            $j = [array]::indexof($packages, $packageReference.ReferencedId) + 1
            Write-Output "$i $j"            
        }
    }
}

function CreateLocalNugetPackages
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=1)]
        [ValidateSet("all")]
        [string[]]$Repositories="All",
        [Parameter()]
        [string]$outputDirectory="$SharedRepoRoot\NugetPackages",
        [Parameter()]
        [switch]$skipAppccelerateVersionInstallation,
        [Parameter()]
        [switch]$skipIntegrate
    )

    $repos = ResolveRepos $Repositories "CreateLocalNugetPackages"

    if (!(Test-Path $outputDirectory -PathType Container)) { New-Item -ItemType directory -Path $outputDirectory | out-Null }

    foreach ($repo in $repos)
    {
        Write-HeaderMessage "Creating nuget package(s) in $repo"

        if (!($skipIntegrate))
        {
            BuildSolution -repo $repo -solution "Appccelerate.$repo.sln"
        }

        $version = GetVersion $repo $skipAppccelerateVersionInstallation
    
        $nuspecs = Get-ChildItem -Recurse "$SharedRepoRoot\$repo\source\" -Include appccelerate*.nuspec
        foreach ($nuspec in $nuspecs)
        {
            $path = $nuspec.FullName
            Write-Message "creating package for $path"
            Write-Message "nuget pack $path -OutputDirectory $outputDirectory -Version $version"
            Exec { & nuget pack $path -OutputDirectory $outputDirectory -Version $version }
        }
    }
}

function WaitForNugetPackageUpdateOnMyGet
{
    param(
        [Parameter(Mandatory=1)]
        [ValidateSet("?")]
        [string]
        $Repository
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $startTime = Get-Date

    $myget = "https://www.myget.org/F/appccelerate/"

    Write-Message "Getting current version of Appccelerate.$Repository NuGet package from MyGet"
    
    $packagesInFeed = nuget list "Appccelerate.$Repository" -Source $myget -Prerelease | ?{ $_ -notlike 'Using credentials*' } | %{
            $parts = $_.Split(' ')
            $info = @{}
            $info.Id = $parts[0]
            $info.Version = $parts[1]
            New-Object –TypeName PSObject –Prop $info
        }

    $currentVersion = $packagesInFeed[0].Version.ToString()

    Write-Message "Found current version of Appccelerate.$Repository NuGet package on MyGet: $currentVersion"

    do
    {
        Start-Sleep -Seconds 10
        Write-Message "Checking for new version of Appccelerate.$Repository NuGet package on MyGet"
    
        $packagesInFeed = nuget list "Appccelerate.$Repository" -Source $myget -Prerelease | ?{ $_ -notlike 'Using credentials*' } | %{
            $parts = $_.Split(' ')
            $info = @{}
            $info.Id = $parts[0]
            $info.Version = $parts[1]
            New-Object –TypeName PSObject –Prop $info
        }

        $newVersion = $packagesInFeed[0].Version.ToString()
    }
    while ($currentVersion -eq $newVersion)
        
    $sw.Stop()
    $endTime = Get-Date
    $elapsed = $sw.Elapsed
    
    Write-Message "Found new version of Appccelerate.$Repository NuGet package on MyGet: $newVersion"
    Write-Message " Start: $startTime"
    Write-Message " End:   $endTime"
    Write-Message " Took:  $elapsed" 
}

function InstallGitHooks
{
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [ValidateSet("all")]
        [string[]]
        $Repositories="all"
    )

    Begin {
        $hooksSourceDirectory = "$SharedRepoRoot\scripts\hooks"
        $processedRepos = @()
    }

    Process {
        $repos = ResolveRepos $Repositories "InstallGitHooks"

        ForEach ($repo in $repos) {
            Write-HeaderMessage "Installing git hooks in $repo"
            
            $hooksDestinationDirectory = "$SharedRepoRoot\$repo\.git\hooks"
            if (Test-Path $hooksDestinationDirectory) {
                Copy-Item "$hooksSourceDirectory\*" $hooksDestinationDirectory

                $processedRepos += $repo
            }
        }
    }

    End {
        Write-HeaderSuccess "SUCCESSFUL"
        Write-Output $processedRepos
    }
}

$repositories = @(
    "bootstrapper",
    "CheckHintPathTask",
    "CheckNoBindingRedirectsTask",
    "CheckNugetDependenciesTask",
    "CheckTestFixtureAttributeSetTask",
    "distributedeventbroker",
    "distributedeventbroker.masstransit",
    "distributedeventbroker.nservicebus",
    "evaluationengine",
    "eventbroker",
    "fundamentals",
    "io",
    "mappingeventbroker",
    "mappingeventbroker.automapper",
    "scopingeventbroker",
    "statemachine",
    "Version"
)

Update-ValidateSet (Get-Command -Name "GetStatus") "Repositories" ($repositories + @("all"))
Update-ValidateSet (Get-Command -Name "Pull") "Repositories" ($repositories + @("all"))
Update-ValidateSet (Get-Command -Name "CheckNugetDependenciesForConflictingVersions") "Repositories" ($repositories + @("all"))
Update-ValidateSet (Get-Command -Name "GetNugetDependencyChains") "Repositories" ($repositories + @("all"))
Update-ValidateSet (Get-Command -Name "UpdatePackage") "Repositories" ($repositories + @("all"))
Update-ValidateSet (Get-Command -Name "CreateLocalNugetPackages") "Repositories" ($repositories + @("all"))
Update-ValidateSet (Get-Command -Name "UpdateLocally") "Repositories" ($repositories + @("all"))
Update-ValidateSet (Get-Command -Name "UpdateLocally") "SourceRepo" ($repositories)
Update-ValidateSet (Get-Command -Name "WaitForNugetPackageUpdateOnMyGet") "Repository" ($repositories)
Update-ValidateSet (Get-Command -Name "InstallGitHooks") "Repositories" ($repositories + @("all"))