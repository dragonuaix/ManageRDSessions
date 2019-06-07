#Requires -RunAsAdministrator
function Get-sbRDSession {
    [OutputType('Custom.SB.RDSession')]
    [cmdletbinding(DefaultParameterSetName = 'State')]
    param(
        [Parameter(Mandatory = $false, ParameterSetName = 'State')]
        [ValidateSet("Active", "Idle", "Connected", "Disconnected", "Any")]
        [Alias("State")]
        [string]$SessionState = "Any",

        # Switch to choose to include self - as we probably don't want to disconnect/logoff our own session, but
        # might want to test a message as an example - however, using the UserName parameter will allow current
        # user to be returned - which makes sense to me
        [Parameter(Mandatory = $false, ParameterSetName = 'State')]
        [Alias("Self")]
        [switch]$IncludeSelf = $false,

        [Parameter(Mandatory = $false, ParameterSetName = 'State')]
        [int]$MinimumIdleMins = 0,

        [Parameter(Mandatory = $false, ParameterSetName = 'UserName')]
        [Alias("Name")]
        [string]$UserName = $null
    )

    Begin {
        #Intentionally empty
    }

    # Process block is required when outputting objects to the pipeline, otherwise only the final object will be passed
    Process {
        # Variable Substitution alternative to Switch - suggested by Adam. Love this. It will convert whatever
        # is passed after $stateLookup. into the value on the right.
        $stateLookup = @{
            Active       = "STATE_ACTIVE"
            Idle         = "STATE_IDLE"
            Disconnected = "STATE_DISCONNECTED"
            Connected    = "STATE_CONNECTED"
            Any          = "*"
        }

        if ($UserName) {
            Write-Verbose "Querying RD Session Collection for users like [$UserName]"
            $sessions = Get-RDUserSession | Where-Object {
                $_.UserName -like "*$UserName*"
            }
        } else {
            if ($IncludeSelf) {
                Write-Verbose "Querying RD Session Collection for [$SessionState] sessions - including [$env:USERNAME]"
                $sessions = Get-RDUserSession | Where-Object {
                    $_.SessionState -like $stateLookup.$SessionState`
                        -and ( $_.IdleTime / 60000 ) -ge $MinimumIdleMins`
                }
            } else {
                Write-Verbose "Querying RD Session Collection for [$SessionState] sessions"
                $sessions = Get-RDUserSession | Where-Object {
                    $_.SessionState -like $stateLookup.$SessionState`
                        -and ( $_.IdleTime / 60000 ) -ge $MinimumIdleMins`
                        -and $_.UserName -notlike "*$env:USERNAME*"
                }
            }
        } #if IncludeSelf


        foreach ($session in $sessions) {
            # Creating and Outputting PSCustomObject
            [PSCustomObject]@{
                PSTypeName       = "Custom.SB.RDSession"
                HostServer       = $session.HostServer
                UserName         = $session.UserName
                UnifiedSessionID = $session.UnifiedSessionID
                SessionState     = $session.SessionState
                IdleTime         = ($session.IdleTime / 60000 -as [int])
            }
        }
    } #process

    End {
        #Intentionally empty
    }
} #function

function Disconnect-sbRDSession {

    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param (
        # Accepting Pipeline ByValue and requiring custom Type - also added [Object[]] to make an array, because this,
        # when supported by a ForEach block in the receiving Function's Process block, will allow someone to output
        # the objects to a variable, then pass that variable in to the receiving function.
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSTypeName("Custom.SB.RDSession")][Object[]]$RDSession
    )

    Begin {
        # Intentionally empty
    }
    # Process block is required when receiving objects from the pipeline, otherwise only last object will be received
    Process {
        # ForEach needed in order to process an array of objects passed in as a variable, as opposed to the Pipeline which feeds objects individually
        foreach ( $session in $RDSession ) {
            if ($PSCmdlet.ShouldProcess("RDUser: [$($session.Username)] with Session ID [$($session.UnifiedSessionID)]", "Disconnect")) {

                $params = @{
                    'HostServer'       = $session.HostServer
                    'UnifiedSessionID' = $session.UnifiedSessionID
                    'ErrorAction'      = 'Stop'
                    'Force'            = $true
                }

                Write-Verbose "Attempting Disconnect of $($session.Username) on $($session.HostServer)"
                Disconnect-RDUser @params
                Write-Host "User [$($session.Username)] Disconnected from [$($session.HostServer)]"
            } #shouldprocess

        } #foreach
    } #Process

    End {
        # Intentionally empty
    }
} #function

