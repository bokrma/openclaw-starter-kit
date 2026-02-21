$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $true
    $PSNativeCommandArgumentPassing = "Standard"
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[openclaw-easy] $Message"
}

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: $Name"
    }
}

function Resolve-ComposeCommand {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        & docker compose version > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            return @("docker", "compose")
        }
    }
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        & docker-compose version > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            return @("docker-compose")
        }
    }
    throw "Docker Compose not found. Install Docker Compose v2 (docker compose) or docker-compose."
}

function Assert-LastExitCode {
    param([string]$Context)
    if ($LASTEXITCODE -ne 0) {
        throw "$Context failed (exit $LASTEXITCODE)."
    }
}

function Clone-OpenClawRepo {
    param(
        [string]$RepoUrl,
        [string]$RepoBranch,
        [string]$Destination
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Remove-Item -Path $Destination -Recurse -Force -ErrorAction SilentlyContinue
        & git clone --depth 1 --branch $RepoBranch $RepoUrl $Destination
        if ($LASTEXITCODE -eq 0) {
            return
        }
        Start-Sleep -Seconds (2 * $attempt)
    }
    throw "git clone failed after retries."
}

function Clone-MissionControlRepo {
    param(
        [string]$RepoUrl,
        [string]$RepoBranch,
        [string]$Destination
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Remove-Item -Path $Destination -Recurse -Force -ErrorAction SilentlyContinue
        & git clone --depth 1 --branch $RepoBranch $RepoUrl $Destination
        if ($LASTEXITCODE -eq 0) {
            return
        }
        Start-Sleep -Seconds (2 * $attempt)
    }
    throw "Mission Control git clone failed after retries."
}

function Clone-CommandCenterRepo {
    param(
        [string]$RepoUrl,
        [string]$RepoBranch,
        [string]$Destination
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Remove-Item -Path $Destination -Recurse -Force -ErrorAction SilentlyContinue
        & git clone --depth 1 --branch $RepoBranch $RepoUrl $Destination
        if ($LASTEXITCODE -eq 0) {
            return
        }
        Start-Sleep -Seconds (2 * $attempt)
    }
    throw "Command Center git clone failed after retries."
}

function Patch-MissionControlGatewayScopes {
    param([string]$MissionControlSrcDir)
    $gatewayRpcPath = Join-Path $MissionControlSrcDir "backend/app/services/openclaw/gateway_rpc.py"
    if (-not (Test-Path $gatewayRpcPath)) {
        return
    }
    $content = Get-Content -Path $gatewayRpcPath -Raw
    $updated = $content
    $changed = $false

    $pattern = '(?s)GATEWAY_OPERATOR_SCOPES\s*=\s*\(.*?\)\r?\n'
    $replacement = @"
GATEWAY_OPERATOR_SCOPES = (
    "operator.admin",
    "operator.read",
    "operator.write",
    "operator.approvals",
    "operator.pairing",
)
"@
    if ($updated -match $pattern) {
        $next = [regex]::Replace($updated, $pattern, $replacement, 1)
        if ($next -ne $updated) {
            $updated = $next
            $changed = $true
        }
    }

    if ($updated.Contains('"id": "gateway-client"')) {
        $updated = $updated.Replace('"id": "gateway-client"', '"id": "openclaw-control-ui"')
        $changed = $true
    }

    if ($updated -notmatch 'def _gateway_origin\(') {
        $originHelper = @"
def _gateway_origin(raw_url: str) -> str:
    parsed = urlparse(raw_url)
    scheme = "https" if parsed.scheme == "wss" else "http"
    return str(urlunparse(parsed._replace(scheme=scheme, path="", params="", query="", fragment="")))

"@
        $anchorPattern = 'def _redacted_url_for_log\(raw_url: str\) -> str:\r?\n\s+parsed = urlparse\(raw_url\)\r?\n\s+return str\(urlunparse\(parsed\._replace\(query="", fragment=""\)\)\)\r?\n'
        if ($updated -match $anchorPattern) {
            $anchor = $matches[0]
            $next = [regex]::Replace($updated, $anchorPattern, ($anchor + "`n" + $originHelper), 1)
            if ($next -ne $updated) {
                $updated = $next
                $changed = $true
            }
        }
    }

    $connectPattern = 'async with websockets\.connect\(\s*gateway_url,\s*ping_interval=None\s*\) as ws:'
    $connectReplacement = @"
async with websockets.connect(
            gateway_url,
            ping_interval=None,
            origin=_gateway_origin(gateway_url),
        ) as ws:
"@
    $nextConnect = [regex]::Replace($updated, $connectPattern, $connectReplacement, 1)
    if ($nextConnect -ne $updated) {
        $updated = $nextConnect
        $changed = $true
    }

    if ($changed) {
        Set-Content -Path $gatewayRpcPath -Value $updated -Encoding UTF8
        Write-Host "[openclaw-easy] Patched Mission Control gateway RPC client for OpenClaw compatibility."
    }
}

function Patch-MissionControlOnboardingRecovery {
    param([string]$MissionControlSrcDir)
    $onboardingPath = Join-Path $MissionControlSrcDir "backend/app/api/board_onboarding.py"
    if (-not (Test-Path $onboardingPath)) {
        return
    }
    $content = Get-Content -Path $onboardingPath -Raw
    if ($content.Contains("onboarding.recover.dispatch_failed")) {
        return
    }
    $pattern = "(?s)if onboarding is None:\r?\n\s+raise HTTPException\(status_code=status\.HTTP_404_NOT_FOUND\)\r?\n\s+return onboarding"
    $replacement = @"
if onboarding is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    messages = list(onboarding.messages or [])
    has_assistant_message = any(
        isinstance(msg, dict)
        and msg.get("role") == "assistant"
        and isinstance(msg.get("content"), str)
        and bool(msg.get("content").strip())
        for msg in messages
    )
    last_user_content: str | None = None
    if messages:
        last_message = messages[-1]
        if isinstance(last_message, dict):
            raw_role = last_message.get("role")
            raw_content = last_message.get("content")
            if raw_role == "user" and isinstance(raw_content, str) and raw_content:
                last_user_content = raw_content
    if onboarding.status == "active" and not has_assistant_message and last_user_content:
        # Recovery path for sessions that started but never received first assistant question.
        try:
            dispatcher = BoardOnboardingMessagingService(session)
            await dispatcher.dispatch_answer(
                board=board,
                onboarding=onboarding,
                answer_text=last_user_content,
                correlation_id=f"onboarding.recover:{board.id}:{onboarding.id}",
            )
            onboarding.updated_at = utcnow()
            session.add(onboarding)
            await session.commit()
            await session.refresh(onboarding)
        except Exception:  # pragma: no cover - best-effort recovery guard.
            logger.warning(
                "onboarding.recover.dispatch_failed board_id=%s onboarding_id=%s",
                board.id,
                onboarding.id,
                exc_info=True,
            )
    return onboarding
"@
    $updated = [regex]::Replace($content, $pattern, $replacement, 1)
    if ($updated -ne $content) {
        Set-Content -Path $onboardingPath -Value $updated -Encoding UTF8
        Write-Host "[openclaw-easy] Patched Mission Control onboarding recovery guard."
    }
}

function Patch-MissionControlOnboardingSessionIsolation {
    param([string]$MissionControlSrcDir)
    $servicePath = Join-Path $MissionControlSrcDir "backend/app/services/openclaw/onboarding_service.py"
    if (-not (Test-Path $servicePath)) {
        return
    }
    $content = Get-Content -Path $servicePath -Raw
    if ($content.Contains(":board-onboarding:")) {
        return
    }
    $needle = "session_key = GatewayAgentIdentity.session_key(gateway)"
    if ($content.Contains($needle)) {
        $replacement = @"
session_key = (
            f"{GatewayAgentIdentity.session_key(gateway)}:board-onboarding:{board.id}"
        )
"@
        $updated = $content.Replace($needle, $replacement.TrimEnd("`r", "`n"))
        Set-Content -Path $servicePath -Value $updated -Encoding UTF8
        Write-Host "[openclaw-easy] Patched Mission Control onboarding session isolation."
    }
}

function Patch-MissionControlOnboardingAgentLabels {
    param([string]$MissionControlSrcDir)
    $servicePath = Join-Path $MissionControlSrcDir "backend/app/services/openclaw/onboarding_service.py"
    if (-not (Test-Path $servicePath)) {
        return
    }
    $content = Get-Content -Path $servicePath -Raw
    if ($content.Contains('agent_name=f"Gateway Agent {str(board.id)[:8]}"')) {
        return
    }
    $updated = $content.Replace(
        'agent_name="Gateway Agent",',
        'agent_name=f"Gateway Agent {str(board.id)[:8]}",'
    )
    if ($updated -ne $content) {
        Set-Content -Path $servicePath -Value $updated -Encoding UTF8
        Write-Host "[openclaw-easy] Patched Mission Control onboarding agent labels."
    }
}

function Patch-MissionControlSecurityBaselines {
    param([string]$MissionControlSrcDir)

    $composeFile = Join-Path $MissionControlSrcDir "compose.yml"
    if (Test-Path $composeFile) {
        $composeText = Get-Content -Path $composeFile -Raw
        $composeUpdated = $composeText
        $composeUpdated = $composeUpdated.Replace(
            "POSTGRES_PASSWORD: `${POSTGRES_PASSWORD:-postgres}",
            "POSTGRES_PASSWORD: `${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}"
        )
        $composeUpdated = $composeUpdated.Replace(
            '- "${POSTGRES_PORT:-5432}:5432"',
            '- "127.0.0.1:${POSTGRES_PORT:-5432}:5432"'
        )
        $composeUpdated = $composeUpdated.Replace(
            '- "${REDIS_PORT:-6379}:6379"',
            '- "127.0.0.1:${REDIS_PORT:-6379}:6379"'
        )
        $composeUpdated = $composeUpdated.Replace(
            '- "${BACKEND_PORT:-8000}:8000"',
            '- "127.0.0.1:${BACKEND_PORT:-8000}:8000"'
        )
        $composeUpdated = $composeUpdated.Replace(
            '- "${FRONTEND_PORT:-3000}:3000"',
            '- "127.0.0.1:${FRONTEND_PORT:-3000}:3000"'
        )
        $composeUpdated = $composeUpdated.Replace(
            '${POSTGRES_PASSWORD:-postgres}@db:5432',
            '${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}@db:5432'
        )
        if ($composeUpdated -ne $composeText) {
            Set-Content -Path $composeFile -Value $composeUpdated -Encoding UTF8
            Write-Host "[openclaw-easy] Patched Mission Control compose security defaults."
        }
    }

    $backendPyproject = Join-Path $MissionControlSrcDir "backend/pyproject.toml"
    if (Test-Path $backendPyproject) {
        $backendPyprojectText = Get-Content -Path $backendPyproject -Raw
        $backendPyprojectUpdated = $backendPyprojectText.Replace(
            "clerk-backend-api==4.2.0",
            "clerk-backend-api==5.0.2"
        )
        if ($backendPyprojectUpdated -notmatch 'cryptography>=46\.0\.5,<47') {
            $backendPyprojectUpdated = $backendPyprojectUpdated.Replace(
                '"clerk-backend-api==5.0.2",',
                '"clerk-backend-api==5.0.2", "cryptography>=46.0.5,<47",'
            )
        }
        if ($backendPyprojectUpdated -ne $backendPyprojectText) {
            Set-Content -Path $backendPyproject -Value $backendPyprojectUpdated -Encoding UTF8
            Write-Host "[openclaw-easy] Patched Mission Control backend dependency baseline."
        }
    }

    $backendDockerfile = Join-Path $MissionControlSrcDir "backend/Dockerfile"
    if (Test-Path $backendDockerfile) {
        $backendDockerfileText = Get-Content -Path $backendDockerfile -Raw
        $backendDockerfileUpdated = $backendDockerfileText.Replace(
            "uv sync --frozen --no-dev",
            "uv sync --no-dev"
        )
        if ($backendDockerfileUpdated -ne $backendDockerfileText) {
            Set-Content -Path $backendDockerfile -Value $backendDockerfileUpdated -Encoding UTF8
            Write-Host "[openclaw-easy] Patched Mission Control backend Docker dependency sync mode."
        }
    }
}

function Repair-MissionControlOnboardingSessions {
    param([string]$MissionControlSrcDir)
    $pythonScript = @'
import asyncio
from sqlalchemy import text
from app.db.session import async_session_maker

async def main():
    async with async_session_maker() as session:
        migrated = await session.execute(
            text(
                """
                update board_onboarding_sessions
                set session_key = session_key || chr(58) || 'board-onboarding' || chr(58) || board_id::text
                where session_key is not null
                  and position('board-onboarding' in session_key) = 0
                returning id
                """
            )
        )
        migrated_rows = migrated.fetchall()
        await session.commit()
        print(f"MISSION_CONTROL_ONBOARDING_SESSIONKEY_MIGRATED={len(migrated_rows)}")

asyncio.run(main())
'@
    $pythonScriptBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pythonScript))
    $pythonLauncher = "import base64;exec(base64.b64decode('$pythonScriptBase64').decode('utf-8'))"
    $repair = Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @(
        "exec", "-T",
        "-e", "PYTHONWARNINGS=ignore::DeprecationWarning",
        "backend", "python", "-c", $pythonLauncher
    ) -Capture -IgnoreExitCode
    if ($repair.Code -ne 0) {
        Write-Host "[openclaw-easy] Mission Control onboarding session migration failed (continuing)."
        foreach ($line in @($repair.Output)) {
            Write-Host "[openclaw-easy] mission-control-onboarding: $line"
        }
    }
    else {
        foreach ($line in @($repair.Output)) {
            $text = $line.ToString().Trim()
            if ($text) {
                Write-Host "[openclaw-easy] mission-control-onboarding: $text"
            }
        }
    }
}

function Test-OpenClawRepoLayout {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $false
    }
    $required = @("Dockerfile", "openclaw.mjs", "src", "ui")
    foreach ($entry in $required) {
        if (-not (Test-Path (Join-Path $Path $entry))) {
            return $false
        }
    }
    return $true
}

function Find-LocalOpenClawRepo {
    param([string]$BaseDir)
    $candidate = Resolve-Path (Join-Path $BaseDir "..") -ErrorAction SilentlyContinue
    if (-not $candidate) {
        return $null
    }
    $path = $candidate.Path
    if (-not (Test-OpenClawRepoLayout -Path $path)) {
        return $null
    }
    return $path
}

function Import-DotEnv {
    param([string]$Path)
    foreach ($rawLine in Get-Content -Path $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }
        $parts = $line -split "=", 2
        if ($parts.Count -ne 2) {
            continue
        }
        $key = $parts[0].Trim()
        $key = $key.TrimStart([char]0xFEFF)
        $value = $parts[1].Trim()
        Set-Item -Path "env:$key" -Value $value
    }
}

function Upsert-DotEnvValue {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Value
    )
    $lines = @()
    if (Test-Path $Path) {
        $lines = Get-Content -Path $Path
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match "^([^=]+)=(.*)$") {
            if ($matches[1] -eq $Key) {
                continue
            }
        }
        $out.Add($line)
    }
    $out.Add("$Key=$Value")
    Set-Content -Path $Path -Encoding ascii -Value @($out)
}

function Require-Env {
    param([string]$Key)
    $value = [Environment]::GetEnvironmentVariable($Key)
    if (-not $value) {
        throw "Missing required value: $Key (set it in .env)"
    }
}

function Is-Blank {
    param([string]$Value)
    return [string]::IsNullOrWhiteSpace($Value)
}

function Is-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    return $Value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")
}

function Prompt-EnvValue {
    param(
        [string]$Key,
        [string]$Description,
        [bool]$Required = $false,
        [bool]$AllowSkip = $false
    )
    $existing = [Environment]::GetEnvironmentVariable($Key)
    if (-not (Is-Blank $existing)) {
        return $existing
    }

    if (-not [Environment]::UserInteractive) {
        if ($Required) {
            throw "Missing required value: $Key (set it in .env)"
        }
        Upsert-DotEnvValue -Path $script:EnvFile -Key $Key -Value ""
        return ""
    }

    Write-Step $Description
    if ($AllowSkip) {
        Write-Host "[openclaw-easy] Press Enter or type skip to leave it empty."
    }
    while ($true) {
        $inputValue = Read-Host "[openclaw-easy] $Key"
        if (-not (Is-Blank $inputValue) -and $inputValue -ne "skip") {
            Set-Item -Path "env:$Key" -Value $inputValue
            Upsert-DotEnvValue -Path $script:EnvFile -Key $Key -Value $inputValue
            return $inputValue
        }
        if ($AllowSkip) {
            Upsert-DotEnvValue -Path $script:EnvFile -Key $Key -Value ""
            return ""
        }
        Write-Host "[openclaw-easy] $Key is required."
    }
}

