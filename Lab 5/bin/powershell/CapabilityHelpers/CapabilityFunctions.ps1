function Add-CapabilityFromApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ApplicationName)

    Write-Host "Checking for application: '$ApplicationName'"
    $application =
        Get-Command -Name $ApplicationName -CommandType Application -ErrorAction Ignore |
        Select-Object -First 1
    if (!$application) {
        Write-Host "Not found."
        return
    }

    Write-Capability -Name $Name -Value $application.Path
}

function Add-CapabilityFromEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$VariableName,

        [ref]$Value)

    $path = "env:$VariableName"
    Write-Host "Checking: '$path'"
    $val = (Get-Item -LiteralPath $path -ErrorAction Ignore).Value
    if (!$val) {
        Write-Host "Value not found or is empty."
        return
    }

    Write-Capability -Name $Name -Value $val
    if ($Value) {
        $Value.Value = $val
    }
}

function Add-CapabilityFromRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string]$Hive,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Default', 'Registry32', 'Registry64')]
        [string]$View,

        [Parameter(Mandatory = $true)]
        [string]$KeyName,

        [Parameter(Mandatory = $true)]
        [string]$ValueName,

        [ref]$Value)

    $val = Get-RegistryValue -Hive $Hive -View $View -KeyName $KeyName -ValueName $ValueName
    if ($val -eq $null) {
        return $false
    }

    if ($val -is [string] -and $val -eq '') {
        return $false
    }

    Write-Capability -Name $Name -Value $val
    if ($Value) {
        $Value.Value = $val
    }

    return $true
}


function Add-CapabilityFromRegistryWithLastVersionAvailableForSubkey {
    <#
        .SYNOPSIS
            Retrieves capability from registry for specified key and subkey. Considers that subkey has semver format
    #>
    [CmdletBinding()]
    param(
        # Prefix name of capability
        [Parameter(Mandatory = $true)]
        [string]$PrefixName,
        # Postfix name of capability
        [Parameter(Mandatory = $false)]
        [string]$PostfixName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string]$Hive,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Default', 'Registry32', 'Registry64')]
        [string]$View,
        # Registry key
        [Parameter(Mandatory = $true)]
        [string]$KeyName,

        [Parameter(Mandatory = $true)]
        [string]$ValueName,
        # Registry subkey
        [Parameter(Mandatory = $true)]
        [string]$Subkey,
        # Major version of tool to be added as capability
        [Parameter(Mandatory = $true)]
        [int]$MajorVersion,
        # Minimum major version of tool to be added as capability. All versions detected less than this version - will be ignored. 
        # This is helpful for backward compatibility with already existing logic for previous versions
        [Parameter(Mandatory = $false)]
        [int]$MinimumMajorVersion,

        [ref]$Value)
    try {
        Write-Host $MajorVersion $MinimumMajorVersion
        if ($MajorVersion -lt $MinimumMajorVersion) {
            return $false
        }

        $wholeKey = Join-Path -Path $KeyName -ChildPath $Subkey

        $capabilityValue = Get-RegistryValue -Hive $Hive -View $View -KeyName $wholeKey -ValueName $ValueName

        if ([string]::IsNullOrEmpty($capabilityValue)) {
            return $false
        }
   
        $capabilityName = $PrefixName + $MajorVersion + $PostfixName

        Write-Capability -Name $capabilityName -Value $capabilityValue
        if ($Value) {
            $Value.Value = $capabilityValue
        }

        return $true
    } catch {
        return $false
    }
}

