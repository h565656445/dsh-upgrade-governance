$ErrorActionPreference = 'Stop'

# Pester 5 兼容化：初始化与辅助函数移入 BeforeAll（Discovery/Run 作用域隔离），
# 候选验证经 HERMES_HARNESS_ROOT 注入真实项目根；晋级后 $PSScriptRoot 兜底，行为等价。
BeforeAll {

    $script:HarnessRoot = $env:HERMES_HARNESS_ROOT
    if (-not $script:HarnessRoot) {
        $script:HarnessRoot = Split-Path -Parent $PSScriptRoot
    }
    $projectRoot = $script:HarnessRoot
$schemaModule = Join-Path $projectRoot 'src\HermesSchemaNegotiator.psm1'
$schemaRegistry = Join-Path $projectRoot 'schemas\schema_registry\registry.json'
$providerRegistry = Join-Path $projectRoot 'config\provider_registry.json'
$secretsPolicy = Join-Path $projectRoot 'config\secrets_policy.json'
$providerModule = Join-Path $projectRoot 'src\HermesProviderControl.psm1'
$asyncModule = Join-Path $projectRoot 'src\HermesAsyncJob.psm1'
$asyncEventSchema = Join-Path $projectRoot 'schemas\schema_registry\v0.2\async-job-event.schema.json'
$observationModule = Join-Path $projectRoot 'src\HermesObservationWriter.psm1'
$observationSchema = Join-Path $projectRoot 'schemas\schema_registry\v0.2\observation-event.schema.json'
$costProjectionSchema = Join-Path $projectRoot 'schemas\schema_registry\v0.2\cost-projection.schema.json'
$governanceModule = Join-Path $projectRoot 'src\HermesUpgradeGovernance.psm1'
$checklistPath = Join-Path $projectRoot 'config\upgate_checklist.json'
$checklistSchema = Join-Path $projectRoot 'schemas\schema_registry\v0.2\upgrade-checklist.schema.json'
$matrixV02 = Join-Path $projectRoot 'adapters\projects\adapter-matrix.v0.2.json'
$matrixV02Schema = Join-Path $projectRoot 'schemas\schema_registry\v0.2\adapter-matrix.schema.json'

function Get-JsonDocument {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
}

function Assert-UpgradeFailure {
    param([Parameter(Mandatory)][scriptblock]$Operation, [Parameter(Mandatory)][string]$Pattern)
    $caught = $null
    try { & $Operation | Out-Null } catch { $caught = $_ }
    $caught | Should -Not -BeNullOrEmpty
    $caught.Exception.Message | Should -Match $Pattern
}

function New-TestObservationEvidence {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$AsyncJobId,
        [Parameter(Mandatory)][string]$ProviderId,
        [Parameter(Mandatory)][string]$OutcomeState,
        [Parameter(Mandatory)][string]$Timestamp,
        [Parameter(Mandatory)][decimal]$CostCny,
        [Parameter(Mandatory)][int]$InputTokens,
        [Parameter(Mandatory)][int]$OutputTokens,
        [Parameter(Mandatory)][string]$EventSuffix,
        [Parameter(Mandatory)][string]$ProjectId
    )
    $contractSha256 = (('A' * 48) + $AsyncJobId.Substring($AsyncJobId.Length - 16)).ToUpperInvariant()
    $providerState = switch ($OutcomeState) { 'provider_succeeded' {'succeeded'} 'provider_failed' {'failed'} 'outcome_unknown' {'unknown'} }
    $jobRoot = Join-Path $RuntimeRoot "tasks\$TaskId\async_jobs\$AsyncJobId"
    $null = New-Item -ItemType Directory -Path $jobRoot -Force
    $event = [ordered]@{
        schema_identity = [ordered]@{schema_id='hermes.async_job_event';version='0.2';sha256=(Get-FileHash $asyncEventSchema).Hash}
        sequence = 1
        event_id = "async-event-$EventSuffix"
        timestamp = $Timestamp
        event_type = $OutcomeState
        async_job_id = $AsyncJobId
        intent_sha256 = 'B' * 64
        contract_sha256 = $contractSha256
        provider_id = $ProviderId
        provider_job_ref = "provider-job-$EventSuffix"
        observation_event_id = "provider-observation-$EventSuffix"
        observed_provider_id = $ProviderId
        observed_intent_sha256 = 'B' * 64
        observed_contract_sha256 = $contractSha256
        observed_state = $providerState
        trusted_source = $true
        changes_state = $true
        from_state = 'submitted'
        to_state = $OutcomeState
        reason = 'Test fixture representing verified active polling evidence.'
        hermes_completed = $false
    }
    $line = $event | ConvertTo-Json -Compress -Depth 100
    $line | Test-Json -SchemaFile $asyncEventSchema | Should -Be $true
    Set-Content -LiteralPath (Join-Path $jobRoot 'job_ledger.jsonl') -Value $line -Encoding utf8
    $lineSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($line)))
    [pscustomobject]@{
        event_id = "observation-event-$EventSuffix"
        timestamp = $Timestamp
        event_type = 'model_call'
        business_action = 'candidate_generation'
        contract_id = "task-contract-$EventSuffix"
        contract_sha256 = $contractSha256
        task_id = $TaskId
        project_id = $ProjectId
        provider_id = $ProviderId
        async_job_id = $AsyncJobId
        outcome_state = $OutcomeState
        cost_cny = $CostCny
        input_tokens = $InputTokens
        output_tokens = $OutputTokens
        ledger_sequence = 1
        ledger_event_sha256 = $lineSha256
    }
}

}

