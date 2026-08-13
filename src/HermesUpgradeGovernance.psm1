Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleProjectRoot = Split-Path -Parent $PSScriptRoot
$jsonModule = Join-Path $PSScriptRoot 'HermesJsonProjection.psm1'
$checklistSchema = Join-Path $moduleProjectRoot 'schemas\schema_registry\v0.2\upgrade-checklist.schema.json'
$matrixSchema = Join-Path $moduleProjectRoot 'schemas\schema_registry\v0.2\adapter-matrix.schema.json'
$auditSchema = Join-Path $moduleProjectRoot 'schemas\schema_registry\v0.2\upgrade-audit.schema.json'
$providerWorkerSchema = Join-Path $moduleProjectRoot 'schemas\schema_registry\v0.2\provider-worker-manifest.schema.json'
$schemaRegistrySchema = Join-Path $moduleProjectRoot 'schemas\schema_registry\registry.schema.json'
$secretsPolicySchema = Join-Path $moduleProjectRoot 'schemas\schema_registry\v0.2\secrets-policy.schema.json'
Import-Module $jsonModule -Force
$fileIdentityModule = Join-Path $PSScriptRoot 'HermesFileIdentity.psm1'
Import-Module $fileIdentityModule -Force
$manualApprovalModule = Join-Path $PSScriptRoot 'HermesManualApproval.psm1'
Import-Module $manualApprovalModule -Force

function Read-HermesGovernanceFile {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Governance artifact not found: $full" }
    $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $null = Assert-HermesFileHandlePath -Handle $stream.SafeFileHandle -ExpectedPath $full -Label 'Governance artifact'
        $cursor = $full
        while (-not [string]::IsNullOrWhiteSpace($cursor)) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Governance artifact cannot traverse a reparse point.' }
            }
            $next = Split-Path -Parent $cursor
            if ([string]::IsNullOrWhiteSpace($next) -or $next -eq $cursor) { break }
            $cursor = $next
        }
        if ($stream.Length -gt 16MB) { throw 'Governance artifact exceeds the 16 MiB limit.' }
        $bytes = [byte[]]::new([int]$stream.Length)
        $read = 0
        while ($read -lt $bytes.Length) {
            $count = $stream.Read($bytes, $read, $bytes.Length - $read)
            if ($count -eq 0) { throw 'Governance artifact changed during stable read.' }
            $read += $count
        }
        [pscustomobject]@{
            path = $full
            text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        }
    }
    finally { $stream.Dispose() }
}

function ConvertFrom-HermesGovernanceJson {
    param([Parameter(Mandatory)]$Artifact, [string]$SchemaPath)
    $text = $Artifact.text
    if (-not [string]::IsNullOrWhiteSpace($SchemaPath) -and -not ($text | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop)) {
        throw "Governance artifact failed schema validation: $($Artifact.path)"
    }
    try { $text | ConvertFrom-Json -Depth 100 -ErrorAction Stop }
    catch { throw "Governance artifact is not valid JSON: $($Artifact.path)" }
}

function Read-HermesGovernanceJson {
    param([Parameter(Mandatory)][string]$Path, [string]$SchemaPath)
    $artifact = Read-HermesGovernanceFile -Path $Path
    ConvertFrom-HermesGovernanceJson -Artifact $artifact -SchemaPath $SchemaPath
}

function Test-HermesPathWithinRoot {
    param([Parameter(Mandatory)][string]$CandidatePath, [Parameter(Mandatory)][string]$AuthorityRoot)
    $candidate = [IO.Path]::GetFullPath($CandidatePath)
    $root = [IO.Path]::GetFullPath($AuthorityRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($candidate.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $candidate.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-HermesNoReparseEscape {
    param([Parameter(Mandatory)][string]$CandidatePath, [Parameter(Mandatory)][string]$AuthorityRoot)
    $candidate = [IO.Path]::GetFullPath($CandidatePath)
    $root = [IO.Path]::GetFullPath($AuthorityRoot)
    $cursor = if (Test-Path -LiteralPath $candidate) { $candidate } else { Split-Path -Parent $candidate }
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Authorized path cannot traverse a reparse point.' }
        }
        if ([IO.Path]::GetFullPath($cursor).Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return }
        $next = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($next) -or $next -eq $cursor) { break }
        $cursor = $next
    }
    throw 'Authorized path did not terminate at the selected authority root.'
}

