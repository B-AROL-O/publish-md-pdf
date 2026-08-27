#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Convert Markdown, Confluence Storage Format and Confluence Cloud pages into
    each other - A4-sized PDF by default - from PowerShell on Windows.

.DESCRIPTION
    Thin wrapper around the ghcr.io/b-arol-o/publish-md-pdf container image, so
    Windows users need Docker Desktop rather than a local pandoc/WeasyPrint
    install. Every parameter maps onto the image's own CLI flag; the only work
    this script does is translating host paths into the container's view of them
    (and back again, in the output it prints).

    $PWD is always bind-mounted at /workspace. Any input file, -OutputDir or
    -CssFile that resolves outside $PWD gets its own extra bind mount.

.PARAMETER Format
    Conversion to perform: pdf (Markdown to A4-sized PDF), confluence (Markdown
    to Confluence Storage Format), or md (Confluence Storage Format back to
    Markdown). Defaults to pdf, or to md when every input is a URL.

.PARAMETER OutputDir
    Directory to write the output file(s) into. Defaults to $PWD, and is created
    if it does not exist.

.PARAMETER OutputName
    Filename for the output. Only valid when converting a single input.

.PARAMETER CssFile
    Style sheet to use instead of the image's built-in publish-md-pdf.css. Only
    valid with -Format pdf.

.PARAMETER NoAttachments
    Skip downloading the attachments of a fetched Confluence Cloud page. Image
    and file references are still rewritten, but point at files that were never
    downloaded.

.PARAMETER InputPath
    One or more Markdown/Confluence files, or Confluence Cloud page URLs. A URL
    is fetched via the REST API, which needs CONFLUENCE_EMAIL and
    CONFLUENCE_API_TOKEN in the environment (ATLASSIAN_EMAIL and
    ATLASSIAN_API_TOKEN are accepted as aliases).

.EXAMPLE
    .\scripts\publish-md-pdf.ps1 report.md

.EXAMPLE
    .\scripts\publish-md-pdf.ps1 -Format confluence -OutputDir dist report.md

.EXAMPLE
    $env:CONFLUENCE_EMAIL = 'me@example.com'
    $env:CONFLUENCE_API_TOKEN = 'xxx'
    .\scripts\publish-md-pdf.ps1 https://example.atlassian.net/wiki/x/AbCdEf

.LINK
    https://github.com/B-AROL-O/publish-md-pdf
#>

[CmdletBinding()]
param(
    [ValidateSet('pdf', 'confluence', 'md')]
    [string]$Format,

    [string]$OutputDir,

    [string]$OutputName,

    [string]$CssFile,

    [switch]$NoAttachments,

    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InputPath
)

Set-StrictMode -Version Latest
# Native stderr arrives through the pipeline below; 'Stop' would turn each of
# the image's own diagnostics into a terminating error instead of a printed line.
$ErrorActionPreference = 'Continue'

# $IsWindows only exists in PowerShell 6+; on Windows PowerShell 5.1 the absence
# of it is itself the answer.
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

# Overridable so a locally built image can be tested without editing this file.
$image = if ($env:PUBLISH_MD_PDF_IMAGE) { $env:PUBLISH_MD_PDF_IMAGE } else { 'ghcr.io/b-arol-o/publish-md-pdf:v2' }

function Write-ErrorLine {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Test-IsUrl {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value -match '^https?://'
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-ErrorLine "ERROR: 'docker' is not installed or not on PATH. Install Docker Desktop: https://docs.docker.com/desktop/setup/install/windows-install/"
    exit 1
}

# 'docker' being on PATH doesn't mean the daemon behind it is reachable (Docker
# Desktop not started, the service stopped, ...); without this, that case falls
# through to whatever raw error the eventual 'docker run' happens to print.
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-ErrorLine "ERROR: Docker is installed, but the daemon isn't running (or not reachable). Start Docker Desktop and try again."
    exit 1
}

