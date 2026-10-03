# DSH 升级后自检（SOP 固化 v2）
#
# 背景：DSH 桌面端会自动升级运行时（例如 0.2.0-rc.1 -> 0.2.0-rc.2）。
# 一旦运行时版本变了，凡是用「精确 pin」声明 peer 的插件都会在启动时被拒
# （典型症状：插件看似已安装，但功能不生效，例如 MCP 工具列表为空）。
#
# 每次桌面端自动升级后运行一次：
#     pwsh -File "<REPO>/dsh-maintenance\check-after-upgrade.ps1"
#
# v2 改进：识别并扣除「精确 prerelease pin == 当前运行时」的已知假阳性，使退出码可直接当门禁用。

param(
    [string]$CompatScript = '<REPO>/compat-check\check-plugin-compat.ps1',
    [string]$Profile      = (Join-Path $env:USERPROFILE '.dsh\profiles\desktop')
)

$ErrorActionPreference = 'Continue'

function Get-DesktopAppVersion {
    $entries = Get-ItemProperty @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    ) -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'DeepSeek Harness' } | Select-Object -First 1
    if ($entries) { return $entries.DisplayVersion } else { return $null }
}

Write-Host '===== DSH 升级后自检 =====' -ForegroundColor Cyan

$appVersion = Get-DesktopAppVersion
$cliVersion = ((& dsh --version 2>&1 | Select-Object -First 1) -as [string])
if ($cliVersion) { $cliVersion = $cliVersion.Trim() }

Write-Host ("桌面运行时 (desktop app) : {0}" -f $(if ($appVersion) { $appVersion } else { '未检测到' }))
Write-Host ("全局 CLI (dsh --version) : {0}" -f $(if ($cliVersion) { $cliVersion } else { '未检测到' }))

if ($appVersion -and $cliVersion -and $appVersion -ne $cliVersion) {
    Write-Host ''
    Write-Host "[!] 版本不一致：预检基准是全局 CLI，会和真实运行时错位。" -ForegroundColor Yellow
    Write-Host "    建议先对齐： npm install -g @deepseek-ai/dsh@$appVersion" -ForegroundColor Yellow
}

# ---- 收集已装插件（以 node_modules 里的实际版本为准）+ 识别假阳性 ----
$pkgPath = Join-Path $Profile 'package.json'
if (-not (Test-Path $pkgPath)) { Write-Host "找不到 $pkgPath" -ForegroundColor Red; exit 2 }

$deps = (Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json).dependencies
if (-not $deps) { Write-Host '该 profile 没有已装插件。' -ForegroundColor Yellow; exit 2 }

$specs       = @()
$benignNames = @()
$benignNote  = @()

foreach ($prop in $deps.PSObject.Properties) {
    $name = $prop.Name
    $pj = Join-Path $Profile ("node_modules\{0}\package.json" -f ($name -replace '/', '\'))
    $installed = $null
    if (Test-Path $pj) { $installed = (Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json).version }
    if (-not $installed) { $installed = $prop.Value }
    $specs += "$name@$installed"

    # 精确 prerelease pin：预检工具必然误判；只有 pin == 运行时版本时才算「良性」
    if (Test-Path $pj) {
        $peers = (Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json).peerDependencies
        if ($peers) {
            $pins = @($peers.PSObject.Properties |
                Where-Object { $_.Name -like '@deepseek-ai/*' -and $_.Value -match '^\d+\.\d+\.\d+-\w' })
            if ($pins.Count -gt 0) {
                $same = ($appVersion -and ($pins | Where-Object { $_.Value -ne $appVersion }).Count -eq 0)
                if ($same) {
                    $benignNames += $name
                    $benignNote  += ("{0} (pin {1} = 运行时)" -f $name, $pins[0].Value)
                }
            }
        }
    }
}

Write-Host ''
Write-Host ("待检插件 {0} 个" -f $specs.Count) -ForegroundColor DarkGray
Write-Host ''

if (-not (Test-Path $CompatScript)) { Write-Host "找不到预检脚本 $CompatScript" -ForegroundColor Red; exit 2 }

$checkOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $CompatScript -Specs ($specs -join ',') -Profile $Profile 2>&1
$code = $LASTEXITCODE
$checkOutput | ForEach-Object { $_ }

# ---- 判定修正：只由「良性假阳性」构成的 INCOMPATIBLE 不计为失败 ----
$inc = @()
foreach ($line in $checkOutput) {
    if ("$line" -match '^\[INCOMPATIBLE\]\s+(.+?)@(\S+)\s*$') { $inc += $matches[1] }
}
$realInc = @($inc | Where-Object { $benignNames -notcontains $_ })

Write-Host ''
if ($benignNote.Count -gt 0) {
    Write-Host '已知假阳性（可忽略）：' -ForegroundColor DarkGray
    $benignNote | ForEach-Object { Write-Host ("   - {0}" -f $_) -ForegroundColor DarkGray }
}

if ($code -eq 1 -and $inc.Count -gt 0 -and $realInc.Count -eq 0) {
    Write-Host ("判定修正：{0} 个 INCOMPATIBLE 全部是「精确 prerelease pin == 当前运行时」的假阳性，实际通过。" -f $inc.Count) -ForegroundColor Green
    $code = 0
}
elseif ($realInc.Count -gt 0) {
    Write-Host ("真正不兼容：{0}" -f ($realInc -join ', ')) -ForegroundColor Red
}

switch ($code) {
    0 { Write-Host '结论：通过 —— 无需处理（REVIEW 仅为外部 peer 警告）。' -ForegroundColor Green }
    1 { Write-Host '结论：存在真正不兼容项 —— 把上面 FAIL 的插件升/降到与运行时匹配的版本。' -ForegroundColor Red }
    3 { Write-Host '结论：有插件无法核实（npm 元数据没拉到）—— 网络恢复后重跑。' -ForegroundColor Magenta }
    default { Write-Host "结论：预检退出码 $code。" -ForegroundColor Yellow }
}

exit $code
