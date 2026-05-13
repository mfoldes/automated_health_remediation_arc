#Requires -Version 5.1

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:WorkbookPath = Join-Path $script:RepoRoot 'workbook/arc-remediator-workbook.json'
}

Describe 'workbook/arc-remediator-workbook.json' {

    It 'exists' {
        (Test-Path -LiteralPath $script:WorkbookPath) | Should -BeTrue
    }

    It 'is valid JSON' {
        $raw = Get-Content -LiteralPath $script:WorkbookPath -Raw
        { $raw | ConvertFrom-Json } | Should -Not -Throw
    }

    Context 'Top-level shape' {
        BeforeEach {
            $script:Wb = (Get-Content -LiteralPath $script:WorkbookPath -Raw) | ConvertFrom-Json
        }
        It 'declares version Notebook/1.0' { $script:Wb.version | Should -Be 'Notebook/1.0' }
        It 'declares the Application-Insights-Workbooks schema' { $script:Wb.'$schema' | Should -Match 'Application-Insights-Workbooks' }
        It 'has at least one item' { @($script:Wb.items).Count | Should -BeGreaterThan 0 }
    }

    Context 'Spec-required tiles' {
        BeforeAll {
            $script:WbItems = ((Get-Content -LiteralPath $script:WorkbookPath -Raw) | ConvertFrom-Json).items
            $script:WbNames = @($script:WbItems | ForEach-Object { $_.name })
        }
        It 'has a silent-servers tile' { $script:WbNames | Should -Contain 'silent-servers' }
        It 'has an outcomes-by-cloud tile' { $script:WbNames | Should -Contain 'outcomes-by-cloud' }
        It 'has a blocked / needs-human tile' { $script:WbNames | Should -Contain 'blocked' }
        It 'has a ResourceNotFound tile' { $script:WbNames | Should -Contain 'resource-not-found' }
        It 'has an ARM-error timechart tile' { $script:WbNames | Should -Contain 'arm-errors-timechart' }
        It 'has an ARM-error table tile' { $script:WbNames | Should -Contain 'arm-errors-table' }
        It 'has an Expired-rejoin tile' { $script:WbNames | Should -Contain 'expired-rejoin' }
        It 'has a breakers tile' { $script:WbNames | Should -Contain 'breakers' }
        It 'has a version-drift tile' { $script:WbNames | Should -Contain 'version-drift' }
        It 'has an Observe-mode tile' { $script:WbNames | Should -Contain 'observe-hosts' }
    }

    Context 'KQL targets the ArcRemediation_CL table' {
        It 'every query item references the ArcRemediation_CL table' {
            $items = ((Get-Content -LiteralPath $script:WorkbookPath -Raw) | ConvertFrom-Json).items
            $queryItems = $items | Where-Object { $_.type -eq 3 }
            @($queryItems).Count | Should -BeGreaterThan 0
            foreach ($q in $queryItems) {
                $q.content.query | Should -Match 'ArcRemediation_CL'
            }
        }
    }
}
