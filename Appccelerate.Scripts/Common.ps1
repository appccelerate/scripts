$global:SharedRepoRoot = Resolve-Path ("$PSScriptRoot\..\..")

function ResolveRepos($repos, $cmdName)
{
    Return ResolveValidateSet $repos $cmdName "Repositories"
}

function ResolveValidateSet($Value, $CmdName, $ParameterName)
{
    if($Value -contains "all" )
    {
        $Command = Get-Command -Name $CmdName

        #Find the parameter on the command object
        $Parameter = $Command.Parameters[$ParameterName]
        if($Parameter) {
            #Find all of the ValidateSet attributes on the parameter
            $ValidateSetAttributes = @($Parameter.Attributes | Where-Object {$_ -is [System.Management.Automation.ValidateSetAttribute]})
            if($ValidateSetAttributes) {
                #Get the validValues private member of the ValidateSetAttribute class
                $ValidValuesField = [System.Management.Automation.ValidateSetAttribute].GetField("validValues", [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
                $validValues = [System.String[]]$ValidValuesField.GetValue($ValidateSetAttributes[0])
            
            
                $validRepos = @()
                foreach($validValue in $validValues)
                {
                    if($validValue.ToLowerInvariant() -ne "all")
                    {
                        $validRepos += $validValue
                    }
                }

                Return $validRepos
            } else {
                Write-Error -Message "Parameter $ParameterName in command $Command doesn't use [ValidateSet()]"
            }
        } else {
            Write-Error -Message "Parameter $ParameterName was not found in command $Command"
        }
    }
    else
    {
        Return $Value
    }
}

function Exec
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=1)]
        [scriptblock]$cmd,

        [Parameter(Mandatory=0)]
        [Switch]
        $DirectOutput
    )

    if($DirectOutput.IsPresent)
    {
        Invoke-Command $cmd
    }
    else
    {
        Invoke-Command $cmd | Out-HostColored
    }

    if ($lastexitcode -ne 0)
    {
        Write-HeaderError "ERRORS OCCURED"
        throw ("Exec finished with return code: " + $lastexitcode)
    }
}

function Out-HostColored
{
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$True)]
        [string]$msg
    )

    Begin {
        $errorRegex = (".*Test Failure.*", ".*(FAIL).*", ".*error MSB.*:.*", ".*error CS.*:.*") -join "|";
        $stylecopRegex = (".*error : SA.*") -join "|";
        $warningRegex = (".*warning :.*") -join "|";
    }

    Process {
        if($msg -cmatch $errorRegex)
        {
            Write-Host $msg -ForegroundColor Red
        }
        elseif($msg -cmatch $stylecopRegex)
        {
            Write-Host $msg -ForegroundColor Magenta
        }
        elseif($msg -cmatch $warningRegex)
        {
            Write-Host $msg -ForegroundColor Yellow
        }
        else
        {
            Write-Host $msg
        }
    }
}

function Write-HeaderSuccess
{
    [CmdletBinding()]
    param(
        [Parameter(Position=0,Mandatory=1)][string]$message
    )
    
    Write-Host "   $message   " -BackgroundColor Green -ForegroundColor Blue
}

function Write-HeaderError
{
    [CmdletBinding()]
    param(
        [Parameter(Position=0,Mandatory=1)][string]$message
    )
    
    Write-Host "   $message   " -BackgroundColor Red -ForegroundColor White 
}

function Write-HeaderMessage
{
    [CmdletBinding()]
    param(
        [Parameter(Position=0,Mandatory=1)][string]$message
    )
    
    Write-Host "   $message   " -BackgroundColor Cyan -ForegroundColor Black 
}

function Write-Message
{
    [CmdletBinding()]
    param(
        [Parameter(Position=0,Mandatory=1)][string]$message
    )
    
    Write-Host $message -ForegroundColor Cyan 
}

function BuildSolution
{
    [CmdletBinding()]
    param(
        [string]$repo,
        [string]$solution,      
        [string]$target="Rebuild"
    )
    
    $solutionFilePath = "$SharedRepoRoot\$repo\source\$solution"
    
    Write-HeaderMessage "Restoring packages in solution: $solution"
    Exec { nuget restore $solutionFilePath }
        
    Write-HeaderMessage "Integrating $repo"
    Exec { msbuild $solutionFilePath /p:Configuration=Release /target:$target /verbosity:minimal }        
}

