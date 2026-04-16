function Import-QuietWrtDependencies {
    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
        throw "Posh-SSH is required. Install it with: Install-Module -Name Posh-SSH -Scope CurrentUser"
    }

    Import-Module Posh-SSH -ErrorAction Stop
}

function New-QuietWrtCredential {
    param(
        [string]$UserName = 'root',
        [securestring]$Password
    )

    if (-not $Password) {
        $plainTextPassword = Read-Host -Prompt "Router password for $UserName"
        $Password = ConvertTo-SecureString -String $plainTextPassword -AsPlainText -Force
    }

    return [pscredential]::new($UserName, $Password)
}

function Connect-QuietWrtRouter {
    param(
        [string]$RouterHost,
        [string]$RouterUser,
        [int]$RouterPort = 22,
        [pscredential]$Credential
    )

    Import-QuietWrtDependencies

    $sshSession = $null
    $sftpSession = $null

    try {
        $sshSession = @(New-QuietWrtSshSession -RouterHost $RouterHost -RouterPort $RouterPort -Credential $Credential)[0]
        $sftpSession = @(New-QuietWrtSftpSession -RouterHost $RouterHost -RouterPort $RouterPort -Credential $Credential)[0]

        return [pscustomobject]@{
            Host = $RouterHost
            User = $RouterUser
            Port = $RouterPort
            Credential = $Credential
            SshSession = $sshSession
            SftpSession = $sftpSession
        }
    } catch {
        if ($sftpSession) {
            try {
                Remove-QuietWrtSftpSession -Session $sftpSession | Out-Null
            } catch {
            }
        }

        if ($sshSession) {
            try {
                Remove-QuietWrtSshSession -Session $sshSession | Out-Null
            } catch {
            }
        }

        throw "Could not connect to $RouterHost over SSH: $($_.Exception.Message)"
    }
}

function Disconnect-QuietWrtRouter {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $Connection
    )

    if (-not $Connection) {
        return
    }

    if ($Connection.SftpSession) {
        try {
            Remove-QuietWrtSftpSession -Session $Connection.SftpSession | Out-Null
        } catch {
        }
    }

    if ($Connection.SshSession) {
        try {
            Remove-QuietWrtSshSession -Session $Connection.SshSession | Out-Null
        } catch {
        }
    }
}

function Get-QuietWrtPlainTextPassword {
    param(
        [pscredential]$Credential
    )

    return $Credential.GetNetworkCredential().Password
}

function New-QuietWrtConnectionInfo {
    param(
        [string]$RouterHost,
        [int]$RouterPort,
        [pscredential]$Credential
    )

    $password = Get-QuietWrtPlainTextPassword -Credential $Credential
    $authentication = [Renci.SshNet.PasswordAuthenticationMethod]::new($Credential.UserName, $password)
    $connectionInfo = [Renci.SshNet.ConnectionInfo]::new($RouterHost, $RouterPort, $Credential.UserName, $authentication)
    $connectionInfo.Timeout = [TimeSpan]::FromSeconds(15)
    return $connectionInfo
}

function ConvertTo-QuietWrtRemoteShellLiteral {
    param(
        [string]$Text
    )

    $escaped = $Text.Replace('\', '\\').Replace('"', '\"').Replace('$', '\$').Replace('`', '\`')
    return '"' + $escaped + '"'
}

function ConvertTo-QuietWrtNormalizedRemotePath {
    param(
        [string]$Path
    )

    if ($null -eq $Path) {
        return ''
    }

    return ($Path -replace '\\', '/').Trim()
}

function Join-QuietWrtRemotePath {
    param(
        [string]$BasePath,
        [string]$ChildPath
    )

    $base = ConvertTo-QuietWrtNormalizedRemotePath -Path $BasePath
    $child = ConvertTo-QuietWrtNormalizedRemotePath -Path $ChildPath

    if ([string]::IsNullOrEmpty($base)) {
        return $child
    }

    if ([string]::IsNullOrEmpty($child)) {
        return $base
    }

    if ($base -eq '/') {
        return '/' + $child.TrimStart('/')
    }

    return $base.TrimEnd('/') + '/' + $child.TrimStart('/')
}

function Get-QuietWrtRemoteParentPath {
    param(
        [string]$Path
    )

    $normalized = ConvertTo-QuietWrtNormalizedRemotePath -Path $Path
    if ([string]::IsNullOrEmpty($normalized) -or $normalized -eq '/') {
        return '/'
    }

    $trimmed = $normalized.TrimEnd('/')
    $lastSlash = $trimmed.LastIndexOf('/')

    if ($lastSlash -lt 0) {
        return ''
    }

    if ($lastSlash -eq 0) {
        return '/'
    }

    return $trimmed.Substring(0, $lastSlash)
}

function Ensure-QuietWrtRemoteDirectory {
    param(
        $Session,
        [string]$Path
    )

    $normalized = ConvertTo-QuietWrtNormalizedRemotePath -Path $Path
    if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized -eq '.' -or $normalized -eq '/') {
        return
    }

    $quotedPath = ConvertTo-QuietWrtRemoteShellLiteral -Text $normalized
    $result = $Session.CommandClient.RunCommand("mkdir -p $quotedPath")

    if ($result.ExitStatus -ne 0) {
        $errorText = $result.Error
        if ([string]::IsNullOrWhiteSpace($errorText)) {
            $errorText = $result.Result
        }
        throw "Could not create remote directory $normalized. $errorText".Trim()
    }
}

