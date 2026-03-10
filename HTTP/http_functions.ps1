# ==============================================================
#  http_functions.ps1  -  Modulo de funciones
#  Practica 6 - Gestor de Servicios HTTP - Windows
#  Corregido: Apache SRVROOT, mod_headers, rutas dinamicas,
#             Nginx BOM/encoding, comment parsing PS5.1,
#             port registry limpio en fallo de instalacion
# ==============================================================

# ── REGISTRO DE PUERTOS ────────────────────────────────────────
$script:PortRegistry     = @{}
$script:PortRegistryFile = "C:\Practica6_ports.json"

function Load-PortRegistry {
    if (Test-Path $script:PortRegistryFile) {
        try {
            $json = Get-Content $script:PortRegistryFile -Raw | ConvertFrom-Json
            $script:PortRegistry = @{}
            $json.PSObject.Properties | ForEach-Object {
                $script:PortRegistry[$_.Name] = [int]$_.Value
            }
        } catch { $script:PortRegistry = @{} }
    }
}

function Save-PortRegistry {
    $script:PortRegistry | ConvertTo-Json | Set-Content $script:PortRegistryFile -Encoding UTF8
}

function Get-ServicePort {
    param([string]$ServiceName)
    if ($script:PortRegistry.ContainsKey($ServiceName)) { return $script:PortRegistry[$ServiceName] }
    return 0
}

function Set-ServicePort {
    param([string]$ServiceName, [int]$Port)
    $script:PortRegistry[$ServiceName] = $Port
    Save-PortRegistry
}

function Clear-PortRegistry {
    $script:PortRegistry = @{}
    if (Test-Path $script:PortRegistryFile) { Remove-Item $script:PortRegistryFile -Force }
    Write-OK "Registro de puertos limpiado."
}

# ── UI ─────────────────────────────────────────────────────────
function Write-Header {
    param([string]$Title)
    $line = "=" * 58
    Write-Host "`n$line" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor White
    Write-Host "$line`n" -ForegroundColor Cyan
}

function Write-SubHeader {
    param([string]$Title)
    $line = "-" * 48
    Write-Host "`n$line" -ForegroundColor DarkCyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "$line`n" -ForegroundColor DarkCyan
}

function Write-Info  { param([string]$M) Write-Host "[INFO]  $M" -ForegroundColor Blue }
function Write-OK    { param([string]$M) Write-Host "[OK]    $M" -ForegroundColor Green }
function Write-Warn  { param([string]$M) Write-Host "[WARN]  $M" -ForegroundColor Yellow }
function Write-Err   { param([string]$M) Write-Host "[ERROR] $M" -ForegroundColor Red }

# ── VALIDACIONES ───────────────────────────────────────────────
function Get-ValidOption {
    param([int]$Min, [int]$Max)
    while ($true) {
        Write-Host "Opcion: " -ForegroundColor Magenta -NoNewline
        $raw = (Read-Host).Trim()
        if ($raw -match '^\d+$') {
            $n = [int]$raw
            if ($n -ge $Min -and $n -le $Max) { return $n }
        }
        Write-Err "Opcion invalida. Ingrese un numero entre $Min y $Max."
    }
}

function Get-ValidPort {
    param([string]$ServiceName = "")
    $reserved     = @(22,23,25,53,110,135,139,143,443,445,3306,3389,5985,5986)
    # Procesos HTTP propios que este script puede matar libremente
    $ownedProcs   = @("httpd","nginx","w3wp")
    $usedByOthers = $script:PortRegistry.GetEnumerator() |
                    Where-Object { $_.Key -ne $ServiceName } |
                    ForEach-Object { $_.Value }
    while ($true) {
        Write-Host "[INPUT] Puerto de escucha (ej. 80, 8080, 8888): " -ForegroundColor Magenta -NoNewline
        $raw = (Read-Host).Trim()
        if ($raw -notmatch '^\d+$') { Write-Err "Solo numeros enteros."; continue }
        $port = [int]$raw
        if ($port -lt 1 -or $port -gt 65535)  { Write-Err "Puerto fuera de rango (1-65535)."; continue }
        if ($reserved -contains $port)          { Write-Err "Puerto $port reservado para el sistema."; continue }
        if ($usedByOthers -contains $port) {
            $owner = ($script:PortRegistry.GetEnumerator() |
                      Where-Object { $_.Value -eq $port } | Select-Object -First 1).Key
            Write-Err "Puerto $port ya lo usa '$owner'. Cada servidor necesita un puerto diferente."
            continue
        }
        if (-not (Test-PortFree $port)) {
            $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            $proc = if ($conn) { Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue } else { $null }
            $procName = if ($proc) { $proc.Name.ToLower() } else { "" }
            if ($ownedProcs -contains $procName) {
                # Es un proceso HTTP propio: detener servicio + matar proceso
                Write-Warn "Puerto $port en uso por $($proc.Name) (PID $($proc.Id)). Liberando..."
                Stop-Service "Apache2.4" -Force -ErrorAction SilentlyContinue
                Stop-Service "nginx"     -Force -ErrorAction SilentlyContinue
                Stop-Service "W3SVC"     -Force -ErrorAction SilentlyContinue
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                if (Test-PortFree $port) {
                    Write-OK "Puerto $port liberado correctamente."
                } else {
                    Write-Err "No se pudo liberar el puerto $port."
                    continue
                }
            } else {
                # Proceso de tercero: no tocar, pedir otro puerto
                Write-Err "Puerto $port ocupado por: $(if ($proc) {"$($proc.Name) (PID $($proc.Id))"} else {"proceso desconocido"})"
                Write-Info "Este proceso no es un servidor HTTP gestionado por este script."
                Write-Info "Elija un puerto diferente."
                continue
            }
        }
        return $port
    }
}

function Test-PortFree {
    param([int]$Port)
    $inUse = (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue).LocalPort
    return ($inUse -notcontains $Port)
}

function Test-PortOwnedByService {
    # Devuelve $true si el puerto esta en uso por el proceso del servicio indicado
    param([int]$Port, [string]$ServiceName)
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) { return $false }
    $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    $knownProcesses = @{
        "Apache" = @("httpd")
        "Nginx"  = @("nginx")
        "IIS"    = @("w3wp","svchost")
    }
    $expected = $knownProcesses[$ServiceName]
    if (-not $expected) { return $false }
    return ($expected -contains $proc.Name.ToLower())
}

# ── CHOCOLATEY ────────────────────────────────────────────────
function Ensure-Chocolatey {
    $chocoBin = "$env:ProgramData\chocolatey\bin"
    $chocoExe = "$chocoBin\choco.exe"
    if ($env:Path -notmatch "chocolatey") { $env:Path += ";$chocoBin" }
    if (Test-Path $chocoExe) {
        Write-OK "Chocolatey disponible."
        return $true
    }
    Write-Info "Instalando Chocolatey..."
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path += ";$chocoBin"
        if (Test-Path $chocoExe) { Write-OK "Chocolatey instalado."; return $true }
        Write-Err "Chocolatey no se instalo correctamente."
        return $false
    } catch {
        Write-Err "Error instalando Chocolatey: $_"
        return $false
    }
}

function Get-ChocoExe {
    # FIX: funcion centralizada para obtener la ruta de choco, evita repeticion
    $path = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (Test-Path $path) { return $path }
    $alt = Get-Command choco -ErrorAction SilentlyContinue
    if ($alt) { return $alt.Source }
    return $null
}

function Invoke-Choco {
    param([string]$Args)
    $chocoExe = Get-ChocoExe
    if ($chocoExe) {
        return & $chocoExe $Args.Split(' ') 2>&1
    }
    return "ERROR: choco.exe no encontrado"
}

