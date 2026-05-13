@{
    Run = @{
        Path = 'tests/unit'
    }
    Output = @{
        Verbosity = 'Detailed'
    }
    TestResult = @{
        Enabled = $true
        OutputFormat = 'NUnitXml'
        OutputPath = 'TestResults/pester.xml'
    }
    CodeCoverage = @{
        Enabled = $false
    }
}