Describe 'Hermes adapter upgrade schema and provider control' {
    It 'validates the active 0.2 Provider Worker without requiring removed legacy manifests' {
        $manifest = Join-Path $projectRoot 'adapters\openai-agents-sdk-worker.v0.2.json'
        $schema = Join-Path $projectRoot 'schemas\schema_registry\v0.2\provider-worker-manifest.schema.json'
        (Get-Content -LiteralPath $manifest -Raw | Test-Json -SchemaFile $schema) | Should -Be $true
        (Get-JsonDocument $manifest).runtime_root | Should -Be 'runtime'
    }

    It 'binds every registered 0.2 protocol to an exact schema identity triple' {
        Test-Path $schemaModule | Should -Be $true
        Import-Module $schemaModule -Force
        $registry = Get-JsonDocument $schemaRegistry
        foreach ($entry in @($registry.schemas)) {
            $entry.schema_identity.schema_id | Should -Not -BeNullOrEmpty
            $entry.schema_identity.version | Should -Not -BeNullOrEmpty
            $entry.schema_identity.sha256 | Should -Match '^[A-F0-9]{64}$'
            $schemaPath = Join-Path $projectRoot $entry.path
            (Get-FileHash -LiteralPath $schemaPath -Algorithm SHA256).Hash | Should -Be $entry.schema_identity.sha256
        }

        $requested = $registry.schemas[0].schema_identity
        $selected = Invoke-HermesSchemaNegotiator -RequestedSchema $requested -ProducerSchemas @($requested) -ConsumerSchemas @($requested) -RegistryPath $schemaRegistry -RegistrySha256 (Get-FileHash $schemaRegistry).Hash
        $selected.schema_id | Should -Be $requested.schema_id
        $selected.version | Should -Be $requested.version
        $selected.sha256 | Should -Be $requested.sha256
        Assert-UpgradeFailure {
            Invoke-HermesSchemaNegotiator -RequestedSchema ([pscustomobject]@{schema_id=$requested.schema_id;version=$requested.version;sha256=('0' * 64)}) -ProducerSchemas @($requested) -ConsumerSchemas @($requested) -RegistryPath $schemaRegistry -RegistrySha256 (Get-FileHash $schemaRegistry).Hash
        } 'schema identity|hash'
    }

    It 'uses canonical provider ids and exact credential profile references without duplicate ownership' {
        $providers = Get-JsonDocument $providerRegistry
        $secrets = Get-JsonDocument $secretsPolicy
        @($providers.providers.provider_id) | Should -Be @('deterministic','deepseek','provider-b')
        ($providers.providers | Where-Object provider_id -eq 'deterministic').test_only | Should -Be $true
        ($providers.providers | Where-Object provider_id -eq 'deterministic').credential_profile_ref | Should -BeNullOrEmpty
        ($providers.providers | Where-Object provider_id -eq 'deepseek').credential_profile_ref | Should -Be 'cred-provider-a'
        ($providers.providers | Where-Object provider_id -eq 'provider-b').credential_profile_ref | Should -Be 'cred-provider-b'
        @($secrets.credential_profiles.credential_profile_id) | Should -Be @('cred-provider-a','cred-provider-b')

        $secretsText = Get-Content -LiteralPath $secretsPolicy -Raw
        $secretsText | Should -Not -Match '"provider_id"|"endpoint"|"model"|"cost"|"max_daily_calls"|"key_env_name"'
        $providerText = Get-Content -LiteralPath $providerRegistry -Raw
        $providerText | Should -Not -Match '"store_entry"|"rotation"|"access_audit"'
    }

    It 'keeps the Provider Adapter port internal and limited to Submit and Observe' {
        $worker = Get-JsonDocument (Join-Path $projectRoot 'adapters\openai-agents-sdk-worker.v0.2.json')
        $worker.provider_port.visibility | Should -Be 'async_job_internal'
        (@($worker.provider_port.operations) -join ',') | Should -Be 'Submit,Observe'
        $worker.provider_port.PSObject.Properties.Name | Should -Not -Contain 'get_unit_cost'
        $worker.provider_port.PSObject.Properties.Name | Should -Not -Contain 'prepare'
        $worker.provider_port.PSObject.Properties.Name | Should -Not -Contain 'reconcile'
        $worker.provider_port.pricing_owner | Should -Be 'provider_registry'
        foreach ($configRef in @($worker.config_refs)) {
            $configPath = Join-Path $projectRoot ($configRef.path -replace '/', '\')
            (Get-FileHash $configPath).Hash | Should -Be $configRef.sha256
        }
    }

    It 'prepares a provider selection from registry facts and rejects test providers unless explicitly allowed' {
        Test-Path $providerModule | Should -Be $true
        $loaded = Import-Module $providerModule -Force -PassThru
        (@($loaded.ExportedCommands.Keys) -join ',') | Should -Be 'Invoke-HermesProviderControl'
        $contract = Join-Path $TestDrive 'contract.json'
        Set-Content -LiteralPath $contract -Value '{"schema_version":"1.0","task_id":"task-provider-test"}' -Encoding utf8
        $common = @{
            ProviderRegistryPath = $providerRegistry
            ProviderRegistrySha256 = (Get-FileHash $providerRegistry).Hash
            SecretsPolicyPath = $secretsPolicy
            SecretsPolicySha256 = (Get-FileHash $secretsPolicy).Hash
            TaskContractPath = $contract
            TaskContractSha256 = (Get-FileHash $contract).Hash
        }
        Assert-UpgradeFailure {
            Invoke-HermesProviderControl -Action PrepareSelection -ProviderId deterministic -Capability 'text.candidate' @common
        } 'test-only'
        $selection = Invoke-HermesProviderControl -Action PrepareSelection -ProviderId deepseek -Capability 'contract.fixture_record' @common
        $selection.provider_id | Should -Be 'deepseek'
        $selection.credential_profile_ref | Should -Be 'cred-provider-a'
        (@($selection.provider_port_operations) -join ',') | Should -Be 'Submit,Observe'
        $selection.pricing_owner | Should -Be 'provider_registry'
        $selection.third_party_success_is_hermes_completion | Should -Be $false
    }

    It 'resolves an exact credential profile without environment access and audits only metadata' {
        Import-Module $providerModule -Force
        $runtime = Join-Path $TestDrive 'runtime'
        $script:resolvedStoreEntry = $null
        $reader = {
            param($StoreEntry)
            $script:resolvedStoreEntry = $StoreEntry
            ConvertTo-SecureString 'fixture-secret-that-must-not-be-logged' -AsPlainText -Force
        }
        $resolved = Invoke-HermesProviderControl -Action ResolveCredential -CredentialProfileRef 'cred-provider-a' -CallerAdapterId 'hermes-provider-worker-v0.2' -Capability 'contract.fixture_record' -SecretsPolicyPath $secretsPolicy -SecretsPolicySha256 (Get-FileHash $secretsPolicy).Hash -RuntimeRoot $runtime -CredentialReader $reader
        $script:resolvedStoreEntry | Should -Be 'hermes_provider_a'
        $resolved.credential | Should -BeOfType ([Security.SecureString])
        $resolved.credential_profile_id | Should -Be 'cred-provider-a'
        $auditPath = Join-Path $runtime '_security\credential_access.jsonl'
        Test-Path $auditPath | Should -Be $true
        $auditText = Get-Content -LiteralPath $auditPath -Raw
        $audit = $auditText | ConvertFrom-Json
        $audit.event_type | Should -Be 'credential_access'
        $audit.result | Should -Be 'success'
        $auditText | Should -Not -Match 'fixture-secret|"action"|"provider_id"'

        $moduleText = Get-Content -LiteralPath $providerModule -Raw
        $moduleText | Should -Not -Match '(?i)GetEnvironmentVariable|Env:|DEEPSEEK_API_KEY|DASHSCOPE_API_KEY'

        $roguePolicy = Join-Path $TestDrive 'rogue-secrets-policy.json'
        Copy-Item -LiteralPath $secretsPolicy -Destination $roguePolicy
        Assert-UpgradeFailure {
            Invoke-HermesProviderControl -Action ResolveCredential -CredentialProfileRef 'cred-provider-a' -CallerAdapterId 'hermes-provider-worker-v0.2' -Capability 'contract.fixture_record' -SecretsPolicyPath $roguePolicy -SecretsPolicySha256 (Get-FileHash $roguePolicy).Hash -RuntimeRoot $runtime -CredentialReader $reader
        } 'Worker manifest|canonical'

        $escapeRuntime = Join-Path $TestDrive 'escape-runtime'
        $escapeTarget = Join-Path $TestDrive 'escape-target'
        $null = New-Item -ItemType Directory -Path $escapeRuntime,$escapeTarget -Force
        $null = New-Item -ItemType Junction -Path (Join-Path $escapeRuntime '_security') -Target $escapeTarget
        Assert-UpgradeFailure {
            Invoke-HermesProviderControl -Action ResolveCredential -CredentialProfileRef 'cred-provider-a' -CallerAdapterId 'hermes-provider-worker-v0.2' -Capability 'contract.fixture_record' -SecretsPolicyPath $secretsPolicy -SecretsPolicySha256 (Get-FileHash $secretsPolicy).Hash -RuntimeRoot $escapeRuntime -CredentialReader $reader
        } 'reparse point'
        Test-Path (Join-Path $escapeTarget 'credential_access.jsonl') | Should -Be $false
    }

    It 'keeps untrusted callbacks as security evidence without changing async job state' {
        Test-Path $asyncModule | Should -Be $true
        $loaded = Import-Module $asyncModule -Force -PassThru
        (@($loaded.ExportedCommands.Keys) -join ',') | Should -Be 'Invoke-HermesAsyncJob'
        $runtime = Join-Path $TestDrive 'async-untrusted'
        $contractHash = 'A' * 64
        $requestHash = 'B' * 64
        $prepared = Invoke-HermesAsyncJob -Action Prepare -RuntimeRoot $runtime -TaskId 'task-async-untrusted' -ContractSha256 $contractHash -AdapterId 'hermes-provider-worker-v0.2' -ProviderId 'deepseek' -RequestSha256 $requestHash -BudgetCny 1.50
        $prepared.state | Should -Be 'prepared'
        $submitted = Invoke-HermesAsyncJob -Action Submit -RuntimeRoot $runtime -JobPath $prepared.job_path -ProviderJobRef 'provider-job-001'
        $submitted.state | Should -Be 'submitted'

        $rejected = Invoke-HermesAsyncJob -Action Observe -RuntimeRoot $runtime -JobPath $prepared.job_path -ObservationEventId 'callback-untrusted-001' -ObservedProviderId 'deepseek' -ObservedIntentSha256 $prepared.intent_sha256 -ObservedContractSha256 $contractHash -ProviderState succeeded -ProviderJobRef 'provider-job-001'
        $rejected.state | Should -Be 'submitted'
        $rejected.event_type | Should -Be 'security_callback_rejected'
        $rejected.state_changed | Should -Be $false

        $inspected = Invoke-HermesAsyncJob -Action Inspect -RuntimeRoot $runtime -JobPath $prepared.job_path
        $inspected.state | Should -Be 'submitted'
        $events = @(Get-Content -LiteralPath (Join-Path $prepared.job_path 'job_ledger.jsonl'))
        foreach ($line in $events) { ($line | Test-Json -SchemaFile $asyncEventSchema) | Should -Be $true }
        $last = $events[-1] | ConvertFrom-Json
        $last.event_type | Should -Be 'security_callback_rejected'
        $last.from_state | Should -Be 'submitted'
        $last.to_state | Should -Be 'submitted'
        $last.changes_state | Should -Be $false
        $last.hermes_completed | Should -Be $false

        $malformed = Invoke-HermesAsyncJob -Action Observe -RuntimeRoot $runtime -JobPath $prepared.job_path -ObservationEventId 'callback-untrusted-malformed-001' -ObservedProviderId 'deepseek' -ObservedIntentSha256 'not-a-hash' -ObservedContractSha256 'also-not-a-hash' -ProviderState unknown -ProviderJobRef 'provider-job-001'
        $malformed.state | Should -Be 'submitted'
        $malformed.event_type | Should -Be 'security_callback_rejected'
        $malformed.state_changed | Should -Be $false
    }

    It 'repairs a prepared intent left before the initial async Ledger event' {
        Import-Module $asyncModule -Force
        $runtime = Join-Path $TestDrive 'async-prepare-recovery'
        $parameters = @{
            Action='Prepare';RuntimeRoot=$runtime;TaskId='task-async-recovery';ContractSha256=('7' * 64)
            AdapterId='hermes-provider-worker-v0.2';ProviderId='deepseek';RequestSha256=('8' * 64);BudgetCny=1
        }
        $first = Invoke-HermesAsyncJob @parameters
        $intentHash = (Get-FileHash (Join-Path $first.job_path 'intent.json')).Hash
        Remove-Item -LiteralPath (Join-Path $first.job_path 'job_ledger.jsonl') -Force
        $recovered = Invoke-HermesAsyncJob @parameters
        $recovered.state | Should -Be 'prepared'
        (Get-FileHash (Join-Path $first.job_path 'intent.json')).Hash | Should -Be $intentHash
        @(Get-Content (Join-Path $first.job_path 'job_ledger.jsonl')).Count | Should -Be 1
    }

    It 'keeps terminal observations fail closed until signed callback or active polling evidence exists' {
        Import-Module $asyncModule -Force
        $runtime = Join-Path $TestDrive 'async-trusted'
        $prepared = Invoke-HermesAsyncJob -Action Prepare -RuntimeRoot $runtime -TaskId 'task-async-trusted' -ContractSha256 ('C' * 64) -AdapterId 'hermes-provider-worker-v0.2' -ProviderId 'provider-b' -RequestSha256 ('D' * 64) -BudgetCny 2
        $null = Invoke-HermesAsyncJob -Action Submit -RuntimeRoot $runtime -JobPath $prepared.job_path -ProviderJobRef 'provider-job-002'
        $unknown = Invoke-HermesAsyncJob -Action Observe -RuntimeRoot $runtime -JobPath $prepared.job_path -ObservationEventId 'poll-unverified-unknown-001' -ObservedProviderId 'provider-b' -ObservedIntentSha256 $prepared.intent_sha256 -ObservedContractSha256 ('C' * 64) -ProviderState unknown -ProviderJobRef 'provider-job-002'
        $unknown.state | Should -Be 'submitted'
        $unknown.event_type | Should -Be 'security_callback_rejected'
        $unknown.hermes_completed | Should -Be $false

        $duplicate = Invoke-HermesAsyncJob -Action Observe -RuntimeRoot $runtime -JobPath $prepared.job_path -ObservationEventId 'poll-unverified-unknown-001' -ObservedProviderId 'provider-b' -ObservedIntentSha256 $prepared.intent_sha256 -ObservedContractSha256 ('C' * 64) -ProviderState unknown -ProviderJobRef 'provider-job-002'
        $duplicate.duplicate_observation | Should -Be $true
        Assert-UpgradeFailure {
            Invoke-HermesAsyncJob -Action Observe -RuntimeRoot $runtime -JobPath $prepared.job_path -ObservationEventId 'poll-unverified-unknown-001' -ObservedProviderId 'deepseek' -ObservedIntentSha256 $prepared.intent_sha256 -ObservedContractSha256 ('C' * 64) -ProviderState unknown -ProviderJobRef 'provider-job-002'
        } 'conflicting content'
        Assert-UpgradeFailure {
            Invoke-HermesAsyncJob -Action Inspect -RuntimeRoot (Join-Path $TestDrive 'other-root') -JobPath $prepared.job_path
        } 'RuntimeRoot'
        $asyncSource = Get-Content -LiteralPath $asyncModule -Raw
        $runnerSource = Get-Content -LiteralPath (Join-Path $projectRoot 'runner\async_job_protocol.ps1') -Raw
        $asyncSource | Should -Not -Match 'CallbackTrusted'
        $runnerSource | Should -Not -Match 'CallbackTrusted'
    }

    It 'writes observations with provider_id, event_type, and business_action as distinct fields' {
        Test-Path $observationModule | Should -Be $true
        $loaded = Import-Module $observationModule -Force -PassThru
        (@($loaded.ExportedCommands.Keys) -join ',') | Should -Be 'Invoke-HermesObservationWriter'
        $runtime = Join-Path $TestDrive 'observation-runtime'
        $observation = New-TestObservationEvidence -RuntimeRoot $runtime -TaskId 'task-observation-001' -AsyncJobId 'async-job-0123456789abcdef' -ProviderId 'deepseek' -OutcomeState 'provider_failed' -Timestamp '2026-07-23T01:00:00Z' -CostCny 0.25 -InputTokens 120 -OutputTokens 30 -EventSuffix '0123456789abcdef' -ProjectId 'ai_content'
        $written = Invoke-HermesObservationWriter -Action AppendObservation -RuntimeRoot $runtime -Observation $observation
        $written.appended | Should -Be $true
        $line = Get-Content -LiteralPath $written.event_log_path -Raw
        ($line | Test-Json -SchemaFile $observationSchema) | Should -Be $true
        $document = $line | ConvertFrom-Json
        $document.provider_id | Should -Be 'deepseek'
        $document.event_type | Should -Be 'model_call'
        $document.business_action | Should -Be 'candidate_generation'
        $line | Should -Not -Match '"provider"\s*:|"action"\s*:'
        $document.non_authoritative | Should -Be $true
    }

    It 'atomically rebuilds cost_projection by actual receipts including failed and unknown outcomes' {
        Import-Module $observationModule -Force
        $runtime = Join-Path $TestDrive 'cost-runtime'
        $receipts = @(
            (New-TestObservationEvidence -RuntimeRoot $runtime -TaskId 'task-cost-success' -AsyncJobId 'async-job-0000000000000001' -ProviderId 'deepseek' -OutcomeState 'provider_succeeded' -Timestamp '2026-07-23T01:00:00Z' -CostCny 0.10 -InputTokens 100 -OutputTokens 20 -EventSuffix '0000000000000001' -ProjectId 'ai_content'),
            (New-TestObservationEvidence -RuntimeRoot $runtime -TaskId 'task-cost-failed' -AsyncJobId 'async-job-0000000000000002' -ProviderId 'deepseek' -OutcomeState 'provider_failed' -Timestamp '2026-07-23T02:00:00Z' -CostCny 0.20 -InputTokens 200 -OutputTokens 0 -EventSuffix '0000000000000002' -ProjectId 'ai_content'),
            (New-TestObservationEvidence -RuntimeRoot $runtime -TaskId 'task-cost-unknown' -AsyncJobId 'async-job-0000000000000003' -ProviderId 'provider-b' -OutcomeState 'outcome_unknown' -Timestamp '2026-07-23T03:00:00Z' -CostCny 0.733924 -InputTokens 0 -OutputTokens 0 -EventSuffix '0000000000000003' -ProjectId 'ai_content')
        )
        foreach ($receipt in $receipts) { $null = Invoke-HermesObservationWriter -Action AppendObservation -RuntimeRoot $runtime -Observation $receipt }
        $rebuilt = Invoke-HermesObservationWriter -Action RebuildCostProjection -RuntimeRoot $runtime -ProjectionDateUtc '2026-07-23'
        (Split-Path -Leaf $rebuilt.projection_path) | Should -Be 'cost_projection_2026-07-23.json'
        $text = Get-Content -LiteralPath $rebuilt.projection_path -Raw
        ($text | Test-Json -SchemaFile $costProjectionSchema) | Should -Be $true
        $projection = $text | ConvertFrom-Json -Depth 100
        $projection.source_receipt_count | Should -Be 3
        (@($projection.included_outcomes) -join ',') | Should -Be 'outcome_unknown,provider_failed,provider_succeeded'
        [decimal]$projection.total_cost_cny | Should -Be ([decimal]1.033924)
        $projection.rebuildable | Should -Be $true
        $projection.non_authoritative | Should -Be $true

        $second = Invoke-HermesObservationWriter -Action RebuildCostProjection -RuntimeRoot $runtime -ProjectionDateUtc '2026-07-23' -ExpectedToken $rebuilt.token_sha256
        $second.token_sha256 | Should -Be $rebuilt.token_sha256
        $source = Get-Content -LiteralPath $observationModule -Raw
        $source | Should -Match 'Set-HermesJsonProjection'
        $source | Should -Not -Match '\[object\[\]\]\$Receipts'
        $source | Should -Not -Match 'cost_\$|cost_\{|cost_<date>|Add-Content|AppendAllText'
    }

    It 'makes G4 and G5 non-overridable and defines path authorization by authorities rather than drives' {
        $text = Get-Content -LiteralPath $checklistPath -Raw
        ($text | Test-Json -SchemaFile $checklistSchema) | Should -Be $true
        $checklist = $text | ConvertFrom-Json -Depth 100
        foreach ($gateId in @('G4','G5')) {
            ($checklist.gates | Where-Object gate_id -eq $gateId).overridable | Should -Be $false
        }
        $g2 = $checklist.gates | Where-Object gate_id -eq 'G2'
        $g2.check_type | Should -Be 'authority_path'
        $g2.authorities | Should -Contain 'project_registry'
        $g2.authorities | Should -Contain 'runtime_root'
        $g2.authorities | Should -Contain 'adapter_allowlist'
        $g2.authorities | Should -Contain 'contract_snapshot'
        $text | Should -Not -Match 'C:\\\\|C:\\Users|drive_letter|allowed_drives'
        $checklist.path_authorities.project_registry_path | Should -Be '<projects-root>\10-知识库\00-系统\项目注册表.md'
        $checklist.path_authorities.runtime_root | Should -Be 'runtime'
        (@($checklist.gates.gate_id) -join ',') | Should -Be 'G1,G2,G3,G4,G5,G6,G7,G8'
        @($checklist.gates | Where-Object overridable).Count | Should -Be 0
        $duplicateGates = $text | ConvertFrom-Json -Depth 100
        $duplicateGates.gates = @($duplicateGates.gates[0],$duplicateGates.gates[0],$duplicateGates.gates[0],$duplicateGates.gates[0],$duplicateGates.gates[0],$duplicateGates.gates[0],$duplicateGates.gates[0],$duplicateGates.gates[0])
        Assert-UpgradeFailure {
            ($duplicateGates | ConvertTo-Json -Depth 100) | Test-Json -SchemaFile $checklistSchema -ErrorAction Stop
        } 'duplicates'
    }

    It 'binds the active 0.2 matrix to the four-project Registry model' {
        $matrixText = Get-Content -LiteralPath $matrixV02 -Raw
        ($matrixText | Test-Json -SchemaFile $matrixV02Schema) | Should -Be $true
        $matrix = $matrixText | ConvertFrom-Json -Depth 100
        $matrix.runtime_root | Should -Be 'runtime'
        $matrix.third_party_success_is_hermes_completion | Should -Be $false
        $matrix.projects.Count | Should -Be 4
        (@($matrix.projects.id) -join ',') | Should -Be 'novel_workbench,ai_content,content_audit,data_collection'
        (@($matrix.projects.name) -join ',') | Should -Be '小说,AI内容创作,内容审计,数据收集'
        foreach ($project in @($matrix.projects)) {
            $project.min_schema_version | Should -Be '0.1'
            $project.max_schema_version | Should -Be '0.2'
        }
        $providerWorker = Join-Path $projectRoot ($matrix.provider_worker_manifest.path -replace '/', '\')
        (Get-FileHash $providerWorker).Hash | Should -Be $matrix.provider_worker_manifest.sha256

        $duplicateProjects = $matrixText | ConvertFrom-Json -Depth 100
        $duplicateProjects.projects = @($duplicateProjects.projects[0],$duplicateProjects.projects[0],$duplicateProjects.projects[0],$duplicateProjects.projects[0])
        Assert-UpgradeFailure {
            ($duplicateProjects | ConvertTo-Json -Depth 100) | Test-Json -SchemaFile $matrixV02Schema -ErrorAction Stop
        } 'duplicates'
    }

    It 'authorizes paths by an exact authority root and audits four current projects' {
        Test-Path $governanceModule | Should -Be $true
        $loaded = Import-Module $governanceModule -Force -PassThru
        (@($loaded.ExportedCommands.Keys) -join ',') | Should -Be 'Invoke-HermesUpgradeGovernance'
        $authorizedRoot = Join-Path $TestDrive 'authority-root'
        $outsideRoot = Join-Path $TestDrive 'outside-root'
        $null = New-Item -ItemType Directory -Path $authorizedRoot,$outsideRoot -Force
        $inside = Join-Path $authorizedRoot 'evidence.txt'; Set-Content $inside 'inside'
        $outside = Join-Path $outsideRoot 'evidence.txt'; Set-Content $outside 'outside'
        (Invoke-HermesUpgradeGovernance -Action TestAuthorizedPath -CandidatePath $inside -AuthorityRoots @($authorizedRoot)).authorized | Should -Be $true
        Assert-UpgradeFailure {
            Invoke-HermesUpgradeGovernance -Action TestAuthorizedPath -CandidatePath $outside -AuthorityRoots @($authorizedRoot)
        } 'authority root'
        $source = Get-Content -LiteralPath $governanceModule -Raw
        $source | Should -Not -Match 'C:\\\\|E:\\\\Projects|drive_letter|allowed_drives'

        Assert-UpgradeFailure {
            Invoke-HermesUpgradeGovernance -Action Audit -ProjectRoot $projectRoot -RuntimeRoot (Join-Path $TestDrive 'audit-runtime') -ProjectRegistryPath '<projects-root>\10-知识库\00-系统\项目注册表.md' -GeneratedRegistryPath (Join-Path $projectRoot 'generated\project_registry.json') -ChecklistPath $checklistPath -MatrixPath $matrixV02 -NoWrite
        } 'RuntimeRoot'
        $audit = Invoke-HermesUpgradeGovernance -Action Audit -ProjectRoot $projectRoot -RuntimeRoot (Join-Path $projectRoot 'runtime') -ProjectRegistryPath '<projects-root>\10-知识库\00-系统\项目注册表.md' -GeneratedRegistryPath (Join-Path $projectRoot 'generated\project_registry.json') -ChecklistPath $checklistPath -MatrixPath $matrixV02 -NoWrite
        $audit.passed | Should -Be $true
        $audit.artifact_hash_matches | Should -Be 2
        $audit.artifact_hash_expected | Should -Be 2
        $audit.g4_overridable | Should -Be $false
        $audit.g5_overridable | Should -Be $false
        $audit.audit_path | Should -BeNullOrEmpty
        $audit.gate_checks_passed | Should -Be 8
        $audit.project_bindings | Should -Be 4
        $audit.schema_registry_entries_verified | Should -BeGreaterThan 10
    }

    It 'routes 0.2 fixture recording through CredentialResolver and never through environment credentials' {
        $recordRunner = Join-Path $projectRoot 'contract_test\record_capture.ps1'
        Test-Path $recordRunner | Should -Be $true
        $source = Get-Content -LiteralPath $recordRunner -Raw
        $source | Should -Match 'Invoke-HermesProviderControl'
        $source | Should -Match "ResolveCredential"
        $source | Should -Match 'TaskContractPath'
        $source | Should -Match 'ProviderIntentPath'
        $source | Should -Match 'ManualStartApprovalPath'
        $source | Should -Match 'BudgetCny'
        $source | Should -Match 'Use-HermesManualStartApproval'
        $source | Should -Match 'approval_consumption'
        $source | Should -Match 'credential-like capture receipt'
        $source | Should -Not -Match '(?i)os\.environ|GetEnvironmentVariable|Env:|DEEPSEEK_API_KEY|DASHSCOPE_API_KEY'
        $manualApprovalModule = Join-Path $projectRoot 'src\HermesManualApproval.psm1'
        $manualSource = Get-Content -LiteralPath $manualApprovalModule -Raw
        $manualSource | Should -Match 'Set-HermesJsonProjection'
        Import-Module $manualApprovalModule -Force
        $probeRoot = Join-Path $TestDrive 'manual-approval-probe'
        $first = Use-HermesManualStartApproval -RuntimeRoot $probeRoot -TaskId 'task-approval-probe' -TaskContractSha256 ('A' * 64) -ProviderIntentSha256 ('B' * 64) -ManualStartApprovalSha256 ('C' * 64) -BudgetCny 1
        $first.document.single_use | Should -Be $true
        Assert-UpgradeFailure {
            Use-HermesManualStartApproval -RuntimeRoot $probeRoot -TaskId 'task-approval-probe' -TaskContractSha256 ('A' * 64) -ProviderIntentSha256 ('B' * 64) -ManualStartApprovalSha256 ('C' * 64) -BudgetCny 1
        } 'already consumed'
    }
}