# ── VERSIONES DINAMICAS ────────────────────────────────────────
function Get-AvailableVersions {
    param([string]$Package)
    Write-Info "Consultando versiones de '$Package' en Chocolatey..."
    $chocoExe = Get-ChocoExe
    if (-not $chocoExe) {
        Ensure-Chocolatey | Out-Null
        $chocoExe = Get-ChocoExe
    }
    if (-not $chocoExe) { return $null }
    try {
        $raw = & $chocoExe search $Package --exact --all-versions 2>&1 |
               Where-Object {
                   $_ -match $Package -and
                   $_ -notmatch "^Chocolatey" -and
                   $_ -match '\d+\.\d+'
               }
        $versions = $raw | ForEach-Object {
            # FIX: regex mas estricta para evitar falsos positivos en versiones
            if ($_ -match '(\d+\.\d+[\.\d]*)') { $matches[1] }
        } | Where-Object {
            $_ -and $_ -match '^\d' -and [version]::TryParse($_, [ref]$null)
        } | Select-Object -Unique |
            Sort-Object { [version]$_ } -Descending
        if ($versions -and @($versions).Count -gt 0) {
            Write-OK "Se encontraron $(@($versions).Count) versiones disponibles."
            return $versions
        }
    } catch { Write-Warn "Error consultando Chocolatey: $_" }
    return $null
}

function Select-Version {
    param([string]$ServiceName, [string]$Package)
    $versions = Get-AvailableVersions -Package $Package
    if (-not $versions) {
        Write-Warn "No se pudo consultar el repositorio. Usando versiones conocidas."
        if ($Package -match "apache") {
            $versions = @("2.4.55","2.4.54","2.4.53","2.4.52","2.4.51","2.4.49","2.4.48","2.4.46")
        } else {
            $versions = @("1.27.2","1.26.2","1.24.0","1.22.1","1.20.2","1.18.0","1.16.1","1.14.2")
        }
    }
    Write-SubHeader "Versiones disponibles - $ServiceName"
    Write-Host "  [Latest] = mas reciente   [LTS] = estable   [OLD] = anteriores`n" -ForegroundColor DarkGray
    $i = 1
    $vList = @()
    foreach ($v in $versions) {
        $tag   = if ($i -eq 1) {"[Latest]"} elseif ($i -eq 2) {"[LTS]   "} else {"[OLD]   "}
        $color = if ($i -eq 1) {"Green"}    elseif ($i -eq 2) {"Cyan"}     else {"DarkGray"}
        Write-Host ("  {0,2}) {1,-14} {2}" -f $i, $v, $tag) -ForegroundColor $color
        $vList += $v
        $i++
    }
    Write-Host ""
    $opt = Get-ValidOption -Min 1 -Max $vList.Count
    $sel = $vList[$opt - 1]
    Write-OK "Version seleccionada: $sel"
    return $sel
}

# ── FIX BOM EN ARCHIVOS DE CONFIGURACION ──────────────────────
function Fix-FileBOM {
    # FIX: funcion generica (renombrada desde Fix-NginxBOM, sirve para nginx y apache)
    param([string]$ConfigFile)
    if (-not (Test-Path $ConfigFile)) { return }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($ConfigFile)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            Write-Info "Eliminando BOM de: $(Split-Path $ConfigFile -Leaf)"
            $noBom = $bytes[3..($bytes.Length - 1)]
            [System.IO.File]::WriteAllBytes($ConfigFile, $noBom)
        }
        $lines = [System.IO.File]::ReadAllLines($ConfigFile, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllLines($ConfigFile, $lines, (New-Object System.Text.UTF8Encoding $false))
    } catch { Write-Warn "No se pudo limpiar BOM: $_" }
}

# Alias para compatibilidad con llamadas existentes
function Fix-NginxBOM { param([string]$ConfigFile) Fix-FileBOM -ConfigFile $ConfigFile }

# ── BUSCAR ARCHIVOS DE CONFIGURACION ──────────────────────────
function Find-ApacheRoot {
    # Rutas conocidas en orden de probabilidad - SIN busqueda recursiva en C:\ para no colgar
    $candidates = @(
        "$env:APPDATA\Apache24",
        "$env:USERPROFILE\AppData\Roaming\Apache24",
        "C:\Apache24",
        "C:\tools\Apache24",
        "C:\ProgramData\chocolatey\lib\apache-httpd\tools\Apache24"
    )
    foreach ($c in $candidates) {
        if (Test-Path "$c\bin\httpd.exe") { return $c }
    }
    # Busqueda limitada solo en directorios de choco y tools (con -Depth para no colgar)
    foreach ($base in @("$env:APPDATA", "$env:ProgramData\chocolatey\lib", "C:\tools")) {
        if (Test-Path $base) {
            $found = Get-ChildItem $base -Recurse -Filter "httpd.exe" -Depth 6 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return Split-Path (Split-Path $found.FullName -Parent) -Parent }
        }
    }
    return $null
}

function Find-ApacheConf {
    $root = Find-ApacheRoot
    if ($root) {
        $conf = "$root\conf\httpd.conf"
        if (Test-Path $conf) { return $conf }
    }
    return $null
}

