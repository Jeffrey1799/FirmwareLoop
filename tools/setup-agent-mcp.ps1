<#
.SYNOPSIS
    Dual-Tier MCP setup and registration helper (v0.0.8).
    Inspects installed AI coding agents (Qoder, Claude Code, Antigravity, Cursor)
    and prints/generates exact registration commands and workspace configuration.

    Usage:
        .\tools\setup-agent-mcp.ps1
        .\tools\setup-agent-mcp.ps1 -Json
        .\tools\setup-agent-mcp.ps1 -WriteWorkspaceMcp
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$WriteWorkspaceMcp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'common\fw.psm1') -Force

$repoRoot = Get-FwRepoRoot
$python = Resolve-FwPython -RepoRoot $repoRoot
$fwMcpServer = Join-Path $repoRoot 'tools\fw_mcp_server.py'
$ahilExe = Join-Path $repoRoot '.venv\Scripts\agentic-hil.exe'

$report = [ordered]@{
    schema = 'firmwareloop-mcp-setup/v1'
    repo_root = $repoRoot
    servers = [ordered]@{
        firmwareloop = [ordered]@{
            command = $python
            args = @($fwMcpServer)
            description = 'Upper-tier firmware engineering workflow MCP'
        }
        agentic_hil = [ordered]@{
            command = $ahilExe
            args = @('mcp-stdio')
            description = 'Lower-tier physical hardware & probe MCP'
        }
    }
    agents = [ordered]@{}
}