function New-HexToken {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Convert-ToPortNumber {
    param(
        [string]$Value,
        [int]$Fallback
    )
    try {
        $port = [int]$Value
        if ($port -ge 1 -and $port -le 65535) {
            return $port
        }
    }
    catch {}
    return $Fallback
}

function Test-HostPortAvailable {
    param([int]$Port)
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
        $listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($listener) {
            try { $listener.Stop() } catch {}
        }
    }
}

function Resolve-AvailablePort {
    param(
        [int]$PreferredPort,
        [int[]]$ReservedPorts = @()
    )
    if (($ReservedPorts -notcontains $PreferredPort) -and (Test-HostPortAvailable -Port $PreferredPort)) {
        return $PreferredPort
    }
    for ($offset = 1; $offset -le 500; $offset++) {
        $candidate = $PreferredPort + $offset
        if ($candidate -gt 65535) {
            break
        }
        if ($ReservedPorts -contains $candidate) {
            continue
        }
        if (Test-HostPortAvailable -Port $candidate) {
            return $candidate
        }
    }
    throw "No available host port found near $PreferredPort."
}

function Invoke-Compose {
    param(
        [string]$OpenClawSrcDir,
        [string[]]$ComposeArgs,
        [switch]$Capture,
        [switch]$IgnoreExitCode
    )
    Push-Location $OpenClawSrcDir
    try {
        $composeSuffix = @($script:ComposeCommand | Select-Object -Skip 1)
        $composeProjectArgs = @()
        if ($script:ComposeProjectName) {
            $composeProjectArgs = @("-p", $script:ComposeProjectName)
        }
        $composeEnvArgs = @()
        if ($script:ComposeEnvFile -and (Test-Path $script:ComposeEnvFile)) {
            $composeEnvArgs = @("--env-file", $script:ComposeEnvFile)
        }
        $nativeErrorPref = $null
        $errorPref = $ErrorActionPreference
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $nativeErrorPref = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $ErrorActionPreference = "Continue"
        try {
            if ($Capture) {
                $output = & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f docker-compose.safe.yml @ComposeArgs 2>&1
            }
            else {
                & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f docker-compose.safe.yml @ComposeArgs
                $output = @()
            }
        }
        finally {
            $ErrorActionPreference = $errorPref
            if ($PSVersionTable.PSVersion.Major -ge 7 -and $null -ne $nativeErrorPref) {
                $PSNativeCommandUseErrorActionPreference = $nativeErrorPref
            }
        }
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if (-not $IgnoreExitCode -and $code -ne 0) {
        throw "docker compose failed (exit $code): $($ComposeArgs -join ' ')"
    }

    return [PSCustomObject]@{
        Code = $code
        Output = $output
    }
}

function Convert-ToShSingleQuoted {
    param([string]$Value)
    if ($null -eq $Value) {
        return "''"
    }
    return "'" + $Value.Replace("'", "'""'""'") + "'"
}

function New-OpenClawCliLine {
    param([string[]]$CliArgs)
    $quoted = @($CliArgs | ForEach-Object { Convert-ToShSingleQuoted -Value "$_" })
    return "node dist/index.js " + ($quoted -join " ")
}

function Invoke-OpenClawCliBatch {
    param(
        [string]$OpenClawSrcDir,
        [string[]]$Lines,
        [switch]$Capture,
        [switch]$Quiet,
        [switch]$IgnoreExitCode
    )
    if (-not $Lines -or $Lines.Count -eq 0) {
        return [PSCustomObject]@{
            Code = 0
            Output = @()
        }
    }
    $script = (@("set -eu") + $Lines) -join "`n"
    $shouldCapture = $Capture.IsPresent -or $Quiet.IsPresent
    $result = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @(
        "run", "--rm", "--entrypoint", "sh", "openclaw-cli", "-lc", $script
    ) -Capture:$shouldCapture -IgnoreExitCode:$IgnoreExitCode
    if ($Quiet) {
        return [PSCustomObject]@{
            Code = $result.Code
            Output = @()
        }
    }
    return $result
}

function Set-ExecApprovalMode {
    param(
        [string]$OpenClawSrcDir,
        [bool]$AlwaysAllowExec
    )
    $askValue = if ($AlwaysAllowExec) { "off" } else { "on-miss" }
    $securityValue = if ($AlwaysAllowExec) { "full" } else { "allowlist" }
    Invoke-OpenClawCliBatch -OpenClawSrcDir $OpenClawSrcDir -Lines @(
        (New-OpenClawCliLine @("config", "set", "tools.exec.ask", $askValue)),
        (New-OpenClawCliLine @("config", "set", "tools.exec.security", $securityValue))
    ) -Quiet -IgnoreExitCode | Out-Null
}

function Stop-LegacyComposeProjects {
    param([string]$OpenClawSrcDir)
    $legacyProjects = @("openclaw", "openclaw-easy-starter")
    $nativeErrorPref = $null
    $errorPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $nativeErrorPref = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    Push-Location $OpenClawSrcDir
    try {
        $composeSuffix = @($script:ComposeCommand | Select-Object -Skip 1)
        foreach ($legacyProject in $legacyProjects) {
            if ($legacyProject -eq $script:ComposeProjectName) {
                continue
            }
            $args = @("-p", $legacyProject)
            if ($script:ComposeEnvFile -and (Test-Path $script:ComposeEnvFile)) {
                $args += @("--env-file", $script:ComposeEnvFile)
            }
            & $script:ComposeCommand[0] @composeSuffix @args -f docker-compose.safe.yml down --remove-orphans *> $null
        }
    }
    finally {
        Pop-Location
        $ErrorActionPreference = $errorPref
        if ($PSVersionTable.PSVersion.Major -ge 7 -and $null -ne $nativeErrorPref) {
            $PSNativeCommandUseErrorActionPreference = $nativeErrorPref
        }
    }
}

function Test-GatewayHttp {
    param([string]$Port)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync("127.0.0.1", [int]$Port)
        if (-not $task.Wait(3000)) {
            return $false
        }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Test-HttpStatus200 {
    param([string]$Url)
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5
        return ($response.StatusCode -eq 200)
    }
    catch {
        return $false
    }
}

function Sync-MissionControlDbPassword {
    param(
        [string]$MissionControlSrcDir,
        [string]$DbUser,
        [string]$DbPassword
    )
    if ([string]::IsNullOrWhiteSpace($DbPassword)) {
        return
    }
    $safeUser = if ([string]::IsNullOrWhiteSpace($DbUser)) { "postgres" } else { $DbUser.Trim() }
    $safePassword = $DbPassword.Replace("'", "''")
    $sql = "ALTER USER ""$safeUser"" WITH PASSWORD '$safePassword';"
    Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @(
        "exec", "-T", "-u", "postgres", "db",
        "psql", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-c", $sql
    ) -IgnoreExitCode | Out-Null
}

function Test-MissionControlBackendReady {
    param(
        [string]$BackendUrl,
        [string]$LocalAuthToken
    )
    if ([string]::IsNullOrWhiteSpace($BackendUrl) -or [string]::IsNullOrWhiteSpace($LocalAuthToken)) {
        return $false
    }
    if (-not (Test-HttpStatus200 -Url "$BackendUrl/health")) {
        return $false
    }
    try {
        $headers = @{ Authorization = "Bearer $LocalAuthToken" }
        $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$BackendUrl/api/v1/auth/bootstrap" -Headers $headers -TimeoutSec 5
        return ($response.StatusCode -eq 200)
    }
    catch {
        return $false
    }
}

function Invoke-MissionControlCompose {
    param(
        [string]$MissionControlSrcDir,
        [string[]]$ComposeArgs,
        [string]$InputText,
        [switch]$Capture,
        [switch]$IgnoreExitCode
    )
    Push-Location $MissionControlSrcDir
    try {
        $composeSuffix = @($script:ComposeCommand | Select-Object -Skip 1)
        $projectName = if ($script:ComposeProjectName) { "$($script:ComposeProjectName)-mission-control" } else { "openclaw-mission-control" }
        $composeProjectArgs = @("-p", $projectName)
        $composeEnvArgs = @()
        $missionControlEnv = Join-Path $MissionControlSrcDir ".env"
        if (Test-Path $missionControlEnv) {
            $composeEnvArgs = @("--env-file", $missionControlEnv)
        }
        $nativeErrorPref = $null
        $errorPref = $ErrorActionPreference
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $nativeErrorPref = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $ErrorActionPreference = "Continue"
        try {
            if ($Capture) {
                if ($PSBoundParameters.ContainsKey("InputText")) {
                    $output = $InputText | & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f compose.yml @ComposeArgs 2>&1
                }
                else {
                    $output = & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f compose.yml @ComposeArgs 2>&1
                }
            }
            else {
                if ($PSBoundParameters.ContainsKey("InputText")) {
                    $null = $InputText | & $script:ComposeCommand[0] @composeSuffix @composeEnvArgs @composeProjectArgs -f compose.yml @ComposeArgs
                }
                else {
                    & $script:ComposeCommand[0] @composeSuffix @composeEnvArgs @composeProjectArgs -f compose.yml @ComposeArgs
                }
                $output = @()
            }
        }
        finally {
            $ErrorActionPreference = $errorPref
            if ($PSVersionTable.PSVersion.Major -ge 7 -and $null -ne $nativeErrorPref) {
                $PSNativeCommandUseErrorActionPreference = $nativeErrorPref
            }
        }
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if (-not $IgnoreExitCode -and $code -ne 0) {
        throw "Mission Control docker compose failed (exit $code): $($ComposeArgs -join ' ')"
    }

    return [PSCustomObject]@{
        Code = $code
        Output = $output
    }
}

function Invoke-CommandCenterCompose {
    param(
        [string]$RootDir,
        [string[]]$ComposeArgs,
        [switch]$Capture,
        [switch]$IgnoreExitCode
    )
    $composeFile = Join-Path $RootDir "command-center.compose.yml"
    if (-not (Test-Path $composeFile)) {
        throw "Command Center compose file missing at $composeFile"
    }
    $composeSuffix = @($script:ComposeCommand | Select-Object -Skip 1)
    $projectName = if ($script:ComposeProjectName) { "$($script:ComposeProjectName)-command-center" } else { "openclaw-command-center" }
    $composeProjectArgs = @("-p", $projectName)
    $composeEnvArgs = @()
    if ($script:EnvFile -and (Test-Path $script:EnvFile)) {
        $composeEnvArgs = @("--env-file", $script:EnvFile)
    }
    $nativeErrorPref = $null
    $errorPref = $ErrorActionPreference
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $nativeErrorPref = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    $ErrorActionPreference = "Continue"
    try {
        if ($Capture) {
            $output = & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f $composeFile @ComposeArgs 2>&1
        }
        else {
            & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f $composeFile @ComposeArgs
            $output = @()
        }
    }
    finally {
        $ErrorActionPreference = $errorPref
        if ($PSVersionTable.PSVersion.Major -ge 7 -and $null -ne $nativeErrorPref) {
            $PSNativeCommandUseErrorActionPreference = $nativeErrorPref
        }
    }
    $code = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $code -ne 0) {
        throw "Command Center docker compose failed (exit $code): $($ComposeArgs -join ' ')"
    }
    return [PSCustomObject]@{
        Code = $code
        Output = $output
    }
}

function Resolve-ContainerId {
    param([object[]]$Lines)
    foreach ($line in $Lines) {
        $candidate = $line.ToString().Trim()
        if ($candidate -match "^[0-9a-f]{12,}$") {
            return $candidate
        }
    }
    return ""
}

function Get-GatewayContainerStatus {
    param([string]$OpenClawSrcDir)
    $idResult = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("ps", "-q", "openclaw-gateway") -Capture -IgnoreExitCode
    if ($idResult.Code -ne 0) {
        return ""
    }
    $lines = @($idResult.Output) | Where-Object { $_ -and $_.ToString().Trim() -ne "" }
    if ($lines.Count -eq 0) {
        return ""
    }
    $containerId = Resolve-ContainerId -Lines $lines
    if (-not $containerId) {
        return ""
    }

    $inspectStatus = ""
    $nativePref = $null
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $nativePref = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    try {
        $inspectStatus = & docker inspect --format "{{.State.Status}}" $containerId 2>$null
    }
    finally {
        if ($PSVersionTable.PSVersion.Major -ge 7 -and $null -ne $nativePref) {
            $PSNativeCommandUseErrorActionPreference = $nativePref
        }
    }
    if ($LASTEXITCODE -eq 0 -and $inspectStatus) {
        return $inspectStatus.ToString().Trim()
    }

    $fallback = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("ps", "openclaw-gateway") -Capture -IgnoreExitCode
    $fallbackLines = @($fallback.Output) | Where-Object { $_ -and $_.ToString().Trim() -ne "" }
    if ($fallbackLines.Count -eq 0) {
        return ""
    }
    return ($fallbackLines | Select-Object -Last 1).ToString().Trim()
}

function Strip-Ansi {
    param([string]$Text)
    if (-not $Text) {
        return ""
    }
    return [regex]::Replace($Text, "\x1b\[[0-9;]*[A-Za-z]", "")
}

function Get-DefaultDashboardUrl {
    $port = if ($env:OPENCLAW_GATEWAY_PORT) { $env:OPENCLAW_GATEWAY_PORT } else { "18789" }
    if ($env:OPENCLAW_GATEWAY_TOKEN) {
        return "http://127.0.0.1:$port/#token=$($env:OPENCLAW_GATEWAY_TOKEN)"
    }
    return "http://127.0.0.1:$port/"
}

function Parse-ChannelPluginList {
    param([string]$Value)
    if (-not $Value) {
        return @()
    }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($Value -split "[,\s]+")) {
        $id = $part.Trim()
        if (-not $id) {
            continue
        }
        if ($seen.Add($id)) {
            $items.Add($id)
        }
    }
    return @($items)
}

function Ensure-TokenizedDashboardUrl {
    param([string]$Url)
    $token = $env:OPENCLAW_GATEWAY_TOKEN
    if (-not $Url) {
        return Get-DefaultDashboardUrl
    }
    if (-not $token) {
        return $Url
    }
    if ($Url -match "(^|[?#&])token=") {
        return $Url
    }
    if ($Url.Contains("#")) {
        if ($Url.EndsWith("#") -or $Url.EndsWith("&")) {
            return "$Url" + "token=$token"
        }
        return "$Url&token=$token"
    }
    return "$Url#token=$token"
}

function Test-BrowserControlService {
    param([string]$OpenClawSrcDir)
    $result = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @(
        "exec", "-T", "openclaw-gateway", "node", "dist/index.js", "browser", "status", "--json"
    ) -Capture -IgnoreExitCode
    if ($result.Code -ne 0) {
        $tail = @($result.Output) | Select-Object -Last 1
        return [PSCustomObject]@{
            Ready = $false
            Detail = "probe command failed: $($tail.ToString().Trim())"
        }
    }
    $jsonRaw = (@($result.Output) | ForEach-Object { $_.ToString() }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($jsonRaw)) {
        return [PSCustomObject]@{
            Ready = $false
            Detail = "probe returned no output"
        }
    }
    try {
        $payload = $jsonRaw | ConvertFrom-Json
        $ready = [bool]$payload.enabled -and ([bool]$payload.cdpHttp -or [bool]$payload.running -or -not [string]::IsNullOrWhiteSpace([string]$payload.detectedBrowser))
        return [PSCustomObject]@{
            Ready = $ready
            Detail = "enabled=$($payload.enabled) cdpHttp=$($payload.cdpHttp) running=$($payload.running) profile=$($payload.profile)"
        }
    }
    catch {
        return [PSCustomObject]@{
            Ready = $false
            Detail = "probe json parse failed"
        }
    }
}