function Find-ApacheExe {
    $root = Find-ApacheRoot
    if ($root) {
        $exe = "$root\bin\httpd.exe"
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

function Find-NginxRoot {
    # Rutas conocidas en orden de probabilidad - SIN busqueda recursiva para no colgar
    $candidates = @(
        "C:\ProgramData\chocolatey\lib\nginx\tools\nginx",
        "C:\tools\nginx",
        "C:\nginx",
        "C:\ProgramData\chocolatey\lib\nginx\tools\nginx-1*"
    )
    foreach ($c in $candidates) {
        # Soportar wildcards para versiones con numero en la ruta
        $resolved = Get-Item $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($resolved -and (Test-Path "$($resolved.FullName)\nginx.exe")) {
            return $resolved.FullName
        }
        if (Test-Path "$c\nginx.exe") { return $c }
    }
    # Busqueda limitada solo en C:\tools y C:\ProgramData\chocolatey (no en C:\)
    foreach ($base in @("C:\tools","C:\ProgramData\chocolatey\lib")) {
        if (Test-Path $base) {
            $found = Get-ChildItem $base -Recurse -Filter "nginx.exe" -Depth 6 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return Split-Path $found.FullName -Parent }
        }
    }
    return $null
}

function Find-NginxConf {
    $root = Find-NginxRoot
    if ($root) {
        $conf = "$root\conf\nginx.conf"
        if (Test-Path $conf) { return $conf }
    }
    return $null
}

function Find-NginxExe {
    $root = Find-NginxRoot
    if ($root) {
        $exe = "$root\nginx.exe"
        if (Test-Path $exe) { return $exe }
    }
    return $null
}

# ── DETENER SERVICIO POR NOMBRE ───────────────────────────────
function Stop-ServiceByName {
    # Detiene el servicio/proceso HTTP indicado de forma silenciosa
    # Usado antes de validar puertos para que el propio servicio no bloquee su puerto
    param([string]$ServiceName, [switch]$Silent)
    switch ($ServiceName) {
        "Apache" {
            # Intentar detener via servicio primero
            $svc = Get-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
            if ($svc) { Stop-Service Apache2.4 -Force -ErrorAction SilentlyContinue }
            # Matar proceso httpd directamente (cubre caso de servicio no registrado)
            Get-Process -Name "httpd" -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            if (-not $Silent) { Write-Info "Apache detenido." }
        }
        "Nginx" {
            $svc = Get-Service -Name "nginx" -ErrorAction SilentlyContinue
            if ($svc) { Stop-Service nginx -Force -ErrorAction SilentlyContinue }
            Get-Process -Name "nginx" -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            if (-not $Silent) { Write-Info "Nginx detenido." }
        }
        "IIS" {
            $svc = Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq "Running") {
                Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
            if (-not $Silent) { Write-Info "IIS detenido." }
        }
    }
}

# ── FIREWALL ───────────────────────────────────────────────────
function Apply-FirewallRule {
    param([int]$NewPort, [int]$OldPort = 0)
    Write-Info "Configurando firewall para puerto $NewPort..."
    try {
        $rule = "HTTP-Practica6-Puerto$NewPort"
        if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $rule -Direction Inbound `
                -Protocol TCP -LocalPort $NewPort -Action Allow | Out-Null
            Write-OK "Firewall: puerto $NewPort abierto."
        } else { Write-Info "Regla de firewall ya existe para puerto $NewPort." }
        if ($OldPort -gt 0 -and $OldPort -ne $NewPort) {
            $oldRule = "HTTP-Practica6-Puerto$OldPort"
            if (Get-NetFirewallRule -DisplayName $oldRule -ErrorAction SilentlyContinue) {
                Remove-NetFirewallRule -DisplayName $oldRule -ErrorAction SilentlyContinue
                Write-OK "Firewall: puerto $OldPort cerrado."
            }
        }
    } catch { Write-Err "Error en firewall: $_" }
}

# ── USUARIO DEDICADO ───────────────────────────────────────────
function Ensure-ServiceUser {
    param([string]$Username, [string]$Webroot)
    Write-Info "Verificando usuario '$Username'..."
    if (-not (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)) {
        $pass = ConvertTo-SecureString "Svc!P6$(Get-Random -Max 9999)" -AsPlainText -Force
        New-LocalUser -Name $Username -Password $pass `
            -Description "Usuario HTTP Practica 6" `
            -PasswordNeverExpires:$true -UserMayNotChangePassword:$true | Out-Null
        Write-OK "Usuario '$Username' creado."
    } else { Write-Info "Usuario '$Username' ya existe." }
    if (Test-Path $Webroot) {
        try {
            # FIX: usar icacls con SID para evitar IdentityNotMappedException en OS localizado
            $sid = (Get-LocalUser -Name $Username).SID.Value
            icacls $Webroot /grant "*${sid}:(OI)(CI)M" /T /Q 2>&1 | Out-Null
            Write-OK "Permisos NTFS aplicados a '$Username' en $Webroot"
        } catch { Write-Warn "No se pudieron aplicar permisos NTFS: $_" }
    }
}

# ── INDEX.HTML ─────────────────────────────────────────────────
function New-IndexPage {
    param([string]$Service, [string]$Version, [int]$Port, [string]$Webroot)
    if (-not (Test-Path $Webroot)) { New-Item -ItemType Directory -Path $Webroot -Force | Out-Null }
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <title>$Service - Practica 6</title>
  <style>
    *{margin:0;padding:0;box-sizing:border-box}
    body{font-family:'Segoe UI',sans-serif;background:#0d0d1a;color:#eee;
         display:flex;justify-content:center;align-items:center;min-height:100vh}
    .card{background:#111827;border:1px solid #1e3a5f;border-radius:12px;
          padding:50px 70px;text-align:center;box-shadow:0 0 40px rgba(0,150,255,.15)}
    h1{color:#00bfff;font-size:1.8rem;margin-bottom:28px}
    table{margin:0 auto;border-collapse:collapse;width:100%}
    td{padding:10px 24px;border:1px solid #1e3a5f}
    td:first-child{color:#8899aa;text-align:right}
    td:last-child{color:#00ff99;font-weight:bold;text-align:left}
    .footer{margin-top:24px;color:#445;font-size:11px}
  </style>
</head>
<body>
  <div class="card">
    <h1>Servidor HTTP &mdash; Windows</h1>
    <table>
      <tr><td>Servidor</td><td>$Service</td></tr>
      <tr><td>Version</td><td>$Version</td></tr>
      <tr><td>Puerto</td><td>$Port</td></tr>
      <tr><td>Host</td><td>$env:COMPUTERNAME</td></tr>
    </table>
    <p class="footer">Practica 6 &mdash; Aprovisionamiento Web Automatizado</p>
  </div>
</body>
</html>
"@
    Set-Content -Path "$Webroot\index.html" -Value $html -Encoding UTF8
    Write-OK "index.html creado en: $Webroot"
}

# ==============================================================
#  IIS
# ==============================================================
function Get-IISVersion {
    try { return (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp").VersionString }
    catch { return "10.0" }
}

function Install-IIS {
    param([int]$Port)
    Write-Info "Instalando IIS..."
    $features = @("Web-Server","Web-Common-Http","Web-Static-Content","Web-Default-Doc",
                  "Web-Http-Errors","Web-Security","Web-Filtering","Web-Http-Logging",
                  "Web-Mgmt-Tools","Web-Mgmt-Console")
    foreach ($f in $features) { Install-WindowsFeature -Name $f -ErrorAction SilentlyContinue | Out-Null }
    Write-OK "IIS instalado."
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    Set-IISPort    -Port $Port
    Set-IISSecurity
    Apply-FirewallRule -NewPort $Port -OldPort (Get-ServicePort "IIS")
    $webroot = "C:\inetpub\wwwroot"
    Ensure-ServiceUser -Username "svc_iis" -Webroot $webroot
    New-IndexPage -Service "IIS" -Version (Get-IISVersion) -Port $Port -Webroot $webroot
    Set-ServicePort -ServiceName "IIS" -Port $Port
    Restart-Service W3SVC -Force -ErrorAction SilentlyContinue
    Write-OK "IIS activo en puerto $Port."
}

function Set-IISPort {
    param([int]$Port)
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    try {
        $b = Get-WebBinding -Name "Default Web Site" -Protocol http -ErrorAction SilentlyContinue
        if ($b) {
            Set-WebBinding -Name "Default Web Site" `
                -BindingInformation $b.bindingInformation `
                -PropertyName BindingInformation -Value "*:${Port}:" | Out-Null
        } else {
            New-WebBinding -Name "Default Web Site" -Protocol http -Port $Port -IPAddress "*" | Out-Null
        }
        iisreset /noforce 2>&1 | Out-Null
        Write-OK "IIS escuchando en puerto $Port."
    } catch { Write-Err "Error cambiando puerto IIS: $_" }
}

function Set-IISSecurity {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    Write-Info "Aplicando seguridad IIS (ocultando version)..."
    try {
        Remove-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" `
            -Filter "system.webServer/httpProtocol/customHeaders" `
            -Name "." -AtElement @{name="X-Powered-By"} -ErrorAction SilentlyContinue
        Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" `
            -Filter "system.webServer/security/requestFiltering" `
            -Name "removeServerHeader" -Value $true -ErrorAction SilentlyContinue
        foreach ($h in @(
            @{name="X-Frame-Options";        value="SAMEORIGIN"},
            @{name="X-Content-Type-Options"; value="nosniff"},
            @{name="X-XSS-Protection";       value="1; mode=block"}
        )) {
            Add-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" `
                -Filter "system.webServer/httpProtocol/customHeaders" `
                -Name "." -Value $h -ErrorAction SilentlyContinue
        }
        foreach ($v in @("TRACE","TRACK","DELETE")) {
            Add-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" `
                -Filter "system.webServer/security/requestFiltering/verbs" `
                -Name "." -Value @{verb=$v; allowed="false"} -ErrorAction SilentlyContinue
        }
        Write-OK "IIS: version oculta, headers seguros, metodos bloqueados."
    } catch { Write-Warn "Algunos ajustes requieren modulos adicionales: $_" }
}

# ==============================================================
#  APACHE  (todos los fixes aplicados aqui)
# ==============================================================
function Install-ApacheWindows {
    param([string]$Version, [int]$Port)
    Write-Info "Instalando Apache $Version para Windows..."

    $chocoExe = Get-ChocoExe
    if (-not $chocoExe) {
        if (-not (Ensure-Chocolatey)) {
            Write-Err "No se puede instalar Apache sin Chocolatey."
            return
        }
        $chocoExe = Get-ChocoExe
    }

    # Detectar si ya esta instalado
    $apacheRoot = Find-ApacheRoot

    if (-not $apacheRoot) {
        Write-Info "Instalando Apache via Chocolatey (version $Version)..."
        $result = & $chocoExe install apache-httpd --version=$Version -y --force 2>&1
        $result | ForEach-Object { Write-Host "  choco: $_" -ForegroundColor DarkGray }

        $apacheRoot = Find-ApacheRoot
        if (-not $apacheRoot) {
            Write-Err "No se pudo instalar Apache $Version."
            Write-Info "Versiones disponibles en Chocolatey van hasta 2.4.55."
            return
        }
    } else {
        Write-OK "Apache ya instalado en: $apacheRoot"
    }

    $httpdExe = "$apacheRoot\bin\httpd.exe"
    $conf     = "$apacheRoot\conf\httpd.conf"

    if (-not (Test-Path $conf)) {
        Write-Err "httpd.conf no encontrado en: $apacheRoot\conf\"
        return
    }

    Write-OK "Apache root   : $apacheRoot"
    Write-OK "httpd.conf    : $conf"
    Write-OK "httpd.exe     : $httpdExe"

    # FIX 1: Corregir SRVROOT con la ruta real encontrada (barras normales)
    $srvRoot = $apacheRoot -replace '\\', '/'
    (Get-Content $conf) -replace 'Define SRVROOT.*', "Define SRVROOT `"$srvRoot`"" |
        Set-Content $conf -Encoding UTF8
    Write-OK "SRVROOT -> $srvRoot"

    # FIX 2: Aplicar puerto y seguridad (seguridad activa mod_headers antes de los headers)
    Set-ApacheSecurity -ConfigFile $conf
    Set-ApachePort     -ConfigFile $conf -Port $Port

    # FIX 3: Validar sintaxis antes de intentar arrancar
    Write-Info "Validando sintaxis de httpd.conf..."
    $testOut = & $httpdExe -t 2>&1
    $testStr = $testOut -join "`n"
    if ($testStr -match "Syntax OK") {
        Write-OK "httpd.conf: sintaxis correcta."
    } else {
        Write-Err "Error de sintaxis en httpd.conf:"
        $testOut | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        Write-Warn "Revisa el archivo antes de continuar."
        return
    }

    $webroot = "$apacheRoot\htdocs"
    if (-not (Test-Path $webroot)) { New-Item -ItemType Directory -Path $webroot -Force | Out-Null }
    Ensure-ServiceUser -Username "svc_apache" -Webroot $webroot
    New-IndexPage -Service "Apache" -Version $Version -Port $Port -Webroot $webroot
    Apply-FirewallRule -NewPort $Port -OldPort (Get-ServicePort "Apache")

    # Registrar / reiniciar servicio
    $svc = Get-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Info "Registrando servicio Apache2.4..."
        & $httpdExe -k install 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    } else {
        Write-Info "Servicio Apache2.4 ya registrado, reiniciando..."
        Stop-Service Apache2.4 -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    Start-Service Apache2.4 -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    $svc = Get-Service -Name "Apache2.4" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Write-OK "Servicio Apache2.4 corriendo."
        Set-ServicePort -ServiceName "Apache" -Port $Port
        Write-OK "Apache $Version activo en puerto $Port."
    } else {
        Write-Err "Apache no inicio. Ejecuta manualmente para ver el error:"
        Write-Host "  & `"$httpdExe`" -k start" -ForegroundColor Yellow
        Write-Host "  & `"$httpdExe`" -t" -ForegroundColor Yellow
        # FIX: NO guardar en registry si el servicio no levanto
    }
}

function Set-ApachePort {
    param([string]$ConfigFile, [int]$Port)
    # FIX: reemplazar todas las directivas Listen (puede haber varias)
    $lines = Get-Content $ConfigFile
    $lines = $lines | ForEach-Object {
        if ($_ -match '^\s*Listen\s+\d+\s*$') { "Listen $Port" } else { $_ }
    }
    $lines | Set-Content $ConfigFile -Encoding UTF8
    Write-OK "Apache: puerto -> $Port"
}

function Set-ApacheSecurity {
    param([string]$ConfigFile)
    Write-Info "Aplicando seguridad Apache (ocultando version)..."
    $apacheDir = Split-Path (Split-Path $ConfigFile -Parent) -Parent

    # Deshabilitar SSL en archivos extra para evitar conflicto con puerto 443
    $sslFiles = @(
        "$apacheDir\conf\extra\httpd-ssl.conf",
        "$apacheDir\conf\extra\httpd-ahssl.conf"
    )
    foreach ($sslFile in $sslFiles) {
        if (Test-Path $sslFile) {
            (Get-Content $sslFile) -replace '^(Listen 443.*)', '#$1' |
                Set-Content $sslFile -Encoding UTF8
            Write-Info "SSL desactivado en: $(Split-Path $sslFile -Leaf)"
        }
    }

    $lines = Get-Content $ConfigFile

    # FIX: comentar include SSL
    $lines = $lines | ForEach-Object {
        if ($_ -match '^\s*Include\s+conf/extra/httpd-ssl\.conf') { "#$_" } else { $_ }
    }

    # FIX: activar mod_headers (necesario para directivas Header)
    $lines = $lines | ForEach-Object {
        $_ -replace '^#(LoadModule headers_module\s)', '$1'
    }

    # FIX: activar mod_rewrite (util y frecuentemente necesario)
    $lines = $lines | ForEach-Object {
        $_ -replace '^#(LoadModule rewrite_module\s)', '$1'
    }

    $lines | Set-Content $ConfigFile -Encoding UTF8

    # Agregar directivas de seguridad si no existen
    $c = Get-Content $ConfigFile -Raw
    if ($c -notmatch 'ServerTokens\s+Prod') {
        Add-Content $ConfigFile "`n# Seguridad Practica6`nServerTokens Prod`nServerSignature Off`nTraceEnable Off`n" -Encoding UTF8
    }
    if ($c -notmatch 'X-Frame-Options') {
        Add-Content $ConfigFile @"

Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
Header always set X-XSS-Protection "1; mode=block"
"@ -Encoding UTF8
    }

    Write-OK "Apache: mod_headers activado, version oculta, headers seguros, SSL desactivado."
}

# ==============================================================
#  NGINX  (todos los fixes aplicados aqui)
# ==============================================================
function Install-NginxWindows {
    param([string]$Version, [int]$Port)
    Write-Info "Instalando Nginx $Version para Windows..."

    $chocoExe = Get-ChocoExe
    if (-not $chocoExe) {
        if (-not (Ensure-Chocolatey)) {
            Write-Err "No se puede instalar Nginx sin Chocolatey."
            return
        }
        $chocoExe = Get-ChocoExe
    }

    $nginxExe = Find-NginxExe
    if (-not $nginxExe) {
        Write-Info "Instalando Nginx via Chocolatey (version $Version, puerto $Port)..."
        # FIX: pasar /port al script de choco para que NO intente ocupar el 80
        & $chocoExe install nginx --version=$Version -y --force --params "'/port:$Port'" 2>&1 |
            ForEach-Object { Write-Host "  choco: $_" -ForegroundColor DarkGray }
        $nginxExe = Find-NginxExe
        if (-not $nginxExe) {
            # Chocolatey deja los archivos aunque falle el script de instalacion.
            # Buscar nginx.exe directamente en la ruta del paquete.
            $pkgExe = "C:\ProgramData\chocolatey\lib\nginx\tools\nginx\nginx.exe"
            if (Test-Path $pkgExe) {
                Write-Warn "choco reporto error pero nginx.exe encontrado. Continuando..."
                $nginxExe = $pkgExe
            } else {
                Write-Err "No se pudo instalar Nginx."
                return
            }
        }
    } else {
        Write-OK "Nginx ya instalado en: $(Split-Path $nginxExe -Parent)"
    }

    $nginxRoot = Split-Path $nginxExe -Parent
    $conf      = "$nginxRoot\conf\nginx.conf"
    if (-not (Test-Path $conf)) {
        # Fallback a Find-NginxConf si la ruta directa no existe
        $conf = Find-NginxConf
    }
    if (-not $conf) {
        Write-Err "nginx.conf no encontrado despues de la instalacion."
        return
    }

    Write-OK "Nginx root  : $nginxRoot"
    Write-OK "nginx.conf  : $conf"

    # FIX 1: Limpiar BOM antes de cualquier modificacion
    Fix-FileBOM -ConfigFile $conf

    # FIX 2: Aplicar puerto y seguridad con escritura sin BOM
    # El puerto ya fue pasado a choco pero lo sobreescribimos para garantizar consistencia
    Set-NginxPort     -ConfigFile $conf -Port $Port
    Set-NginxSecurity -ConfigFile $conf

    # FIX 3: Validar sintaxis antes de arrancar
    Write-Info "Validando sintaxis de nginx.conf..."
    $testFile = "$env:TEMP\nginx_test_$Port.txt"
    $proc = Start-Process -FilePath $nginxExe -ArgumentList "-t" `
        -WorkingDirectory $nginxRoot -Wait -PassThru `
        -WindowStyle Hidden -RedirectStandardError $testFile
    $testResult = Get-Content $testFile -ErrorAction SilentlyContinue
    if ($testResult -match "successful") {
        Write-OK "nginx.conf: sintaxis correcta."
    } else {
        Write-Err "Error en nginx.conf:"
        $testResult | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        return
    }

    $webroot = "$nginxRoot\html"
    if (-not (Test-Path $webroot)) { New-Item -ItemType Directory -Path $webroot -Force | Out-Null }
    Ensure-ServiceUser -Username "svc_nginx" -Webroot $webroot
    New-IndexPage -Service "Nginx" -Version $Version -Port $Port -Webroot $webroot
    Apply-FirewallRule -NewPort $Port -OldPort (Get-ServicePort "Nginx")

    # Detener instancia anterior e iniciar nueva
    Stop-Process -Name "nginx" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Process -FilePath $nginxExe -WorkingDirectory $nginxRoot -WindowStyle Hidden
    Start-Sleep -Seconds 3

    $procs = Get-Process -Name "nginx" -ErrorAction SilentlyContinue
    if ($procs) {
        Write-OK "Nginx corriendo (PID: $($procs[0].Id))"
        Set-ServicePort -ServiceName "Nginx" -Port $Port
        Write-OK "Nginx $Version activo en puerto $Port."
    } else {
        Write-Err "Nginx no inicio. Revisa el log:"
        Write-Host "  $nginxRoot\logs\error.log" -ForegroundColor Yellow
        # FIX: NO guardar en registry si nginx no levanto
    }
}

function Set-NginxPort {
    param([string]$ConfigFile, [int]$Port)
    # FIX: usar System.IO para escritura sin BOM en todas las operaciones
    Fix-FileBOM -ConfigFile $ConfigFile
    $lines = [System.IO.File]::ReadAllLines($ConfigFile, [System.Text.Encoding]::UTF8)
    $lines = $lines | ForEach-Object { $_ -replace 'listen\s+\d+\s*;', "listen $Port;" }
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($ConfigFile, $lines, $enc)
    Write-OK "Nginx: puerto -> $Port"
}

function Set-NginxSecurity {
    param([string]$ConfigFile)
    Write-Info "Aplicando seguridad Nginx (ocultando version)..."

    # FIX: leer con System.IO para evitar introducir BOM
    $lines = [System.IO.File]::ReadAllLines($ConfigFile, [System.Text.Encoding]::UTF8)
    $c = $lines -join "`n"

    # Limpiar limit_except previo mal colocado
    $c = $c -replace '\s*limit_except GET POST HEAD \{ deny all; \}', ''

    # Agregar server_tokens y headers dentro del bloque http si no existen
    if ($c -notmatch 'server_tokens') {
        $sec  = "`n    server_tokens off;"
        $sec += "`n    add_header X-Frame-Options SAMEORIGIN;"
        $sec += "`n    add_header X-Content-Type-Options nosniff;"
        $sec += "`n    add_header X-XSS-Protection `"1; mode=block`";"
        $c = $c -replace '(http\s*\{)', "`$1$sec"
    }

    # FIX: escribir siempre con UTF8 sin BOM via System.IO
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($ConfigFile, ($c -split "`r?`n"), $enc)
    Write-OK "Nginx: version oculta, headers seguros."
}

# ==============================================================
#  MENU 1 - VERIFICACION
# ==============================================================
function Menu-Verificacion {
    while ($true) {
        Write-Header "Verificacion de Servicios HTTP"
        Write-Host "  1) Panel general de servicios"          -ForegroundColor White
        Write-Host "  2) Verificar disponibilidad de puerto"  -ForegroundColor White
        Write-Host "  3) Verificar usuario dedicado"          -ForegroundColor White
        Write-Host "  4) Volver al menu principal`n"          -ForegroundColor White
        switch (Get-ValidOption -Min 1 -Max 4) {
            1 { Show-ServicePanel }
            2 { Check-PortMenu    }
            3 { Check-ServiceUser }
            4 { return }
        }
    }
}

function Show-ServicePanel {
    Write-SubHeader "Panel General de Servicios HTTP"
    if ($script:PortRegistry.Count -eq 0) {
        Write-Host "  Puertos registrados: (Ninguno instalado aun)`n" -ForegroundColor DarkGray
    } else {
        Write-Host "  Puertos registrados en esta practica:" -ForegroundColor DarkGray
        foreach ($e in $script:PortRegistry.GetEnumerator()) {
            Write-Host ("    {0,-10} -> Puerto {1}" -f $e.Key, $e.Value) -ForegroundColor DarkGray
        }
        Write-Host ""
    }
    foreach ($s in @(
        @{Name="W3SVC";     Label="IIS    "},
        @{Name="Apache2.4"; Label="Apache "},
        @{Name="nginx";     Label="Nginx  "}
    )) {
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        if ($svc) {
            $color = if ($svc.Status -eq "Running") {"Green"} else {"Red"}
            Write-Host "  $($s.Label) [$($svc.Status)]" -ForegroundColor $color
        } else {
            # FIX: para Nginx que corre como proceso (no servicio), verificar proceso
            if ($s.Name -eq "nginx") {
                $proc = Get-Process -Name "nginx" -ErrorAction SilentlyContinue
                if ($proc) {
                    Write-Host "  $($s.Label) [Running (proceso)]" -ForegroundColor Green
                } else {
                    Write-Host "  $($s.Label) [No instalado / detenido]" -ForegroundColor DarkGray
                }
            } else {
                Write-Host "  $($s.Label) [No instalado]" -ForegroundColor DarkGray
            }
        }
    }
    Write-Host ""
    Read-Host "Presione Enter para continuar"
}

function Check-PortMenu {
    Write-Host "[INPUT] Puerto a verificar: " -ForegroundColor Magenta -NoNewline
    $raw = (Read-Host).Trim()
    if ($raw -notmatch '^\d+$') { Write-Err "Puerto invalido."; return }
    $port = [int]$raw
    if (Test-PortFree $port) { Write-OK "Puerto $port esta LIBRE." }
    else {
        Write-Warn "Puerto $port esta EN USO."
        $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn) {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            Write-Info "Proceso: $($proc.Name) (PID $($conn.OwningProcess))"
        }
    }
    $owner = $script:PortRegistry.GetEnumerator() | Where-Object { $_.Value -eq $port } | Select-Object -First 1
    if ($owner) { Write-Info "Asignado a '$($owner.Key)' en esta practica." }
    Read-Host "Presione Enter para continuar"
}

