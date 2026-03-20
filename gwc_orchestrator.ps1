param(
    [string]$ConfigPath = "D:\Servers\SDS03 Geos\data\gwc_layers.json",
    [string[]]$LayerFilter,
    [string[]]$ServerFilter,
    [switch]$WhatIf,
    [switch]$Insecure,
    [switch]$KillExisting  # default ON below
)

# Default KillExisting=ON unless explicitly disabled
if (-not $PSBoundParameters.ContainsKey('KillExisting')) { $KillExisting = $true }

# Force TLS 1.2 (PowerShell 5.x may default to TLS1.0/1.1)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ------------------- Utilities -------------------

function Read-Json($path) {
    if (!(Test-Path $path -PathType Leaf)) { throw ("Config not found: {0}" -f $path) }
    try { Get-Content $path -Raw | ConvertFrom-Json } catch { throw ("Invalid JSON in {0}: {1}" -f $path, $_.Exception.Message) }
}

function Read-BBoxes([string]$path) {
    if (!(Test-Path $path -PathType Leaf)) { throw ("BBOX file not found: {0}" -f $path) }
    $lines = Get-Content $path -Raw |
      Select-String -Pattern '.*' -AllMatches |
      ForEach-Object { $_.ToString() } |
      Where-Object { $_ -and $_.Trim() -ne "" -and -not $_.Trim().StartsWith("#") }
    $boxes = @()
    foreach ($line in $lines) {
        $parts = $line.Split(",") | ForEach-Object { $_.Trim() }
        if ($parts.Count -ne 4) { throw ("Bad BBOX line in {0}: '{1}'" -f $path, $line) }
        $minX=[double]$parts[0]; $minY=[double]$parts[1]; $maxX=[double]$parts[2]; $maxY=[double]$parts[3]
        if ($minX -ge $maxX -or $minY -ge $maxY) { throw ("Invalid BBOX in {0}: '{1}'" -f $path, $line) }
        $boxes += [pscustomobject]@{minX=$minX;minY=$minY;maxX=$maxX;maxY=$maxY}
    }
    return $boxes
}

# ------------------- Projection helpers (4326 -> 3857/3395) -------------------

function Convert-WGS84ToEPSG3857 {
    param([double]$lonDeg,[double]$latDeg)
    $R = 6378137.0
    if ($latDeg -gt 85.05112878) { $latDeg = 85.05112878 }
    if ($latDeg -lt -85.05112878) { $latDeg = -85.05112878 }
    $lon = [math]::PI * $lonDeg / 180.0
    $lat = [math]::PI * $latDeg / 180.0
    $x = $R * $lon
    $y = $R * [math]::Log([math]::Tan(([math]::PI/4.0) + ($lat/2.0)))
    @{ x = $x; y = $y }
}

function Convert-WGS84ToEPSG3395 {
    param([double]$lonDeg,[double]$latDeg)
    $R = 6378137.0
    if ($latDeg -gt 89.5) { $latDeg = 89.5 }
    if ($latDeg -lt -89.5) { $latDeg = -89.5 }
    $lon = [math]::PI * $lonDeg / 180.0
    $lat = [math]::PI * $latDeg / 180.0
    $x = $R * $lon
    $y = $R * [math]::Log([math]::Tan(([math]::PI/4.0) + ($lat/2.0)))
    @{ x = $x; y = $y }
}