function Clear-StaleBrowserProfileLocks {
    param([string]$OpenClawSrcDir)
    $cleanupScript = @'
set -eu
for dir in /home/node/.openclaw/browser/*/user-data; do
  [ -d "$dir" ] || continue
  rm -f "$dir/SingletonLock" "$dir/SingletonSocket" "$dir/SingletonCookie"
done
'@
    $result = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @(
        "run", "--rm",
        "--entrypoint", "sh",
        "openclaw-cli",
        "-lc",
        $cleanupScript
    ) -Capture -IgnoreExitCode
    if ($result.Code -ne 0) {
        Write-Host "[openclaw-easy] Could not clear stale browser profile locks (continuing)."
    }
}

function Test-PrivateOrLoopbackIp {
    param([string]$Ip)
    if ([string]::IsNullOrWhiteSpace($Ip)) {
        return $false
    }
    $trimmed = $Ip.Trim().ToLowerInvariant()
    return (
        $trimmed -eq "127.0.0.1" -or
        $trimmed -eq "::1" -or
        $trimmed.StartsWith("10.") -or
        $trimmed.StartsWith("172.") -or
        $trimmed.StartsWith("192.168.") -or
        $trimmed.StartsWith("fc") -or
        $trimmed.StartsWith("fd")
    )
}

function Approve-LocalPendingDevicePairings {
    param([string]$OpenClawSrcDir)
    $nodeScript = @'
import { approveDevicePairing, listDevicePairing } from "/app/dist/infra/device-pairing.js";

const baseDir = "/home/node/.openclaw";
const isLocalIp = (value) => {
  const ip = String(value ?? "").trim().toLowerCase();
  if (!ip) return false;
  return (
    ip === "127.0.0.1" ||
    ip === "::1" ||
    ip.startsWith("10.") ||
    ip.startsWith("172.") ||
    ip.startsWith("192.168.") ||
    ip.startsWith("fc") ||
    ip.startsWith("fd")
  );
};

const list = await listDevicePairing(baseDir);
let approved = 0;
for (const req of list.pending ?? []) {
  if (!isLocalIp(req.remoteIp)) continue;
  await approveDevicePairing(req.requestId, baseDir);
  approved += 1;
}
console.log(JSON.stringify({ pending: (list.pending ?? []).length, approved }));
'@
    $result = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("exec", "-T", "openclaw-gateway", "node", "--input-type=module", "-e", $nodeScript) -Capture -IgnoreExitCode
    if ($result.Code -ne 0) {
        return
    }
    $summaryLine = @($result.Output) | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match "^\{.*\}$" } | Select-Object -Last 1
    if (-not $summaryLine) {
        return
    }
    try {
        $summary = $summaryLine | ConvertFrom-Json
        if (($summary.approved -as [int]) -gt 0) {
            Write-Host "[openclaw-easy] Auto-approved $($summary.approved) local pending device pairing request(s)."
        }
    }
    catch {
        # no-op
    }
}

function Initialize-AgentMainSessions {
    param(
        [string]$OpenClawSrcDir,
        [object[]]$AgentDefinitions
    )
    if (-not $AgentDefinitions -or $AgentDefinitions.Count -eq 0) {
        return
    }

    $seed = @(
        $AgentDefinitions | ForEach-Object {
            [PSCustomObject]@{
                id = $_.Id
                name = $_.Name
            }
        }
    )
    $seedJson = $seed | ConvertTo-Json -Compress
    $nodeScript = @'
import { loadConfig } from "/app/dist/config/config.js";
import { updateSessionStore } from "/app/dist/config/sessions.js";
import { resolveAgentMainSessionKey } from "/app/dist/config/sessions/main-session.js";
import { resolveGatewaySessionStoreTarget } from "/app/dist/gateway/session-utils.js";
import { applySessionsPatchToStore } from "/app/dist/gateway/sessions-patch.js";

const cfg = loadConfig();
const seed = JSON.parse(process.env.OPENCLAW_AGENT_SESSION_SEED ?? "[]");
let bootstrapped = 0;

for (const item of seed) {
  const agentId = String(item?.id ?? "").trim();
  const label = String(item?.name ?? "").trim();
  if (!agentId || !label) continue;

  const key = resolveAgentMainSessionKey({ cfg, agentId });
  const target = resolveGatewaySessionStoreTarget({ cfg, key });
  const storeKey = target.storeKeys[0] ?? key;

  await updateSessionStore(target.storePath, async (store) => {
    const existingKey = target.storeKeys.find((candidate) => store[candidate]);
    if (existingKey && existingKey !== storeKey && !store[storeKey]) {
      store[storeKey] = store[existingKey];
      delete store[existingKey];
    }
    const patched = await applySessionsPatchToStore({
      cfg,
      store,
      storeKey,
      patch: { key: storeKey, label },
    });
    if (!patched.ok) {
      throw new Error(patched.error?.message ?? `failed to patch session for ${agentId}`);
    }
    return patched.entry;
  });
  bootstrapped += 1;
}

console.log(JSON.stringify({ requested: seed.length, bootstrapped }));
'@
    $shellScript = @'
set -eu
cat > /tmp/openclaw-agent-session-seed.json <<'"'"'JSON'"'"'
__OPENCLAW_AGENT_SESSION_SEED__
JSON
cat > /tmp/openclaw-bootstrap-sessions.mjs <<'"'"'NODE'"'"'
__OPENCLAW_NODE_SCRIPT__
NODE
OPENCLAW_AGENT_SESSION_SEED="$(cat /tmp/openclaw-agent-session-seed.json)" node /tmp/openclaw-bootstrap-sessions.mjs
'@
    $shellScript = $shellScript.Replace("__OPENCLAW_AGENT_SESSION_SEED__", $seedJson)
    $shellScript = $shellScript.Replace("__OPENCLAW_NODE_SCRIPT__", $nodeScript)

    $result = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @(
        "run", "--rm",
        "--entrypoint", "sh",
        "openclaw-cli",
        "-lc",
        $shellScript
    ) -Capture -IgnoreExitCode

    if ($result.Code -ne 0) {
        Write-Host "[openclaw-easy] Could not bootstrap agent chat sessions (continuing)."
    }
}

function Get-OpenClawAgentManifestPath {
    param([string]$RootDir)
    return Join-Path (Join-Path (Join-Path $RootDir "openclaw-agents") "agents") "manifest.json"
}

function Split-OpenClawAgentFiles {
    param(
        [string]$RootDir,
        [string]$OpenClawSrcDir
    )
    $resolvedRoot = (Resolve-Path $RootDir).Path
    $mountSpec = "${resolvedRoot}:/work"
    Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @(
        "run", "--rm",
        "--volume", $mountSpec,
        "--entrypoint", "node",
        "openclaw-cli",
        "/work/scripts/split_openclaw_agents.mjs",
        "--source-dir", "/work/openclaw-agents/agents",
        "--output-dir", "/work/openclaw-agents/agents",
        "--manifest", "/work/openclaw-agents/agents/manifest.json"
    ) | Out-Null

    $manifestPath = Get-OpenClawAgentManifestPath -RootDir $RootDir
    if (-not (Test-Path $manifestPath)) {
        throw "Agent manifest was not generated: $manifestPath"
    }
}

function Get-OpenClawAgentDefinitions {
    param([string]$RootDir)
    $manifestPath = Get-OpenClawAgentManifestPath -RootDir $RootDir
    if (-not (Test-Path $manifestPath)) {
        throw "Agent manifest missing: $manifestPath"
    }
    $rawManifest = Get-Content -Path $manifestPath -Raw
    $manifest = $rawManifest | ConvertFrom-Json
    $definitions = @()
    foreach ($item in @($manifest.agents)) {
        $id = "$($item.id)".Trim()
        if ([string]::IsNullOrWhiteSpace($id)) {
            continue
        }
        $name = "$($item.name)".Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = $id
        }
        $workspace = "$($item.workspace)".Trim()
        if ([string]::IsNullOrWhiteSpace($workspace)) {
            $workspace = "/home/node/.openclaw/workspace/agents/$id"
        }
        $definitions += [PSCustomObject]@{
            Id = $id
            Name = $name
            Workspace = $workspace
            IsDefault = [bool]$item.default
        }
    }

    if ($definitions.Count -eq 0) {
        throw "No agent definitions found in $manifestPath"
    }

    if (-not ($definitions | Where-Object { $_.IsDefault })) {
        $main = $definitions | Where-Object { $_.Id -eq "main" } | Select-Object -First 1
        if ($main) {
            $main.IsDefault = $true
        }
        else {
            $definitions[0].IsDefault = $true
        }
    }

    return @(
        $definitions | Sort-Object `
            @{ Expression = { if ($_.IsDefault) { 0 } else { 1 } } }, `
            @{ Expression = { $_.Id } }
    )
}

function Sync-OpenClawAgentWorkspaces {
    param(
        [string]$RootDir,
        [string]$OpenClawSrcDir
    )
    $splitDir = Join-Path (Join-Path $RootDir "openclaw-agents") "agents"
    if (-not (Test-Path $splitDir)) {
        throw "Split agent directory missing: $splitDir"
    }
    $resolvedSplitDir = (Resolve-Path $splitDir).Path
    $mountSpec = "${resolvedSplitDir}:/tmp/openclaw-agent-defs:ro"
    $copyScript = @'
set -eu
DEST=/home/node/.openclaw/workspace/agents
mkdir -p "$DEST"
find "$DEST" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
for src in /tmp/openclaw-agent-defs/*; do
  [ -d "$src" ] || continue
  cp -a "$src" "$DEST/"
done
'@
    Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @(
        "run", "--rm",
        "--volume", $mountSpec,
        "--entrypoint", "sh",
        "openclaw-cli",
        "-lc", $copyScript
    ) | Out-Null
}

if ($env:OPENCLAW_EASY_TEST_MODE -eq "1") {
    return
}

$RootDir = $PSScriptRoot
$EnvFile = Join-Path $RootDir ".env"
$EnvExampleFile = Join-Path $RootDir ".env.example"
$SafeComposeTemplate = Join-Path $RootDir "docker-compose.safe.yml"
$script:EnvFile = $EnvFile

Require-Command docker
Require-Command git

$script:ComposeCommand = Resolve-ComposeCommand
$script:ComposeHint = $script:ComposeCommand -join " "

if (-not (Test-Path $EnvFile)) {
    Copy-Item -Path $EnvExampleFile -Destination $EnvFile -Force
    Write-Step "Created .env from .env.example"
}

Import-DotEnv -Path $EnvFile

$env:OPENAI_API_KEY = Prompt-EnvValue -Key "OPENAI_API_KEY" -Description "OpenAI key is required to run onboarding." -Required $true
$env:SUPERMEMORY_API_KEY = Prompt-EnvValue -Key "SUPERMEMORY_API_KEY" -Description "Supermemory key is optional. Skip if you do not want Supermemory." -AllowSkip $true

if (-not $env:SUPERMEMORY_OPENCLAW_API_KEY -and -not (Is-Blank $env:SUPERMEMORY_API_KEY)) {
    $env:SUPERMEMORY_OPENCLAW_API_KEY = $env:SUPERMEMORY_API_KEY
    Upsert-DotEnvValue -Path $EnvFile -Key "SUPERMEMORY_OPENCLAW_API_KEY" -Value $env:SUPERMEMORY_OPENCLAW_API_KEY
}

$supermemoryEnabled = if (Is-Blank $env:SUPERMEMORY_OPENCLAW_API_KEY) { "false" } else { "true" }
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_ENABLE_SUPERMEMORY" -Value $supermemoryEnabled

if (-not $env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME = "openclaw-easy" }
Upsert-DotEnvValue -Path $EnvFile -Key "COMPOSE_PROJECT_NAME" -Value $env:COMPOSE_PROJECT_NAME
if (-not $env:OPENCLAW_SAFE_PROJECT_NAME) { $env:OPENCLAW_SAFE_PROJECT_NAME = $env:COMPOSE_PROJECT_NAME }
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_SAFE_PROJECT_NAME" -Value $env:OPENCLAW_SAFE_PROJECT_NAME
$script:ComposeProjectName = $env:COMPOSE_PROJECT_NAME

if (-not $env:OPENCLAW_IMAGE) { $env:OPENCLAW_IMAGE = "openclaw:local" }
if (-not $env:OPENCLAW_GATEWAY_PORT) { $env:OPENCLAW_GATEWAY_PORT = "18789" }
if (-not $env:OPENCLAW_DEFAULT_CHANNEL_PLUGINS) { $env:OPENCLAW_DEFAULT_CHANNEL_PLUGINS = "telegram,whatsapp" }
if (-not $env:OPENCLAW_ALWAYS_ALLOW_EXEC) { $env:OPENCLAW_ALWAYS_ALLOW_EXEC = "false" }
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_ALWAYS_ALLOW_EXEC" -Value $env:OPENCLAW_ALWAYS_ALLOW_EXEC
if (-not $env:OPENCLAW_ENABLE_MISSION_CONTROL) { $env:OPENCLAW_ENABLE_MISSION_CONTROL = "true" }
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_ENABLE_MISSION_CONTROL" -Value $env:OPENCLAW_ENABLE_MISSION_CONTROL
if (-not $env:OPENCLAW_ENABLE_COMMAND_CENTER) { $env:OPENCLAW_ENABLE_COMMAND_CENTER = "false" }
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_ENABLE_COMMAND_CENTER" -Value $env:OPENCLAW_ENABLE_COMMAND_CENTER
if (-not $env:OPENCLAW_MISSION_CONTROL_REPO_URL) { $env:OPENCLAW_MISSION_CONTROL_REPO_URL = "https://github.com/abhi1693/openclaw-mission-control.git" }
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_REPO_URL" -Value $env:OPENCLAW_MISSION_CONTROL_REPO_URL
if (-not $env:OPENCLAW_MISSION_CONTROL_REPO_BRANCH) { $env:OPENCLAW_MISSION_CONTROL_REPO_BRANCH = "master" }
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_REPO_BRANCH" -Value $env:OPENCLAW_MISSION_CONTROL_REPO_BRANCH
if (-not $env:OPENCLAW_MISSION_CONTROL_SRC_DIR) {
    $env:OPENCLAW_MISSION_CONTROL_SRC_DIR = Join-Path (Join-Path $RootDir "vendor") "openclaw-mission-control"
}
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_SRC_DIR" -Value $env:OPENCLAW_MISSION_CONTROL_SRC_DIR
if (-not $env:OPENCLAW_MISSION_CONTROL_FRONTEND_PORT) { $env:OPENCLAW_MISSION_CONTROL_FRONTEND_PORT = "3310" }
if (-not $env:OPENCLAW_MISSION_CONTROL_BACKEND_PORT) { $env:OPENCLAW_MISSION_CONTROL_BACKEND_PORT = "8310" }
if (-not $env:OPENCLAW_MISSION_CONTROL_POSTGRES_PORT) { $env:OPENCLAW_MISSION_CONTROL_POSTGRES_PORT = "55432" }
if (-not $env:OPENCLAW_MISSION_CONTROL_REDIS_PORT) { $env:OPENCLAW_MISSION_CONTROL_REDIS_PORT = "56379" }
if (-not $env:OPENCLAW_MISSION_CONTROL_POSTGRES_DB) { $env:OPENCLAW_MISSION_CONTROL_POSTGRES_DB = "mission_control" }
if (-not $env:OPENCLAW_MISSION_CONTROL_POSTGRES_USER) { $env:OPENCLAW_MISSION_CONTROL_POSTGRES_USER = "postgres" }
if (-not $env:OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD -or $env:OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD -eq "postgres") {
    $env:OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD = New-HexToken
    Write-Host "[openclaw-easy] Generated secure Mission Control Postgres password."
}
if (-not $env:OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY) { $env:OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY = "true" }
if (-not $env:OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES) { $env:OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES = "true" }
if (-not $env:OPENCLAW_MISSION_CONTROL_SYNC_MANIFEST_AGENTS) { $env:OPENCLAW_MISSION_CONTROL_SYNC_MANIFEST_AGENTS = "true" }
if (-not $env:OPENCLAW_MISSION_CONTROL_GATEWAY_NAME) { $env:OPENCLAW_MISSION_CONTROL_GATEWAY_NAME = "OpenClaw Docker Gateway" }
if (-not $env:OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT) { $env:OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT = "/home/node/.openclaw" }
if ($null -eq $env:OPENCLAW_MISSION_CONTROL_GATEWAY_ID) { $env:OPENCLAW_MISSION_CONTROL_GATEWAY_ID = "" }
if (-not $env:OPENCLAW_MISSION_CONTROL_GATEWAY_URL) { $env:OPENCLAW_MISSION_CONTROL_GATEWAY_URL = "" }
if ($null -eq $env:OPENCLAW_MISSION_CONTROL_BASE_URL) { $env:OPENCLAW_MISSION_CONTROL_BASE_URL = "" }
if (-not $env:OPENCLAW_MISSION_CONTROL_SEED_BOARD) { $env:OPENCLAW_MISSION_CONTROL_SEED_BOARD = "true" }
if (-not $env:OPENCLAW_MISSION_CONTROL_BOARD_NAME) { $env:OPENCLAW_MISSION_CONTROL_BOARD_NAME = "Main Board" }
if (-not $env:OPENCLAW_MISSION_CONTROL_BOARD_SLUG) { $env:OPENCLAW_MISSION_CONTROL_BOARD_SLUG = "main-board" }
if ($null -eq $env:OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_ID) { $env:OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_ID = "" }
if (-not $env:OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_SLUG) { $env:OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_SLUG = $env:OPENCLAW_MISSION_CONTROL_BOARD_SLUG }
if (-not $env:OPENCLAW_MISSION_CONTROL_BOARD_DESCRIPTION) { $env:OPENCLAW_MISSION_CONTROL_BOARD_DESCRIPTION = "Primary board for OpenClaw automation." }
if (-not $env:OPENCLAW_MISSION_CONTROL_BOARD_PERSPECTIVE) { $env:OPENCLAW_MISSION_CONTROL_BOARD_PERSPECTIVE = "Pragmatic execution: prioritize outcomes, clear ownership, and fast feedback loops." }
if (-not $env:OPENCLAW_MISSION_CONTROL_BOARD_TYPE) { $env:OPENCLAW_MISSION_CONTROL_BOARD_TYPE = "goal" }
if ($null -eq $env:OPENCLAW_MISSION_CONTROL_BOARD_OBJECTIVE) { $env:OPENCLAW_MISSION_CONTROL_BOARD_OBJECTIVE = "" }
if ($null -eq $env:OPENCLAW_MISSION_CONTROL_BOARD_SUCCESS_METRICS_JSON) { $env:OPENCLAW_MISSION_CONTROL_BOARD_SUCCESS_METRICS_JSON = "" }
if ($null -eq $env:OPENCLAW_MISSION_CONTROL_BOARD_TARGET_DATE) { $env:OPENCLAW_MISSION_CONTROL_BOARD_TARGET_DATE = "" }
if (-not $env:OPENCLAW_MISSION_CONTROL_BOARD_GOAL_CONFIRMED) { $env:OPENCLAW_MISSION_CONTROL_BOARD_GOAL_CONFIRMED = "false" }
if ($null -eq $env:OPENCLAW_MISSION_CONTROL_BOARD_GOAL_SOURCE) { $env:OPENCLAW_MISSION_CONTROL_BOARD_GOAL_SOURCE = "" }
if ($null -eq $env:OPENCLAW_MISSION_CONTROL_BOARD_GROUP_ID) { $env:OPENCLAW_MISSION_CONTROL_BOARD_GROUP_ID = "" }
if (-not $env:OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS) { $env:OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS = "1" }
if ($null -eq $env:OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON) { $env:OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON = "" }
if ($null -eq $env:OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE) { $env:OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE = "" }
if (-not $env:OPENCLAW_MISSION_CONTROL_SEED_BOARD_PACK) { $env:OPENCLAW_MISSION_CONTROL_SEED_BOARD_PACK = "false" }
if ($null -eq $env:OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_JSON) { $env:OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_JSON = "" }
if ($null -eq $env:OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_FILE) { $env:OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_FILE = "" }
if (-not $env:OPENCLAW_COMMAND_CENTER_REPO_URL) { $env:OPENCLAW_COMMAND_CENTER_REPO_URL = "https://github.com/jontsai/openclaw-command-center.git" }
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_COMMAND_CENTER_REPO_URL" -Value $env:OPENCLAW_COMMAND_CENTER_REPO_URL
if (-not $env:OPENCLAW_COMMAND_CENTER_REPO_BRANCH) { $env:OPENCLAW_COMMAND_CENTER_REPO_BRANCH = "main" }
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_COMMAND_CENTER_REPO_BRANCH" -Value $env:OPENCLAW_COMMAND_CENTER_REPO_BRANCH
if (-not $env:OPENCLAW_COMMAND_CENTER_SRC_DIR) {
    $env:OPENCLAW_COMMAND_CENTER_SRC_DIR = Join-Path (Join-Path $RootDir "vendor") "openclaw-command-center"
}
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_COMMAND_CENTER_SRC_DIR" -Value $env:OPENCLAW_COMMAND_CENTER_SRC_DIR
if (-not $env:OPENCLAW_COMMAND_CENTER_PORT) { $env:OPENCLAW_COMMAND_CENTER_PORT = "3340" }
if (-not $env:OPENCLAW_COMMAND_CENTER_AUTH_MODE) { $env:OPENCLAW_COMMAND_CENTER_AUTH_MODE = "token" }
if ($null -eq $env:OPENCLAW_COMMAND_CENTER_TOKEN) { $env:OPENCLAW_COMMAND_CENTER_TOKEN = "" }
$commandCenterAuthMode = "$($env:OPENCLAW_COMMAND_CENTER_AUTH_MODE)".Trim().ToLowerInvariant()
if ($commandCenterAuthMode -eq "token" -and (Is-Blank $env:OPENCLAW_COMMAND_CENTER_TOKEN)) {
    $env:OPENCLAW_COMMAND_CENTER_TOKEN = New-HexToken
    Write-Host "[openclaw-easy] Generated Command Center dashboard token."
}
if (-not $env:OPENCLAW_COMMAND_CENTER_ALLOWED_USERS) { $env:OPENCLAW_COMMAND_CENTER_ALLOWED_USERS = "*" }
if (-not $env:OPENCLAW_COMMAND_CENTER_ALLOWED_IPS) { $env:OPENCLAW_COMMAND_CENTER_ALLOWED_IPS = "127.0.0.1,::1" }
if ($null -eq $env:OPENCLAW_COMMAND_CENTER_OPENCLAW_PROFILE) { $env:OPENCLAW_COMMAND_CENTER_OPENCLAW_PROFILE = "" }
$gatewayPortReserved = Convert-ToPortNumber -Value $env:OPENCLAW_GATEWAY_PORT -Fallback 18789
$requestedMcFrontendPort = Convert-ToPortNumber -Value $env:OPENCLAW_MISSION_CONTROL_FRONTEND_PORT -Fallback 3310
$requestedMcBackendPort = Convert-ToPortNumber -Value $env:OPENCLAW_MISSION_CONTROL_BACKEND_PORT -Fallback 8310
$requestedMcPostgresPort = Convert-ToPortNumber -Value $env:OPENCLAW_MISSION_CONTROL_POSTGRES_PORT -Fallback 55432
$requestedMcRedisPort = Convert-ToPortNumber -Value $env:OPENCLAW_MISSION_CONTROL_REDIS_PORT -Fallback 56379
$requestedCommandCenterPort = Convert-ToPortNumber -Value $env:OPENCLAW_COMMAND_CENTER_PORT -Fallback 3340
$reservedPorts = New-Object System.Collections.Generic.List[int]
$reservedPorts.Add($gatewayPortReserved) | Out-Null
$resolvedMcFrontendPort = Resolve-AvailablePort -PreferredPort $requestedMcFrontendPort -ReservedPorts @($reservedPorts)
$reservedPorts.Add($resolvedMcFrontendPort) | Out-Null
$resolvedMcBackendPort = Resolve-AvailablePort -PreferredPort $requestedMcBackendPort -ReservedPorts @($reservedPorts)
$reservedPorts.Add($resolvedMcBackendPort) | Out-Null
$resolvedMcPostgresPort = Resolve-AvailablePort -PreferredPort $requestedMcPostgresPort -ReservedPorts @($reservedPorts)
$reservedPorts.Add($resolvedMcPostgresPort) | Out-Null
$resolvedMcRedisPort = Resolve-AvailablePort -PreferredPort $requestedMcRedisPort -ReservedPorts @($reservedPorts)
$reservedPorts.Add($resolvedMcRedisPort) | Out-Null
$resolvedCommandCenterPort = Resolve-AvailablePort -PreferredPort $requestedCommandCenterPort -ReservedPorts @($reservedPorts)
$env:OPENCLAW_MISSION_CONTROL_FRONTEND_PORT = "$resolvedMcFrontendPort"
$env:OPENCLAW_MISSION_CONTROL_BACKEND_PORT = "$resolvedMcBackendPort"
$env:OPENCLAW_MISSION_CONTROL_POSTGRES_PORT = "$resolvedMcPostgresPort"
$env:OPENCLAW_MISSION_CONTROL_REDIS_PORT = "$resolvedMcRedisPort"
$env:OPENCLAW_COMMAND_CENTER_PORT = "$resolvedCommandCenterPort"
if ($resolvedMcFrontendPort -ne $requestedMcFrontendPort) {
    Write-Host "[openclaw-easy] Mission Control frontend port $requestedMcFrontendPort is busy; using $resolvedMcFrontendPort."
}
if ($resolvedMcBackendPort -ne $requestedMcBackendPort) {
    Write-Host "[openclaw-easy] Mission Control backend port $requestedMcBackendPort is busy; using $resolvedMcBackendPort."
}
if ($resolvedMcPostgresPort -ne $requestedMcPostgresPort) {
    Write-Host "[openclaw-easy] Mission Control postgres port $requestedMcPostgresPort is busy; using $resolvedMcPostgresPort."
}
if ($resolvedMcRedisPort -ne $requestedMcRedisPort) {
    Write-Host "[openclaw-easy] Mission Control redis port $requestedMcRedisPort is busy; using $resolvedMcRedisPort."
}
if ($resolvedCommandCenterPort -ne $requestedCommandCenterPort) {
    Write-Host "[openclaw-easy] Command Center port $requestedCommandCenterPort is busy; using $resolvedCommandCenterPort."
}
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_FRONTEND_PORT" -Value $env:OPENCLAW_MISSION_CONTROL_FRONTEND_PORT
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BACKEND_PORT" -Value $env:OPENCLAW_MISSION_CONTROL_BACKEND_PORT
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_POSTGRES_PORT" -Value $env:OPENCLAW_MISSION_CONTROL_POSTGRES_PORT
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_REDIS_PORT" -Value $env:OPENCLAW_MISSION_CONTROL_REDIS_PORT
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_POSTGRES_DB" -Value $env:OPENCLAW_MISSION_CONTROL_POSTGRES_DB
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_POSTGRES_USER" -Value $env:OPENCLAW_MISSION_CONTROL_POSTGRES_USER
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD" -Value $env:OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY" -Value $env:OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES" -Value $env:OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_SYNC_MANIFEST_AGENTS" -Value $env:OPENCLAW_MISSION_CONTROL_SYNC_MANIFEST_AGENTS
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_GATEWAY_NAME" -Value $env:OPENCLAW_MISSION_CONTROL_GATEWAY_NAME
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT" -Value $env:OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_GATEWAY_ID" -Value $env:OPENCLAW_MISSION_CONTROL_GATEWAY_ID
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_GATEWAY_URL" -Value $env:OPENCLAW_MISSION_CONTROL_GATEWAY_URL
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BASE_URL" -Value $env:OPENCLAW_MISSION_CONTROL_BASE_URL
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_SEED_BOARD" -Value $env:OPENCLAW_MISSION_CONTROL_SEED_BOARD
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_NAME" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_NAME
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_SLUG" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_SLUG
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_ID" -Value $env:OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_ID
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_SLUG" -Value $env:OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_SLUG
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_DESCRIPTION" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_DESCRIPTION
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_PERSPECTIVE" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_PERSPECTIVE
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_TYPE" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_TYPE
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_OBJECTIVE" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_OBJECTIVE
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_SUCCESS_METRICS_JSON" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_SUCCESS_METRICS_JSON
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_TARGET_DATE" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_TARGET_DATE
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_GOAL_CONFIRMED" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_GOAL_CONFIRMED
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_GOAL_SOURCE" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_GOAL_SOURCE
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_GROUP_ID" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_GROUP_ID
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_SEED_BOARD_PACK" -Value $env:OPENCLAW_MISSION_CONTROL_SEED_BOARD_PACK
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_JSON" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_JSON
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_FILE" -Value $env:OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_FILE
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_COMMAND_CENTER_PORT" -Value $env:OPENCLAW_COMMAND_CENTER_PORT
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_COMMAND_CENTER_AUTH_MODE" -Value $env:OPENCLAW_COMMAND_CENTER_AUTH_MODE
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_COMMAND_CENTER_TOKEN" -Value $env:OPENCLAW_COMMAND_CENTER_TOKEN
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_COMMAND_CENTER_ALLOWED_USERS" -Value $env:OPENCLAW_COMMAND_CENTER_ALLOWED_USERS
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_COMMAND_CENTER_ALLOWED_IPS" -Value $env:OPENCLAW_COMMAND_CENTER_ALLOWED_IPS
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_COMMAND_CENTER_OPENCLAW_PROFILE" -Value $env:OPENCLAW_COMMAND_CENTER_OPENCLAW_PROFILE
if (-not $env:OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN) {
    $env:OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN = New-HexToken + New-HexToken
    Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN" -Value $env:OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN
}
if (-not $env:OPENCLAW_DOCKER_APT_PACKAGES) { $env:OPENCLAW_DOCKER_APT_PACKAGES = "chromium git python3 python3-pip sudo" }
if ($env:OPENCLAW_DOCKER_APT_PACKAGES -notmatch "(^|\s)chromium(\s|$)") {
    $env:OPENCLAW_DOCKER_APT_PACKAGES = "$($env:OPENCLAW_DOCKER_APT_PACKAGES) chromium".Trim()
}
if ($env:OPENCLAW_DOCKER_APT_PACKAGES -notmatch "(^|\s)git(\s|$)") {
    $env:OPENCLAW_DOCKER_APT_PACKAGES = "$($env:OPENCLAW_DOCKER_APT_PACKAGES) git".Trim()
}
if ($env:OPENCLAW_DOCKER_APT_PACKAGES -notmatch "(^|\s)python3(\s|$)") {
    $env:OPENCLAW_DOCKER_APT_PACKAGES = "$($env:OPENCLAW_DOCKER_APT_PACKAGES) python3".Trim()
}
if ($env:OPENCLAW_DOCKER_APT_PACKAGES -notmatch "(^|\s)python3-pip(\s|$)") {
    $env:OPENCLAW_DOCKER_APT_PACKAGES = "$($env:OPENCLAW_DOCKER_APT_PACKAGES) python3-pip".Trim()
}
if ($env:OPENCLAW_DOCKER_APT_PACKAGES -notmatch "(^|\s)sudo(\s|$)") {
    $env:OPENCLAW_DOCKER_APT_PACKAGES = "$($env:OPENCLAW_DOCKER_APT_PACKAGES) sudo".Trim()
}

if (-not $env:OPENCLAW_GATEWAY_TOKEN) {
    $env:OPENCLAW_GATEWAY_TOKEN = New-HexToken
    Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_GATEWAY_TOKEN" -Value $env:OPENCLAW_GATEWAY_TOKEN
    Write-Step "Generated OPENCLAW_GATEWAY_TOKEN and saved it to .env"
}

if (-not $env:OPENCLAW_REPO_URL) { $env:OPENCLAW_REPO_URL = "https://github.com/openclaw/openclaw.git" }
if (-not $env:OPENCLAW_REPO_BRANCH -or $env:OPENCLAW_REPO_BRANCH -eq "v2026.2.14") {
    $env:OPENCLAW_REPO_BRANCH = "main"
    Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_REPO_BRANCH" -Value $env:OPENCLAW_REPO_BRANCH
}

if ((-not $env:OPENCLAW_USE_LOCAL_SOURCE -or $env:OPENCLAW_USE_LOCAL_SOURCE -eq "auto") -and -not $env:OPENCLAW_SRC_DIR) {
    $localRepo = Find-LocalOpenClawRepo -BaseDir $RootDir
    if ($localRepo) {
        $env:OPENCLAW_USE_LOCAL_SOURCE = "true"
        $env:OPENCLAW_SRC_DIR = $localRepo
        Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_USE_LOCAL_SOURCE" -Value $env:OPENCLAW_USE_LOCAL_SOURCE
        Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_SRC_DIR" -Value $env:OPENCLAW_SRC_DIR
    }
}

$OpenClawSrcDir = if ($env:OPENCLAW_SRC_DIR) {
    $env:OPENCLAW_SRC_DIR
}
else {
    Join-Path (Join-Path $RootDir "vendor") "openclaw"
}
$env:OPENCLAW_SRC_DIR = $OpenClawSrcDir

if ($env:OPENCLAW_USE_LOCAL_SOURCE -eq "true") {
    if (-not (Test-Path $OpenClawSrcDir)) {
        throw "OPENCLAW_USE_LOCAL_SOURCE=true but source directory does not exist: $OpenClawSrcDir"
    }
    if (-not (Test-OpenClawRepoLayout -Path $OpenClawSrcDir)) {
        $fallbackSrcDir = Join-Path (Join-Path $RootDir "vendor") "openclaw"
        Write-Step "OPENCLAW_USE_LOCAL_SOURCE=true but source directory is not a valid OpenClaw repo: $OpenClawSrcDir"
        Write-Step "Falling back to managed clone at: $fallbackSrcDir"
        $env:OPENCLAW_USE_LOCAL_SOURCE = "false"
        Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_USE_LOCAL_SOURCE" -Value $env:OPENCLAW_USE_LOCAL_SOURCE
        $OpenClawSrcDir = $fallbackSrcDir
        $env:OPENCLAW_SRC_DIR = $OpenClawSrcDir
        Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_SRC_DIR" -Value $env:OPENCLAW_SRC_DIR
    }
    else {
        Write-Step "Using local OpenClaw source: $OpenClawSrcDir"
    }
}
elseif (Test-Path (Join-Path $OpenClawSrcDir ".git")) {
    Write-Step "Updating OpenClaw source: $OpenClawSrcDir"
    & git -C $OpenClawSrcDir fetch --depth 1 --force origin $env:OPENCLAW_REPO_BRANCH
    if ($LASTEXITCODE -ne 0) {
        Write-Step "Update failed, recloning OpenClaw source"
        Clone-OpenClawRepo -RepoUrl $env:OPENCLAW_REPO_URL -RepoBranch $env:OPENCLAW_REPO_BRANCH -Destination $OpenClawSrcDir
    }
    else {
        & git -C $OpenClawSrcDir checkout --force FETCH_HEAD
        if ($LASTEXITCODE -ne 0) {
            Write-Step "Update failed, recloning OpenClaw source"
            Clone-OpenClawRepo -RepoUrl $env:OPENCLAW_REPO_URL -RepoBranch $env:OPENCLAW_REPO_BRANCH -Destination $OpenClawSrcDir
        }
    }
}
else {
    Write-Step "Cloning OpenClaw source"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OpenClawSrcDir) | Out-Null
    Clone-OpenClawRepo -RepoUrl $env:OPENCLAW_REPO_URL -RepoBranch $env:OPENCLAW_REPO_BRANCH -Destination $OpenClawSrcDir
}

$safeComposeTarget = Join-Path $OpenClawSrcDir "docker-compose.safe.yml"
if (-not (Test-Path $SafeComposeTemplate)) {
    throw "Missing starter compose template: $SafeComposeTemplate"
}
Copy-Item -Path $SafeComposeTemplate -Destination $safeComposeTarget -Force
Write-Step "Synced docker-compose.safe.yml into cloned OpenClaw repo"

$vendorEnvFile = Join-Path $OpenClawSrcDir ".env"
Copy-Item -Path $EnvFile -Destination $vendorEnvFile -Force
$script:ComposeEnvFile = $vendorEnvFile
Write-Step "Synced .env into cloned OpenClaw repo"

Write-Step "Building OpenClaw image"
& docker build `
    --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=$($env:OPENCLAW_DOCKER_APT_PACKAGES)" `
    -t $env:OPENCLAW_IMAGE `
    -f (Join-Path $OpenClawSrcDir "Dockerfile") `
    $OpenClawSrcDir
Assert-LastExitCode "docker build"

Write-Step "Initializing gateway + auth"
 $gatewayAuthBatch = @(
    (New-OpenClawCliLine @("config", "set", "gateway.mode", "local")),
    (New-OpenClawCliLine @("config", "set", "gateway.auth.mode", "token")),
    (New-OpenClawCliLine @("config", "set", "gateway.auth.token", $env:OPENCLAW_GATEWAY_TOKEN)),
    (New-OpenClawCliLine @("config", "set", "gateway.controlUi.allowInsecureAuth", "true", "--json")),
    (New-OpenClawCliLine @("config", "set", "gateway.controlUi.dangerouslyDisableDeviceAuth", "true", "--json"))
 )
Invoke-OpenClawCliBatch -OpenClawSrcDir $OpenClawSrcDir -Lines $gatewayAuthBatch -Quiet | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @(
    "run", "--rm", "openclaw-cli", "onboard",
    "--non-interactive", "--accept-risk",
    "--auth-choice", "openai-api-key",
    "--openai-api-key", $env:OPENAI_API_KEY,
    "--skip-channels", "--skip-skills", "--skip-health", "--no-install-daemon"
) | Out-Null
Invoke-OpenClawCliBatch -OpenClawSrcDir $OpenClawSrcDir -Lines $gatewayAuthBatch -Quiet | Out-Null

Write-Step "Loading local agent specs from openclaw-agents/agents"
Split-OpenClawAgentFiles -RootDir $RootDir -OpenClawSrcDir $OpenClawSrcDir
$agentDefinitions = Get-OpenClawAgentDefinitions -RootDir $RootDir
Sync-OpenClawAgentWorkspaces -RootDir $RootDir -OpenClawSrcDir $OpenClawSrcDir

Write-Step "Applying defaults (CLI backends, concurrency, agent pack)"
$alwaysAllowExec = Is-Truthy -Value $env:OPENCLAW_ALWAYS_ALLOW_EXEC

$defaultsBatch = New-Object System.Collections.Generic.List[string]
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.cliBackends[claude-cli].command", "/home/node/.openclaw/tools/bin/claude")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.cliBackends[codex-cli].command", "/home/node/.openclaw/tools/bin/codex")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.cliBackends[codex-cli].env.OPENAI_API_KEY", '${OPENAI_API_KEY}')))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.subagents.maxConcurrent", "8", "--json")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.model.primary", "openai/gpt-5.2")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "unset", "agents.defaults.model.fallbacks")) + " || true")
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.model.fallbacks[0]", "openai/gpt-5-mini")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.maxConcurrent", "10", "--json")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.enabled", "true", "--json")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.provider", "openai")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "unset", "agents.defaults.memorySearch.sources")) + " || true")
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.sources[0]", "memory")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.sources[1]", "sessions")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.experimental.sessionMemory", "true", "--json")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.sync.onSessionStart", "true", "--json")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.sync.onSearch", "true", "--json")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "browser.enabled", "true", "--json")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "browser.headless", "true", "--json")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "browser.noSandbox", "true", "--json")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "browser.defaultProfile", "openclaw")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "unset", "agents.list")) + " || true")
for ($i = 0; $i -lt $agentDefinitions.Count; $i++) {
    $agent = $agentDefinitions[$i]
    $defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.list[$i].id", $agent.Id)))
    $defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.list[$i].name", $agent.Name)))
    $defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.list[$i].identity.name", $agent.Name)))
    $defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.list[$i].workspace", $agent.Workspace)))
    if ($agent.IsDefault) {
        $defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.list[$i].default", "true")))
        $defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "agents.list[$i].subagents.allowAgents[0]", "*")))
    }
}
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "tools.agentToAgent.enabled", "true", "--json")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "unset", "tools.agentToAgent.allow")) + " || true")
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "tools.agentToAgent.allow[0]", "*")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "commands.bash", "true", "--json")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "tools.elevated.enabled", "true", "--json")))
$defaultsBatch.Add((New-OpenClawCliLine @("config", "unset", "tools.elevated.allowFrom.web")) + " || true")
$defaultsBatch.Add((New-OpenClawCliLine @("config", "unset", "tools.elevated.allowFrom.webchat")) + " || true")
$defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "tools.elevated.allowFrom.webchat[0]", "*")))
if ($alwaysAllowExec) {
    $defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "tools.exec.ask", "off")))
    $defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "tools.exec.security", "full")))
}
else {
    $defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "tools.exec.ask", "on-miss")))
    $defaultsBatch.Add((New-OpenClawCliLine @("config", "set", "tools.exec.security", "allowlist")))
}
Invoke-OpenClawCliBatch -OpenClawSrcDir $OpenClawSrcDir -Lines $defaultsBatch -Quiet | Out-Null
Set-ExecApprovalMode -OpenClawSrcDir $OpenClawSrcDir -AlwaysAllowExec $alwaysAllowExec

if ($supermemoryEnabled -eq "true") {
    Write-Step "Installing and configuring Supermemory plugin"
    $pluginInfo = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "plugins", "info", "openclaw-supermemory", "--json") -Capture -IgnoreExitCode
    if ($pluginInfo.Code -ne 0) {
        Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "plugins", "install", "@supermemory/openclaw-supermemory") | Out-Null
    }
    Invoke-OpenClawCliBatch -OpenClawSrcDir $OpenClawSrcDir -Lines @(
        (New-OpenClawCliLine @("config", "set", "plugins.entries.openclaw-supermemory.enabled", "true", "--json")),
        (New-OpenClawCliLine @("config", "set", "plugins.entries.openclaw-supermemory.config.apiKey", '${SUPERMEMORY_OPENCLAW_API_KEY}'))
    ) -Quiet | Out-Null
}
else {
    Write-Step "Skipping Supermemory plugin (no key provided)"
    Invoke-OpenClawCliBatch -OpenClawSrcDir $OpenClawSrcDir -Lines @(
        (New-OpenClawCliLine @("config", "set", "plugins.entries.openclaw-supermemory.enabled", "false", "--json"))
    ) -Quiet -IgnoreExitCode | Out-Null
}

Write-Step "Bootstrapping tools + skills"
$bootstrapScript = @'
set -eu
WORKSPACE=/home/node/.openclaw/workspace
TMP_DIR="$WORKSPACE/tmp"
SKILLS_DIR="$WORKSPACE/skills"
TOOLS_DIR=/home/node/.openclaw/tools
CLAWHUB_BIN="$TOOLS_DIR/bin/clawhub"

mkdir -p "$TMP_DIR" "$SKILLS_DIR" "$TOOLS_DIR"
PROFILE_FILE=/home/node/.profile
if [ -f "$PROFILE_FILE" ]; then
  grep -Fq 'export PATH="$HOME/.local/bin:$HOME/.openclaw/tools/bin:$PATH"' "$PROFILE_FILE" || echo 'export PATH="$HOME/.local/bin:$HOME/.openclaw/tools/bin:$PATH"' >> "$PROFILE_FILE"
else
  echo 'export PATH="$HOME/.local/bin:$HOME/.openclaw/tools/bin:$PATH"' > "$PROFILE_FILE"
fi

npm i -g clawhub --prefix "$TOOLS_DIR"
rm -f "$TOOLS_DIR/bin/claude" "$TOOLS_DIR/bin/codex" "$TOOLS_DIR/bin/playwright"
npm i -g @anthropic-ai/claude-code @openai/codex playwright --prefix "$TOOLS_DIR" --force

cat > "$TOOLS_DIR/bin/openclaw" <<'EOF'
#!/usr/bin/env sh
set -eu
exec node /app/dist/index.js "$@"
EOF
chmod +x "$TOOLS_DIR/bin/openclaw"

cat > "$TOOLS_DIR/bin/agent-browser" <<'EOF'
#!/usr/bin/env sh
set -eu

OPENCLAW_BIN=/home/node/.openclaw/tools/bin/openclaw
if [ ! -x $OPENCLAW_BIN ]; then
  OPENCLAW_BIN=openclaw
fi

cmd=${1-}
if [ $# -gt 0 ]; then
  shift
fi

case ${cmd-} in
  -h|--help|help|'')
    exec $OPENCLAW_BIN browser --help
    ;;
  -v|--version|version)
    exec $OPENCLAW_BIN --version
    ;;
  open)
    exec $OPENCLAW_BIN browser open $@
    ;;
  snapshot)
    if [ x${1-} = x-i ]; then
      shift
      exec $OPENCLAW_BIN browser snapshot --interactive $@
    fi
    exec $OPENCLAW_BIN browser snapshot $@
    ;;
  screenshot)
    exec $OPENCLAW_BIN browser screenshot $@
    ;;
  close)
    exec $OPENCLAW_BIN browser close $@
    ;;
  *)
    exec $OPENCLAW_BIN browser ${cmd-} $@
    ;;
esac
EOF
chmod +x "$TOOLS_DIR/bin/agent-browser"

export PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright
mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
if command -v sudo >/dev/null 2>&1; then
  sudo -n "$TOOLS_DIR/bin/playwright" install --with-deps chromium >/dev/null 2>&1 || "$TOOLS_DIR/bin/playwright" install chromium >/dev/null 2>&1 || true
else
  "$TOOLS_DIR/bin/playwright" install chromium >/dev/null 2>&1 || true
fi

rm -rf "$TMP_DIR/anthropics-skills"
git clone --depth 1 https://github.com/anthropics/skills "$TMP_DIR/anthropics-skills"
if [ -d "$TMP_DIR/anthropics-skills/skills" ]; then
  cp -a "$TMP_DIR/anthropics-skills/skills/." "$SKILLS_DIR/"
fi

rm -rf "$TMP_DIR/vercel-agent-skills"
git clone --depth 1 https://github.com/vercel-labs/agent-skills "$TMP_DIR/vercel-agent-skills"
if [ -d "$TMP_DIR/vercel-agent-skills/skills" ]; then
  cp -a "$TMP_DIR/vercel-agent-skills/skills/." "$SKILLS_DIR/"
fi

rm -rf "$TMP_DIR/openclaw-community-skills"
git clone --depth 1 https://github.com/openclaw/skills "$TMP_DIR/openclaw-community-skills"
for pair in \
  gxsy886/downloads \
  itsahedge/agent-council \
  nguyenphutrong/agentlens \
  satyajiit/aster \
  jasonfdg/bidclub \
  hexnickk/claude-optimised \
  bowen31337/create-agent-skills \
  qrucio/anthropic-frontend-design \
  tommygeoco/ui-audit \
  adinvadim/2captcha \
  dowingard/agent-zero-bridge \
  murphykobe/agent-browser-2 \
  lucasgeeksinthewood/dating \
  steipete/local-places \
  tiborera/clawexchange \
  felo-sparticle/clawdwork \
  seyhunak/deep-research \
  nextfrontierbuilds/web-qa-bot \
  myestery/verify-on-browser \
  iahmadzain/home-assistant \
  gumadeiras/playwright-cli \
  alirezarezvani/quality-manager-qmr \
  nextfrontierbuilds/skill-scaffold \
  alirezarezvani/tdd-guide \
  alirezarezvani/cto-advisor \
  autogame-17/evolver \
  steipete/coding-agent
do
  owner="${pair%%/*}"
  skill="${pair##*/}"
  src="$TMP_DIR/openclaw-community-skills/skills/$owner/$skill"
  if [ -d "$src" ]; then
    rm -rf "$SKILLS_DIR/$skill"
    cp -a "$src" "$SKILLS_DIR/$skill"
  fi