function Invoke-HermesAuthorizedPathTest {
    param([Parameter(Mandatory)][string]$CandidatePath, [Parameter(Mandatory)][string[]]$AuthorityRoots)
    $matches = @($AuthorityRoots | Where-Object { Test-HermesPathWithinRoot -CandidatePath $CandidatePath -AuthorityRoot $_ })
    if ($matches.Count -eq 0) { throw 'Candidate path is outside every explicit authority root.' }
    $selectedMatch = $matches | Sort-Object Length -Descending | Select-Object -First 1
    $selected = [IO.Path]::GetFullPath([string]$selectedMatch)
    Assert-HermesNoReparseEscape -CandidatePath $CandidatePath -AuthorityRoot $selected
    [pscustomobject]@{
        authorized = $true
        candidate_path = [IO.Path]::GetFullPath($CandidatePath)
        authority_root = $selected
    }
}

function Resolve-HermesProjectArtifact {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath)) { throw 'Project artifact references must be relative.' }
    $full = [IO.Path]::GetFullPath((Join-Path $ProjectRoot ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)))
    $null = Invoke-HermesAuthorizedPathTest -CandidatePath $full -AuthorityRoots @($ProjectRoot)
    $full
}

function New-HermesGovernanceCheck {
    param([Parameter(Mandatory)][string]$CheckId, [Parameter(Mandatory)][bool]$Passed, [Parameter(Mandatory)][string]$Evidence)
    [pscustomobject][ordered]@{ check_id=$CheckId; passed=$Passed; evidence=$Evidence }
}