function Check-ServiceUser {
    Write-Host "[INPUT] Usuario a verificar (ej. svc_iis): " -ForegroundColor Magenta -NoNewline
    $user = (Read-Host).Trim()
    if ([string]::IsNullOrWhiteSpace($user) -or $user -match '[<>|&;/\\]') {
        Write-Err "Nombre invalido."; return
    }
    $u = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
    if ($u) { Write-OK "Usuario '$user' existe. Habilitado: $($u.Enabled)" }
    else     { Write-Warn "Usuario '$user' NO existe." }
    Read-Host "Presione Enter para continuar"
}

# ==============================================================
#  MENU 2 - INSTALAR
# ==============================================================
function Menu-Instalar {
    Write-Header "[HTTP] Selector de Servicio - Paso 1 de 4"
    Write-Host "[INFO] Servicios HTTP disponibles en Windows:`n" -ForegroundColor Blue
    $pI = Get-ServicePort "IIS";    $tI = if ($pI) {"Puerto actual: $pI"}    else {"Puerto default: 80"}
    $pA = Get-ServicePort "Apache"; $tA = if ($pA) {"Puerto actual: $pA"}    else {"Puerto default: 80"}
    $pN = Get-ServicePort "Nginx";  $tN = if ($pN) {"Puerto actual: $pN"}    else {"Puerto default: 80"}
    Write-Host "  1) IIS (Internet Information Services)" -ForegroundColor White
    Write-Host "     Nativo de Windows. No requiere internet." -ForegroundColor DarkGray
    Write-Host "     Usuario: svc_iis  |  $tI`n" -ForegroundColor DarkGray
    Write-Host "  2) Apache (Win64)" -ForegroundColor White
    Write-Host "     Requiere Chocolatey + internet." -ForegroundColor DarkGray
    Write-Host "     Paquete: apache-httpd  |  Usuario: svc_apache  |  $tA`n" -ForegroundColor DarkGray
    Write-Host "  3) Nginx para Windows" -ForegroundColor White
    Write-Host "     Requiere Chocolatey + internet." -ForegroundColor DarkGray
    Write-Host "     Paquete: nginx  |  Usuario: svc_nginx  |  $tN`n" -ForegroundColor DarkGray
    Write-Host "[INPUT] Seleccione el servicio [1-3]: " -ForegroundColor Magenta -NoNewline
    $svc     = Get-ValidOption -Min 1 -Max 3
    $svcName = @("","IIS","Apache","Nginx")[$svc]

    # FIX: para Apache/Nginx verificar Chocolatey ANTES de pedir puerto
    if ($svc -in @(2,3)) {
        $chocoExe = Get-ChocoExe
        if (-not $chocoExe) {
            Write-Info "Chocolatey no encontrado. Instalando primero..."
            if (-not (Ensure-Chocolatey)) {
                Write-Err "No se puede continuar sin Chocolatey."
                Read-Host "`nPresione Enter para continuar"
                return
            }
        }
    }

    # Detener el servicio ANTES de validar el puerto para que no bloquee la seleccion
    Stop-ServiceByName -ServiceName $svcName -Silent

    $port = Get-ValidPort -ServiceName $svcName
    switch ($svc) {
        1 { Install-IIS -Port $port }
        2 { $v = Select-Version -ServiceName "Apache" -Package "apache-httpd"; Install-ApacheWindows -Version $v -Port $port }
        3 { $v = Select-Version -ServiceName "Nginx"  -Package "nginx";        Install-NginxWindows  -Version $v -Port $port }
    }
    Read-Host "`nPresione Enter para continuar"
}