done

rm -rf "$TMP_DIR/openclaw-supermemory"
git clone --depth 1 https://github.com/supermemoryai/openclaw-supermemory "$TMP_DIR/openclaw-supermemory"

export PATH="$TOOLS_DIR/bin:$PATH"
cd "$WORKSPACE"
for slug in gmail github automation-workflows playwright-mcp summarize weather skill-creator openclaw-github-assistant github-mcp github-cli github-automation-pro; do
  "$CLAWHUB_BIN" install "$slug" --force || "$CLAWHUB_BIN" update "$slug" || true
done

# ClawHub installs can replace wrappers; enforce executable bits again.
chmod +x "$TOOLS_DIR/bin/openclaw" "$TOOLS_DIR/bin/agent-browser" || true
'@
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "--entrypoint", "sh", "openclaw-cli", "-lc", $bootstrapScript) | Out-Null

Write-Step "Finalizing CLI backend commands"
Invoke-OpenClawCliBatch -OpenClawSrcDir $OpenClawSrcDir -Lines @(
    (New-OpenClawCliLine @("config", "set", "agents.defaults.cliBackends[claude-cli].command", "/home/node/.openclaw/tools/bin/claude")),
    (New-OpenClawCliLine @("config", "set", "agents.defaults.cliBackends[codex-cli].command", "/home/node/.openclaw/tools/bin/codex")),
    (New-OpenClawCliLine @("config", "set", "agents.defaults.cliBackends[codex-cli].env.OPENAI_API_KEY", '${OPENAI_API_KEY}'))
) -Quiet | Out-Null

