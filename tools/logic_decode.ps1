<#
.SYNOPSIS
    Logic decoder (Spec §13 fallback). Decodes a raw capture (CSV with a
    time_s first column and one column per channel) into JSON frames using the
    channel/protocol layout from lab/protocol-decode.yaml.

    SPI  : D0=SCLK, D1=MOSI, D2=MISO, D3=CS (low active), MSB first
    UART : D0=TX (idle high), 8N1, LSB first, baud from config
    I2C  : D0=SCL, D1=SDA (basic byte/ACK extraction)

    Every decoded result is saved next to the capture and carries the
    timestamp. Optional -Expect/-ExpectKind asserts the result and exits 1
    with TEST_FAILED on mismatch (for HIL assertions).

    Usage:
        .\tools\logic_decode.ps1 -Capture artifacts\captures\20260817-000000 -Json
        .\tools\logic_decode.ps1 -CaptureFile x.csv -Protocol spi -Expect EF4018 -ExpectKind hex -Json
#>
[CmdletBinding()]
param(
    [string]$Capture,                 # capture dir containing capture.csv + capture.json
    [string]$CaptureFile,             # direct path to the raw CSV
    [ValidateSet('spi', 'uart', 'i2c')]
    [string]$Protocol,                # override protocol (else read from metadata)
    [string]$Expect,                  # expected decoded value (hex string or text)
    [ValidateSet('hex', 'text')]
    [string]$ExpectKind = 'hex',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\fw.psm1') -Force

$repoRoot = Get-FwRepoRoot

function Exit-WithError {
    param([string]$Class, [string]$Message, [string]$Detail)
    $body = New-FwError -ErrorClass $Class -Message $Message -Detail $Detail
    if ($Json) { Write-FwJson $body -Compact } else { Write-FwJson $body; Write-Error "$Class : $Message" -ErrorAction Continue }
    exit 2
}

# ---- locate raw capture -------------------------------------------------------
$rawFile = $null
$meta = $null
if ($Capture) {
    if (Test-Path -LiteralPath $Capture -PathType Container) {
        $rawFile = Join-Path $Capture 'capture.csv'
        $metaPath = Join-Path $Capture 'capture.json'
        if (Test-Path -LiteralPath $metaPath) {
            $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        }
        if (-not (Test-Path -LiteralPath $rawFile)) {
            $srFile = Join-Path $Capture 'capture.sr'
            if (Test-Path -LiteralPath $srFile) {
                Exit-WithError -Class 'LOGIC_CAPTURE_ERROR' -Message 'sigrok binary capture needs sigrok-cli decode; export CSV from PulseView or pass -CaptureFile <csv>.' -Detail $srFile
            }
            Exit-WithError -Class 'LOGIC_CAPTURE_ERROR' -Message 'no capture.csv or capture.sr found in capture dir.' -Detail $Capture
        }
    } elseif (Test-Path -LiteralPath $Capture -PathType Leaf) {
        $rawFile = $Capture   # direct file path (capture.csv)
        $metaPath = Join-Path (Split-Path $Capture) 'capture.json'
        if (Test-Path -LiteralPath $metaPath) {
            $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        }
    } else {
        Exit-WithError -Class 'CONFIG_ERROR' -Message 'Capture path does not exist.' -Detail $Capture
    }
} elseif ($CaptureFile) {
    $rawFile = $CaptureFile
} else {
    Exit-WithError -Class 'CONFIG_ERROR' -Message 'pass -Capture <dir> or -CaptureFile <csv>'
}

if (-not (Test-Path -LiteralPath $rawFile)) {
    Exit-WithError -Class 'ARTIFACT_NOT_FOUND' -Message 'capture file does not exist.' -Detail $rawFile
}

# ---- protocol/config resolution ------------------------------------------------
$cfg = @{}
$cfgPath = Join-Path $repoRoot 'lab\protocol-decode.yaml'
# YAML is not natively parseable in PowerShell; the decoder only needs the
# baud rate for UART and channel mapping. Fall back to sane defaults.
if ($meta -and $meta.protocol) { $reqProtocol = [string]$meta.protocol } else { $reqProtocol = $null }
if ($Protocol) { $reqProtocol = $Protocol }
if (-not $reqProtocol) {
    Exit-WithError -Class 'CONFIG_ERROR' -Message 'protocol unknown; pass -Protocol or run capture first' -Detail $metaPath
}

$baud = 115200
if ($reqProtocol -eq 'uart' -and $meta) {
    $bProp = $meta.PSObject.Properties['baud']
    if ($bProp -and $bProp.Value) { $baud = [int]$bProp.Value }
}

# ---- load samples --------------------------------------------------------------
$rows = Import-Csv -LiteralPath $rawFile
if ($rows.Count -lt 3) {
    Exit-WithError -Class 'LOGIC_CAPTURE_ERROR' -Message 'capture has too few samples to decode.' -Detail $rawFile
}
$cols = $rows[0].PSObject.Properties.Name
foreach ($c in @('time_s')) { if ($c -notin $cols) { Exit-WithError -Class 'LOGIC_CAPTURE_ERROR' -Message "missing column '$c' in capture" -Detail $rawFile } }
$ch = @{}
foreach ($c in $cols) { if ($c -ne 'time_s') { $ch[$c] = $true } }

function Get-Ch {
    param([int]$Index)
    $names = @($cols | Where-Object { $_ -ne 'time_s' })
    if ($Index -ge $names.Count) { return $null }
    return $names[$Index]
}

# normalize levels (CSV values may be 0/1, true/false, high/low)
function Lev([string]$v) {
    $s = $v.Trim().ToLowerInvariant()
    if ($s -in @('1', 'true', 'high', 'h')) { return 1 }
    if ($s -in @('0', 'false', 'low', 'l')) { return 0 }
    return 0
}

# ---- decoders -------------------------------------------------------------------
$frames = @()
$bytes = @()
$text = ''

switch ($reqProtocol) {
    'spi' {
        $cClk = Get-Ch 0; $cMosi = Get-Ch 1; $cMiso = Get-Ch 2; $cCs = Get-Ch 3
        if (-not ($cClk -and $cMosi -and $cMiso -and $cCs)) {
            Exit-WithError -Class 'LOGIC_CAPTURE_ERROR' -Message "SPI needs 4 channels (SCLK,MOSI,MISO,CS); found: $($cols -join ',')"
        }
        $inWindow = $false
        $cmdBits = @(); $respBits = @(); $prevClk = 0
        foreach ($r in $rows) {
            $cs = Lev $r.$cCs
            if (-not $inWindow -and $cs -eq 0) { $inWindow = $true; $cmdBits = @(); $respBits = @() }
            if ($inWindow -and $cs -eq 1) { break }   # window closed
            if ($inWindow) {
                $clk = Lev $r.$cClk
                if ($clk -eq 1 -and $prevClk -eq 0) {        # rising edge
                    $mosi = Lev $r.$cMosi
                    $miso = Lev $r.$cMiso
                    if ($cmdBits.Count + $respBits.Count -lt 8) {
                        $cmdBits += $mosi
                    } else {
                        $respBits += $miso
                    }
                }
                $prevClk = $clk
            }
        }
        if ($cmdBits.Count + $respBits.Count -ne 32) {
            Exit-WithError -Class 'LOGIC_CAPTURE_ERROR' -Message "expected 32 SPI edges (8 cmd + 24 resp), got $($cmdBits.Count + $respBits.Count)" -Detail $rawFile
        }
        $cmdByte = 0; foreach ($b in $cmdBits) { $cmdByte = ($cmdByte -shl 1) -bor $b }
        $respBytes = @()
        for ($k = 0; $k -lt 24; $k += 8) {
            $v = 0
            for ($j = 0; $j -lt 8; $j++) { $v = ($v -shl 1) -bor $respBits[$k + $j] }
            $respBytes += $v
        }
        $bytes = @($cmdByte) + $respBytes
        $frames = @([ordered]@{
            type = 'command'; bytes_hex = ('0x{0:X2}' -f $cmdByte)
        }, [ordered]@{
            type = 'response'; bytes_hex = (($respBytes | ForEach-Object { '0x{0:X2}' -f $_ }) -join ' ')
        })
    }

    'uart' {
        $cTx = Get-Ch 0
        if (-not $cTx) { Exit-WithError -Class 'LOGIC_CAPTURE_ERROR' -Message "UART needs a TX channel (D0); found: $($cols -join ',')" }
        $samples = @($rows | ForEach-Object { Lev $_.$cTx })
        # Estimate bit width from the MODE of adjacent edge spacings - robust
        # against data bits that are low for more than one bit (e.g. 0x48).
        $edges = @()
        for ($k = 0; $k -lt $samples.Count - 1; $k++) {
            if ($samples[$k] -ne $samples[$k + 1]) { $edges += $k + 1 }
        }
        $spacings = @()
        for ($k = 1; $k -lt $edges.Count; $k++) {
            $spacings += ($edges[$k] - $edges[$k - 1])
        }
        if ($spacings.Count -eq 0) {
            Exit-WithError -Class 'LOGIC_CAPTURE_ERROR' -Message 'no edges found on UART TX channel; is the capture from a real UART?'
        }
        $bitSamples = ($spacings | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
        $bitSamples = [math]::Max(2, [int]$bitSamples)

        $i = 0
        while ($i -lt $samples.Count - 1) {
            # Frame boundary: falling edge preceded by >= 3 bits of idle high.
            # A real start bit has stop + inter-frame idle before it; mid-data
            # runs of 1s are at most 2 bits before a data falling edge.
            $preHigh = $true
            for ($c = 0; $c -lt 3 * $bitSamples; $c++) {
                $pi = $i - $c
                if ($pi -lt 0) { $preHigh = $false; break }
                if ($samples[$pi] -ne 1) { $preHigh = $false; break }
            }
            if ($samples[$i] -eq 1 -and $samples[$i + 1] -eq 0 -and $preHigh) {
                $collected = @()
                for ($b = 0; $b -lt 8; $b++) {
                    $idx = $i + 1 + [int]((1.5 + $b) * $bitSamples)
                    $bitVal = if ($idx -lt $samples.Count) { $samples[$idx] } else { 1 }
                    $collected += $bitVal   # LSB first
                }
                # stop bit must be high (idle level) for a valid UART frame
                $stopIdx = $i + 1 + [int](10.0 * $bitSamples)
                $stopOk = ($stopIdx -lt $samples.Count) -and ($samples[$stopIdx] -eq 1)
                if (-not $stopOk) {
                    $i++   # not a real frame boundary (mid-data flip); keep scanning
                    continue
                }
                $val = 0
                for ($b = 7; $b -ge 0; $b--) { $val = ($val -shl 1) -bor $collected[$b] }
                $bytes += $val
                $frames += [ordered]@{ type = 'frame'; bytes_hex = '0x{0:X2}' -f $val }
                $i += $bitSamples  # advance into the frame interior; the scan
                # re-hits the next boundary via the idle-high precondition
                continue
            }
            $i++
        }
        $text = -join ($bytes | ForEach-Object { [char]$_ })
    }

    'i2c' {
        $cScl = Get-Ch 0; $cSda = Get-Ch 1
        if (-not ($cScl -and $cSda)) {
            Exit-WithError -Class 'LOGIC_CAPTURE_ERROR' -Message "I2C needs SCL (D0) and SDA (D1); found: $($cols -join ',')"
        }
        # Collect the SDA value at every SCL rising edge; one byte = 8 data
        # bits + 1 ACK. START (SDA falls while SCL high) opens the stream.
        $prevScl = 0
        $bits = [System.Collections.Generic.List[int]]::new()
        $inStream = $false
        foreach ($r in $rows) {
            $scl = Lev $r.$cScl
            $sda = Lev $r.$cSda
            if ($scl -eq 1 -and $prevScl -eq 0) {          # rising edge
                if ($inStream) { $bits.Add($sda) }
            } elseif ($scl -eq 1 -and $prevScl -eq 1) {
                # SCL high window: SDA falling => START, rising => STOP
                if ($lastSclHighSda -eq 1 -and $sda -eq 0) { $inStream = $true; $bits.Clear() }
                elseif ($lastSclHighSda -eq 0 -and $sda -eq 1) { $inStream = $false }
                $lastSclHighSda = $sda
            }
            $prevScl = $scl
            if ($scl -eq 1) { $lastSclHighSda = $sda }
        }
        # group 8-bit chunks (skip the ACK bit every 9th sample)
        $payload = [System.Collections.Generic.List[int]]::new()
        $idx = 0
        while ($idx + 8 -le $bits.Count) {
            $v = 0
            for ($b = 0; $b -lt 8; $b++) { $v = ($v -shl 1) -bor $bits[$idx + $b] }
            $payload.Add($v)
            $idx += 9   # skip ACK
        }
        foreach ($v in $payload) {
            $bytes += $v
            $frames += [ordered]@{ type = 'byte'; bytes_hex = '0x{0:X2}' -f $v }
        }
    }
}

$hexStr = (($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join '')
$outDir = Split-Path -Parent (Resolve-Path -LiteralPath $rawFile).Path
$outJson = Join-Path $outDir 'decoded.json'

$decoded = [ordered]@{
    schema    = 'lab-logic-decode/v1'
    ok        = $true
    protocol  = $reqProtocol
    source    = (Resolve-Path -LiteralPath $rawFile).Path
    bytes_hex = $hexStr
    text      = $text
    frames    = $frames
    timestamp = Get-FwTimestamp
}
$decoded | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outJson -Encoding utf8
$decoded.out_file = (Resolve-Path -LiteralPath $outJson).Path

# ---- assertion ----------------------------------------------------------------
if ($Expect) {
    $actual = if ($ExpectKind -eq 'hex') { $hexStr } else { $text }
    if ($actual -ne $Expect) {
        $body = [ordered]@{
            schema       = 'lab-logic-decode/v1'
            ok           = $false
            error_class  = 'TEST_FAILED'
            error        = 'decoded value did not match expectation'
            protocol     = $reqProtocol
            expected     = $Expect
            actual       = $actual
            decoded_file = $outJson
            timestamp    = Get-FwTimestamp
        }
        if ($Json) { Write-FwJson ([pscustomobject]$body) -Compact } else { Write-FwJson ([pscustomobject]$body) }
        exit 1
    }
}

if ($Json) { Write-FwJson ([pscustomobject]$decoded) -Compact } else { Write-FwJson ([pscustomobject]$decoded) }
exit 0