# ==============================================================
#  MENU 3 - CONFIGURAR
# ==============================================================
function Menu-Configurar {
    while ($true) {
        Write-Header "Configurar Servicio HTTP"
        Write-Host "  1) Cambiar puerto de escucha"                -ForegroundColor White
        Write-Host "  2) Configurar security headers"              -ForegroundColor White
        Write-Host "  3) Control de metodos HTTP"                  -ForegroundColor White
        Write-Host "  4) Gestion de versiones (upgrade/downgrade)" -ForegroundColor White
        Write-Host "  5) Volver al menu principal`n"               -ForegroundColor White
        switch (Get-ValidOption -Min 1 -Max 5) {
            1 { Config-CambiarPuerto    }
            2 { Config-SecurityHeaders  }
            3 { Config-MetodosHTTP      }
            4 { Config-GestionVersiones }
            5 { return }
        }
    }
}

function Config-CambiarPuerto {
    Write-SubHeader "Cambiar Puerto de Escucha"
    Write-Host "  1) IIS`n  2) Apache`n  3) Nginx`n" -ForegroundColor White
    $svc     = Get-ValidOption -Min 1 -Max 3
    $svcName = @("","IIS","Apache","Nginx")[$svc]
    $oldPort = Get-ServicePort $svcName
    # Detener antes de validar para que el propio puerto quede libre
    Stop-ServiceByName -ServiceName $svcName -Silent
    $port    = Get-ValidPort -ServiceName $svcName
    switch ($svc) {
        1 {
            Set-IISPort -Port $port
            Apply-FirewallRule -NewPort $port -OldPort $oldPort
        }
        2 {
            $conf = Find-ApacheConf
            if ($conf) {
                Set-ApachePort -ConfigFile $conf -Port $port
                $exe = Find-ApacheExe
                if ($exe) { & $exe -k restart 2>&1 | Out-Null }
                Apply-FirewallRule -NewPort $port -OldPort $oldPort
            } else { Write-Err "httpd.conf no encontrado." }
        }
        3 {
            $conf = Find-NginxConf
            if ($conf) {
                Set-NginxPort -ConfigFile $conf -Port $port
                $exe = Find-NginxExe
                if ($exe) {
                    # FIX: Nginx en Windows no tiene servicio, usar -s reload como proceso
                    $root = Split-Path $exe -Parent
                    Start-Process -FilePath $exe -ArgumentList "-s reload" -WorkingDirectory $root -WindowStyle Hidden -Wait
                }
                Apply-FirewallRule -NewPort $port -OldPort $oldPort
            } else { Write-Err "nginx.conf no encontrado." }
        }
    }
    Set-ServicePort -ServiceName $svcName -Port $port
    Write-OK "$svcName ahora escucha en puerto $port."
    Read-Host "Presione Enter para continuar"
}

