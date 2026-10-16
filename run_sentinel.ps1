$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$flutterRoot = Join-Path $projectRoot 'sentinel_ai'
$pythonPath = Join-Path $projectRoot 'venv\Scripts\python.exe'
$localEnvPath = Join-Path $projectRoot '.env.local'
$flutterWebPort = 8766
$engineProcess = $null
$exitCode = 0

try {
    if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
        throw "Python virtual environment not found at '$pythonPath'. Create it and install requirements.txt first."
    }
    if (-not (Test-Path -LiteralPath $localEnvPath -PathType Leaf)) {
        throw "Configuration file '$localEnvPath' was not found. Create it with SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY."
    }

    $flutterCommand = Get-Command flutter -ErrorAction Stop
    if (-not $flutterCommand.Source) {
        throw 'Could not resolve the Flutter executable. Add Flutter to PATH and reopen PowerShell.'
    }

    $configuration = @{}
    foreach ($rawLine in Get-Content -LiteralPath $localEnvPath) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) {
            continue
        }
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) {
            continue
        }
        $key = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        if ($value.Length -ge 2) {
            $first = $value[0]
            $last = $value[$value.Length - 1]
            if (($first -eq '"' -and $last -eq '"') -or
                ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $configuration[$key] = $value
    }

    $supabaseUrl = $configuration['SUPABASE_URL']
    $publishableKey = $configuration['SUPABASE_PUBLISHABLE_KEY']
    if (-not $supabaseUrl -or -not $publishableKey) {
        throw 'Add SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY to the root .env.local file. Use the Supabase publishable key, not the service_role key.'
    }

    $packageConfigPath = Join-Path $flutterRoot '.dart_tool\package_config.json'
    $pubspecPath = Join-Path $flutterRoot 'pubspec.yaml'
    $pubspecLockPath = Join-Path $flutterRoot 'pubspec.lock'
    $resolvePackages = -not (Test-Path -LiteralPath $packageConfigPath -PathType Leaf)
    if (-not $resolvePackages) {
        $packageConfigTime = (Get-Item -LiteralPath $packageConfigPath).LastWriteTimeUtc
        foreach ($manifestPath in @($pubspecPath, $pubspecLockPath)) {
            if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and
                (Get-Item -LiteralPath $manifestPath).LastWriteTimeUtc -gt $packageConfigTime) {
                $resolvePackages = $true
            }
        }
    }

    if ($resolvePackages) {
        Write-Host 'Resolving Flutter dependencies (needed for first run or after dependency changes)...'
        Push-Location $flutterRoot
        try {
            & $flutterCommand.Source pub get
            if ($LASTEXITCODE -ne 0) {
                throw "flutter pub get failed with exit code $LASTEXITCODE."
            }
        }
        finally {
            Pop-Location
        }
    }

    Write-Host 'Starting the AI engine...'
    $engineProcess = Start-Process `
        -FilePath $pythonPath `
        -ArgumentList @(
            'main.py',
            '--headless',
            '--api-allowed-origin',
            "http://localhost:$flutterWebPort"
        ) `
        -WorkingDirectory $projectRoot `
        -NoNewWindow `
        -PassThru

    Write-Host 'Starting Sentinel in Chrome while the AI engine loads...'
    Push-Location $flutterRoot
    try {
        & $flutterCommand.Source run `
            --no-pub `
            -d chrome `
            "--web-port=$flutterWebPort" `
            "--dart-define=SUPABASE_URL=$supabaseUrl" `
            "--dart-define=SUPABASE_PUBLISHABLE_KEY=$publishableKey"
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}
catch {
    Write-Error $_
    $exitCode = 1
}
finally {
    if ($engineProcess -and -not $engineProcess.HasExited) {
        Write-Host 'Stopping the AI engine...'
        try {
            Invoke-RestMethod `
                -Uri 'http://127.0.0.1:8765/api/shutdown' `
                -Method Post `
                -TimeoutSec 3 | Out-Null
        }
        catch {
            Write-Warning 'Could not request a clean engine shutdown; stopping its process.'
        }
        if (-not $engineProcess.WaitForExit(15000)) {
            Stop-Process -Id $engineProcess.Id -Force
        }
    }
}

exit $exitCode