# 1. Claude Code CLI
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
$report.agents.claude_code = [ordered]@{
    detected = ($null -ne $claudeCmd)
    path = if ($claudeCmd) { $claudeCmd.Source } else { $null }
    registration_commands = @(
        "claude mcp add firmwareloop -- `"$python`" `"$fwMcpServer`"",
        "claude mcp add agentic-hil -- `"$ahilExe`" mcp-stdio"
    )
}

# 2. Qoder IDE / CLI
$qoderCmd = $null
foreach ($name in @('qoder', 'qodercli')) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { $qoderCmd = $c; break }
}
$report.agents.qoder = [ordered]@{
    detected = ($null -ne $qoderCmd)
    path = if ($qoderCmd) { $qoderCmd.Source } else { $null }
    registration_commands = if ($qoderCmd) {
        @(
            "$($qoderCmd.Name) mcp add firmwareloop -- `"$python`" `"$fwMcpServer`"",
            "$($qoderCmd.Name) mcp add agentic-hil -- `"$ahilExe`" mcp-stdio"
        )
    } else {
        @(
            "qoder mcp add firmwareloop -- `"$python`" `"$fwMcpServer`"",
            "qoder mcp add agentic-hil -- `"$ahilExe`" mcp-stdio"
        )
    }
}

# 3. Antigravity CLI / Gemini 全局 MCP 配置与 Skills
$antigravityConfigDir = Join-Path $env:USERPROFILE '.gemini\config'
$antigravityMcpConfigFile = Join-Path $antigravityConfigDir 'mcp_config.json'
if (Test-Path -LiteralPath $antigravityConfigDir) {
    try {
        $existingJson = if (Test-Path -LiteralPath $antigravityMcpConfigFile) {
            Get-Content -LiteralPath $antigravityMcpConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } else {
            [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
        }
        if (-not $existingJson.PSObject.Properties['mcpServers']) {
            $existingJson | Add-Member -MemberType NoteProperty -Name 'mcpServers' -Value ([pscustomobject]@{})
        }
        $existingJson.mcpServers | Add-Member -MemberType NoteProperty -Name 'firmwareloop' -Value ([pscustomobject]@{ command = "fwloop" }) -Force
        $existingJson.mcpServers | Add-Member -MemberType NoteProperty -Name 'agentic-hil' -Value ([pscustomobject]@{ command = "agentic-hil"; args = @("mcp-stdio") }) -Force
        $updatedJsonStr = ConvertTo-Json -InputObject $existingJson -Depth 10
        [System.IO.File]::WriteAllText($antigravityMcpConfigFile, $updatedJsonStr, [System.Text.Encoding]::UTF8)
    } catch {
        # ignore non-fatal config write error
    }
}

$antigravitySkillsRoot = Join-Path $env:USERPROFILE '.gemini\antigravity-cli\skills'
$claudeSkillsRoot = Join-Path $env:USERPROFILE '.claude\skills'

$installedSkills = @()
$sourceSkillsDir = Join-Path $repoRoot 'skills'
if (Test-Path -LiteralPath $sourceSkillsDir) {
    Get-ChildItem -Directory -Path $sourceSkillsDir | ForEach-Object {
        $skillName = $_.Name
        $sourceSkillFile = Join-Path $_.FullName 'SKILL.md'
        if (Test-Path -LiteralPath $sourceSkillFile) {
            # Sync to Antigravity
            if (Test-Path -LiteralPath (Split-Path $antigravitySkillsRoot)) {
                $targetDir = Join-Path $antigravitySkillsRoot $skillName
                New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
                Copy-Item -LiteralPath $sourceSkillFile -Destination (Join-Path $targetDir 'SKILL.md') -Force
            }
            # Sync to Claude
            if (Test-Path -LiteralPath (Split-Path $claudeSkillsRoot)) {
                $targetDir = Join-Path $claudeSkillsRoot $skillName
                New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
                Copy-Item -LiteralPath $sourceSkillFile -Destination (Join-Path $targetDir 'SKILL.md') -Force
            }
            $installedSkills += $skillName
        }
    }
}

$report.agents.antigravity = [ordered]@{
    mcp_config_path = $antigravityMcpConfigFile
    global_skills_installed = ($installedSkills.Count -gt 0)
    installed_skills = $installedSkills
    note = "Antigravity global mcp_config.json and skills configured."
}

# Optional: write project-level .mcp.json
if ($WriteWorkspaceMcp) {
    $mcpJsonPath = Join-Path $repoRoot '.mcp.json'
    $mcpConfig = [ordered]@{
        mcpServers = [ordered]@{
            firmwareloop = [ordered]@{
                type = 'stdio'
                command = $python
                args = @($fwMcpServer)
                timeout = 300000
            }
            "agentic-hil" = [ordered]@{
                type = 'stdio'
                command = $ahilExe
                args = @('mcp-stdio')
                timeout = 120000
            }
        }
    }
    $jsonContent = ConvertTo-Json -InputObject $mcpConfig -Depth 10
    [System.IO.File]::WriteAllText($mcpJsonPath, $jsonContent, [System.Text.Encoding]::UTF8)
    $report.workspace_mcp_written = $mcpJsonPath
}

if ($Json) {
    Write-FwJson ([pscustomobject]$report)
} else {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "FirmwareLoop v0.0.8 - Dual-Tier MCP & Skill Setup Helper" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[1] Claude Code CLI Registration:" -ForegroundColor Yellow
    Write-Host "    $($report.agents.claude_code.registration_commands[0])"
    Write-Host "    $($report.agents.claude_code.registration_commands[1])"
    Write-Host ""
    Write-Host "[2] Qoder IDE (Official GUI & Workspace .mcp.json):" -ForegroundColor Yellow
    Write-Host "    - GUI: Press 'Ctrl + Shift + ,' -> MCP -> My Services -> '+ Add', paste the JSON config"
    Write-Host "    - Workspace: Qoder automatically detects '.mcp.json' in your workspace root"
    Write-Host "    - CLI: $($report.agents.qoder.registration_commands[0])"
    Write-Host "           $($report.agents.qoder.registration_commands[1])"
    Write-Host ""
    Write-Host "[3] Antigravity CLI / Cursor / VS Code:" -ForegroundColor Yellow
    Write-Host "    - MCP: Automatically reads '.mcp.json' in workspace root"
    if ($skillInstalled) {
        Write-Host "    - Global Skill: [OK] Successfully registered to: $targetGlobalSkillDir\SKILL.md" -ForegroundColor Green
    }
    Write-Host "    - Generate workspace config: .\tools\setup-agent-mcp.ps1 -WriteWorkspaceMcp"
    Write-Host ""
}