function Remove-sbRDSession {

    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param (
        # Accepting Pipeline ByValue and requiring custom Type - also added [Object[]] to make an array, because this,
        # when supported by a ForEach block in the receiving Function's Process block, will allow someone to output
        # the objects to a variable, then pass that variable in to the receiving function.
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSTypeName("Custom.SB.RDSession")][Object[]]$RDSession,
        [Parameter(Mandatory = $false)]
        [switch]$AsJob
    )

    Begin {
        # Intentionally empty
    }
    # Process block is required when receiving objects from the pipeline, otherwise only last object will be received
    Process {
        # ForEach needed in order to process an array of objects passed in as a variable, as opposed to the Pipeline which feeds objects individually
        foreach ( $session in $RDSession ) {
            if ($PSCmdlet.ShouldProcess("RDUser: [$($session.Username)] with Session ID [$($session.UnifiedSessionID)]", "Logoff")) {

                $params = @{
                    'HostServer'       = $session.HostServer
                    'UnifiedSessionID' = $session.UnifiedSessionID
                    'ErrorAction'      = 'Stop'
                    'Force'            = $true
                }

                if ($AsJob.IsPresent) {
                    Write-Verbose "Attempting Logoff of [$($session.Username)] on [$($session.HostServer)] [AsJob]"
                    # Need to use "using:" scope here to pass local hashtable to Job function, otherwise will pass all as null
                    $sb = { Invoke-RDUserLogoff @using:params }
                    Start-Job -ScriptBlock $sb -Name "Log Off [$($session.UserName)]"
                } else {
                    Write-Verbose "Attempting Logoff of [$($session.Username)] on [$($session.HostServer)]"
                    Invoke-RDUserLogoff @params
                    Write-Host "User [$($session.Username)] logged off from [$($session.HostServer)]" -ForegroundColor Green
                } #ifasjob
            } #shouldprocess
        } #foreach
    } #Process

    End {
        # Intentionally empty
    }
} #function

function Send-sbRDMessage {
    # Adding a WhatIf/Confirm setting because this involves messaging users in Production, so professionalism counts and this allows mistakes
    # to be avoided
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param (
        [Parameter(Mandatory = $true)]
        [Alias('Title')]
        [string]$MessageTitle,

        [Parameter(Mandatory = $true)]
        [Alias('Body')]
        [string]$MessageBody,

        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSTypeName("Custom.SB.RDSession")][Object[]]$RDSession
    )

    Begin {
        # Intentionally empty
    }
    # Process block is required when receiving objects from the pipeline, otherwise only last object will be received
    Process {
        # ForEach needed in order to process an array of objects passed in as a variable, as opposed to the Pipeline which feeds objects individually
        foreach ( $session in $RDSession ) {
            if ($PSCmdlet.ShouldProcess("RDUser: [$($session.UserName)] with Session ID [$($session.UnifiedSessionID)]", "Send message")) {

                $messageParams = @{
                    Hostserver       = $session.HostServer
                    UnifiedSessionId = $session.UnifiedSessionId
                    MessageTitle     = $MessageTitle
                    MessageBody      = $MessageBody
                }

                Write-Verbose "Sending message to $($session.UserName)"
                Send-RDUserMessage @messageParams
            } #shouldprocess

        } #foreach
    } #process

    End {
        # Intentionally empty
    }
} #function
