<#
.SYNOPSIS
    Compila o RustAgility (Windows x64) localmente, sem GitHub Actions.

.DESCRIPTION
    Replica .github/workflows/agility-windows.yml numa maquina Windows:
      1. instala as ferramentas que faltarem (Git, Python, Rust, LLVM 15,
         Visual Studio 2022 Build Tools com C++)
      2. baixa o Flutter 3.24.5 e troca o engine pelo da RustDesk
      3. clona/atualiza o fork e aplica agility/hbb_common.patch
      4. copia os arquivos do bridge Flutter<->Rust ja gerados (agility/bridge)
      5. compila as dependencias C com vcpkg (ffmpeg, opus, libvpx, aom...)
      6. compila o app e gera RustAgility-<versao>-x86_64.exe (e o .msi com -Msi)

    Pode ser rodado de novo: cada etapa pula o que ja estiver pronto. A
    primeira vez leva HORAS (o vcpkg compila ffmpeg e companhia) e usa ~40 GB.

    Precisa de PowerShell COMO ADMINISTRADOR (instalacoes e Modo de
    Desenvolvedor, que o Flutter exige para plugins no Windows).

.PARAMETER Root
    Pasta de trabalho. Use um caminho CURTO (limite de 260 caracteres do
    Windows em algumas ferramentas). Padrao: C:\ra

.PARAMETER Repo
    URL do fork.

.PARAMETER Msi
    Tenta gerar tambem o .msi (WiX via NuGet). Se falhar, o .exe continua.

.PARAMETER SkipInstall
    Nao tenta instalar ferramentas (use se ja instalou tudo a mao).

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\build-windows.ps1

.EXAMPLE
    .\build-windows.ps1 -Root D:\ra -Msi
#>

[CmdletBinding()]
param(
    [string]$Root = 'C:\ra',
    [string]$Repo = 'https://github.com/Daniellbj/rustdesk-agility.git',
    [switch]$Msi,
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest muito mais rapido

# Versoes: as mesmas do workflow (agility-windows.yml / flutter-build.yml).
$RustVersion    = '1.75'
$FlutterVersion = '3.24.5'
$LlvmVersion    = '15.0.6'
$VcpkgCommit    = '9e593bb18ea69cc5095e012465dcd675a822ed0d'
$AppName        = 'RustAgility'

$Src     = Join-Path $Root 'src'
$Flutter = Join-Path $Root 'flutter'
$Vcpkg   = Join-Path $Root 'vcpkg'
$Out     = Join-Path $Root 'out'

function Step($msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Rode este script em um PowerShell COMO ADMINISTRADOR.'
    }
}

# Rele o PATH do registro: o que o winget acabou de instalar fica visivel
# sem precisar abrir outro terminal.
function Update-Path {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$m;$u;$env:USERPROFILE\.cargo\bin"
}

# Roda um programa externo e para o script se ele falhar ($ErrorActionPreference
# nao pega codigo de saida de executavel).
function Exec {
    param([Parameter(Mandatory)][string]$File, [string[]]$ArgList = @())
    & $File @ArgList
    if ($LASTEXITCODE -ne 0) { throw "Falhou ($LASTEXITCODE): $File $($ArgList -join ' ')" }
}

function Test-Cmd($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

# "python" pode ser so o atalho da Microsoft Store (abre a loja e sai com
# erro). Considera instalado apenas se responder "Python 3.x".
function Test-Python {
    try { return ((& python --version 2>&1 | Out-String) -match 'Python 3\.') } catch { return $false }
}

function Download($url, $dest) {
    if (Test-Path $dest) { return }
    Write-Host "    baixando $url"
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -Uri $url -OutFile "$dest.part" -UseBasicParsing
            Move-Item "$dest.part" $dest -Force
            return
        } catch {
            Write-Warning "tentativa $i/3 falhou: $($_.Exception.Message)"
            Start-Sleep -Seconds (5 * $i)
        }
    }
    throw "Nao consegui baixar $url"
}