function Get-WmsBBoxProjected {
    param(
        [string]$CapabilitiesUrl,
        [string]$LayerName,
        [string]$TargetGridSet
    )
    $resp = Invoke-WebRequest -Uri $CapabilitiesUrl -UseBasicParsing
    $xml = [xml]$resp.Content

    $layerNode = $null
    if ($xml.WMS_Capabilities) {
        $layerNode = $xml.WMS_Capabilities.Capability.Layer.Layer | Where-Object { $_.Name -eq $LayerName }
    }
    if (-not $layerNode -and $xml.WMT_MS_Capabilities) {
        $layerNode = $xml.WMT_MS_Capabilities.Capability.Layer.Layer | Where-Object { $_.Name -eq $LayerName }
    }
    if (-not $layerNode) { throw ("Layer '{0}' not found in WMS GetCapabilities." -f $LayerName) }

    $west = $layerNode.EX_GeographicBoundingBox.westBoundLongitude
    $east = $layerNode.EX_GeographicBoundingBox.eastBoundLongitude
    $south = $layerNode.EX_GeographicBoundingBox.southBoundLatitude
    $north = $layerNode.EX_GeographicBoundingBox.northBoundLatitude

    if (-not $west) {
        $llbb = $layerNode.LatLonBoundingBox
        if ($llbb) {
            $west = [double]$llbb.minx; $south = [double]$llbb.miny
            $east = [double]$llbb.maxx; $north = [double]$llbb.maxy
        } else {
            throw ("No geographic bbox found for '{0}' in GetCapabilities." -f $LayerName)
        }
    } else {
        $west = [double]$west; $east = [double]$east; $south = [double]$south; $north = [double]$north
    }

    if ($TargetGridSet -eq "EPSG:3857") {
        $pMin = Convert-WGS84ToEPSG3857 -lonDeg $west -latDeg $south
        $pMax = Convert-WGS84ToEPSG3857 -lonDeg $east -latDeg $north
    } elseif ($TargetGridSet -eq "EPSG:3395") {
        $pMin = Convert-WGS84ToEPSG3395 -lonDeg $west -latDeg $south
        $pMax = Convert-WGS84ToEPSG3395 -lonDeg $east -latDeg $north
    } else {
        throw ("Unsupported TargetGridSet '{0}' for WMS BBOX reprojection." -f $TargetGridSet)
    }

    return @{
        minX = [double][math]::Min($pMin.x, $pMax.x)
        minY = [double][math]::Min($pMin.y, $pMax.y)
        maxX = [double][math]::Max($pMin.x, $pMax.x)
        maxY = [double][math]::Max($pMin.y, $pMax.y)
    }
}

function Get-GsRestLayerBounds {
    param(
        [string]$GeoserverBase,
        [string]$LayerName,
        [System.Management.Automation.PSCredential]$Cred
    )
    $layerUrl = "$GeoserverBase/rest/layers/$LayerName.json"
    $resp = Invoke-WebRequest -Uri $layerUrl -Credential $Cred -UseBasicParsing
    $json = $resp.Content | ConvertFrom-Json
    if (-not $json.layer.resource.href) { throw ("No resource href for layer '{0}'." -f $LayerName) }
    $resUrl = $json.layer.resource.href
    $res = Invoke-WebRequest -Uri $resUrl -Credential $Cred -UseBasicParsing
    $resJson = $res.Content | ConvertFrom-Json
    $bbox = $resJson.resource.nativeBoundingBox
    if (-not $bbox) { throw ("No nativeBoundingBox found for resource of '{0}'." -f $LayerName) }
    return @{
        minX = [double]$bbox.minx
        minY = [double]$bbox.miny
        maxX = [double]$bbox.maxx
        maxY = [double]$bbox.maxy
        crs  = $bbox.crs
    }
}

# --- Cascading default bounds resolver: GWC -> REST -> WMS -> world ---
function Get-DefaultBounds {
    param(
        [string]$SeedBaseUrl,
        [string]$LayerName,
        [System.Management.Automation.PSCredential]$Cred,
        [switch]$Insecure,
        [string]$GridSet,
        [string]$ServerCapsUrl,
        [string]$LayerCapsUrl
    )

    if ($Insecure) {
        add-type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint p, X509Certificate c, WebRequest r, int pr) { return true; }
}
"@ | Out-Null
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }

    # 1) GWC tile layer XML
    try {
        $url = "$($SeedBaseUrl)/../layers/$LayerName.xml"
        $gwc = Invoke-WebRequest -Uri $url -Credential $Cred -UseBasicParsing
        $xml = [xml]$gwc.Content
        $coords = $xml.layer.bounds.coords.double
        return @{minX=[double]$coords[0]; minY=[double]$coords[1]; maxX=[double]$coords[2]; maxY=[double]$coords[3]}
    } catch { }

    # 2) GeoServer REST
    try {
        $gsBase = $SeedBaseUrl -replace "/gwc/rest/seed$",""
        $nbb = Get-GsRestLayerBounds -GeoserverBase $gsBase -LayerName $LayerName -Cred $Cred
        if ($nbb.crs -match "EPSG:4326") {
            if ($GridSet -eq "EPSG:3857") {
                $pMin = Convert-WGS84ToEPSG3857 -lonDeg $nbb.minX -latDeg $nbb.minY
                $pMax = Convert-WGS84ToEPSG3857 -lonDeg $nbb.maxX -latDeg $nbb.maxY
            } elseif ($GridSet -eq "EPSG:3395") {
                $pMin = Convert-WGS84ToEPSG3395 -lonDeg $nbb.minX -latDeg $nbb.minY
                $pMax = Convert-WGS84ToEPSG3395 -lonDeg $nbb.maxX -latDeg $nbb.maxY
            } else { throw "Unsupported target gridset for 4326 reprojection." }
            return @{
                minX=[double][math]::Min($pMin.x,$pMax.x)
                minY=[double][math]::Min($pMin.y,$pMax.y)
                maxX=[double][math]::Max($pMin.x,$pMax.x)
                maxY=[double][math]::Max($pMin.y,$pMax.y)
            }
        } else {
            return @{minX=[double]$nbb.minX; minY=[double]$nbb.miny; maxX=[double]$nbb.maxX; maxY=[double]$nbb.maxY}
        }
    } catch { }

    # 3) WMS GetCapabilities
    try {
        $gsBase = $SeedBaseUrl -replace "/gwc/rest/seed$",""
        $capsUrl = $LayerCapsUrl
        if (-not $capsUrl) { $capsUrl = $ServerCapsUrl }
        if (-not $capsUrl) { $capsUrl = "$gsBase/wms?service=WMS&request=GetCapabilities" }
        return Get-WmsBBoxProjected -CapabilitiesUrl $capsUrl -LayerName $LayerName -TargetGridSet $GridSet
    } catch { }

    # 4) Fallback to gridset world
    switch ($GridSet.ToUpper()) {
        "EPSG:3857" { return @{ minX=-20037508.34; minY=-20037508.34; maxX=20037508.34; maxY=20037508.34 } }
        "EPSG:3395" { return @{ minX=-20037508.34; minY=-19971868.88; maxX=20037508.34; maxY=19971868.88 } }
        default     { throw ("Unknown gridset '{0}' and no service-derived bounds available." -f $GridSet) }
    }
}