function Config-SecurityHeaders {
    Write-SubHeader "Configurar Security Headers"
    Write-Host "  1) IIS`n  2) Apache`n  3) Nginx`n" -ForegroundColor White
    switch (Get-ValidOption -Min 1 -Max 3) {
        1 { Set-IISSecurity }
        2 {
            $c = Find-ApacheConf
            if ($c) { Set-ApacheSecurity -ConfigFile $c }
            else     { Write-Err "httpd.conf no encontrado." }
        }
        3 {
            $c = Find-NginxConf
            if ($c) { Set-NginxSecurity -ConfigFile $c }
            else     { Write-Err "nginx.conf no encontrado." }
        }
    }
    Read-Host "Presione Enter para continuar"
}

function Config-MetodosHTTP {
    Write-SubHeader "Bloquear Metodos Peligrosos (TRACE, TRACK, DELETE)"
    Write-Host "  1) IIS`n  2) Apache`n  3) Nginx`n" -ForegroundColor White
    switch (Get-ValidOption -Min 1 -Max 3) {
        1 {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            foreach ($v in @("TRACE","TRACK","DELETE")) {
                Add-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" `
                    -Filter "system.webServer/security/requestFiltering/verbs" `
                    -Name "." -Value @{verb=$v; allowed="false"} -ErrorAction SilentlyContinue
            }
            Write-OK "TRACE, TRACK, DELETE bloqueados en IIS."
        }
        2 {
            $c = Find-ApacheConf
            if ($c) {
                if ((Get-Content $c -Raw) -notmatch 'TraceEnable') {
                    Add-Content $c "`nTraceEnable Off" -Encoding UTF8
                    Write-OK "TRACE desactivado en Apache."
                } else { Write-Info "Ya estaba configurado." }
            } else { Write-Err "httpd.conf no encontrado." }
        }
        3 {
            $c = Find-NginxConf
            if ($c) {
                Fix-FileBOM -ConfigFile $c
                $lines = [System.IO.File]::ReadAllLines($c, [System.Text.Encoding]::UTF8)
                $txt   = $lines -join "`n"
                if ($txt -notmatch 'limit_except') {
                    $txt = $txt -replace '(location\s*/\s*\{)', "`$1`n        limit_except GET POST HEAD { deny all; }"
                    $enc = New-Object System.Text.UTF8Encoding $false
                    [System.IO.File]::WriteAllLines($c, ($txt -split "`r?`n"), $enc)
                    Write-OK "Metodos bloqueados en Nginx."
                } else { Write-Info "Ya estaba configurado." }
            } else { Write-Err "nginx.conf no encontrado." }
        }
    }
    Read-Host "Presione Enter para continuar"
}