function GetVersion
{
    [CmdletBinding()]
    param(
        [string]$repo,
        [bool]$skipAppccelerateVersionInstallation
    )

    Write-HeaderMessage "Determining version"

    if (!$skipAppccelerateVersionInstallation)
    {
        Write-HeaderMessage "Installing Appccelerate.Version"
        Exec { nuget install Appccelerate.Version -OutputDirectory $env:TEMP\Appccelerate.Version }
    }

    # find path to latest Appccelerate.Version (with natural number sorting, up to 20 digits)
    $NaturalSort = { [regex]::Replace($_.FullName, '\d+', { $args[0].Value.PadLeft(20, "0") }) }
    $latestVersion = Get-ChildItem -Path $env:TEMP\Appccelerate.Version -Recurse -Filter Appccelerate.Version.exe | Sort-Object $NaturalSort | Select-Object -Last 1

    if ($latestVersion -is [io.fileinfo])
    {
        $versionExe = $latestVersion.FullName
        Write-Message "Using $versionExe"
    }
    else
    {
      throw "Cannot find path of Appccelerate.Version.exe"
    }

    # Determine version
    $version_output = Exec { & $versionExe $repo } -DirectOutput
    $version = $version_output[2].ToString().Replace('"', "").Replace(",", "").Replace("NugetVersion: ", "")  # output is NugetVersion: <version>   e.g. "NugetVersion": "2.5.0",

    return $version
}

<#
   .SYNOPSIS
    Replace the set of valid values on a function parameter that was defined using ValidateSet.

  .DESCRIPTION
    Replace the set of valid values on a function parameter that was defined using ValidateSet.

  .PARAMETER Command
    A FunctionInfo object for the command that has the parameter validation to be updated.  Get this using:

    Get-Command -Name YourCommandName

  .PARAMETER ParameterName
    The name of the parameter that is using ValidateSet.

  .PARAMETER  NewSet
    The new set of valid values to use for parameter validation.

  .EXAMPLE
    Define a test function:

    PS> Function Test-Function {
      param(
        [ValidateSet("one")]
        $P
      )
    }

    PS> Update-ValidateSet -Command (Get-Command Test-Function) -ParameterName "P" -NewSet @("one","two")

    After running Update-ValidateSet, Test-Function will accept the values "one" and "two" as valid input for the -P parameter.

  .OUTPUTS
    Nothing

  .NOTES
    This function is updating a private member of ValidateSetAttribute and is thus not following the rules of .Net and could break at any time.  Use at your own risk!

    Author : Chris Duck

  .LINK
    http://blog.whatsupduck.net/2013/05/hacking-validateset.html
#>
function Update-ValidateSet {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [System.Management.Automation.FunctionInfo]$Command,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$ParameterName,

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [String[]]$NewSet
  )

  #Find the parameter on the command object
  $Parameter = $Command.Parameters[$ParameterName]
  if($Parameter) {
    #Find all of the ValidateSet attributes on the parameter
    $ValidateSetAttributes = @($Parameter.Attributes | Where-Object {$_ -is [System.Management.Automation.ValidateSetAttribute]})
    if($ValidateSetAttributes) {
      $ValidateSetAttributes | ForEach-Object {
        #Get the validValues private member of the ValidateSetAttribute class
        $ValidValuesField = [System.Management.Automation.ValidateSetAttribute].GetField("validValues", [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
        if($PsCmdlet.ShouldProcess("$Command -$ParameterName", "Set valid set to: $($NewSet -join ', ')")) {
          #Update the validValues array on each instance of ValidateSetAttribute
          $ValidValuesField.SetValue($_, $NewSet)
        }
      }
    } else {
      Write-Error -Message "Parameter $ParameterName in command $Command doesn't use [ValidateSet()]"
    }
  } else {
    Write-Error -Message "Parameter $ParameterName was not found in command $Command"
  }
}