# ------------------- Credentials -------------------

function Get-GwcCredential {
    param([Parameter(Mandatory=$true)][object]$Server)
    if ($Server.PSObject.Properties.Match("credentialFile").Count -gt 0) {
        $file = $Server.credentialFile
        if (!(Test-Path $file -PathType Leaf)) { throw ("credentialFile not found: {0}" -f $file) }
        try { return Import-Clixml -Path $file } catch { throw ("Failed to import credentialFile '{0}': {1}" -f $file, $_.Exception.Message) }
    }
    if ($Server.PSObject.Properties.Match("userFile").Count -gt 0 -and $Server.PSObject.Properties.Match("passwordFile").Count -gt 0) {
        $user=(Get-Content $Server.userFile -Raw).Trim()
        $secure=$null
        if (Test-Path $Server.passwordFile -PathType Leaf) {
            try { $secure = Get-Content $Server.passwordFile -Raw | ConvertTo-SecureString } catch { }
        }
        if (-not $secure -and $Server.PSObject.Properties.Match("plainTextPasswordFile").Count -gt 0 -and (Test-Path $Server.plainTextPasswordFile)) {
            $secure = ConvertTo-SecureString (Get-Content $Server.plainTextPasswordFile -Raw) -AsPlainText -Force
        }
        if (-not $secure) { throw "No valid credential found (credentialFile or user/password)" }
        return New-Object System.Management.Automation.PSCredential($user,$secure)
    }
    throw "No credential source configured for this server."
}

# ------------------- Seed submit and control -------------------

function Invoke-GwcSeed {
    param(
        [string]$SeedBaseUrl, [System.Management.Automation.PSCredential]$Cred, [hashtable]$Bounds,
        [string]$Layer, [string]$GridSet, [string]$Format,
        [int]$ZoomStart, [int]$ZoomStop, [int]$Threads, [string]$Type="reseed",
        [switch]$Insecure, [switch]$WhatIf
    )
    $url = "$SeedBaseUrl/$Layer.xml"
    $xml = @"
<seedRequest>
  <name>$Layer</name>
  <bounds><coords>
    <double>$($Bounds.minX)</double>
    <double>$($Bounds.minY)</double>
    <double>$($Bounds.maxX)</double>
    <double>$($Bounds.maxY)</double>
  </coords></bounds>
  <gridSetId>$GridSet</gridSetId>
  <format>$Format</format>
  <type>$Type</type>
  <threadCount>$Threads</threadCount>
  <zoomStart>$ZoomStart</zoomStart>
  <zoomStop>$ZoomStop</zoomStop>
</seedRequest>
"@
    Write-Host ("POST {0} (z {1}-{2}, threads={3})" -f $url, $ZoomStart, $ZoomStop, $Threads)
    if ($WhatIf) { return }
    if ($Insecure) {
        add-type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint p, X509Certificate c, WebRequest r, int pr) { return true; }
}
"@ | Out-Null
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }
    Invoke-WebRequest -Uri $url -Method POST -Body $xml -ContentType "text/xml" -Credential $Cred -UseBasicParsing | Out-Null
}