Write-Step "Priming long-memory search index"
$memoryIndex = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "memory", "index", "--agent", "main") -Capture -IgnoreExitCode
if ($memoryIndex.Code -ne 0) {
    Write-Host "[openclaw-easy] Memory index warmup failed (continuing)."
}

Write-Step "Enabling channel plugins for Control UI schema"
$defaultChannelPlugins = Parse-ChannelPluginList -Value $env:OPENCLAW_DEFAULT_CHANNEL_PLUGINS
foreach ($pluginId in $defaultChannelPlugins) {
    $enableResult = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "plugins", "enable", $pluginId) -Capture -IgnoreExitCode
    if ($enableResult.Code -ne 0) {
        Write-Host "[openclaw-easy] Could not enable channel plugin '$pluginId' (continuing)."
    }
}

Write-Step "Starting gateway"
Stop-LegacyComposeProjects -OpenClawSrcDir $OpenClawSrcDir
Clear-StaleBrowserProfileLocks -OpenClawSrcDir $OpenClawSrcDir
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("up", "-d", "openclaw-gateway") -IgnoreExitCode | Out-Null
Start-Sleep -Seconds 2

Write-Step "Health check"
$healthy = $false
for ($attempt = 1; $attempt -le 60; $attempt++) {
    if ($attempt -eq 1 -or ($attempt % 5) -eq 0) {
        Write-Host "[openclaw-easy] waiting for gateway port 127.0.0.1:$($env:OPENCLAW_GATEWAY_PORT) (attempt $attempt/60)"
    }
    if (Test-GatewayHttp -Port $env:OPENCLAW_GATEWAY_PORT) {
        $healthy = $true
        break
    }
    if ($attempt -eq 1 -or ($attempt % 4) -eq 0) {
        Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("up", "-d", "openclaw-gateway") -IgnoreExitCode | Out-Null
        $status = Get-GatewayContainerStatus -OpenClawSrcDir $OpenClawSrcDir
        if ($status) {
            Write-Host "[openclaw-easy] gateway status: $status"
        } else {
            Write-Host "[openclaw-easy] gateway status: unknown"
        }
    }
    Start-Sleep -Seconds 2
}
if (-not $healthy) {
    Write-Host "[openclaw-easy] gateway ps:"
    $psResult = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("ps") -Capture -IgnoreExitCode
    foreach ($line in @($psResult.Output)) {
        Write-Host $line
    }
    Write-Host "[openclaw-easy] gateway logs (last 120 lines):"
    $logs = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("logs", "--tail=120", "openclaw-gateway") -Capture -IgnoreExitCode
    foreach ($line in @($logs.Output)) {
        Write-Host $line
    }
    throw "Gateway health check failed after retries."
}