function Add-CapabilityFromRegistryWithLastVersionAvailable {
    <#
        .SYNOPSIS
            Retrieves capability from registry with last version. Considers that subkeys for specified key name are versions (in semver format like 1.2.3)
            This is useful to detect last version of tools as agent capabilities

        .EXAMPLE
            If KeyName = 'SOFTWARE\JavaSoft\JDK', and this registry key contains subkeys: 14.0.1, 16.0 - it will write the last one as specified capability
    #>
    [CmdletBinding()]
    param(
        # Prefix name of capability
        [Parameter(Mandatory = $true)]
        [string]$PrefixName,
        # Postfix name of capability
        [Parameter(Mandatory = $false)]
        [string]$PostfixName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('CurrentUser', 'LocalMachine')]
        [string]$Hive,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Default', 'Registry32', 'Registry64')]
        [string]$View,
        # Registry key
        [Parameter(Mandatory = $true)]
        [string]$KeyName,

        [Parameter(Mandatory = $true)]
        [string]$ValueName,
        # Minimum major version of tool to be added as capability. All versions detected less than this version - will be ignored. 
        # This is helpful for backward compatibility with already existing logic for previous versions
        [Parameter(Mandatory = $false)]
        [string]$MinimumMajorVersion,

        [ref]$Value)

    try {
        $subkeys = Get-RegistrySubKeyNames -Hive $Hive -View $View -KeyName $KeyName | Sort-Object

        $versionSubkeys = $subkeys | ForEach {[tuple]::Create((Parse-Version -Version $_), $_)} | Where { ![string]::IsNullOrEmpty($_.Item1)}

        $sortedVersionSubkeys = $versionSubkeys | Sort-Object -Property @{Expression = {$_.Item1}; Descending = $False}
        Write-Host $sortedVersionSubkeys[-1].Item1.Major
        $res = Add-CapabilityFromRegistryWithLastVersionAvailableForSubkey -PrefixName $PrefixName -PostfixName $PostfixName -Hive $Hive -View $View -KeyName $KeyName -ValueName $ValueName -Subkey $sortedVersionSubkeys[-1].Item2 -MajorVersion $sortedVersionSubkeys[-1].Item1.Major -Value $Value  -MinimumMajorVersion $MinimumMajorVersion

        if (!$res) {
            Write-Host "An error occured while trying to get last available version for capability: " $PrefixName + "<version>" + $PostfixName
            Write-Host $_ 

            $major = (Parse-Version -Version $subkeys[-1]).Major

            $res = Add-CapabilityFromRegistryWithLastVersionAvailableForSubkey -PrefixName $PrefixName -PostfixName $PostfixName -Hive $Hive -View $View -KeyName $KeyName -ValueName $ValueName -Subkey $subkeys[-1] -MajorVersion $major -Value $Value -MinimumMajorVersion $MinimumMajorVersion

            if(!$res) {
                Write-Host "An error occured while trying to set capability for first found subkey: " $subkeys[-1]
                Write-Host $_

                return $false
            }
        }

        return $true
    } catch {
        Write-Host "An error occured while trying to sort subkeys for capability as versions: " $PrefixName + "<version>" + $PostfixName
        Write-Host $_ 

        return $false
    }
}


function Write-Capability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$Value)

    $escapeMappings = @( # TODO: WHAT ABOUT "="? WHAT ABOUT "%"?
        New-Object psobject -Property @{ Token = ';' ; Replacement = '%3B' }
        New-Object psobject -Property @{ Token = "`r" ; Replacement = '%0D' }
        New-Object psobject -Property @{ Token = "`n" ; Replacement = '%0A' }
    )
    $formattedName = "$Name"
    $formattedValue = "$Value"
    foreach ($mapping in $escapeMappings) {
        $formattedName = $formattedName.Replace($mapping.Token, $mapping.Replacement)
        $formattedValue = $formattedValue.Replace($mapping.Token, $mapping.Replacement)
    }

    Write-Host "##vso[agent.capability name=$formattedName]$formattedValue"
}