# Best-effort global kill (many servers disallow DELETE; we never block on failure)
function Kill-GwcTasksGlobal {
    param([string]$SeedBaseUrl, [System.Management.Automation.PSCredential]$Cred, [switch]$Insecure)
    $url = "$SeedBaseUrl"
    Write-Host ("DELETE {0} (global kill)" -f $url)
    if ($WhatIf) { return }
    if ($Insecure) {
        add-type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint p, X509Certificate c, WebRequest r, int pr) { return true; }
}
"@ | Out-Null
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }
    try {
        Invoke-WebRequest -Uri $url -Method DELETE -Credential $Cred -UseBasicParsing | Out-Null
        Write-Host " -> Kill request submitted."
    } catch {
        Write-Host (" -> Note: could not delete tasks globally: {0}" -f $_.Exception.Message)
    }
}

# Version-flexible idle waiter (tries multiple endpoints; never loops forever)
function Wait-GwcIdle {
    param(
        [string]$SeedBaseUrl, [string]$Layer,
        [System.Management.Automation.PSCredential]$Cred,
        [int]$PollSeconds=10, [switch]$Insecure,
        [int]$MaxPolls = 30  # safety: ~5 minutes by default
    )

    $tries = 0
    while ($true) {
        $tries += 1
        $idle = $false
        $checkedAny = $false

        # 1) Prefer layer XML endpoint
        try {
            if ($Insecure) {
                add-type @"
using System.Net; using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint p, X509Certificate c, WebRequest r, int pr) { return true; }
}
"@ | Out-Null
                [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
            }
            $statusUrl = "$SeedBaseUrl/$Layer.xml"
            $resp = Invoke-WebRequest -Uri $statusUrl -Credential $Cred -UseBasicParsing
            $checkedAny = $true
            if ($resp.Content -match "<ongoing>false</ongoing>") { $idle = $true }
        } catch { }

        # 2) Global status endpoint (fallback)
        if (-not $idle) {
            try {
                $url2 = "$SeedBaseUrl/../status"
                $resp2 = Invoke-WebRequest -Uri $url2 -Credential $Cred -UseBasicParsing
                $checkedAny = $true
                # idle if no <task> element present
                if ($resp2.Content -notmatch "<task>") { $idle = $true }
            } catch { }
        }

        # 3) Layer HTML endpoint (legacy)
        if (-not $idle) {
            try {
                $url3 = "$SeedBaseUrl/$Layer"
                $resp3 = Invoke-WebRequest -Uri $url3 -Credential $Cred -UseBasicParsing
                $checkedAny = $true
                if ($resp3.Content -match "No tasks are currently running") { $idle = $true }
            } catch { }
        }

        if ($idle) {
            Write-Host (" -> GWC queue idle for '{0}'" -f $Layer)
            return
        }

        if (-not $checkedAny) {
            Write-Host ("Warning: Could not access any status endpoint for '{0}'. Proceeding without waiting." -f $Layer)
            return
        }

        if ($tries -ge $MaxPolls) {
            Write-Host ("Warning: Max polls reached for '{0}'. Proceeding." -f $Layer)
            return
        }

        Write-Host (" -> Tasks still running for '{0}' ... recheck in {1}s" -f $Layer, $PollSeconds)
        Start-Sleep -Seconds $PollSeconds
    }
}

# ------------------- MAIN -------------------

$cfg = Read-Json $ConfigPath
$servers = $cfg.servers
$layers  = $cfg.layers
if ($ServerFilter) { $servers = $servers | Where-Object { $ServerFilter -contains $_.name } }
if ($LayerFilter)  { $layers  = $layers  | Where-Object { $LayerFilter  -contains $_.name } }
if (-not $servers) { throw "No servers to process." }
if (-not $layers)  { throw "No layers to process." }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$localLog = ("D:\Servers\SDS03 Geos\data\gwc_orchestrator_{0}.log" -f $stamp)
Start-Transcript -Path $localLog -Force | Out-Null

Write-Host ("=== GWC Orchestrator (Sequential; KillExisting={0}) ===" -f $KillExisting)
Write-Host ("Servers: {0}" -f ($servers.name -join ", "))
Write-Host ("Layers:  {0}" -f ($layers.name -join ", "))

