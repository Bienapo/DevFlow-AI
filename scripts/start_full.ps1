param(
    [ValidateRange(1, 65535)]
    [int]$BackendPort = 8000,
    [ValidateRange(1, 65535)]
    [int]$FrontendPort = 3000
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$backendDirectory = Join-Path $projectRoot "backend"
$frontendDirectory = Join-Path $projectRoot "frontend"
$pythonPath = Join-Path $backendDirectory ".venv\Scripts\python.exe"
$dataDirectory = Join-Path $projectRoot ".data"
$docker = (Get-Command docker -ErrorAction SilentlyContinue).Source
if (-not $docker) {
    $docker = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
}

if (-not (Test-Path -LiteralPath (Join-Path $projectRoot ".env") -PathType Leaf)) {
    throw "未找到项目根目录的 .env。请先配置数据库与模型密钥。"
}
if (-not (Test-Path -LiteralPath $docker -PathType Leaf)) {
    throw "未找到 Docker CLI。请安装并启动 Docker Desktop。"
}
if (-not (Test-Path -LiteralPath $pythonPath -PathType Leaf)) {
    throw "未找到 backend/.venv。请安装后端依赖。"
}
if (-not (Test-Path -LiteralPath (Join-Path $frontendDirectory "node_modules") -PathType Container)) {
    throw "未找到 frontend/node_modules。请安装前端依赖。"
}

New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $dataDirectory "tmp") -Force | Out-Null

Push-Location $projectRoot
try {
    & $docker compose up -d postgres etcd minio milvus
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose 启动失败。" }
}
finally {
    Pop-Location
}

$env:HF_HOME = Join-Path $dataDirectory "hf"
$env:PYTHONPATH = $backendDirectory
$env:PYTHONUTF8 = "1"
$env:TEMP = Join-Path $dataDirectory "tmp"
$env:TMP = $env:TEMP
$env:NEXT_PUBLIC_API_BASE_URL = "http://127.0.0.1:$BackendPort"

if (-not (Test-Path -LiteralPath (Join-Path $frontendDirectory ".next\BUILD_ID") -PathType Leaf)) {
    Push-Location $frontendDirectory
    try {
        & npm.cmd run build
        if ($LASTEXITCODE -ne 0) { throw "Next.js 构建失败。" }
    }
    finally {
        Pop-Location
    }
}

$backendProcess = $null
$frontendProcess = $null
try {
    $backendProcess = Start-Process `
        -FilePath $pythonPath `
        -ArgumentList @("-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "$BackendPort") `
        -WorkingDirectory $backendDirectory `
        -RedirectStandardOutput (Join-Path $dataDirectory "devflow-full-backend.out.log") `
        -RedirectStandardError (Join-Path $dataDirectory "devflow-full-backend.err.log") `
        -WindowStyle Hidden `
        -PassThru

    $backendReady = $false
    for ($attempt = 0; $attempt -lt 120; $attempt += 1) {
        if ($backendProcess.HasExited) { throw "后端进程提前退出，请检查 .data/devflow-full-backend.err.log。" }
        try {
            Invoke-RestMethod -Uri "http://127.0.0.1:$BackendPort/health" -TimeoutSec 2 | Out-Null
            $backendReady = $true
            break
        }
        catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $backendReady) { throw "后端在 60 秒内没有就绪，请检查后端日志。" }

    $frontendProcess = Start-Process `
        -FilePath "npm.cmd" `
        -ArgumentList @("run", "start", "--", "-p", "$FrontendPort") `
        -WorkingDirectory $frontendDirectory `
        -RedirectStandardOutput (Join-Path $dataDirectory "devflow-full-frontend.out.log") `
        -RedirectStandardError (Join-Path $dataDirectory "devflow-full-frontend.err.log") `
        -WindowStyle Hidden `
        -PassThru

    $frontendReady = $false
    for ($attempt = 0; $attempt -lt 120; $attempt += 1) {
        if ($frontendProcess.HasExited) { throw "前端进程提前退出，请检查 .data/devflow-full-frontend.err.log。" }
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$FrontendPort" -TimeoutSec 2 | Out-Null
            $frontendReady = $true
            break
        }
        catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $frontendReady) { throw "前端在 60 秒内没有就绪，请检查前端日志。" }

    Write-Host "DevFlow AI 正式模式已启动："
    Write-Host "  前端：http://127.0.0.1:$FrontendPort"
    Write-Host "  后端：http://127.0.0.1:$BackendPort"
    Write-Host "  API 文档：http://127.0.0.1:$BackendPort/docs"
    Write-Host "  后端 PID：$($backendProcess.Id)"
    Write-Host "  前端 PID：$($frontendProcess.Id)"
}
catch {
    if ($frontendProcess -and -not $frontendProcess.HasExited) { Stop-Process -Id $frontendProcess.Id }
    if ($backendProcess -and -not $backendProcess.HasExited) { Stop-Process -Id $backendProcess.Id }
    throw
}