# SIG # Begin signature block
# MIIjkgYJKoZIhvcNAQcCoIIjgzCCI38CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC8cN1xGrApiSPw
# +bQn6eYAuJZPBWqfKxU9aJ6JAl2vCqCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
# LpKnSrTQAAAAAAHfMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjAxMjE1MjEzMTQ1WhcNMjExMjAyMjEzMTQ1WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQC2uxlZEACjqfHkuFyoCwfL25ofI9DZWKt4wEj3JBQ48GPt1UsDv834CcoUUPMn
# s/6CtPoaQ4Thy/kbOOg/zJAnrJeiMQqRe2Lsdb/NSI2gXXX9lad1/yPUDOXo4GNw
# PjXq1JZi+HZV91bUr6ZjzePj1g+bepsqd/HC1XScj0fT3aAxLRykJSzExEBmU9eS
# yuOwUuq+CriudQtWGMdJU650v/KmzfM46Y6lo/MCnnpvz3zEL7PMdUdwqj/nYhGG
# 3UVILxX7tAdMbz7LN+6WOIpT1A41rwaoOVnv+8Ua94HwhjZmu1S73yeV7RZZNxoh
# EegJi9YYssXa7UZUUkCCA+KnAgMBAAGjggF+MIIBejAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUOPbML8IdkNGtCfMmVPtvI6VZ8+Mw
# UAYDVR0RBEkwR6RFMEMxKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVyYXRpb25zIFB1
# ZXJ0byBSaWNvMRYwFAYDVQQFEw0yMzAwMTIrNDYzMDA5MB8GA1UdIwQYMBaAFEhu
# ZOVQBdOCqhc3NyK1bajKdQKVMFQGA1UdHwRNMEswSaBHoEWGQ2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY0NvZFNpZ1BDQTIwMTFfMjAxMS0w
# Ny0wOC5jcmwwYQYIKwYBBQUHAQEEVTBTMFEGCCsGAQUFBzAChkVodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY0NvZFNpZ1BDQTIwMTFfMjAx
# MS0wNy0wOC5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAgEAnnqH
# tDyYUFaVAkvAK0eqq6nhoL95SZQu3RnpZ7tdQ89QR3++7A+4hrr7V4xxmkB5BObS
# 0YK+MALE02atjwWgPdpYQ68WdLGroJZHkbZdgERG+7tETFl3aKF4KpoSaGOskZXp
# TPnCaMo2PXoAMVMGpsQEQswimZq3IQ3nRQfBlJ0PoMMcN/+Pks8ZTL1BoPYsJpok
# t6cql59q6CypZYIwgyJ892HpttybHKg1ZtQLUlSXccRMlugPgEcNZJagPEgPYni4
# b11snjRAgf0dyQ0zI9aLXqTxWUU5pCIFiPT0b2wsxzRqCtyGqpkGM8P9GazO8eao
# mVItCYBcJSByBx/pS0cSYwBBHAZxJODUqxSXoSGDvmTfqUJXntnWkL4okok1FiCD
# Z4jpyXOQunb6egIXvkgQ7jb2uO26Ow0m8RwleDvhOMrnHsupiOPbozKroSa6paFt
# VSh89abUSooR8QdZciemmoFhcWkEwFg4spzvYNP4nIs193261WyTaRMZoceGun7G
# CT2Rl653uUj+F+g94c63AhzSq4khdL4HlFIP2ePv29smfUnHtGq6yYFDLnT0q/Y+
# Di3jwloF8EWkkHRtSuXlFUbTmwr/lDDgbpZiKhLS7CBTDj32I0L5i532+uHczw82
# oZDmYmYmIUSMbZOgS65h797rj5JJ6OkeEUJoAVwwggd6MIIFYqADAgECAgphDpDS
# AAAAAAADMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMTAeFw0xMTA3MDgyMDU5MDlaFw0yNjA3MDgyMTA5MDla
# MH4xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMT
# H01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQCr8PpyEBwurdhuqoIQTTS68rZYIZ9CGypr6VpQqrgG
# OBoESbp/wwwe3TdrxhLYC/A4wpkGsMg51QEUMULTiQ15ZId+lGAkbK+eSZzpaF7S
# 35tTsgosw6/ZqSuuegmv15ZZymAaBelmdugyUiYSL+erCFDPs0S3XdjELgN1q2jz
# y23zOlyhFvRGuuA4ZKxuZDV4pqBjDy3TQJP4494HDdVceaVJKecNvqATd76UPe/7
# 4ytaEB9NViiienLgEjq3SV7Y7e1DkYPZe7J7hhvZPrGMXeiJT4Qa8qEvWeSQOy2u
# M1jFtz7+MtOzAz2xsq+SOH7SnYAs9U5WkSE1JcM5bmR/U7qcD60ZI4TL9LoDho33
# X/DQUr+MlIe8wCF0JV8YKLbMJyg4JZg5SjbPfLGSrhwjp6lm7GEfauEoSZ1fiOIl
# XdMhSz5SxLVXPyQD8NF6Wy/VI+NwXQ9RRnez+ADhvKwCgl/bwBWzvRvUVUvnOaEP
# 6SNJvBi4RHxF5MHDcnrgcuck379GmcXvwhxX24ON7E1JMKerjt/sW5+v/N2wZuLB
# l4F77dbtS+dJKacTKKanfWeA5opieF+yL4TXV5xcv3coKPHtbcMojyyPQDdPweGF
# RInECUzF1KVDL3SV9274eCBYLBNdYJWaPk8zhNqwiBfenk70lrC8RqBsmNLg1oiM
# CwIDAQABo4IB7TCCAekwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFEhuZOVQ
# BdOCqhc3NyK1bajKdQKVMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1Ud
# DwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFHItOgIxkEO5FAVO
# 4eqnxzHRI4k0MFoGA1UdHwRTMFEwT6BNoEuGSWh0dHA6Ly9jcmwubWljcm9zb2Z0
# LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcmwwXgYIKwYBBQUHAQEEUjBQME4GCCsGAQUFBzAChkJodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcnQwgZ8GA1UdIASBlzCBlDCBkQYJKwYBBAGCNy4DMIGDMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2RvY3MvcHJpbWFyeWNw
# cy5odG0wQAYIKwYBBQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AcABvAGwAaQBjAHkA
# XwBzAHQAYQB0AGUAbQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAGfyhqWY
# 4FR5Gi7T2HRnIpsLlhHhY5KZQpZ90nkMkMFlXy4sPvjDctFtg/6+P+gKyju/R6mj
# 82nbY78iNaWXXWWEkH2LRlBV2AySfNIaSxzzPEKLUtCw/WvjPgcuKZvmPRul1LUd
# d5Q54ulkyUQ9eHoj8xN9ppB0g430yyYCRirCihC7pKkFDJvtaPpoLpWgKj8qa1hJ
# Yx8JaW5amJbkg/TAj/NGK978O9C9Ne9uJa7lryft0N3zDq+ZKJeYTQ49C/IIidYf
# wzIY4vDFLc5bnrRJOQrGCsLGra7lstnbFYhRRVg4MnEnGn+x9Cf43iw6IGmYslmJ
# aG5vp7d0w0AFBqYBKig+gj8TTWYLwLNN9eGPfxxvFX1Fp3blQCplo8NdUmKGwx1j
# NpeG39rz+PIWoZon4c2ll9DuXWNB41sHnIc+BncG0QaxdR8UvmFhtfDcxhsEvt9B
# xw4o7t5lL+yX9qFcltgA1qFGvVnzl6UJS0gQmYAf0AApxbGbpT9Fdx41xtKiop96
# eiL6SJUfq/tHI4D1nvi/a7dLl+LrdXga7Oo3mXkYS//WsyNodeav+vyL6wuA6mk7
# r/ww7QRMjt/fdW1jkT3RnVZOT7+AVyKheBEyIXrvQQqxP/uozKRdwaGIm1dxVk5I
# RcBCyZt2WwqASGv9eZ/BvW1taslScxMNelDNMYIVZzCCFWMCAQEwgZUwfjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
# b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMQITMwAAAd9r8C6Sp0q00AAAAAAB3zAN
# BglghkgBZQMEAgEFAKCBrjAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgGKx9F1ph
# pgm++5RfhIUjYHbwDdlXklXDbiiyS8DF2nMwQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQAXaopMGq9a7vWwKj+EcGPo14IHHq9edWehCeINPhqA
# Li8KwVygtFxJqIkZ8mm8f3dlDcYoG5BFZucAduayFeG3W2DnK8YoSieBY7QqE5E1
# L062EUsfa3dEYnJy1N3zymzzEg48rXeLC9UQHs3k7owRwpGzIj9SunjoYQoOxHfw
# 8MAidUHmyWnAwsmj1ii3AQ9a7GoDaKOklzgvbZ9DfqLE8HdKZHtHl0nwETpGoWvz
# 0DxYY/LueBCcRpneKbfixkCV37uuW+MbaUHL7l/qVzujngWMXDGvre9MseRwm/1h
# dO9Tl0+Qedj+7fpdGIReBxFFv49dyCidn3YZ8xtfDMggoYIS8TCCEu0GCisGAQQB
# gjcDAwExghLdMIIS2QYJKoZIhvcNAQcCoIISyjCCEsYCAQMxDzANBglghkgBZQME
# AgEFADCCAVUGCyqGSIb3DQEJEAEEoIIBRASCAUAwggE8AgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEIAs3sAkH13avrQJpQbKU4RN+pgUOfhURhPdpwD2s
# GV6cAgZg04+Gs78YEzIwMjEwNzAxMTQzMTQ0LjM5MlowBIACAfSggdSkgdEwgc4x
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKTAnBgNVBAsTIE1p
# Y3Jvc29mdCBPcGVyYXRpb25zIFB1ZXJ0byBSaWNvMSYwJAYDVQQLEx1UaGFsZXMg
# VFNTIEVTTjozMkJELUUzRDUtM0IxRDElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgU2VydmljZaCCDkQwggT1MIID3aADAgECAhMzAAABYtD+AvMB5c1JAAAA
# AAFiMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEw
# MB4XDTIxMDExNDE5MDIyMloXDTIyMDQxMTE5MDIyMlowgc4xCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVy
# YXRpb25zIFB1ZXJ0byBSaWNvMSYwJAYDVQQLEx1UaGFsZXMgVFNTIEVTTjozMkJE
# LUUzRDUtM0IxRDElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vydmlj
# ZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAO+GodT2ucL3Mr2DQsv2
# ELNbSvKyBpYdUKtUBWiZmFVy18pG/pucgkrc5i9tu8CY7GpWV/CQNmHG2mVeSHMJ
# vbwCc/AAv7JP3bFCt6Zg75IbVSNOGA1eqLbmQiC6UAfSKXLN3dHtQ5diihb3Ymzp
# NP9K0cVPZfv2MXm+ZVU0RES8cyPkXel7+UEGE+kqdiBNDdb8yBXd8sju+90+V4nz
# YC+ZWW7SFJ2FFZlASpVaHpjv+eGohXlQaSBvmM4Q0xe3LhzQM8ViGz9cLeFSKgFf
# SY7qizL7wUg+eqYvDUyjPX8axEQHmk0th23wWH5p0Wduws43qNIo0OQ0mRotBK71
# nykCAwEAAaOCARswggEXMB0GA1UdDgQWBBTLxEoRYEpDtzp84B5WlZN2kP4qazAf
# BgNVHSMEGDAWgBTVYzpcijGQ80N7fEYbxTNoWoVtVTBWBgNVHR8ETzBNMEugSaBH
# hkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNU
# aW1TdGFQQ0FfMjAxMC0wNy0wMS5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUF
# BzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1RpbVN0
# YVBDQV8yMDEwLTA3LTAxLmNydDAMBgNVHRMBAf8EAjAAMBMGA1UdJQQMMAoGCCsG
# AQUFBwMIMA0GCSqGSIb3DQEBCwUAA4IBAQAtQa3DoXYbW/cXACbcVSFGe4gC8GXs
# FxSHT3JgwFU/NdJOcbkcFTVvTp6vlmTvHm6sIjknRBB0Xi1NBTqPw20u6u/T7Cnc
# /z0gT6mf9crI0VR9C+R1CtjezYKZEdZZ7fuNQWjsyftNDhQy+Rqnqryt0VoezLal
# heiinHzZD/4Y4hZYPf0u8TSv1ZfKtdBweWG3QU0Lp/I9SbIoemDG97RULMcPvq2u
# fhUp3OMiYQGL1WqkykSnqRJsM2IcA4l4dmoPNP6dLg5Dr7NVoYKIMInaQVZjSwDM
# ZhWryvfizX0SrzyLgkMPhLMVkfLxQQSQ37NeFk7F1RfeAkNWAh6mCORBMIIGcTCC
# BFmgAwIBAgIKYQmBKgAAAAAAAjANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJv
# b3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMTAwHhcNMTAwNzAxMjEzNjU1WhcN
# MjUwNzAxMjE0NjU1WjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDCCASIw
# DQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKkdDbx3EYo6IOz8E5f1+n9plGt0
# VBDVpQoAgoX77XxoSyxfxcPlYcJ2tz5mK1vwFVMnBDEfQRsalR3OCROOfGEwWbEw
# RA/xYIiEVEMM1024OAizQt2TrNZzMFcmgqNFDdDq9UeBzb8kYDJYYEbyWEeGMoQe
# dGFnkV+BVLHPk0ySwcSmXdFhE24oxhr5hoC732H8RsEnHSRnEnIaIYqvS2SJUGKx
# Xf13Hz3wV3WsvYpCTUBR0Q+cBj5nf/VmwAOWRH7v0Ev9buWayrGo8noqCjHw2k4G
# kbaICDXoeByw6ZnNPOcvRLqn9NxkvaQBwSAJk3jN/LzAyURdXhacAQVPIk0CAwEA
# AaOCAeYwggHiMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBTVYzpcijGQ80N7
# fEYbxTNoWoVtVTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMC
# AYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvX
# zpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20v
# cGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYI
# KwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDCBoAYDVR0g
# AQH/BIGVMIGSMIGPBgkrBgEEAYI3LgMwgYEwPQYIKwYBBQUHAgEWMWh0dHA6Ly93
# d3cubWljcm9zb2Z0LmNvbS9QS0kvZG9jcy9DUFMvZGVmYXVsdC5odG0wQAYIKwYB
# BQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AUABvAGwAaQBjAHkAXwBTAHQAYQB0AGUA
# bQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAAfmiFEN4sbgmD+BcQM9naOh
# IW+z66bM9TG+zwXiqf76V20ZMLPCxWbJat/15/B4vceoniXj+bzta1RXCCtRgkQS
# +7lTjMz0YBKKdsxAQEGb3FwX/1z5Xhc1mCRWS3TvQhDIr79/xn/yN31aPxzymXlK
# kVIArzgPF/UveYFl2am1a+THzvbKegBvSzBEJCI8z+0DpZaPWSm8tv0E4XCfMkon
# /VWvL/625Y4zu2JfmttXQOnxzplmkIz/amJ/3cVKC5Em4jnsGUpxY517IW3DnKOi
# PPp/fZZqkHimbdLhnPkd/DjYlPTGpQqWhqS9nhquBEKDuLWAmyI4ILUl5WTs9/S/
# fmNZJQ96LjlXdqJxqgaKD4kWumGnEcua2A5HmoDF0M2n0O99g/DhO3EJ3110mCII
# YdqwUB5vvfHhAN/nMQekkzr3ZUd46PioSKv33nJ+YWtvd6mBy6cJrDm77MbL2IK0
# cs0d9LiFAR6A+xuJKlQ5slvayA1VmXqHczsI5pgt6o3gMy4SKfXAL1QnIffIrE7a
# KLixqduWsqdCosnPGUFN4Ib5KpqjEWYw07t0MkvfY3v1mYovG8chr1m1rtxEPJdQ
# cdeh0sVV42neV8HR3jDA/czmTfsNv11P6Z0eGTgvvM9YBS7vDaBQNdrvCScc1bN+
# NR4Iuto229Nfj950iEkSoYIC0jCCAjsCAQEwgfyhgdSkgdEwgc4xCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKTAnBgNVBAsTIE1pY3Jvc29mdCBP
# cGVyYXRpb25zIFB1ZXJ0byBSaWNvMSYwJAYDVQQLEx1UaGFsZXMgVFNTIEVTTjoz
# MkJELUUzRDUtM0IxRDElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAmrP6Chrbz0ax7s57n5Pop3VC8gyggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQUFAAIF
# AOSH8PcwIhgPMjAyMTA3MDExMTQ0NTVaGA8yMDIxMDcwMjExNDQ1NVowdzA9Bgor
# BgEEAYRZCgQBMS8wLTAKAgUA5Ifw9wIBADAKAgEAAgIdPgIB/zAHAgEAAgIRNzAK
# AgUA5IlCdwIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIB
# AAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBBQUAA4GBAGpUSLX38cImbRFR
# oyhYOKwl8sqBEekRGoVWN0HGcMzfIjCR7X7fyS6eF5WZHhM41LbxWIkU9NESuwRB
# BkX6oWF4qwYAeuT+OfAWcIKwWgJASG6aEtzYF19xOH+74xwPGU32U37fdquv4Egp
# V1H9t2jBZT7vcf7BUBLFgMXkc9moMYIDDTCCAwkCAQEwgZMwfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAFi0P4C8wHlzUkAAAAAAWIwDQYJYIZIAWUD
# BAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0B
# CQQxIgQgic3bIydbx/6cVzP3c7q8YkT4bfZi9LKpWuuGkbh5XK8wgfoGCyqGSIb3
# DQEJEAIvMYHqMIHnMIHkMIG9BCCKqhiV+zwNDrpU7DRB7Mi57xi6GBNYsGjgZqq2
# qVMKMjCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAAB
# YtD+AvMB5c1JAAAAAAFiMCIEICTFMoju1u7krLSQIHuMYnlG9e3tJzJe/PlcpuNA
# U1UmMA0GCSqGSIb3DQEBCwUABIIBANusGO4lFVzD6wzFOC3FtwIxnrgKD8tSZlF/
# KAWu2IA8DRWUZLLBu9yAzSm3QsOOpLbct431rBLVjCQpC5mv0xrD34pNUp3VVOfP
# UUVbB09lEdVvM5GL4hGnlTdcVWrn9zdDp6Z1f4Dbn9vA8bU96DmejANnsB7mZ+cz
# PrImjyjyfR9DWviFWqy5daR5XaDt7tMjGvZfuaPCWmtc+Ga8XrtcozCQuvJ893oa
# 5DvnQ8d+tPhRaaa39cPrs8+9z5Ji8SoUkhTHu59WvQBxZGpr9srzCEhwNB3JS09p
# L8L18CUiK3CoMswaNIb0WiXSl7x6TSJqsd7pcX/jddpK0iQ3T5U=
# SIG # End signature block