function New-QuietWrtSshSession {
    param(
        [string]$RouterHost,
        [int]$RouterPort,
        [pscredential]$Credential
    )

    $connectionInfo = New-QuietWrtConnectionInfo -RouterHost $RouterHost -RouterPort $RouterPort -Credential $Credential
    $client = [Renci.SshNet.SshClient]::new($connectionInfo)
    $client.Connect()
    return $client
}

function New-QuietWrtSftpSession {
    param(
        [string]$RouterHost,
        [int]$RouterPort,
        [pscredential]$Credential
    )

    $transferClient = [Renci.SshNet.ScpClient]::new((New-QuietWrtConnectionInfo -RouterHost $RouterHost -RouterPort $RouterPort -Credential $Credential))
    $commandClient = [Renci.SshNet.SshClient]::new((New-QuietWrtConnectionInfo -RouterHost $RouterHost -RouterPort $RouterPort -Credential $Credential))
    $transferClient.Connect()
    $commandClient.Connect()

    return [pscustomobject]@{
        TransferClient = $transferClient
        CommandClient = $commandClient
    }
}

function Remove-QuietWrtSshSession {
    param(
        $Session
    )

    if (-not $Session) {
        return
    }

    if ($Session.IsConnected) {
        $Session.Disconnect()
    }

    $Session.Dispose()
}

function Remove-QuietWrtSftpSession {
    param(
        $Session
    )

    if (-not $Session) {
        return
    }

    if ($Session.TransferClient) {
        if ($Session.TransferClient.IsConnected) {
            $Session.TransferClient.Disconnect()
        }

        $Session.TransferClient.Dispose()
    }

    if ($Session.CommandClient) {
        if ($Session.CommandClient.IsConnected) {
            $Session.CommandClient.Disconnect()
        }

        $Session.CommandClient.Dispose()
    }
}

function Invoke-QuietWrtSshCommand {
    param(
        $Session,
        [string]$Command,
        [int]$TimeoutSeconds
    )

    $sshCommand = $Session.CreateCommand($Command)
    $sshCommand.CommandTimeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $output = $sshCommand.Execute()

    return [pscustomobject]@{
        ExitStatus = $sshCommand.ExitStatus
        Output = if ([string]::IsNullOrEmpty($output)) { @() } else { $output -split "`r?`n" }
        Error = $sshCommand.Error
        Raw = $sshCommand
    }
}

function Send-QuietWrtSftpItem {
    param(
        $Session,
        [string]$Path,
        [string]$Destination
    )

    $item = Get-Item -LiteralPath $Path -ErrorAction Stop

    if ($item.PSIsContainer) {
        $remoteRoot = Join-QuietWrtRemotePath -BasePath $Destination -ChildPath $item.Name
        Ensure-QuietWrtRemoteDirectory -Session $Session -Path $remoteRoot

        foreach ($child in Get-ChildItem -LiteralPath $item.FullName -File -Recurse) {
            $relativePath = $child.FullName.Substring($item.FullName.Length).TrimStart('\', '/')
            $remotePath = Join-QuietWrtRemotePath -BasePath $remoteRoot -ChildPath ($relativePath -replace '\\', '/')
            $remoteParent = Get-QuietWrtRemoteParentPath -Path $remotePath
            Ensure-QuietWrtRemoteDirectory -Session $Session -Path $remoteParent

            $Session.TransferClient.Upload($child, $remotePath)
        }

        return $remoteRoot
    }

    Ensure-QuietWrtRemoteDirectory -Session $Session -Path $Destination
    $remoteFilePath = Join-QuietWrtRemotePath -BasePath $Destination -ChildPath $item.Name
    $Session.TransferClient.Upload($item, $remoteFilePath)

    return $remoteFilePath
}

function Receive-QuietWrtSftpItem {
    param(
        $Session,
        [string]$Path,
        [string]$Destination
    )

    $remotePath = ($Path -replace '\\', '/')
    $itemName = [System.IO.Path]::GetFileName($remotePath)
    $destinationIsDirectory = (Test-Path -LiteralPath $Destination -PathType Container)
    $localPath = if ($destinationIsDirectory) { Join-Path $Destination $itemName } else { $Destination }
    $localDirectory = Split-Path -Parent $localPath

    if (-not [string]::IsNullOrWhiteSpace($localDirectory)) {
        $null = New-Item -ItemType Directory -Path $localDirectory -Force
    }

    $stream = [System.IO.File]::Create($localPath)
    try {
        $Session.TransferClient.Download($remotePath, $stream)
    } finally {
        $stream.Dispose()
    }

    return $localPath
}

function Invoke-QuietWrtRemote {
    param(
        $Connection,
        [string]$Command,
        [int]$TimeoutSeconds = 60,
        [switch]$AllowFailure
    )

    $result = @(Invoke-QuietWrtSshCommand -Session $Connection.SshSession -Command $Command -TimeoutSeconds $TimeoutSeconds)[0]
    $output = ''

    if ($null -ne $result.Output) {
        $output = (($result.Output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
    }

    if ([string]::IsNullOrWhiteSpace($output) -and $null -ne $result.Error) {
        $output = $result.Error.ToString().Trim()
    }

    if (-not $AllowFailure -and $result.ExitStatus -ne 0) {
        if ([string]::IsNullOrWhiteSpace($output)) {
            $output = 'The remote command did not return an error message.'
        }

        throw "Remote command failed with exit code $($result.ExitStatus): $output"
    }

    return [pscustomobject]@{
        ExitStatus = $result.ExitStatus
        Output = $output
        Raw = $result
    }
}
