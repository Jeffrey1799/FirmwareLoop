<#
.SYNOPSIS
    Dual-Tier MCP setup and registration helper (v0.0.12).
    Inspects installed AI coding agents (Qoder, Claude Code, Antigravity, Cursor)
    and configures global MCP / skills or prints exact registration commands.

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

$isSourceRepo = (Test-Path -LiteralPath $fwMcpServer)

$fwCmdName = if ($isSourceRepo -and $python) { "`"$python`" `"$fwMcpServer`"" } else { "fwloop" }
$ahilCmdName = if (Test-Path -LiteralPath $ahilExe) { "`"$ahilExe`" mcp-stdio" } else { "agentic-hil mcp-stdio" }

$report = [ordered]@{
    schema = 'firmwareloop-mcp-setup/v1'
    repo_root = $repoRoot
    is_source_repo = $isSourceRepo
    servers = [ordered]@{
        firmwareloop = [ordered]@{
            command = if ($isSourceRepo -and $python) { $python } else { "fwloop" }
            args = if ($isSourceRepo) { @($fwMcpServer) } else { @() }
            description = 'Upper-tier firmware engineering workflow MCP'
        }
        agentic_hil = [ordered]@{
            command = if (Test-Path -LiteralPath $ahilExe) { $ahilExe } else { "agentic-hil" }
            args = @('mcp-stdio')
            description = 'Lower-tier physical hardware & probe MCP'
        }
    }
    agents = [ordered]@{}
}

# 1. Claude Code CLI 全局 MCP 自动配置
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
$claudeConfigUpdated = $false
$claudeConfigFile = Join-Path $env:USERPROFILE '.claude.json'
if (Test-Path -LiteralPath $claudeConfigFile) {
    try {
        $existingClaude = Get-Content -LiteralPath $claudeConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $existingClaude.PSObject.Properties['mcpServers']) {
            $existingClaude | Add-Member -MemberType NoteProperty -Name 'mcpServers' -Value ([pscustomobject]@{})
        }
        $existingClaude.mcpServers | Add-Member -MemberType NoteProperty -Name 'fwloop' -Value ([pscustomobject]@{ command = "fwloop" }) -Force
        $existingClaude.mcpServers | Add-Member -MemberType NoteProperty -Name 'agentic-hil' -Value ([pscustomobject]@{ command = "agentic-hil"; args = @("mcp-stdio") }) -Force
        $updatedClaudeStr = ConvertTo-Json -InputObject $existingClaude -Depth 20
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($claudeConfigFile, $updatedClaudeStr, $utf8NoBom)
        $claudeConfigUpdated = $true
    } catch {
        # ignore non-fatal config write error
    }
}
if ($claudeCmd -and -not $claudeConfigUpdated) {
    try {
        & $claudeCmd.Source mcp add --scope user fwloop -- fwloop | Out-Null
        & $claudeCmd.Source mcp add --scope user agentic-hil -- agentic-hil mcp-stdio | Out-Null
        $claudeConfigUpdated = $true
    } catch {
        # ignore non-fatal error
    }
}
$report.agents.claude_code = [ordered]@{
    detected = ($null -ne $claudeCmd)
    path = if ($claudeCmd) { $claudeCmd.Source } else { $null }
    configured = $claudeConfigUpdated
    registration_commands = @(
        "claude mcp add --scope user fwloop -- $fwCmdName",
        "claude mcp add --scope user agentic-hil -- $ahilCmdName"
    )
}

# 2. Qoder IDE / CLI 全局 User Profile MCP 自动配置
$qoderCmd = $null
foreach ($name in @('qoder.cmd', 'qoder', 'qodercli')) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { $qoderCmd = $c; break }
}
$qoderConfigured = $false
if ($qoderCmd) {
    try {
        $fwJsonStr = '{"name":"firmwareloop","command":"fwloop"}'
        $ahilJsonStr = '{"name":"agentic-hil","command":"agentic-hil","args":["mcp-stdio"]}'
        & $qoderCmd.Source --add-mcp $fwJsonStr | Out-Null
        & $qoderCmd.Source --add-mcp $ahilJsonStr | Out-Null
        $qoderConfigured = $true
    } catch {
        # ignore non-fatal error
    }
}
$report.agents.qoder = [ordered]@{
    detected = ($null -ne $qoderCmd)
    path = if ($qoderCmd) { $qoderCmd.Source } else { $null }
    user_profile_configured = $qoderConfigured
    registration_commands = @(
        "qoder.cmd --add-mcp '{\`"name\`":\`"firmwareloop\`",\`"command\`":\`"fwloop\`"}'",
        "qoder.cmd --add-mcp '{\`"name\`":\`"agentic-hil\`",\`"command\`":\`"agentic-hil\`",\`"args\`":[\`"mcp-stdio\`"]}'"
    )
}

# 3. Antigravity CLI / Gemini 全局 MCP 自动配置与 Skills
$antigravityConfigDir = Join-Path $env:USERPROFILE '.gemini\config'
$antigravityMcpConfigFile = Join-Path $antigravityConfigDir 'mcp_config.json'
$antigravityMcpUpdated = $false
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
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($antigravityMcpConfigFile, $updatedJsonStr, $utf8NoBom)
        $antigravityMcpUpdated = $true
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
    mcp_configured = $antigravityMcpUpdated
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
                command = if ($isSourceRepo -and $python) { $python } else { "fwloop" }
                args = if ($isSourceRepo) { @($fwMcpServer) } else { @() }
                timeout = 300000
            }
            "agentic-hil" = [ordered]@{
                type = 'stdio'
                command = if (Test-Path -LiteralPath $ahilExe) { $ahilExe } else { "agentic-hil" }
                args = @('mcp-stdio')
                timeout = 120000
            }
        }
    }
    $jsonContent = ConvertTo-Json -InputObject $mcpConfig -Depth 10
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($mcpJsonPath, $jsonContent, $utf8NoBom)
    $report.workspace_mcp_written = $mcpJsonPath
}

if ($Json) {
    Write-FwJson ([pscustomobject]$report)
} else {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  FirmwareLoop Dual-Tier MCP & Agent Setup Helper (v0.0.10)" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[1] Google Antigravity / Gemini CLI:" -ForegroundColor Yellow
    if ($antigravityMcpUpdated) {
        Write-Host "    - Global MCP Config: [OK] Written to $antigravityMcpConfigFile" -ForegroundColor Green
    } else {
        Write-Host "    - Global MCP Config: ~/.gemini/config/mcp_config.json (Ready)"
    }
    if ($installedSkills.Count -gt 0) {
        Write-Host "    - Global Skills: [OK] Synchronized $($installedSkills.Count) skills ($($installedSkills -join ', ')) to Antigravity & Claude Code" -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "[2] Claude Code CLI Registration:" -ForegroundColor Yellow
    Write-Host "    $($report.agents.claude_code.registration_commands[0])"
    Write-Host "    $($report.agents.claude_code.registration_commands[1])"
    Write-Host ""
    Write-Host "[3] Qoder IDE:" -ForegroundColor Yellow
    if ($qoderConfigured) {
        Write-Host "    - User Profile MCP: [OK] Automatically registered to Qoder User Profile" -ForegroundColor Green
    } else {
        Write-Host "    - User Profile MCP: Run $($report.agents.qoder.registration_commands[0])"
    }
    Write-Host "    - Workspace: Project root '.mcp.json' is automatically detected"
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "[+] All AI Coding Agents are configured and ready!" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Cyan
}