# Which format is in effect decides what the file inputs must look like. The
# image applies the same default - pdf, unless every input is a URL, in which
# case the page's own Markdown - so only an explicit -Format is passed on.
$effectiveFormat = $Format
if (-not $effectiveFormat) {
    $effectiveFormat = if (@($InputPath | Where-Object { -not (Test-IsUrl $_) }).Count -eq 0) { 'md' } else { 'pdf' }
}

if ($effectiveFormat -eq 'md') {
    $sourceExtension = '.confluence'
    $sourceLabel = 'Confluence Storage Format (.confluence)'
}
else {
    $sourceExtension = '.md'
    $sourceLabel = 'Markdown (.md)'
}

if ($CssFile -and $effectiveFormat -ne 'pdf') {
    Write-ErrorLine "ERROR: -CssFile is only valid with -Format pdf (got -Format $effectiveFormat)"
    exit 1
}

# A POSIX shell expands "docs/*.md" before the bash wrapper ever sees it;
# PowerShell hands a script parameter the pattern verbatim, so expand it here to
# keep both wrappers accepting the same command line. This has to happen before
# the -OutputName check below, which counts inputs after expansion.
$expandedInputs = [System.Collections.Generic.List[string]]::new()
foreach ($item in $InputPath) {
    if (Test-IsUrl $item) {
        $expandedInputs.Add($item)
        continue
    }
    $matched = @(Resolve-Path -Path $item -ErrorAction SilentlyContinue)
    if ($matched.Count -eq 0) {
        Write-ErrorLine "ERROR: File not found: $item"
        exit 1
    }
    foreach ($match in $matched) {
        $expandedInputs.Add($match.ProviderPath)
    }
}

if ($OutputName -and $expandedInputs.Count -gt 1) {
    Write-ErrorLine 'ERROR: -OutputName can only be used with a single input'
    exit 1
}

# The container only sees paths under bind-mounted directories. Docker Desktop
# accepts a Windows path in -v as long as the separators are forward slashes.
$mounts = [System.Collections.Generic.List[string]]::new()
$workingDir = (Get-Location).ProviderPath
$mounts.AddRange([string[]]@('-v', "$($workingDir -replace '\\', '/'):/workspace"))

# Host directories outside $PWD, in the order they were first seen: index N is
# bind-mounted at /mnt/extra-N. This also drives the reverse translation of the
# image's output at the end of this script.
$extraHosts = [System.Collections.Generic.List[string]]::new()
$pathComparison = if ($onWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }

function Get-ContainerDir {
    param([Parameter(Mandatory = $true)][string]$HostDir)

    if ([string]::Equals($HostDir, $workingDir, $pathComparison)) {
        return '/workspace'
    }
    if ($HostDir.StartsWith($workingDir + [System.IO.Path]::DirectorySeparatorChar, $pathComparison)) {
        return '/workspace/' + ($HostDir.Substring($workingDir.Length + 1) -replace '\\', '/')
    }

    for ($i = 0; $i -lt $extraHosts.Count; $i++) {
        if ([string]::Equals($extraHosts[$i], $HostDir, $pathComparison)) {
            return "/mnt/extra-$i"
        }
    }
    $extraHosts.Add($HostDir)
    $index = $extraHosts.Count - 1
    $mounts.AddRange([string[]]@('-v', "$($HostDir -replace '\\', '/'):/mnt/extra-$index"))
    return "/mnt/extra-$index"
}

function Get-ContainerPath {
    param([Parameter(Mandatory = $true)][string]$HostPath)

    # Resolve-Path rather than Join-Path + GetFullPath: on a Unix host the
    # latter keeps $PWD in front of an already-absolute $HostPath, which would
    # place the file under /workspace instead of its own bind mount. Every
    # caller has already checked that the path exists.
    $resolved = (Resolve-Path -LiteralPath $HostPath).ProviderPath
    $containerDir = Get-ContainerDir ([System.IO.Path]::GetDirectoryName($resolved))
    return ($containerDir.TrimEnd('/') + '/' + [System.IO.Path]::GetFileName($resolved))
}

$cliArgs = [System.Collections.Generic.List[string]]::new()