foreach ($srv in $servers) {
    Write-Host ("`n--- Server: {0} ---" -f $srv.name)
    $cred = Get-GwcCredential -Server $srv
    $seedBaseUrl = $srv.url.TrimEnd("/")
    $serverCapsUrl = $null
    if ($srv.PSObject.Properties.Match("wmsCapabilitiesUrl").Count -gt 0) { $serverCapsUrl = $srv.wmsCapabilitiesUrl }

    foreach ($layer in $layers) {
        $layerName = $layer.name
        $gridset   = $layer.gridset
        $format    = $layer.format
        $minZoom   = [int]$layer.minZoom
        $maxZoom   = [int]$layer.maxZoom
        $threads   = $layer.threads; if (-not $threads) { $threads = 20 }
        $bboxMin   = $layer.bboxOnlyMinZoom; if (-not $bboxMin) { $bboxMin = 15 }
        $layerCapsUrl = $null
        if ($layer.PSObject.Properties.Match("wmsCapabilitiesUrl").Count -gt 0) { $layerCapsUrl = $layer.wmsCapabilitiesUrl }

        Write-Host ("`nLayer: {0} ({1} z {2}-{3})" -f $layerName, $gridset, $minZoom, $maxZoom)

        if ($KillExisting) {
            Kill-GwcTasksGlobal -SeedBaseUrl $seedBaseUrl -Cred $cred -Insecure:$Insecure
            Wait-GwcIdle        -SeedBaseUrl $seedBaseUrl -Layer $layerName -Cred $cred -PollSeconds 10 -Insecure:$Insecure
        }

        Write-Host " Fetching default bounds (service-derived if available)..."
        $defaultBBox = Get-DefaultBounds -SeedBaseUrl $seedBaseUrl -LayerName $layerName -Cred $cred -Insecure:$Insecure -GridSet $gridset -ServerCapsUrl $serverCapsUrl -LayerCapsUrl $layerCapsUrl

        $bboxOverrides = @{}
        if ($layer.bboxFilesByZoom) { $bboxOverrides = $layer.bboxFilesByZoom }

        if ($minZoom -lt $bboxMin) {
            $lowStart=$minZoom; $lowStop=[Math]::Min($maxZoom, $bboxMin-1)
            if ($lowStart -le $lowStop) {
                Write-Host (" Seeding low zooms z {0}-{1}..." -f $lowStart,$lowStop)
                Invoke-GwcSeed -SeedBaseUrl $seedBaseUrl -Cred $cred -Bounds $defaultBBox -Layer $layerName -GridSet $gridset -Format $format -ZoomStart $lowStart -ZoomStop $lowStop -Threads $threads -Type "reseed" -Insecure:$Insecure -WhatIf:$WhatIf
                Wait-GwcIdle   -SeedBaseUrl $seedBaseUrl -Layer $layerName -Cred $cred -PollSeconds 10 -Insecure:$Insecure
            }
        }

        $highStart=[Math]::Max($minZoom,$bboxMin)
        if ($highStart -le $maxZoom) {
            for ($z=$highStart; $z -le $maxZoom; $z++) {
                $bboxFile=$null
                if ($bboxOverrides.ContainsKey("$z")) {
                    $bboxFile=$bboxOverrides["$z"]
                    Write-Host (" Using per-level BBOX file for zoom {0}: {1}" -f $z, $bboxFile)
                } else {
                    Write-Host (" Using default bounds for zoom {0}" -f $z)
                }

                if ($bboxFile) {
                    $bboxes = Read-BBoxes $bboxFile
                } else {
                    $bboxes = @([pscustomobject]$defaultBBox)
                }

                $i=0
                foreach ($box in $bboxes) {
                    $i++
                    Write-Host ("  Seeding zoom {0} bbox #{1}..." -f $z, $i)
                    Invoke-GwcSeed -SeedBaseUrl $seedBaseUrl -Cred $cred -Bounds $box -Layer $layerName -GridSet $gridset -Format $format -ZoomStart $z -ZoomStop $z -Threads $threads -Type "reseed" -Insecure:$Insecure -WhatIf:$WhatIf
                    Wait-GwcIdle   -SeedBaseUrl $seedBaseUrl -Layer $layerName -Cred $cred -PollSeconds 10 -Insecure:$Insecure
                }
            }
        }

        Write-Host (" Done: {0}" -f $layerName)
    }
}

Stop-Transcript | Out-Null
Write-Host ""
Write-Host ("=== GWC Orchestrator complete ===")
Write-Host ("Local log: {0}" -f $localLog)