Write-Step "Warming browser control service"
$browserReady = $false
for ($attempt = 1; $attempt -le 15; $attempt++) {
    $probe = Test-BrowserControlService -OpenClawSrcDir $OpenClawSrcDir
    if ($probe.Ready) {
        $browserReady = $true
        break
    }
    if ($attempt -eq 1 -or ($attempt % 5) -eq 0) {
        Write-Host "[openclaw-easy] browser probe retry $attempt/15: $($probe.Detail)"
    }
    Start-Sleep -Seconds 2
}
if (-not $browserReady) {
    Write-Host "[openclaw-easy] gateway logs (last 120 lines):"
    $logs = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("logs", "--tail=120", "openclaw-gateway") -Capture -IgnoreExitCode
    foreach ($line in @($logs.Output)) {
        Write-Host $line
    }
    Write-Host "[openclaw-easy] Browser warmup probe failed after retries (continuing)."
    Write-Host "[openclaw-easy] Gateway is running; browser service may initialize on first browser action."
}

Approve-LocalPendingDevicePairings -OpenClawSrcDir $OpenClawSrcDir
Initialize-AgentMainSessions -OpenClawSrcDir $OpenClawSrcDir -AgentDefinitions $agentDefinitions

$missionControlEnabled = Is-Truthy -Value $env:OPENCLAW_ENABLE_MISSION_CONTROL
$missionControlDashboardUrl = ""
$missionControlSeedBoardSummary = ""
$missionControlSeedBoardId = ""
$missionControlRegisteredGatewayUrl = ""
$missionControlRegisteredGatewayId = ""
$commandCenterEnabled = Is-Truthy -Value $env:OPENCLAW_ENABLE_COMMAND_CENTER
$commandCenterDashboardUrl = ""
if ($missionControlEnabled) {
    $MissionControlSrcDir = $env:OPENCLAW_MISSION_CONTROL_SRC_DIR
    if (-not $MissionControlSrcDir) {
        $MissionControlSrcDir = Join-Path (Join-Path $RootDir "vendor") "openclaw-mission-control"
        $env:OPENCLAW_MISSION_CONTROL_SRC_DIR = $MissionControlSrcDir
        Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_SRC_DIR" -Value $MissionControlSrcDir
    }

    if (Test-Path (Join-Path $MissionControlSrcDir ".git")) {
        Write-Step "Updating Mission Control source: $MissionControlSrcDir"
        & git -C $MissionControlSrcDir fetch --depth 1 --force origin $env:OPENCLAW_MISSION_CONTROL_REPO_BRANCH
        if ($LASTEXITCODE -ne 0) {
            Write-Step "Mission Control update failed, recloning"
            Clone-MissionControlRepo -RepoUrl $env:OPENCLAW_MISSION_CONTROL_REPO_URL -RepoBranch $env:OPENCLAW_MISSION_CONTROL_REPO_BRANCH -Destination $MissionControlSrcDir
        }
        else {
            & git -C $MissionControlSrcDir checkout --force FETCH_HEAD
            if ($LASTEXITCODE -ne 0) {
                Write-Step "Mission Control update failed, recloning"
                Clone-MissionControlRepo -RepoUrl $env:OPENCLAW_MISSION_CONTROL_REPO_URL -RepoBranch $env:OPENCLAW_MISSION_CONTROL_REPO_BRANCH -Destination $MissionControlSrcDir
            }
        }
    }
    else {
        Write-Step "Cloning Mission Control source"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $MissionControlSrcDir) | Out-Null
        Clone-MissionControlRepo -RepoUrl $env:OPENCLAW_MISSION_CONTROL_REPO_URL -RepoBranch $env:OPENCLAW_MISSION_CONTROL_REPO_BRANCH -Destination $MissionControlSrcDir
    }
    Patch-MissionControlSecurityBaselines -MissionControlSrcDir $MissionControlSrcDir
    Patch-MissionControlGatewayScopes -MissionControlSrcDir $MissionControlSrcDir
    Patch-MissionControlOnboardingRecovery -MissionControlSrcDir $MissionControlSrcDir
    Patch-MissionControlOnboardingSessionIsolation -MissionControlSrcDir $MissionControlSrcDir
    Patch-MissionControlOnboardingAgentLabels -MissionControlSrcDir $MissionControlSrcDir

    $missionControlEnvFile = Join-Path $MissionControlSrcDir ".env"
    $missionControlEnvExample = Join-Path $MissionControlSrcDir ".env.example"
    if (-not (Test-Path $missionControlEnvFile) -and (Test-Path $missionControlEnvExample)) {
        Copy-Item -Path $missionControlEnvExample -Destination $missionControlEnvFile -Force
    }
    if (-not (Test-Path $missionControlEnvFile)) {
        throw "Mission Control .env file is missing at $missionControlEnvFile"
    }

    $missionControlFrontendPort = if ($env:OPENCLAW_MISSION_CONTROL_FRONTEND_PORT) { $env:OPENCLAW_MISSION_CONTROL_FRONTEND_PORT } else { "3310" }
    $missionControlBackendPort = if ($env:OPENCLAW_MISSION_CONTROL_BACKEND_PORT) { $env:OPENCLAW_MISSION_CONTROL_BACKEND_PORT } else { "8310" }
    $missionControlPostgresPort = if ($env:OPENCLAW_MISSION_CONTROL_POSTGRES_PORT) { $env:OPENCLAW_MISSION_CONTROL_POSTGRES_PORT } else { "55432" }
    $missionControlRedisPort = if ($env:OPENCLAW_MISSION_CONTROL_REDIS_PORT) { $env:OPENCLAW_MISSION_CONTROL_REDIS_PORT } else { "56379" }
    $missionControlBackendContainerHost = "$($script:ComposeProjectName)-mission-control-backend-1"
    $missionControlBaseUrl = if (Is-Blank $env:OPENCLAW_MISSION_CONTROL_BASE_URL) { "http://$missionControlBackendContainerHost`:8000" } else { $env:OPENCLAW_MISSION_CONTROL_BASE_URL }
    $env:OPENCLAW_MISSION_CONTROL_BASE_URL = $missionControlBaseUrl
    Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BASE_URL" -Value $env:OPENCLAW_MISSION_CONTROL_BASE_URL
    $missionControlBackendUrl = "http://127.0.0.1:$missionControlBackendPort"
    $missionControlFrontendUrl = "http://127.0.0.1:$missionControlFrontendPort"
    $missionControlToken = $env:OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN
    if (Is-Blank $missionControlToken) {
        $missionControlToken = New-HexToken + New-HexToken
        $env:OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN = $missionControlToken
        Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN" -Value $missionControlToken
    }

    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "FRONTEND_PORT" -Value $missionControlFrontendPort
    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "BACKEND_PORT" -Value $missionControlBackendPort
    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "POSTGRES_PORT" -Value $missionControlPostgresPort
    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "REDIS_PORT" -Value $missionControlRedisPort
    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "POSTGRES_DB" -Value $env:OPENCLAW_MISSION_CONTROL_POSTGRES_DB
    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "POSTGRES_USER" -Value $env:OPENCLAW_MISSION_CONTROL_POSTGRES_USER
    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "POSTGRES_PASSWORD" -Value $env:OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD
    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "AUTH_MODE" -Value "local"
    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "LOCAL_AUTH_TOKEN" -Value $missionControlToken
    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "CORS_ORIGINS" -Value $missionControlFrontendUrl
    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "NEXT_PUBLIC_API_URL" -Value $missionControlBackendUrl
    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "BASE_URL" -Value $missionControlBaseUrl
    Upsert-DotEnvValue -Path $missionControlEnvFile -Key "DB_AUTO_MIGRATE" -Value "true"

    $missionControlFrontendEnvFile = Join-Path (Join-Path $MissionControlSrcDir "frontend") ".env"
    Upsert-DotEnvValue -Path $missionControlFrontendEnvFile -Key "NEXT_PUBLIC_API_URL" -Value $missionControlBackendUrl
    Upsert-DotEnvValue -Path $missionControlFrontendEnvFile -Key "NEXT_PUBLIC_AUTH_MODE" -Value "local"
    $missionControlBackendEnvExampleFile = Join-Path (Join-Path $MissionControlSrcDir "backend") ".env.example"
    if (Test-Path $missionControlBackendEnvExampleFile) {
        Upsert-DotEnvValue -Path $missionControlBackendEnvExampleFile -Key "BASE_URL" -Value $missionControlBaseUrl
    }
    $missionControlBackendEnvFile = Join-Path (Join-Path $MissionControlSrcDir "backend") ".env"
    if (Test-Path $missionControlBackendEnvFile) {
        Upsert-DotEnvValue -Path $missionControlBackendEnvFile -Key "BASE_URL" -Value $missionControlBaseUrl
    }

    Write-Step "Starting Mission Control"
    Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @("up", "-d", "--build") | Out-Null
    Sync-MissionControlDbPassword -MissionControlSrcDir $MissionControlSrcDir -DbUser $env:OPENCLAW_MISSION_CONTROL_POSTGRES_USER -DbPassword $env:OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD
    Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @("up", "-d", "backend") -IgnoreExitCode | Out-Null

    Write-Step "Mission Control health check"
    $missionControlHealthy = $false
    for ($attempt = 1; $attempt -le 90; $attempt++) {
        if (Test-HttpStatus200 -Url "$missionControlFrontendUrl/") {
            $missionControlHealthy = $true
            break
        }
        if ($attempt -eq 1 -or ($attempt % 10) -eq 0) {
            Write-Host "[openclaw-easy] waiting for Mission Control UI $missionControlFrontendUrl (attempt $attempt/90)"
            $mcStatus = Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @("ps") -Capture -IgnoreExitCode
            foreach ($line in @($mcStatus.Output)) {
                Write-Host "[openclaw-easy] mission-control: $line"
            }
        }
        Start-Sleep -Seconds 2
    }
    if (-not $missionControlHealthy) {
        Write-Host "[openclaw-easy] Mission Control logs (backend, frontend; last 120 lines):"
        $mcLogs = Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @("logs", "--tail=120", "backend", "frontend") -Capture -IgnoreExitCode
        foreach ($line in @($mcLogs.Output)) {
            Write-Host $line
        }
        throw "Mission Control health check failed (expected HTTP 200 at $missionControlFrontendUrl/)."
    }

    $missionControlBackendReady = $false
    for ($attempt = 1; $attempt -le 45; $attempt++) {
        if (Test-MissionControlBackendReady -BackendUrl $missionControlBackendUrl -LocalAuthToken $missionControlToken) {
            $missionControlBackendReady = $true
            break
        }
        if ($attempt -eq 1 -or ($attempt % 10) -eq 0) {
            Write-Host "[openclaw-easy] waiting for Mission Control backend $missionControlBackendUrl (attempt $attempt/45)"
            $mcStatus = Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @("ps") -Capture -IgnoreExitCode
            foreach ($line in @($mcStatus.Output)) {
                Write-Host "[openclaw-easy] mission-control: $line"
            }
        }
        Start-Sleep -Seconds 2
    }
    if (-not $missionControlBackendReady) {
        Write-Host "[openclaw-easy] Mission Control backend logs (last 120 lines):"
        $mcBackendLogs = Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @("logs", "--tail=120", "backend") -Capture -IgnoreExitCode
        foreach ($line in @($mcBackendLogs.Output)) {
            Write-Host $line
        }
        throw "Mission Control backend is unreachable for auth bootstrap at $missionControlBackendUrl/api/v1/auth/bootstrap."
    }

    $openClawNetworkName = "$($script:ComposeProjectName)_openclaw-safe-net"
    $mcBackendPs = Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @("ps", "-q", "backend") -Capture -IgnoreExitCode
    $mcBackendContainerId = Resolve-ContainerId -Lines @($mcBackendPs.Output)
    if ($mcBackendContainerId) {
        & docker network connect $openClawNetworkName $mcBackendContainerId *> $null
    }
    $mcWorkerPs = Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @("ps", "-q", "webhook-worker") -Capture -IgnoreExitCode
    $mcWorkerContainerId = Resolve-ContainerId -Lines @($mcWorkerPs.Output)
    if ($mcWorkerContainerId) {
        & docker network connect $openClawNetworkName $mcWorkerContainerId *> $null
    }

    Repair-MissionControlOnboardingSessions -MissionControlSrcDir $MissionControlSrcDir

    if (Is-Truthy -Value $env:OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY) {
        Write-Step "Mission Control gateway auto-config"
        $pythonScript = @'
import json
import os
import urllib.error
import urllib.parse
import urllib.request

base = "http://127.0.0.1:8000/api/v1"
token = (os.environ.get("MC_TOKEN") or "").strip()
gateway_token = (os.environ.get("MC_GATEWAY_TOKEN") or "").strip()
gateway_port = (os.environ.get("MC_GATEWAY_PORT") or "18789").strip()
gateway_name = (os.environ.get("MC_GATEWAY_NAME") or "OpenClaw Docker Gateway").strip()
workspace_root = (os.environ.get("MC_WORKSPACE_ROOT") or "/home/node/.openclaw").strip()
override_url = (os.environ.get("MC_GATEWAY_URL_OVERRIDE") or "").strip()
sync_templates = (os.environ.get("MC_SYNC_TEMPLATES") or "true").strip().lower() in {"1", "true", "yes", "on"}

if not token:
    raise RuntimeError("mission control auth token is empty")

headers = {
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/json",
}

def request_json(method: str, path: str, *, query: dict[str, str] | None = None, payload: object | None = None):
    url = f"{base}{path}"
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8")
            parsed = json.loads(raw) if raw else {}
            return resp.getcode(), parsed
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="ignore") if exc.fp else ""
        detail = raw.strip() or exc.reason
        raise RuntimeError(f"{method} {path} failed ({exc.code}): {detail}") from exc