function Test-HermesCredentialExposureScope {
    param([Parameter(Mandatory)][string[]]$Paths)
    $patterns = @(
        '(?i)\b(?:api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|client[-_ ]?secret|password|cookie|密码|密钥|令牌)\b\s*[:=：]\s*["'']?(?!null\b|none\b|false\b|true\b|v0\.1_only\b)[^\s"'',}]{6,}',
        '(?i)(?:\bauthorization\s*[:=]\s*)?\bBearer\s+\S+',
        '(?i)\bsk-[A-Za-z0-9_-]{8,}',
        '-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'
    )
    $scanned = 0
    $findings = [Collections.Generic.List[string]]::new()
    foreach ($path in @($Paths | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $artifact = Read-HermesGovernanceFile -Path $path
        $scanned++
        foreach ($pattern in $patterns) {
            if ($artifact.text -match $pattern) {
                $findings.Add([IO.Path]::GetFullPath($path))
                break
            }
        }
    }
    [pscustomobject]@{ passed=($findings.Count -eq 0); scanned=$scanned; findings=@($findings) }
}

function Test-HermesManualApprovalGate {
    param([Parameter(Mandatory)][string]$RecordCapturePath)
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $probeRoot = Join-Path $temporaryBase ('hermes-g6-probe-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $probeRoot
    try {
        $first = Use-HermesManualStartApproval -RuntimeRoot $probeRoot -TaskId 'task-governance-g6-probe' -TaskContractSha256 ('A' * 64) -ProviderIntentSha256 ('B' * 64) -ManualStartApprovalSha256 ('C' * 64) -BudgetCny 1
        $replayRejected = $false
        try {
            $null = Use-HermesManualStartApproval -RuntimeRoot $probeRoot -TaskId 'task-governance-g6-probe' -TaskContractSha256 ('A' * 64) -ProviderIntentSha256 ('B' * 64) -ManualStartApprovalSha256 ('C' * 64) -BudgetCny 1
        } catch { $replayRejected = $_.Exception.Message -match 'already consumed' }
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($RecordCapturePath, [ref]$tokens, [ref]$errors)
        $calls = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Use-HermesManualStartApproval' }, $true))
        [pscustomobject]@{
            passed = $null -ne $first -and [bool]$first.document.single_use -and $replayRejected -and $errors.Count -eq 0 -and $calls.Count -eq 1
            replay_rejected = $replayRejected
            integration_calls = $calls.Count
        }
    }
    finally {
        $resolvedProbe = [IO.Path]::GetFullPath($probeRoot)
        if ($resolvedProbe.StartsWith($temporaryBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedProbe).StartsWith('hermes-g6-probe-', [StringComparison]::Ordinal)) {
            [IO.Directory]::Delete($resolvedProbe, $true)
        }
    }
}

function Invoke-HermesUpgradeAudit {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$ProjectRegistryPath,
        [Parameter(Mandatory)][string]$GeneratedRegistryPath,
        [Parameter(Mandatory)][string]$ChecklistPath,
        [Parameter(Mandatory)][string]$MatrixPath,
        [switch]$NoWrite
    )
    $root = [IO.Path]::GetFullPath($ProjectRoot)
    $null = Invoke-HermesAuthorizedPathTest -CandidatePath $ChecklistPath -AuthorityRoots @($root)
    $null = Invoke-HermesAuthorizedPathTest -CandidatePath $MatrixPath -AuthorityRoots @($root)
    $null = Invoke-HermesAuthorizedPathTest -CandidatePath $GeneratedRegistryPath -AuthorityRoots @($root)

    $checklistArtifact = Read-HermesGovernanceFile -Path $ChecklistPath
    $matrixArtifact = Read-HermesGovernanceFile -Path $MatrixPath
    $checklist = ConvertFrom-HermesGovernanceJson -Artifact $checklistArtifact -SchemaPath $checklistSchema
    $matrix = ConvertFrom-HermesGovernanceJson -Artifact $matrixArtifact -SchemaPath $matrixSchema
    $matrixRuntimeRoot = [string]$matrix.runtime_root
    $canonicalRuntimeRoot = if ([IO.Path]::IsPathRooted($matrixRuntimeRoot)) {
        [IO.Path]::GetFullPath($matrixRuntimeRoot)
    } else {
        [IO.Path]::GetFullPath((Join-Path $root $matrixRuntimeRoot))
    }
    $checklistRuntimeRoot = [string]$checklist.path_authorities.runtime_root
    $canonicalChecklistRuntimeRoot = if ([IO.Path]::IsPathRooted($checklistRuntimeRoot)) {
        [IO.Path]::GetFullPath($checklistRuntimeRoot)
    } else {
        [IO.Path]::GetFullPath((Join-Path $root $checklistRuntimeRoot))
    }
    if (-not [IO.Path]::GetFullPath($RuntimeRoot).Equals($canonicalRuntimeRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $canonicalChecklistRuntimeRoot.Equals($canonicalRuntimeRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Governance Audit RuntimeRoot must match the active checklist and v0.2 matrix RuntimeRoot authority.'
    }
    $generatedArtifact = Read-HermesGovernanceFile -Path $GeneratedRegistryPath
    $generated = ConvertFrom-HermesGovernanceJson -Artifact $generatedArtifact
    $registrySha = (Read-HermesGovernanceFile -Path $ProjectRegistryPath).sha256
    $generatedSha = $generatedArtifact.sha256
    $matrixSha = $matrixArtifact.sha256

    $checks = [Collections.Generic.List[object]]::new()
    $registryBindingPass = [string]$generated.source_path -ceq [IO.Path]::GetFullPath($ProjectRegistryPath) -and [string]$generated.source_sha256 -ceq $registrySha
    $checks.Add((New-HermesGovernanceCheck 'REGISTRY_BINDING' $registryBindingPass 'Generated registry source path and SHA-256 match the current project registry.'))

    $schemaRegistryPath = Resolve-HermesProjectArtifact -ProjectRoot $root -RelativePath ([string]$matrix.schema_registry_ref.path)
    $schemaRegistryArtifact = Read-HermesGovernanceFile -Path $schemaRegistryPath
    $schemaRegistryText = $schemaRegistryArtifact.text
    $schemaRegistry = ConvertFrom-HermesGovernanceJson -Artifact $schemaRegistryArtifact -SchemaPath $schemaRegistrySchema
    $schemaRegistryPass = $schemaRegistryArtifact.sha256 -ceq [string]$matrix.schema_registry_ref.sha256
    $schemaRegistryEntriesVerified = 0
    $schemaIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($schemaRegistry.schemas)) {
        $identityKey = '{0}|{1}|{2}' -f [string]$entry.schema_identity.schema_id, [string]$entry.schema_identity.version, [string]$entry.schema_identity.sha256
        $schemaPath = Resolve-HermesProjectArtifact -ProjectRoot $root -RelativePath ([string]$entry.path)
        if (-not $schemaIdentities.Add($identityKey) -or (Read-HermesGovernanceFile -Path $schemaPath).sha256 -cne [string]$entry.schema_identity.sha256) {
            $schemaRegistryPass = $false
        } else { $schemaRegistryEntriesVerified++ }
    }
    if ([string]$schemaRegistry.schema_identity.sha256 -cne (Read-HermesGovernanceFile -Path $schemaRegistrySchema).sha256) { $schemaRegistryPass = $false }
    $checks.Add((New-HermesGovernanceCheck 'SCHEMA_REGISTRY_CLOSURE' $schemaRegistryPass "$schemaRegistryEntriesVerified schema identity triples resolve to the registered bytes."))

    $providerWorkerPath = Resolve-HermesProjectArtifact -ProjectRoot $root -RelativePath ([string]$matrix.provider_worker_manifest.path)
    $providerWorkerArtifact = Read-HermesGovernanceFile -Path $providerWorkerPath
    $providerWorkerText = $providerWorkerArtifact.text
    $providerWorker = ConvertFrom-HermesGovernanceJson -Artifact $providerWorkerArtifact -SchemaPath $providerWorkerSchema
    $providerWorkerPass = $providerWorkerArtifact.sha256 -ceq [string]$matrix.provider_worker_manifest.sha256
    $checks.Add((New-HermesGovernanceCheck 'PROVIDER_WORKER_HASH' $providerWorkerPass 'The v0.2 provider Worker manifest hash and schema are valid.'))

    $canonicalProjectIds = @('novel_workbench','ai_content','content_audit','data_collection')
    $projectBindings = 0
    foreach ($projectId in $canonicalProjectIds) {
        $matrixProject = @($matrix.projects | Where-Object { [string]$_.id -ceq $projectId })
        $registeredProject = @($generated.projects | Where-Object { [string]$_.id -ceq $projectId })
        if ($matrixProject.Count -eq 1 -and $registeredProject.Count -eq 1 -and
            [string]$matrixProject[0].name -ceq [string]$registeredProject[0].name) {
            $projectBindings++
        }
    }
    $projectModelPass = [int]$matrix.business_project_count -eq 4 -and
        @($matrix.projects).Count -eq 4 -and @($generated.projects).Count -eq 4 -and
        $projectBindings -eq 4
    $artifactHashMatches = 0
    if ($schemaRegistryArtifact.sha256 -ceq [string]$matrix.schema_registry_ref.sha256) { $artifactHashMatches++ }
    if ($providerWorkerArtifact.sha256 -ceq [string]$matrix.provider_worker_manifest.sha256) { $artifactHashMatches++ }

    $gateIds = @($checklist.gates.gate_id)
    $gateDefinitionPass = ($gateIds -join ',') -ceq 'G1,G2,G3,G4,G5,G6,G7,G8' -and @($checklist.gates | Where-Object { [bool]$_.overridable }).Count -eq 0
    $secretsPolicyPath = Resolve-HermesProjectArtifact -ProjectRoot $root -RelativePath 'config/secrets_policy.json'
    $secretsPolicyText = Get-Content -LiteralPath $secretsPolicyPath -Raw
    $providerControlSource = Get-Content -LiteralPath (Join-Path $root 'src\HermesProviderControl.psm1') -Raw
    $credentialScanPaths = [Collections.Generic.List[string]]::new()
    foreach ($path in @($ChecklistPath,$MatrixPath,$schemaRegistryPath,$providerWorkerPath,$secretsPolicyPath,(Join-Path $root 'config\provider_registry.json'),(Join-Path $root 'runner\async_job_protocol.ps1'),(Join-Path $root 'contract_test\record_capture.ps1'))) { $credentialScanPaths.Add([IO.Path]::GetFullPath($path)) }
    foreach ($sourceName in @('HermesFileIdentity.psm1','HermesManualApproval.psm1','HermesSchemaNegotiator.psm1','HermesProviderControl.psm1','HermesAsyncJob.psm1','HermesObservationWriter.psm1','HermesUpgradeGovernance.psm1')) { $credentialScanPaths.Add((Join-Path $root "src\$sourceName")) }
    foreach ($entry in @($schemaRegistry.schemas)) { $credentialScanPaths.Add((Resolve-HermesProjectArtifact -ProjectRoot $root -RelativePath ([string]$entry.path))) }
    foreach ($evidenceRoot in @((Join-Path $canonicalRuntimeRoot '_security'),(Join-Path $canonicalRuntimeRoot '_audits'))) {
        if (Test-Path -LiteralPath $evidenceRoot -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $evidenceRoot -File -Force)) { $credentialScanPaths.Add($file.FullName) }
        }
    }
    $credentialScan = Test-HermesCredentialExposureScope -Paths @($credentialScanPaths)
    $g1Pass = ($secretsPolicyText | Test-Json -SchemaFile $secretsPolicySchema -ErrorAction Stop) -and $providerControlSource -notmatch '(?i)GetEnvironmentVariable|Env:|DEEPSEEK_API_KEY|DASHSCOPE_API_KEY' -and $credentialScan.passed
    $checks.Add((New-HermesGovernanceCheck 'G1_CREDENTIAL_EXPOSURE' $g1Pass "Secrets Policy and environment boundary validate; $($credentialScan.scanned) active v0.2 artifacts and security logs contain no credential-like value."))

    $configuredAuthorityPass = [string]$checklist.path_authorities.project_registry_path -ceq [IO.Path]::GetFullPath($ProjectRegistryPath) -and $canonicalChecklistRuntimeRoot.Equals($canonicalRuntimeRoot, [StringComparison]::OrdinalIgnoreCase)
    $g2Pass = $projectModelPass -and $configuredAuthorityPass
    $checks.Add((New-HermesGovernanceCheck 'G2_PATH_AUTHORITIES' $g2Pass 'The five active matrix identities match the generated Registry projection, and the project-local RuntimeRoot is exact.'))

    $forbiddenActions = @('publish','payment','delete','account_change','production_registration','formal_rule_write')
    $g3Pass = @($providerWorker.actions | Where-Object { $_ -in $forbiddenActions }).Count -eq 0 -and @($forbiddenActions | Where-Object { $providerWorker.denied -cnotcontains $_ }).Count -eq 0
    $checks.Add((New-HermesGovernanceCheck 'G3_REDLINE_CAPABILITIES' $g3Pass 'The Provider Worker exposes no redline action and explicitly denies every redline capability.'))

    $g4Pass = $schemaRegistryPass -and $projectModelPass
    $checks.Add((New-HermesGovernanceCheck 'G4_SCHEMA_COMPATIBILITY' $g4Pass 'The five-project matrix validates and every registered v0.2 schema identity closes to exact bytes.'))
    $g5Pass = $artifactHashMatches -eq 2 -and $providerWorkerPass
    $checks.Add((New-HermesGovernanceCheck 'G5_ARTIFACT_HASHES' $g5Pass "$artifactHashMatches of 2 active matrix artifact hashes match."))

    $recordCaptureSource = Get-Content -LiteralPath (Join-Path $root 'contract_test\record_capture.ps1') -Raw
    $manualApprovalProbe = Test-HermesManualApprovalGate -RecordCapturePath (Join-Path $root 'contract_test\record_capture.ps1')
    $g6Pass = $manualApprovalProbe.passed
    $checks.Add((New-HermesGovernanceCheck 'G6_HUMAN_REVIEW_GATE' $g6Pass 'The record runner calls the tested manual approval state machine once; the same approval hash is rejected on replay.'))

    $asyncSource = Get-Content -LiteralPath (Join-Path $root 'src\HermesAsyncJob.psm1') -Raw
    $asyncRunnerSource = Get-Content -LiteralPath (Join-Path $root 'runner\async_job_protocol.ps1') -Raw
    $g7Pass = $asyncSource -notmatch 'CallbackTrusted' -and $asyncRunnerSource -notmatch 'CallbackTrusted' -and $asyncSource -match '(?s)EventType ''security_callback_rejected''.*?-TrustedSource \$false' -and @($providerWorker.observation_trust.trusted_modes).Count -eq 0 -and -not [bool]$providerWorker.observation_trust.terminal_transition_enabled
    $checks.Add((New-HermesGovernanceCheck 'G7_CALLBACK_TRUST' $g7Pass 'No caller-asserted trust switch exists; unverified observations are security evidence and cannot change state.'))

    $g8Pass = -not [bool]$matrix.third_party_success_is_hermes_completion -and -not [bool]$providerWorker.completion.third_party_success_is_hermes_completion
    $checks.Add((New-HermesGovernanceCheck 'G8_COMPLETION_AUTHORITY' $g8Pass 'Third-party success is not Hermes completion in either the matrix or Worker manifest.'))
    $checks.Add((New-HermesGovernanceCheck 'GATE_DEFINITIONS' $gateDefinitionPass 'G1 through G8 exist exactly once, in order, and none is overridable.'))

    $g4 = @($checklist.gates | Where-Object gate_id -eq 'G4')
    $g5 = @($checklist.gates | Where-Object gate_id -eq 'G5')
    $gateChecksPassed = @($checks | Where-Object { $_.check_id -match '^G[1-8]_' -and $_.passed }).Count
    $passed = @($checks | Where-Object { -not $_.passed }).Count -eq 0
    $document = [ordered]@{
        schema_identity = [ordered]@{ schema_id='hermes.upgrade_audit'; version='0.2'; sha256=(Get-FileHash $auditSchema).Hash }
        audited_at = [DateTimeOffset]::UtcNow.ToString('o')
        passed = $passed
        project_registry_sha256 = $registrySha
        generated_registry_sha256 = $generatedSha
        matrix_sha256 = $matrixSha
        artifact_hash_matches = $artifactHashMatches
        artifact_hash_expected = 2
        gate_checks_passed = $gateChecksPassed
        project_bindings = $projectBindings
        schema_registry_entries_verified = $schemaRegistryEntriesVerified
        g4_overridable = [bool]$g4[0].overridable
        g5_overridable = [bool]$g5[0].overridable
        checks = @($checks)
        non_authoritative = $true
    }
    $auditPath = $null
    $auditToken = $null
    if (-not $NoWrite) {
        $auditRoot = Join-Path $canonicalRuntimeRoot '_audits'
        $null = New-Item -ItemType Directory -Path $auditRoot -Force
        $auditPath = Join-Path $auditRoot 'adapter_upgrade_audit.json'
        $snapshot = Get-HermesJsonSnapshot -Path $auditPath -AllowMissing
        $written = Set-HermesJsonProjection -Path $auditPath -Document $document -ExpectedToken $snapshot.token_sha256 -SchemaPath $auditSchema
        $auditToken = $written.token_sha256
    }
    [pscustomobject]@{
        passed = $passed
        artifact_hash_matches = $artifactHashMatches
        artifact_hash_expected = 2
        gate_checks_passed = $gateChecksPassed
        project_bindings = $projectBindings
        schema_registry_entries_verified = $schemaRegistryEntriesVerified
        g4_overridable = [bool]$g4[0].overridable
        g5_overridable = [bool]$g5[0].overridable
        audit_path = $auditPath
        token_sha256 = $auditToken
        checks = @($checks)
    }
}

function Invoke-HermesUpgradeGovernance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('TestAuthorizedPath', 'Audit')][string]$Action,
        [string]$CandidatePath,
        [string[]]$AuthorityRoots,
        [string]$ProjectRoot,
        [string]$RuntimeRoot,
        [string]$ProjectRegistryPath,
        [string]$GeneratedRegistryPath,
        [string]$ChecklistPath,
        [string]$MatrixPath,
        [switch]$NoWrite
    )
    if ($Action -eq 'TestAuthorizedPath') { return Invoke-HermesAuthorizedPathTest -CandidatePath $CandidatePath -AuthorityRoots $AuthorityRoots }
    Invoke-HermesUpgradeAudit -ProjectRoot $ProjectRoot -RuntimeRoot $RuntimeRoot -ProjectRegistryPath $ProjectRegistryPath -GeneratedRegistryPath $GeneratedRegistryPath -ChecklistPath $ChecklistPath -MatrixPath $MatrixPath -NoWrite:$NoWrite
}

Export-ModuleMember -Function 'Invoke-HermesUpgradeGovernance'