function Winget-Install($id, $extra = @()) {
    Write-Host "    winget install $id"
    & winget install --id $id -e --accept-package-agreements --accept-source-agreements --silent @extra
    # 0 = ok; -1978335189 = ja instalado / sem atualizacao
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Write-Warning "winget $id retornou $LASTEXITCODE (seguindo; confira se instalou)"
    }
}

Assert-Admin
New-Item -ItemType Directory -Force -Path $Root, $Out | Out-Null
Start-Transcript -Path (Join-Path $Root 'build.log') -Append | Out-Null
$sw = [Diagnostics.Stopwatch]::StartNew()

try {
    # ------------------------------------------------------------------
    Step 'Configuracoes do Windows (caminhos longos e Modo de Desenvolvedor)'
    # Flutter usa symlinks para plugins: sem o Modo de Desenvolvedor o build
    # para com "Building with plugins requires symlink support".
    reg add 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' /v LongPathsEnabled /t REG_DWORD /d 1 /f | Out-Null
    reg add 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f | Out-Null

    # ------------------------------------------------------------------
    if (-not $SkipInstall) {
        Step 'Ferramentas (instala so o que faltar)'
        if (-not (Test-Cmd winget)) { throw 'winget nao encontrado. Instale o "App Installer" pela Microsoft Store.' }

        if (-not (Test-Cmd git))    { Winget-Install 'Git.Git' }
        if (-not (Test-Python)) { Winget-Install 'Python.Python.3.12' }
        if (-not (Test-Path "$env:USERPROFILE\.cargo\bin\rustup.exe")) { Winget-Install 'Rustlang.Rustup' }

        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        $hasVc = (Test-Path $vswhere) -and (& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
        if (-not $hasVc) {
            Write-Host '    Visual Studio 2022 Build Tools (C++) - demora, ~10 GB'
            Winget-Install 'Microsoft.VisualStudio.2022.BuildTools' @('--override', '--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended')
        }

        # LLVM na versao exata do workflow (bindgen/clang). O winget nem sempre
        # tem a 15.0.6, entao vai pelo instalador oficial.
        $clang = 'C:\Program Files\LLVM\bin\clang.exe'
        $clangOk = (Test-Path $clang) -and ((& $clang --version | Select-Object -First 1) -match [regex]::Escape($LlvmVersion))
        if (-not $clangOk) {
            $llvmExe = Join-Path $Root "LLVM-$LlvmVersion-win64.exe"
            Download "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/LLVM-$LlvmVersion-win64.exe" $llvmExe
            Exec $llvmExe @('/S')
        }
    }
    Update-Path
    $env:LIBCLANG_PATH = 'C:\Program Files\LLVM\bin'
    foreach ($c in 'git', 'rustup') {
        if (-not (Test-Cmd $c)) { throw "$c nao esta no PATH. Feche e abra o PowerShell (como Admin) e rode de novo." }
    }
    if (-not (Test-Python)) { throw 'Python 3 nao encontrado no PATH. Feche e abra o PowerShell (como Admin) e rode de novo.' }

    # ------------------------------------------------------------------
    Step "Rust $RustVersion"
    Exec rustup @('toolchain', 'install', "$RustVersion-x86_64-pc-windows-msvc", '--profile', 'minimal', '-c', 'rustfmt')

    # ------------------------------------------------------------------
    Step "Codigo-fonte ($Repo)"
    Exec git @('config', '--global', 'core.longpaths', 'true')
    if (-not (Test-Path (Join-Path $Src '.git'))) {
        Exec git @('clone', '--depth', '1', '--recurse-submodules', '--shallow-submodules', $Repo, $Src)
    } else {
        # Desfaz o patch/arquivos copiados da rodada anterior antes de atualizar.
        Exec git @('-C', $Src, 'submodule', 'foreach', '--recursive', 'git checkout -- . && git clean -fdq')
        Exec git @('-C', $Src, 'checkout', '--', '.')
        Exec git @('-C', $Src, 'pull', '--ff-only')
        Exec git @('-C', $Src, 'submodule', 'update', '--init', '--recursive', '--depth', '1')
    }
    Set-Location $Src
    Exec rustup @('override', 'set', "$RustVersion-x86_64-pc-windows-msvc")

    Step 'Aplicando agility/hbb_common.patch (nome, servidor, Key, WebSocket)'
    Exec git @('-C', 'libs/hbb_common', 'apply', '--verbose', '../../agility/hbb_common.patch')

    Step 'Bridge Flutter<->Rust (gerado no Linux, em agility/bridge)'
    Copy-Item agility\bridge\bridge_generated.rs, agility\bridge\bridge_generated.io.rs src\ -Force
    Copy-Item agility\bridge\generated_bridge.dart, agility\bridge\generated_bridge.freezed.dart flutter\lib\ -Force
    Copy-Item agility\bridge\bridge_generated.h flutter\macos\Runner\ -Force

    # ------------------------------------------------------------------
    Step "Flutter $FlutterVersion"
    if (-not (Test-Path (Join-Path $Flutter 'bin\flutter.bat'))) {
        $zip = Join-Path $Root "flutter_windows_$FlutterVersion-stable.zip"
        Download "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_$FlutterVersion-stable.zip" $zip
        Expand-Archive $zip -DestinationPath $Root -Force
    }
    $env:Path = "$Flutter\bin;$env:Path"
    Exec git @('config', '--global', '--add', 'safe.directory', ($Flutter -replace '\\', '/'))
    Exec flutter @('config', '--no-analytics')
    Exec flutter @('precache', '--windows')

    # Engine customizado da RustDesk (https://github.com/flutter/flutter/issues/155685)
    $engineDir = Join-Path $Flutter 'bin\cache\artifacts\engine\windows-x64-release'
    $engineMark = Join-Path $engineDir '.rustdesk-engine'
    if (-not (Test-Path $engineMark)) {
        $ezip = Join-Path $Root 'windows-x64-release.zip'
        Download 'https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip' $ezip
        $etmp = Join-Path $Root 'engine-tmp'
        Remove-Item $etmp -Recurse -Force -ErrorAction SilentlyContinue
        Expand-Archive $ezip -DestinationPath $etmp -Force
        Copy-Item (Join-Path $etmp '*') $engineDir -Recurse -Force
        Set-Content $engineMark 'ok'
    }

    # Patch do dropdown (so uma vez: --check falha se ja aplicado)
    $diff = Join-Path $Src '.github\patches\flutter_3.24.4_dropdown_menu_enableFilter.diff'
    & git -C $Flutter apply --check $diff 2>$null
    if ($LASTEXITCODE -eq 0) { Exec git @('-C', $Flutter, 'apply', $diff) } else { Write-Host '    patch do flutter ja aplicado' }

    # ------------------------------------------------------------------
    Step 'vcpkg (dependencias C/C++). Primeira vez: 1-3 horas'
    if (-not (Test-Path (Join-Path $Vcpkg '.git'))) {
        Exec git @('clone', 'https://github.com/microsoft/vcpkg.git', $Vcpkg)
    }
    Exec git @('-C', $Vcpkg, 'fetch', '--quiet', 'origin')
    Exec git @('-C', $Vcpkg, 'checkout', '--quiet', $VcpkgCommit)
    if (-not (Test-Path (Join-Path $Vcpkg 'vcpkg.exe'))) {
        Exec (Join-Path $Vcpkg 'bootstrap-vcpkg.bat') @('-disableMetrics')
    }
    $env:VCPKG_ROOT = $Vcpkg
    $env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
    Exec (Join-Path $Vcpkg 'vcpkg.exe') @('install', '--triplet', 'x64-windows-static', "--x-install-root=$Vcpkg\installed")

    # ------------------------------------------------------------------
    Step 'Compilando (cargo + flutter). 30-60 min'
    Exec python @('-m', 'pip', 'install', '--quiet', '--upgrade', 'pip')
    Exec python @('.\build.py', '--portable', '--flutter', '--skip-portable-pack', '--hwcodec', '--vram')

    $dist = Join-Path $Src 'rustdesk'
    Remove-Item $dist -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item (Join-Path $Src 'flutter\build\windows\x64\runner\Release') $dist

    # Driver de monitor virtual (mesmo passo do build oficial)
    $uzip = Join-Path $Root 'usbmmidd_v2.zip'
    Download 'https://github.com/rustdesk-org/rdev/releases/download/usbmmidd_v2/usbmmidd_v2.zip' $uzip
    $utmp = Join-Path $Root 'usbmmidd-tmp'
    Remove-Item $utmp -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $uzip -DestinationPath $utmp -Force
    Remove-Item (Join-Path $utmp 'usbmmidd_v2\Win32') -Recurse -Force
    Remove-Item (Join-Path $utmp 'usbmmidd_v2\deviceinstaller64.exe'), (Join-Path $utmp 'usbmmidd_v2\deviceinstaller.exe'), (Join-Path $utmp 'usbmmidd_v2\usbmmidd.bat') -Force
    Move-Item (Join-Path $utmp 'usbmmidd_v2') $dist -Force

    # ------------------------------------------------------------------
    Step 'Gerando o instalador auto-extraivel'
    $version = (Select-String -Path Cargo.toml -Pattern '^version\s*=\s*"([^"]+)"' | Select-Object -First 1).Matches.Groups[1].Value
    $res = Get-ChildItem -Path . -Recurse -Filter Runner.res -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($res) { Copy-Item $res.FullName libs\portable\Runner.res -Force }

    (Get-Content res\manifest.xml) | Where-Object { $_ -notmatch 'dpiAware' } | Set-Content res\manifest.xml
    Push-Location libs\portable
    Exec python @('-m', 'pip', 'install', '--quiet', '-r', 'requirements.txt')
    Exec python @('.\generate.py', '-f', '..\..\rustdesk\', '-o', '.', '-e', '..\..\rustdesk\rustdesk.exe')
    Pop-Location
    Exec git @('checkout', '--', 'res/manifest.xml')

    $exeOut = Join-Path $Out "$AppName-$version-x86_64.exe"
    Move-Item target\release\rustdesk-portable-packer.exe $exeOut -Force
    Write-Host "    $exeOut"

    # ------------------------------------------------------------------
    if ($Msi) {
        Step 'MSI (opcional)'
        try {
            $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
            $msbuild = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
            $nuget = Join-Path $Root 'nuget.exe'
            Download 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' $nuget

            $msiDist = Join-Path $Src 'rustdesk-msi'
            Remove-Item $msiDist -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item $dist $msiDist -Recurse
            Rename-Item (Join-Path $msiDist 'rustdesk.exe') "$AppName.exe"

            Push-Location res\msi
            Exec python @('preprocess.py', '--arp', '-c', '--app-name', $AppName, '-m', $AppName, '-d', '..\..\rustdesk-msi')
            Exec $nuget @('restore', 'msi.sln')
            Exec $msbuild @('msi.sln', '-p:Configuration=Release', '-p:Platform=x64', '/p:TargetVersion=Windows10')
            $msi = Get-ChildItem .\Package\bin\*\Release\en-us\Package.msi | Select-Object -First 1
            Pop-Location
            $msiOut = Join-Path $Out "$AppName-$version-x86_64.msi"
            Move-Item $msi.FullName $msiOut -Force
            Exec git @('checkout', '--', 'res/msi')
            Write-Host "    $msiOut"
        } catch {
            Pop-Location -ErrorAction SilentlyContinue
            Write-Warning "MSI falhou (o .exe esta pronto): $($_.Exception.Message)"
        }
    }

    Step ("Pronto em {0:hh\:mm\:ss}. Instaladores em {1}" -f $sw.Elapsed, $Out)
    Get-ChildItem $Out | Format-Table Name, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } -AutoSize
}
finally {
    Stop-Transcript | Out-Null
}