if ($Format) {
    $cliArgs.AddRange([string[]]@('--format', $Format))
}
if ($OutputDir) {
    $created = New-Item -ItemType Directory -Force -Path $OutputDir
    $cliArgs.AddRange([string[]]@('--output-dir', (Get-ContainerDir $created.FullName)))
}
if ($OutputName) {
    $cliArgs.AddRange([string[]]@('--output-name', $OutputName))
}
if ($CssFile) {
    if (-not (Test-Path -LiteralPath $CssFile -PathType Leaf)) {
        Write-ErrorLine "ERROR: CSS file not found: $CssFile"
        exit 1
    }
    $cliArgs.AddRange([string[]]@('--css-file', (Get-ContainerPath $CssFile)))
}
if ($NoAttachments) {
    $cliArgs.Add('--no-attachments')
}

foreach ($item in $expandedInputs) {
    # URLs are passed through untouched: the image fetches them itself.
    if (Test-IsUrl $item) {
        $cliArgs.Add($item)
        continue
    }
    # A wildcard can match a directory; like the bash wrapper, refuse anything
    # that isn't a file of the format's source type rather than skipping it.
    if (-not (Test-Path -LiteralPath $item -PathType Leaf)) {
        Write-ErrorLine "ERROR: Not a file: $item"
        exit 1
    }
    if ([System.IO.Path]::GetExtension($item) -ne $sourceExtension) {
        Write-ErrorLine "ERROR: Not a $sourceLabel file: $item"
        exit 1
    }
    $cliArgs.Add((Get-ContainerPath $item))
}

# The image reads Confluence credentials from the environment only, so they are
# forwarded by name: passing them as -e VAR=value would expose the API token in
# the process list. ATLASSIAN_* is accepted as an alias for either.
if (-not $env:CONFLUENCE_EMAIL -and $env:ATLASSIAN_EMAIL) {
    $env:CONFLUENCE_EMAIL = $env:ATLASSIAN_EMAIL
}
if (-not $env:CONFLUENCE_API_TOKEN -and $env:ATLASSIAN_API_TOKEN) {
    $env:CONFLUENCE_API_TOKEN = $env:ATLASSIAN_API_TOKEN
}

$envArgs = [System.Collections.Generic.List[string]]::new()
# PUBLISH_MD_PDF_ALLOW_INSECURE lets the image fetch over plain http, for a
# local test server; it is forwarded so it can be set without editing this.
foreach ($name in @('CONFLUENCE_EMAIL', 'CONFLUENCE_API_TOKEN', 'PUBLISH_MD_PDF_ALLOW_INSECURE')) {
    if ([Environment]::GetEnvironmentVariable($name)) {
        $envArgs.AddRange([string[]]@('-e', $name))
    }
}

$userArgs = [System.Collections.Generic.List[string]]::new()
if (-not $onWindows) {
    # The image always runs as root (the GitHub Action needs that), which on a
    # Linux/macOS host leaves root-owned output in the bind mount. HOME=/tmp is
    # what lets Puppeteer render Mermaid diagrams under a UID that has no
    # /etc/passwd entry. Docker Desktop on Windows already maps ownership back.
    $userArgs.AddRange([string[]]@('--user', "$(id -u):$(id -g)", '-e', 'HOME=/tmp'))
}

$dockerArgs = @('run', '--rm') + $userArgs + $envArgs + $mounts + @($image) + $cliArgs
Write-Verbose "docker $($dockerArgs -join ' ')"

# The image's own INFO/ERROR messages report paths as it sees them inside the
# container (e.g. "/workspace/foo.pdf", "/mnt/extra-0/bar.css"), which is
# confusing on the host. Translate them back to host paths before printing.
# Highest index first, so "/mnt/extra-1" can't eat the prefix of "/mnt/extra-10".
& docker $dockerArgs 2>&1 | ForEach-Object {
    $line = [string]$_
    for ($i = $extraHosts.Count - 1; $i -ge 0; $i--) {
        $line = $line.Replace("/mnt/extra-$i", $extraHosts[$i])
    }
    Write-Output $line.Replace('/workspace', $workingDir)
}
exit $LASTEXITCODE

# EOF
