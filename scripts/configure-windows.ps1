[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Persist,
    [int]$InterfaceIndex = 0,
    [string]$Gateway = '',
    [int]$Metric = 512,
    [string]$TestUrl = 'http://ipv6.test-ipv6.com/'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$campusPrefix = '2001:da8:'
$fallbackGateway = 'fe80::200:5eff:fe00:101'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-IPv6AcceptanceTest {
    param([string]$Url, [int]$ExpectedInterfaceIndex)

    $uri = [Uri]$Url
    $destination = (Resolve-DnsName -Type AAAA $uri.Host | Where-Object IPAddress | Select-Object -First 1).IPAddress
    if (-not $destination) {
        Write-Error "No AAAA record was found for $($uri.Host)."
        return 125
    }
    try {
        $effectiveRoute = Find-NetRoute -RemoteIPAddress $destination -ErrorAction Stop |
            Where-Object { $_.PSObject.Properties.Name -contains 'DestinationPrefix' } |
            Select-Object -First 1
    }
    catch {
        Write-Warning "No effective IPv6 route to $destination was found."
        return 125
    }
    if (-not $effectiveRoute -or $effectiveRoute.InterfaceIndex -ne $ExpectedInterfaceIndex) {
        $actualIndex = if ($effectiveRoute) { $effectiveRoute.InterfaceIndex } else { 'none' }
        Write-Warning "The effective route to $destination uses interface $actualIndex, not $ExpectedInterfaceIndex."
        return 125
    }

    $oldNoProxy = $env:NO_PROXY
    $oldNoProxyLower = $env:no_proxy
    $bypass = $uri.Host
    if ($oldNoProxy) { $bypass = "$oldNoProxy,$bypass" }

    try {
        $env:NO_PROXY = $bypass
        $env:no_proxy = $bypass
        Write-Host "Effective IPv6 route: $destination via interface $ExpectedInterfaceIndex"
        Write-Host "Acceptance: curl.exe -6 $Url"
        & curl.exe -6 $Url | Out-Null
        $curlExitCode = $LASTEXITCODE
        return $curlExitCode
    }
    finally {
        $env:NO_PROXY = $oldNoProxy
        $env:no_proxy = $oldNoProxyLower
    }
}

function Find-RouterNeighbor {
    param([int]$Index)

    $output = (& netsh.exe interface ipv6 show neighbors $Index 2>$null) -join "`n"
    $matches = [regex]::Matches(
        $output,
        '(?im)^\s*(fe80::[0-9a-f:]+)\s+[0-9a-f-]+\s+.*\(Router\)\s*$'
    )
    $routers = @($matches | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    if ($routers.Count -eq 1) { return $routers[0] }
    return $null
}

function Test-GatewayNeighbor {
    param([int]$Index, [string]$Address)

    & ping.exe -6 -n 1 -w 1000 "$Address%$Index" *> $null
    $neighbor = Get-NetNeighbor -AddressFamily IPv6 -InterfaceIndex $Index -IPAddress $Address -ErrorAction SilentlyContinue
    return $null -ne $neighbor -and $neighbor.State -notin @('Unreachable', 'Incomplete')
}

$addresses = @(Get-NetIPAddress -AddressFamily IPv6 | Where-Object {
    $_.IPAddress -like "$campusPrefix*" -and
    $_.AddressState -in @('Preferred', 'Deprecated') -and
    -not $_.SkipAsSource
})

if ($InterfaceIndex -ne 0) {
    $addresses = @($addresses | Where-Object InterfaceIndex -eq $InterfaceIndex)
}

$interfaceIndexes = @($addresses | Select-Object -ExpandProperty InterfaceIndex -Unique)
if ($interfaceIndexes.Count -eq 0) {
    throw 'Prerequisite not met: no usable 2001:da8:... DHCPv6 address was found.'
}
if ($interfaceIndexes.Count -gt 1) {
    throw "Multiple campus IPv6 interfaces found ($($interfaceIndexes -join ', ')); rerun with -InterfaceIndex."
}

$selectedIndex = [int]$interfaceIndexes[0]
$selectedAddresses = @($addresses | Where-Object InterfaceIndex -eq $selectedIndex | Select-Object -ExpandProperty IPAddress)
$ipInterface = Get-NetIPInterface -AddressFamily IPv6 -InterfaceIndex $selectedIndex
$defaultRoutes = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -InterfaceIndex $selectedIndex -ErrorAction SilentlyContinue |
    Where-Object State -ne 'Dead' |
    Sort-Object RouteMetric)

Write-Host "Interface: $($ipInterface.InterfaceAlias) (index $selectedIndex)"
Write-Host "Campus IPv6 address(es): $($selectedAddresses -join ', ')"

$testExit = Invoke-IPv6AcceptanceTest -Url $TestUrl -ExpectedInterfaceIndex $selectedIndex
if ($testExit -eq 0) {
    $route = $defaultRoutes | Select-Object -First 1
    if ($route) { Write-Host "IPv6 default route: $($route.NextHop) (metric $($route.RouteMetric))" }
    Write-Host 'Result: IPv6 is usable; no route change was needed.'
    exit 0
}

if ($defaultRoutes.Count -gt 0) {
    $routeSummary = ($defaultRoutes | ForEach-Object { "$($_.NextHop) metric=$($_.RouteMetric)" }) -join '; '
    throw "IPv6 test failed even though a default route exists: $routeSummary. Check upstream access, DNS, or firewall; no route was changed."
}

if (-not $Gateway) { $Gateway = Find-RouterNeighbor -Index $selectedIndex }
if (-not $Gateway -and (Test-GatewayNeighbor -Index $selectedIndex -Address $fallbackGateway)) {
    $Gateway = $fallbackGateway
}
if (-not $Gateway) {
    throw 'No unique link-local router was discovered. Supply -Gateway only after verifying the campus router on this interface.'
}
if ($Gateway -notlike 'fe80::*') {
    throw "Refusing non-link-local gateway: $Gateway"
}

Write-Host "Missing route: ::/0 via $Gateway on interface $selectedIndex"
if (-not $Apply) {
    Write-Host 'Rerun from an elevated PowerShell with -Apply to add an active route.'
    exit 2
}
if (-not (Test-IsAdministrator)) {
    throw 'The -Apply operation requires an elevated PowerShell.'
}

$createdRoute = $false
try {
    if ($Persist) {
        & netsh.exe interface ipv6 add route prefix='::/0' interface=$selectedIndex nexthop=$Gateway metric=$Metric store=persistent
        if ($LASTEXITCODE -ne 0) { throw "netsh failed with exit code $LASTEXITCODE" }
    }
    else {
        New-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -InterfaceIndex $selectedIndex `
            -NextHop $Gateway -RouteMetric $Metric -PolicyStore ActiveStore | Out-Null
    }
    $createdRoute = $true

    $testExit = Invoke-IPv6AcceptanceTest -Url $TestUrl -ExpectedInterfaceIndex $selectedIndex
    if ($testExit -ne 0) { throw "curl exited with code $testExit" }

    $scope = if ($Persist) { 'persistent' } else { 'active (until disconnect/reboot)' }
    Write-Host "Result: IPv6 is usable; added $scope route ::/0 via $Gateway."
    exit 0
}
catch {
    if ($createdRoute) {
        Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -InterfaceIndex $selectedIndex -NextHop $Gateway `
            -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        Write-Warning 'The newly added route was rolled back because validation failed.'
    }
    throw
}