request_json("POST", "/auth/bootstrap")

candidates: list[str] = []
if override_url:
    candidates.append(override_url)
candidates.extend([
    "ws://openclaw-gateway:18789",
    f"ws://host.docker.internal:{gateway_port}",
    f"ws://gateway.docker.internal:{gateway_port}",
    f"ws://172.17.0.1:{gateway_port}",
])
deduped: list[str] = []
seen = set()
for item in candidates:
    value = (item or "").strip()
    if not value or value in seen:
        continue
    deduped.append(value)
    seen.add(value)

selected_url = deduped[0]
for candidate in deduped:
    try:
        _, status_payload = request_json(
            "GET",
            "/gateways/status",
            query={
                "gateway_url": candidate,
                "gateway_token": gateway_token,
            },
        )
        if bool(status_payload.get("connected")):
            selected_url = candidate
            break
    except Exception:
        continue

_, gateways_payload = request_json("GET", "/gateways", query={"limit": "200", "offset": "0"})
items = gateways_payload.get("items") if isinstance(gateways_payload, dict) else []
if not isinstance(items, list):
    items = []
existing = None
for item in items:
    if not isinstance(item, dict):
        continue
    if item.get("name") == gateway_name or item.get("url") == selected_url:
        existing = item
        break

payload = {
    "name": gateway_name,
    "url": selected_url,
    "workspace_root": workspace_root,
    "token": gateway_token or None,
}

gateway_id = None
if existing and existing.get("id"):
    _, updated_payload = request_json("PATCH", f"/gateways/{existing['id']}", payload=payload)
    action = "updated"
    if isinstance(updated_payload, dict):
        gateway_id = updated_payload.get("id")
    if not gateway_id:
        gateway_id = existing.get("id")
else:
    _, created_payload = request_json("POST", "/gateways", payload=payload)
    action = "created"
    if isinstance(created_payload, dict):
        gateway_id = created_payload.get("id")

if sync_templates and gateway_id:
    query = {
        "include_main": "true",
        "reset_sessions": "true",
        "rotate_tokens": "true",
        "force_bootstrap": "true",
        "overwrite": "true",
    }
    _, sync_payload = request_json("POST", f"/gateways/{gateway_id}/templates/sync", query=query)
    if isinstance(sync_payload, dict):
        print(
            "MISSION_CONTROL_GATEWAY_SYNC="
            f"agents_updated={sync_payload.get('agents_updated', 0)} "
            f"agents_skipped={sync_payload.get('agents_skipped', 0)} "
            f"errors={len(sync_payload.get('errors') or [])}"
        )

print(f"MISSION_CONTROL_GATEWAY_ACTION={action}")
print(f"MISSION_CONTROL_GATEWAY_URL={selected_url}")
if gateway_id:
    print(f"MISSION_CONTROL_GATEWAY_ID={gateway_id}")
'@
        $pythonScriptBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pythonScript))
        $pythonLauncher = "import base64;exec(base64.b64decode('$pythonScriptBase64').decode('utf-8'))"
        $gatewaySync = Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @(
            "exec", "-T",
            "-e", "MC_TOKEN=$missionControlToken",
            "-e", "MC_GATEWAY_TOKEN=$($env:OPENCLAW_GATEWAY_TOKEN)",
            "-e", "MC_GATEWAY_PORT=$($env:OPENCLAW_GATEWAY_PORT)",
            "-e", "MC_GATEWAY_NAME=$($env:OPENCLAW_MISSION_CONTROL_GATEWAY_NAME)",
            "-e", "MC_WORKSPACE_ROOT=$($env:OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT)",
            "-e", "MC_GATEWAY_URL_OVERRIDE=$($env:OPENCLAW_MISSION_CONTROL_GATEWAY_URL)",
            "-e", "MC_SYNC_TEMPLATES=$($env:OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES)",
            "backend", "python", "-c", $pythonLauncher
        ) -Capture -IgnoreExitCode
        if ($gatewaySync.Code -ne 0) {
            Write-Host "[openclaw-easy] Mission Control gateway auto-config failed (continuing)."
            foreach ($line in @($gatewaySync.Output)) {
                Write-Host "[openclaw-easy] mission-control-gateway: $line"
            }
        }
        else {
            foreach ($line in @($gatewaySync.Output)) {
                $text = $line.ToString().Trim()
                if (-not $text) { continue }
                if ($text.StartsWith("MISSION_CONTROL_GATEWAY_URL=")) {
                    $missionControlRegisteredGatewayUrl = $text.Substring("MISSION_CONTROL_GATEWAY_URL=".Length)
                    if (-not (Is-Blank $missionControlRegisteredGatewayUrl)) {
                        $env:OPENCLAW_MISSION_CONTROL_GATEWAY_URL = $missionControlRegisteredGatewayUrl
                        Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_GATEWAY_URL" -Value $missionControlRegisteredGatewayUrl
                    }
                }
                if ($text.StartsWith("MISSION_CONTROL_GATEWAY_ID=")) {
                    $missionControlRegisteredGatewayId = $text.Substring("MISSION_CONTROL_GATEWAY_ID=".Length)
                    if (-not (Is-Blank $missionControlRegisteredGatewayId)) {
                        $env:OPENCLAW_MISSION_CONTROL_GATEWAY_ID = $missionControlRegisteredGatewayId
                        Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_GATEWAY_ID" -Value $missionControlRegisteredGatewayId
                    }
                }
                Write-Host "[openclaw-easy] mission-control-gateway: $text"
            }
        }
    }
    if (Is-Blank $missionControlRegisteredGatewayId) {
        $missionControlRegisteredGatewayId = $env:OPENCLAW_MISSION_CONTROL_GATEWAY_ID
    }
    $boardConfigJson = ""
    if (-not (Is-Blank $env:OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON)) {
        $boardConfigJson = $env:OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON
    }
    elseif (-not (Is-Blank $env:OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE)) {
        $boardConfigPath = $env:OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE
        if (-not [System.IO.Path]::IsPathRooted($boardConfigPath)) {
            $boardConfigPath = Join-Path $RootDir $boardConfigPath
        }
        if (Test-Path $boardConfigPath) {
            $boardConfigJson = Get-Content -Path $boardConfigPath -Raw
        }
        else {
            Write-Host "[openclaw-easy] Mission Control board config file not found: $boardConfigPath (continuing with env values)."
        }
    }
    $boardConfigB64 = ""
    if (-not (Is-Blank $boardConfigJson)) {
        $boardConfigB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($boardConfigJson))
    }
    $boardPackConfigJson = ""
    if (-not (Is-Blank $env:OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_JSON)) {
        $boardPackConfigJson = $env:OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_JSON
    }
    elseif (-not (Is-Blank $env:OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_FILE)) {
        $boardPackConfigPath = $env:OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_FILE
        if (-not [System.IO.Path]::IsPathRooted($boardPackConfigPath)) {
            $boardPackConfigPath = Join-Path $RootDir $boardPackConfigPath
        }
        if (Test-Path $boardPackConfigPath) {
            $boardPackConfigJson = Get-Content -Path $boardPackConfigPath -Raw
        }
        else {
            Write-Host "[openclaw-easy] Mission Control board pack config file not found: $boardPackConfigPath (continuing with env values)."
        }
    }
    $boardPackConfigB64 = ""
    if (-not (Is-Blank $boardPackConfigJson)) {
        $boardPackConfigB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($boardPackConfigJson))
    }
    $shouldSeedMissionControlBoard = (Is-Truthy -Value $env:OPENCLAW_MISSION_CONTROL_SEED_BOARD) -or (Is-Truthy -Value $env:OPENCLAW_MISSION_CONTROL_SEED_BOARD_PACK) -or (-not (Is-Blank $boardPackConfigJson))
    if ($shouldSeedMissionControlBoard) {
        Write-Step "Mission Control board seed"
        $seedBoardScriptPath = Join-Path $RootDir "scripts/mission_control/seed_starter_pack.py"
        if (-not (Test-Path $seedBoardScriptPath)) {
            Write-Host "[openclaw-easy] Mission Control board seed script missing: $seedBoardScriptPath (continuing)."
        }
        else {
            $seedBoardScript = Get-Content -Path $seedBoardScriptPath -Raw
            $seedBoard = Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @(
                "exec", "-T",
                "-e", "MC_TOKEN=$missionControlToken",
                "-e", "MC_GATEWAY_ID=$missionControlRegisteredGatewayId",
                "-e", "MC_GATEWAY_NAME=$($env:OPENCLAW_MISSION_CONTROL_GATEWAY_NAME)",
                "-e", "MC_GATEWAY_URL=$($env:OPENCLAW_MISSION_CONTROL_GATEWAY_URL)",
                "-e", "MC_BOARD_NAME=$($env:OPENCLAW_MISSION_CONTROL_BOARD_NAME)",
                "-e", "MC_BOARD_SLUG=$($env:OPENCLAW_MISSION_CONTROL_BOARD_SLUG)",
                "-e", "MC_BOARD_DESCRIPTION=$($env:OPENCLAW_MISSION_CONTROL_BOARD_DESCRIPTION)",
                "-e", "MC_BOARD_PERSPECTIVE=$($env:OPENCLAW_MISSION_CONTROL_BOARD_PERSPECTIVE)",
                "-e", "MC_BOARD_TYPE=$($env:OPENCLAW_MISSION_CONTROL_BOARD_TYPE)",
                "-e", "MC_BOARD_OBJECTIVE=$($env:OPENCLAW_MISSION_CONTROL_BOARD_OBJECTIVE)",
                "-e", "MC_BOARD_SUCCESS_METRICS_JSON=$($env:OPENCLAW_MISSION_CONTROL_BOARD_SUCCESS_METRICS_JSON)",
                "-e", "MC_BOARD_TARGET_DATE=$($env:OPENCLAW_MISSION_CONTROL_BOARD_TARGET_DATE)",
                "-e", "MC_BOARD_GOAL_CONFIRMED=$($env:OPENCLAW_MISSION_CONTROL_BOARD_GOAL_CONFIRMED)",
                "-e", "MC_BOARD_GOAL_SOURCE=$($env:OPENCLAW_MISSION_CONTROL_BOARD_GOAL_SOURCE)",
                "-e", "MC_BOARD_GROUP_ID=$($env:OPENCLAW_MISSION_CONTROL_BOARD_GROUP_ID)",
                "-e", "MC_BOARD_MAX_AGENTS=$($env:OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS)",
                "-e", "MC_BOARD_CONFIG_B64=$boardConfigB64",
                "-e", "MC_SEED_BOARD=$($env:OPENCLAW_MISSION_CONTROL_SEED_BOARD)",
                "-e", "MC_SEED_BOARD_PACK=$($env:OPENCLAW_MISSION_CONTROL_SEED_BOARD_PACK)",
                "-e", "MC_BOARD_PACK_CONFIG_B64=$boardPackConfigB64",
                "backend", "python", "-"
            ) -InputText $seedBoardScript -Capture -IgnoreExitCode
            if ($seedBoard.Code -ne 0) {
                Write-Host "[openclaw-easy] Mission Control board seed failed (continuing)."
                foreach ($line in @($seedBoard.Output)) {
                    Write-Host "[openclaw-easy] mission-control-board: $line"
                }
            }
            else {
                $boardAction = ""
                $boardId = ""
                $boardName = ""
                $boardSlug = ""
                $boardSeedSummaryB64 = ""
                foreach ($line in @($seedBoard.Output)) {
                    $text = $line.ToString().Trim()
                    if (-not $text) { continue }
                    if ($text.StartsWith("MISSION_CONTROL_BOARD_ACTION=")) {
                        $boardAction = $text.Substring("MISSION_CONTROL_BOARD_ACTION=".Length)
                    }
                    elseif ($text.StartsWith("MISSION_CONTROL_BOARD_ID=")) {
                        $boardId = $text.Substring("MISSION_CONTROL_BOARD_ID=".Length)
                    }
                    elseif ($text.StartsWith("MISSION_CONTROL_BOARD_NAME=")) {
                        $boardName = $text.Substring("MISSION_CONTROL_BOARD_NAME=".Length)
                    }
                    elseif ($text.StartsWith("MISSION_CONTROL_BOARD_SLUG=")) {
                        $boardSlug = $text.Substring("MISSION_CONTROL_BOARD_SLUG=".Length)
                    }
                    elseif ($text.StartsWith("MISSION_CONTROL_SEED_SUMMARY_B64=")) {
                        $boardSeedSummaryB64 = $text.Substring("MISSION_CONTROL_SEED_SUMMARY_B64=".Length)
                    }
                    Write-Host "[openclaw-easy] mission-control-board: $text"
                }
                if (-not (Is-Blank $boardAction) -or -not (Is-Blank $boardName)) {
                    $missionControlSeedBoardSummary = "action=$boardAction name=$boardName slug=$boardSlug id=$boardId".Trim()
                }
                elseif (-not (Is-Blank $boardSeedSummaryB64)) {
                    $missionControlSeedBoardSummary = "starter pack seed completed"
                }
                if (-not (Is-Blank $boardId)) {
                    $missionControlSeedBoardId = $boardId
                }
            }
        }
    }
    if (Is-Truthy -Value $env:OPENCLAW_MISSION_CONTROL_SYNC_MANIFEST_AGENTS) {
        Write-Step "Mission Control manifest agent sync"
        $manifestAgents = Get-OpenClawAgentDefinitions -RootDir $RootDir
        $manifestPayload = @()
        foreach ($agent in @($manifestAgents)) {
            $manifestPayload += [PSCustomObject]@{
                id = $agent.Id
                name = $agent.Name
            }
        }
        $manifestAgentsJson = $manifestPayload | ConvertTo-Json -Depth 4 -Compress
        if (Is-Blank $manifestAgentsJson) {
            $manifestAgentsJson = "[]"
        }
        $manifestAgentsB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($manifestAgentsJson))
        $pythonScript = @'
import base64
import json
import os
import urllib.error
import urllib.parse
import urllib.request

base = "http://127.0.0.1:8000/api/v1"
token = (os.environ.get("MC_TOKEN") or "").strip()
gateway_id_hint = (os.environ.get("MC_GATEWAY_ID") or "").strip()
gateway_name_hint = (os.environ.get("MC_GATEWAY_NAME") or "").strip()
gateway_url_hint = (os.environ.get("MC_GATEWAY_URL") or "").strip()
target_board_id_hint = (os.environ.get("MC_TARGET_BOARD_ID") or "").strip()
target_board_slug_hint = (os.environ.get("MC_TARGET_BOARD_SLUG") or "").strip()
seeded_board_id_hint = (os.environ.get("MC_SEEDED_BOARD_ID") or "").strip()
manifest_agents_b64 = (os.environ.get("MC_MANIFEST_AGENTS_B64") or "").strip()

if not token:
    raise RuntimeError("mission control auth token is empty")

headers = {
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/json",
}