function Config-GestionVersiones {
    Write-SubHeader "Gestion de Versiones (Upgrade / Downgrade)"
    Write-Host "  1) Apache`n  2) Nginx`n" -ForegroundColor White
    $svc      = Get-ValidOption -Min 1 -Max 2
    $chocoExe = Get-ChocoExe
    if (-not $chocoExe) { Write-Err "Chocolatey no disponible."; return }
    if ($svc -eq 1) {
        $v    = Select-Version -ServiceName "Apache" -Package "apache-httpd"
        $port = Get-ServicePort "Apache"
        if ($port -eq 0) { $port = Get-ValidPort -ServiceName "Apache" }
        & $chocoExe install apache-httpd --version=$v -y --force 2>&1 | Out-Null
        $c = Find-ApacheConf
        if ($c) {
            $root = Find-ApacheRoot
            $srvRoot = $root -replace '\\', '/'
            (Get-Content $c) -replace 'Define SRVROOT.*', "Define SRVROOT `"$srvRoot`"" |
                Set-Content $c -Encoding UTF8
            Set-ApacheSecurity -ConfigFile $c
            Set-ApachePort     -ConfigFile $c -Port $port
        }
        Write-OK "Apache -> $v en puerto $port."
    } else {
        $v    = Select-Version -ServiceName "Nginx" -Package "nginx"
        $port = Get-ServicePort "Nginx"
        if ($port -eq 0) { $port = Get-ValidPort -ServiceName "Nginx" }
        & $chocoExe install nginx --version=$v -y --force 2>&1 | Out-Null
        $c = Find-NginxConf
        if ($c) {
            Set-NginxPort     -ConfigFile $c -Port $port
            Set-NginxSecurity -ConfigFile $c
        }
        Write-OK "Nginx -> $v en puerto $port."
    }
    Read-Host "Presione Enter para continuar"
}

# ==============================================================
#  MENU 4 - MONITOREO
# ==============================================================
function Menu-Monitoreo {
    while ($true) {
        Write-Header "Monitoreo de Servicios HTTP"
        Write-Host "  1) Estado del servicio    (PID, memoria, uptime)"      -ForegroundColor White
        Write-Host "  2) Monitoreo de puertos   (escucha + firewall)"         -ForegroundColor White
        Write-Host "  3) Logs del servicio      (Event Log + errores)"        -ForegroundColor White
        Write-Host "  4) Headers HTTP en vivo   (curl -I + auditoria)"        -ForegroundColor White
        Write-Host "  5) Configuracion activa   (webroot + usuario + puerto)" -ForegroundColor White
        Write-Host "  6) Volver al menu principal`n"                          -ForegroundColor White
        switch (Get-ValidOption -Min 1 -Max 6) {
            1 { Monitor-EstadoServicio }
            2 { Monitor-Puertos        }
            3 { Monitor-Logs           }
            4 { Monitor-HeadersHTTP    }
            5 { Monitor-ConfigActiva   }
            6 { return }
        }
    }
}

function Monitor-EstadoServicio {
    Write-SubHeader "Estado de Servicios HTTP"
    foreach ($name in @("W3SVC","Apache2.4","nginx")) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            $wmi  = Get-WmiObject Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
            $proc = Get-Process -Id $wmi.ProcessId -ErrorAction SilentlyContinue
            if ($proc) {
                $mem    = [math]::Round($proc.WorkingSet64 / 1MB, 2)
                $uptime = (Get-Date) - $proc.StartTime
                Write-Host "`n  $name" -ForegroundColor Cyan
                Write-Host ("    PID    : {0}"             -f $proc.Id)                                     -ForegroundColor White
                Write-Host ("    Memoria: {0} MB"          -f $mem)                                         -ForegroundColor White
                Write-Host ("    Uptime : {0}d {1}h {2}m" -f $uptime.Days,$uptime.Hours,$uptime.Minutes)   -ForegroundColor White
            }
        } elseif ($name -eq "nginx") {
            # FIX: Nginx en Windows corre como proceso, no como servicio
            $procs = Get-Process -Name "nginx" -ErrorAction SilentlyContinue
            if ($procs) {
                $p      = $procs[0]
                $mem    = [math]::Round($p.WorkingSet64 / 1MB, 2)
                $uptime = (Get-Date) - $p.StartTime
                Write-Host "`n  nginx (proceso)" -ForegroundColor Cyan
                Write-Host ("    PID    : {0}"             -f $p.Id)                                        -ForegroundColor White
                Write-Host ("    Workers: {0}"             -f $procs.Count)                                 -ForegroundColor White
                Write-Host ("    Memoria: {0} MB"          -f $mem)                                         -ForegroundColor White
                Write-Host ("    Uptime : {0}d {1}h {2}m" -f $uptime.Days,$uptime.Hours,$uptime.Minutes)   -ForegroundColor White
            } else {
                Write-Host "  nginx : [No corriendo]" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  $name : [$(if ($svc) {$svc.Status} else {'No instalado'})]" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    Read-Host "Presione Enter para continuar"
}

function Monitor-Puertos {
    Write-SubHeader "Puertos en Escucha + Reglas Firewall"
    Write-Info "Puertos HTTP activos:"
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object {
            $p = $_.LocalPort
            $p -in @(80,443,8080,8081,8082,8888,9090,9091,9092) -or
            (Get-NetFirewallRule -DisplayName "HTTP-Practica6-Puerto$p" -ErrorAction SilentlyContinue)
        } | Sort-Object LocalPort -Unique |
        ForEach-Object {
            $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
            Write-Host ("  Puerto {0,-6} Proceso: {1}" -f $_.LocalPort, $proc.Name) -ForegroundColor White
        }
    Write-Host ""
    Write-Info "Reglas de firewall de esta practica:"
    $rules = Get-NetFirewallRule -DisplayName "HTTP-Practica6-*" -ErrorAction SilentlyContinue
    if ($rules) { $rules | ForEach-Object { Write-Host "  $($_.DisplayName) [Habilitado: $($_.Enabled)]" -ForegroundColor White } }
    else         { Write-Host "  (Ninguna regla aun)" -ForegroundColor DarkGray }
    Write-Host ""
    Read-Host "Presione Enter para continuar"
}

function Monitor-Logs {
    Write-SubHeader "Logs de Servicios HTTP (Ultimos 10 eventos)"
    $found = $false
    foreach ($src in @("W3SVC","IIS-W3SVC-WP","IIS")) {
        $events = Get-EventLog -LogName System -Source "*$src*" -EntryType Error,Warning -Newest 10 -ErrorAction SilentlyContinue
        if ($events) {
            $found = $true
            Write-Host "`n  Fuente: $src" -ForegroundColor Cyan
            $events | ForEach-Object {
                Write-Host ("  [{0}] {1}" -f $_.TimeGenerated.ToString("MM/dd HH:mm"), $_.Message.Substring(0,[Math]::Min(90,$_.Message.Length))) -ForegroundColor DarkYellow
            }
        }
    }
    # FIX: mostrar log de error de Nginx si existe
    $nginxRoot = Find-NginxRoot
    if ($nginxRoot) {
        $errorLog = "$nginxRoot\logs\error.log"
        if (Test-Path $errorLog) {
            $found = $true
            Write-Host "`n  Nginx error.log (ultimas 10 lineas):" -ForegroundColor Cyan
            Get-Content $errorLog -Tail 10 | ForEach-Object {
                Write-Host "  $_" -ForegroundColor DarkYellow
            }
        }
    }
    # FIX: mostrar log de error de Apache si existe
    $apacheRoot = Find-ApacheRoot
    if ($apacheRoot) {
        $errorLog = "$apacheRoot\logs\error.log"
        if (Test-Path $errorLog) {
            $found = $true
            Write-Host "`n  Apache error.log (ultimas 10 lineas):" -ForegroundColor Cyan
            Get-Content $errorLog -Tail 10 | ForEach-Object {
                Write-Host "  $_" -ForegroundColor DarkYellow
            }
        }
    }
    if (-not $found) { Write-Info "No se encontraron eventos de error recientes." }
    Write-Host ""
    Read-Host "Presione Enter para continuar"
}

function Monitor-HeadersHTTP {
    Write-SubHeader "Headers HTTP en Vivo + Auditoria de Seguridad"
    Write-Host "[INPUT] Puerto a auditar: " -ForegroundColor Magenta -NoNewline
    $raw = (Read-Host).Trim()
    if ($raw -notmatch '^\d+$') { Write-Err "Puerto invalido."; return }
    $port = [int]$raw
    Write-Info "Ejecutando: curl -I http://localhost:$port"
    try {
        $headers = curl.exe -I --max-time 5 "http://localhost:$port" 2>&1
        Write-Host "`n$headers`n" -ForegroundColor White
        Write-SubHeader "Resultado de Auditoria"
        if ($headers -match "Server:.*(/[\d\.]+)") { Write-Warn "FALLO : Server expone version -> $($matches[0])" }
        else                                        { Write-OK   "PASS  : Server no expone version." }
        foreach ($h in @("X-Frame-Options","X-Content-Type-Options","X-XSS-Protection")) {
            if ($headers -match $h) { Write-OK   "PASS  : $h presente." }
            else                    { Write-Warn "FALLO : $h AUSENTE."  }
        }
        if ($headers -match "X-Powered-By") { Write-Warn "FALLO : X-Powered-By expuesto." }
        else                                 { Write-OK   "PASS  : X-Powered-By no expuesto." }
    } catch { Write-Err "No se pudo conectar al puerto $port." }
    Write-Host ""
    Read-Host "Presione Enter para continuar"
}

function Monitor-ConfigActiva {
    Write-SubHeader "Configuracion Activa por Servicio"

    # IIS - ruta fija
    $iisPort    = Get-ServicePort "IIS"
    $iisWebroot = "C:\inetpub\wwwroot"
    Write-Host "`n  IIS" -ForegroundColor Cyan
    Write-Host ("    Puerto  : {0}" -f (if ($iisPort) {$iisPort} else {"No configurado"})) -ForegroundColor White
    Write-Host ("    Webroot : {0} [{1}]" -f $iisWebroot, (if (Test-Path $iisWebroot) {"Existe"} else {"No existe"})) -ForegroundColor White
    Write-Host ("    Usuario : svc_iis [{0}]" -f (if (Get-LocalUser "svc_iis" -ErrorAction SilentlyContinue) {"Existe"} else {"No existe"})) -ForegroundColor White

    # FIX: Apache y Nginx usan rutas dinamicas
    $apacheRoot = Find-ApacheRoot
    $apachePort = Get-ServicePort "Apache"
    $apacheWebroot = if ($apacheRoot) { "$apacheRoot\htdocs" } else { "No encontrado" }
    Write-Host "`n  Apache" -ForegroundColor Cyan
    Write-Host ("    Puerto  : {0}" -f (if ($apachePort) {$apachePort} else {"No configurado"})) -ForegroundColor White
    Write-Host ("    Root    : {0}" -f (if ($apacheRoot) {$apacheRoot} else {"No instalado"})) -ForegroundColor White
    Write-Host ("    Webroot : {0} [{1}]" -f $apacheWebroot, (if (Test-Path $apacheWebroot) {"Existe"} else {"No existe"})) -ForegroundColor White
    Write-Host ("    Usuario : svc_apache [{0}]" -f (if (Get-LocalUser "svc_apache" -ErrorAction SilentlyContinue) {"Existe"} else {"No existe"})) -ForegroundColor White

    $nginxRoot    = Find-NginxRoot
    $nginxPort    = Get-ServicePort "Nginx"
    $nginxWebroot = if ($nginxRoot) { "$nginxRoot\html" } else { "No encontrado" }
    Write-Host "`n  Nginx" -ForegroundColor Cyan
    Write-Host ("    Puerto  : {0}" -f (if ($nginxPort) {$nginxPort} else {"No configurado"})) -ForegroundColor White
    Write-Host ("    Root    : {0}" -f (if ($nginxRoot) {$nginxRoot} else {"No instalado"})) -ForegroundColor White
    Write-Host ("    Webroot : {0} [{1}]" -f $nginxWebroot, (if (Test-Path $nginxWebroot) {"Existe"} else {"No existe"})) -ForegroundColor White
    Write-Host ("    Usuario : svc_nginx [{0}]" -f (if (Get-LocalUser "svc_nginx" -ErrorAction SilentlyContinue) {"Existe"} else {"No existe"})) -ForegroundColor White

    Write-Host ""
    Read-Host "Presione Enter para continuar"
}