def request_json(method: str, path: str, *, query: dict[str, str] | None = None, payload: object | None = None):
    url = f"{base}{path}"
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            parsed = json.loads(raw) if raw else {}
            return resp.getcode(), parsed
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="ignore") if exc.fp else ""
        detail = raw.strip() or exc.reason
        raise RuntimeError(f"{method} {path} failed ({exc.code}): {detail}") from exc


def fetch_all(path: str, *, query: dict[str, str] | None = None, limit: int = 200):
    merged_query = dict(query or {})
    offset = 0
    items = []
    while True:
        page_query = dict(merged_query)
        page_query["limit"] = str(limit)
        page_query["offset"] = str(offset)
        _, payload = request_json("GET", path, query=page_query)
        page_items = payload.get("items") if isinstance(payload, dict) else []
        if not isinstance(page_items, list):
            page_items = []
        normalized = [item for item in page_items if isinstance(item, dict)]
        items.extend(normalized)
        if len(normalized) < limit:
            break
        offset += limit
    return items


def parse_manifest_agents(raw_b64: str):
    if not raw_b64:
        return []
    padded = raw_b64 + ("=" * (-len(raw_b64) % 4))
    decoded = base64.b64decode(padded.encode("utf-8")).decode("utf-8")
    parsed = json.loads(decoded)
    if not isinstance(parsed, list):
        return []
    agents = []
    for item in parsed:
        if not isinstance(item, dict):
            continue
        agent_id = str(item.get("id") or "").strip()
        if not agent_id:
            continue
        name = str(item.get("name") or agent_id).strip() or agent_id
        agents.append({"id": agent_id, "name": name})
    return agents


def parse_int(value: object, default: int):
    try:
        return int(str(value).strip())
    except Exception:
        return default


def pick_gateway(gateways: list[dict[str, object]]):
    if gateway_id_hint:
        for item in gateways:
            if str(item.get("id") or "").strip() == gateway_id_hint:
                return item
    for item in gateways:
        if gateway_name_hint and str(item.get("name") or "").strip() == gateway_name_hint:
            return item
        if gateway_url_hint and str(item.get("url") or "").strip() == gateway_url_hint:
            return item
    return gateways[0] if gateways else None


def pick_board(all_boards: list[dict[str, object]], gateway_id: str):
    if target_board_id_hint:
        for board in all_boards:
            if str(board.get("id") or "").strip() == target_board_id_hint:
                return board
    if seeded_board_id_hint:
        for board in all_boards:
            if str(board.get("id") or "").strip() == seeded_board_id_hint:
                return board
    gateway_boards = [
        board
        for board in all_boards
        if str(board.get("gateway_id") or "").strip() == gateway_id
    ]
    if target_board_slug_hint:
        for board in gateway_boards:
            if str(board.get("slug") or "").strip() == target_board_slug_hint:
                return board
    return gateway_boards[0] if gateway_boards else None


def normalize_identity_profile(existing_profile: object, manifest_id: str, manifest_name: str):
    merged = {}
    if isinstance(existing_profile, dict):
        for raw_key, raw_value in existing_profile.items():
            key = str(raw_key).strip()
            if not key or raw_value is None:
                continue
            merged[key] = raw_value
    merged["openclaw_manifest_id"] = manifest_id
    merged["openclaw_manifest_name"] = manifest_name
    return merged


request_json("POST", "/auth/bootstrap")
manifest_agents = parse_manifest_agents(manifest_agents_b64)
if not manifest_agents:
    print("MISSION_CONTROL_MANIFEST_AGENT_SYNC=created=0 updated=0 skipped=0 errors=0")
    raise SystemExit(0)

gateways = fetch_all("/gateways")
gateway = pick_gateway(gateways)
if not gateway:
    raise RuntimeError("No Mission Control gateway available for manifest agent sync")
gateway_id = str(gateway.get("id") or "").strip()
if not gateway_id:
    raise RuntimeError("Selected Mission Control gateway has empty id")

boards = fetch_all("/boards")
target_board = pick_board(boards, gateway_id)
if not target_board:
    raise RuntimeError("No board available for manifest agent sync")
board_id = str(target_board.get("id") or "").strip()
if not board_id:
    raise RuntimeError("Selected board has empty id")

current_max = parse_int(target_board.get("max_agents"), 0)
required_max = len(manifest_agents)
if current_max < required_max:
    _, patched_board = request_json(
        "PATCH",
        f"/boards/{board_id}",
        payload={"max_agents": required_max},
    )
    if isinstance(patched_board, dict):
        target_board = patched_board
    current_max = required_max

existing_agents = fetch_all("/agents", query={"board_id": board_id})
existing_by_manifest_id = {}
existing_by_name = {}
for item in existing_agents:
    name = str(item.get("name") or "").strip()
    if name and name not in existing_by_name:
        existing_by_name[name] = item
    profile = item.get("identity_profile")
    if isinstance(profile, dict):
        manifest_id = str(profile.get("openclaw_manifest_id") or "").strip()
        if manifest_id and manifest_id not in existing_by_manifest_id:
            existing_by_manifest_id[manifest_id] = item

created = 0
updated = 0
skipped = 0
errors = []

for manifest_item in manifest_agents:
    manifest_id = manifest_item["id"]
    manifest_name = manifest_item["name"]
    existing = existing_by_manifest_id.get(manifest_id) or existing_by_name.get(manifest_name)
    try:
        if existing:
            existing_id = str(existing.get("id") or "").strip()
            existing_name = str(existing.get("name") or "").strip()
            existing_board_id = str(existing.get("board_id") or "").strip()
            existing_profile = existing.get("identity_profile")
            existing_manifest_id = ""
            existing_manifest_name = ""
            if isinstance(existing_profile, dict):
                existing_manifest_id = str(existing_profile.get("openclaw_manifest_id") or "").strip()
                existing_manifest_name = str(existing_profile.get("openclaw_manifest_name") or "").strip()
            profile = normalize_identity_profile(existing_profile, manifest_id, manifest_name)
            needs_update = (
                existing_name != manifest_name
                or existing_board_id != board_id
                or existing_manifest_id != manifest_id
                or existing_manifest_name != manifest_name
            )
            if needs_update and existing_id:
                _, updated_payload = request_json(
                    "PATCH",
                    f"/agents/{existing_id}",
                    payload={
                        "board_id": board_id,
                        "name": manifest_name,
                        "identity_profile": profile,
                    },
                )
                if isinstance(updated_payload, dict):
                    existing = updated_payload
                updated += 1
            else:
                skipped += 1
        else:
            _, created_payload = request_json(
                "POST",
                "/agents",
                payload={
                    "board_id": board_id,
                    "name": manifest_name,
                    "identity_profile": {
                        "openclaw_manifest_id": manifest_id,
                        "openclaw_manifest_name": manifest_name,
                    },
                },
            )
            if isinstance(created_payload, dict):
                existing = created_payload
            created += 1
    except Exception as exc:
        errors.append(f"{manifest_id}: {exc}")
        continue
    if isinstance(existing, dict):
        existing_by_name[str(existing.get("name") or "").strip()] = existing
        profile = existing.get("identity_profile")
        if isinstance(profile, dict):
            existing_manifest_id = str(profile.get("openclaw_manifest_id") or "").strip()
            if existing_manifest_id:
                existing_by_manifest_id[existing_manifest_id] = existing

print(
    "MISSION_CONTROL_MANIFEST_AGENT_SYNC="
    f"created={created} updated={updated} skipped={skipped} errors={len(errors)}"
)
print(f"MISSION_CONTROL_MANIFEST_AGENT_BOARD_ID={board_id}")
print(f"MISSION_CONTROL_MANIFEST_AGENT_BOARD_MAX_AGENTS={current_max}")
for message in errors[:25]:
    clean = str(message).replace("\n", " ").strip()
    print(f"MISSION_CONTROL_MANIFEST_AGENT_ERROR={clean}")
'@
        $pythonScriptBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pythonScript))
        $pythonLauncher = "import base64;exec(base64.b64decode('$pythonScriptBase64').decode('utf-8'))"
        $manifestSync = Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @(
            "exec", "-T",
            "-e", "MC_TOKEN=$missionControlToken",
            "-e", "MC_GATEWAY_ID=$missionControlRegisteredGatewayId",
            "-e", "MC_GATEWAY_NAME=$($env:OPENCLAW_MISSION_CONTROL_GATEWAY_NAME)",
            "-e", "MC_GATEWAY_URL=$($env:OPENCLAW_MISSION_CONTROL_GATEWAY_URL)",
            "-e", "MC_TARGET_BOARD_ID=$($env:OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_ID)",
            "-e", "MC_TARGET_BOARD_SLUG=$($env:OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_SLUG)",
            "-e", "MC_SEEDED_BOARD_ID=$missionControlSeedBoardId",
            "-e", "MC_MANIFEST_AGENTS_B64=$manifestAgentsB64",
            "backend", "python", "-c", $pythonLauncher
        ) -Capture -IgnoreExitCode
        if ($manifestSync.Code -ne 0) {
            Write-Host "[openclaw-easy] Mission Control manifest agent sync failed (continuing)."
            foreach ($line in @($manifestSync.Output)) {
                Write-Host "[openclaw-easy] mission-control-agents: $line"
            }
        }
        else {
            foreach ($line in @($manifestSync.Output)) {
                $text = $line.ToString().Trim()
                if (-not $text) { continue }
                if ($text.StartsWith("MISSION_CONTROL_MANIFEST_AGENT_BOARD_ID=")) {
                    $manifestBoardId = $text.Substring("MISSION_CONTROL_MANIFEST_AGENT_BOARD_ID=".Length)
                    if (-not (Is-Blank $manifestBoardId)) {
                        $env:OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_ID = $manifestBoardId
                        Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_ID" -Value $manifestBoardId
                    }
                }
                elseif ($text.StartsWith("MISSION_CONTROL_MANIFEST_AGENT_BOARD_MAX_AGENTS=")) {
                    $manifestBoardMaxAgents = $text.Substring("MISSION_CONTROL_MANIFEST_AGENT_BOARD_MAX_AGENTS=".Length)
                    if (-not (Is-Blank $manifestBoardMaxAgents)) {
                        $env:OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS = $manifestBoardMaxAgents
                        Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS" -Value $manifestBoardMaxAgents
                    }
                }
                Write-Host "[openclaw-easy] mission-control-agents: $text"
            }
        }
    }
    $missionControlDashboardUrl = "$missionControlFrontendUrl/"
}

if ($commandCenterEnabled) {
    $CommandCenterSrcDir = $env:OPENCLAW_COMMAND_CENTER_SRC_DIR
    if (-not $CommandCenterSrcDir) {
        $CommandCenterSrcDir = Join-Path (Join-Path $RootDir "vendor") "openclaw-command-center"
        $env:OPENCLAW_COMMAND_CENTER_SRC_DIR = $CommandCenterSrcDir
        Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_COMMAND_CENTER_SRC_DIR" -Value $CommandCenterSrcDir
    }

    if (Test-Path (Join-Path $CommandCenterSrcDir ".git")) {
        Write-Step "Updating Command Center source: $CommandCenterSrcDir"
        & git -C $CommandCenterSrcDir fetch --depth 1 --force origin $env:OPENCLAW_COMMAND_CENTER_REPO_BRANCH
        if ($LASTEXITCODE -ne 0) {
            Write-Step "Command Center update failed, recloning"
            Clone-CommandCenterRepo -RepoUrl $env:OPENCLAW_COMMAND_CENTER_REPO_URL -RepoBranch $env:OPENCLAW_COMMAND_CENTER_REPO_BRANCH -Destination $CommandCenterSrcDir
        }
        else {
            & git -C $CommandCenterSrcDir checkout --force FETCH_HEAD
            if ($LASTEXITCODE -ne 0) {
                Write-Step "Command Center update failed, recloning"
                Clone-CommandCenterRepo -RepoUrl $env:OPENCLAW_COMMAND_CENTER_REPO_URL -RepoBranch $env:OPENCLAW_COMMAND_CENTER_REPO_BRANCH -Destination $CommandCenterSrcDir
            }
        }
    }
    else {
        Write-Step "Cloning Command Center source"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $CommandCenterSrcDir) | Out-Null
        Clone-CommandCenterRepo -RepoUrl $env:OPENCLAW_COMMAND_CENTER_REPO_URL -RepoBranch $env:OPENCLAW_COMMAND_CENTER_REPO_BRANCH -Destination $CommandCenterSrcDir
    }

    Write-Step "Starting OpenClaw Command Center"
    Invoke-CommandCenterCompose -RootDir $RootDir -ComposeArgs @("up", "-d", "--build") | Out-Null

    Write-Step "OpenClaw Command Center health check"
    $commandCenterPort = if ($env:OPENCLAW_COMMAND_CENTER_PORT) { $env:OPENCLAW_COMMAND_CENTER_PORT } else { "3340" }
    $commandCenterUrl = "http://127.0.0.1:$commandCenterPort/"
    $commandCenterHealthy = $false
    for ($attempt = 1; $attempt -le 90; $attempt++) {
        if (Test-HttpStatus200 -Url $commandCenterUrl) {
            $commandCenterHealthy = $true
            break
        }
        if ($attempt -eq 1 -or ($attempt % 10) -eq 0) {
            Write-Host "[openclaw-easy] waiting for OpenClaw Command Center $commandCenterUrl (attempt $attempt/90)"
            $ccStatus = Invoke-CommandCenterCompose -RootDir $RootDir -ComposeArgs @("ps") -Capture -IgnoreExitCode
            foreach ($line in @($ccStatus.Output)) {
                Write-Host "[openclaw-easy] command-center: $line"
            }
        }
        Start-Sleep -Seconds 2
    }
    if (-not $commandCenterHealthy) {
        Write-Host "[openclaw-easy] Command Center logs (last 120 lines):"
        $ccLogs = Invoke-CommandCenterCompose -RootDir $RootDir -ComposeArgs @("logs", "--tail=120", "openclaw-command-center") -Capture -IgnoreExitCode
        foreach ($line in @($ccLogs.Output)) {
            Write-Host $line
        }
        throw "OpenClaw Command Center health check failed (expected HTTP 200 at $commandCenterUrl)."
    }
    $commandCenterDashboardUrl = $commandCenterUrl
}

$dashboard = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "dashboard", "--no-open") -Capture -IgnoreExitCode
$dashboardUrl = Get-DefaultDashboardUrl
$dashboardLines = @($dashboard.Output) | ForEach-Object { Strip-Ansi $_.ToString() }
$dashboardMatch = $dashboardLines | Select-String "Dashboard URL:" | Select-Object -Last 1
if ($dashboardMatch) {
    $dashboardText = $dashboardMatch.ToString()
    if ($dashboardText -match "Dashboard URL:\s*(.+)$") {
        $candidate = $matches[1].Trim()
        if ($candidate) {
            $dashboardUrl = $candidate
        }
    }
}
$dashboardUrl = Ensure-TokenizedDashboardUrl -Url $dashboardUrl

Write-Step "Setup complete"
if ($dashboardUrl) {
    Write-Host "[openclaw-easy] Open this URL:"
    Write-Host $dashboardUrl
    Write-Host "[openclaw-easy] If you see device token mismatch, run .\repair-auth.cmd then reload browser."
}
else {
    Write-Host "[openclaw-easy] Run this to print your URL:"
    Write-Host "cd $OpenClawSrcDir; $script:ComposeHint -p $script:ComposeProjectName --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli dashboard --no-open"
}
if ($missionControlEnabled -and $missionControlDashboardUrl) {
    Write-Host "[openclaw-easy] Mission Control URL:"
    Write-Host $missionControlDashboardUrl
    Write-Host "[openclaw-easy] Mission Control local auth token (for first login):"
    Write-Host $env:OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN
    if (-not (Is-Blank $missionControlRegisteredGatewayUrl)) {
        Write-Host "[openclaw-easy] Mission Control gateway (auto-registered):"
        Write-Host $missionControlRegisteredGatewayUrl
    }
    if (-not (Is-Blank $missionControlSeedBoardSummary)) {
        Write-Host "[openclaw-easy] Mission Control board seed:"
        Write-Host $missionControlSeedBoardSummary
    }
}
if ($commandCenterEnabled -and $commandCenterDashboardUrl) {
    Write-Host "[openclaw-easy] OpenClaw Command Center URL:"
    Write-Host $commandCenterDashboardUrl
}
