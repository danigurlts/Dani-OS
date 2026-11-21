@{
    ManifestVersion = "1.0.0"
    OSName          = "DaniOs"
    License         = "GNU-GPL-3.0"
    Architecture    = "Polyglot-DLL-Kernel-3x3"

    KernelCore = @{
        RequiredAssemblies = @(
            "kernel/bin/System.Management.Automation.dll",
            "kernel/bin/DaniOs.Kernel.Host.dll",
            "kernel/bin/DaniOs.Kernel.AI.dll"
        )
        NativeInferenceBinaries = @{
            Windows = "native/llama.dll"
            Linux   = "native/libllama.so"
            MacOS   = "native/libllama.dylib"
        }
        NativeInferenceBuild = @{
            Runtime      = "llama.cpp"
            Version      = "b12602"
            Architecture = "x64"
            Backend      = "CPU"
        }
        AISettingsDefaults = @{
            provider                     = "in-kernel-dll"
            nativeRuntime                = "llama.cpp"
            modelFile                    = "kernel/models/Qwen2.5-3B-Instruct-Q5_K_M.gguf"
            nativeLibraryDirectory       = "native"
            contextTokens                = 4096
            batchSize                    = 128
            threads                      = 3
            gpuLayers                    = 0
            temperature                  = 0.0
            topP                         = 0.9
            repeatPenalty                = 1.05
            maxTokens                    = 96
            maxOutputCharacters          = 4096
            modelLoadTimeoutMs           = 120000
            inferenceTimeoutMs           = 30000
            fallbackToDeterministicRules = $true
        }
        GoldenSeeds = @{
            Markdown = "kernel/seeds/default.md"
            Yaml     = "kernel/seeds/default.yml"
            Json     = "kernel/seeds/default.json"
        }
        ImmutablePaths = @(
            "/kernel/bin",
            "/kernel/models",
            "/native",
            "/kernel/seeds",
            "/kernel/Policy.psm1",
            "/boot/DaniOs.Boot"
        )
    }

    ParallelMemoryMatrix = @{
        Topology          = "3x3"
        ExpectedNodeCount = 9
        Tiers             = @(
            @{ Name = "tier_1_active";   Role = "ImmediateRunState" },
            @{ Name = "tier_2_rolling";  Role = "RollingConsolidation" },
            @{ Name = "tier_3_baseline"; Role = "KernelInvariants" }
        )
        NodeFiles         = @("journal.md", "solutions.yml", "state.json")
        SecurityIsolation = @{
            EnforceKernelOnlyAcl    = $true
            DenyStandardUsers       = $true
            HideFromDirectoryScan   = $true
            BlockZone3PathTraversal = $true
        }
    }

    EncapsulatedNativeFS = @{
        DefaultNativeSubdir       = "native"
        EnforcePathContainment    = $true
        AutoHealHashDrift         = $true
        BlockedWebWriteExtensions = @(".exe", ".dll", ".sys", ".drv", ".bat", ".cmd", ".vbs", ".scr", ".msi", ".so", ".dylib")
        AstValidatedExtensions    = @(".ps1", ".psm1")
    }

    CloudOriginContract = @{
        CompressionAlgorithm = "GZip"
        EncryptionCipher     = "AES-256-CBC+HMAC-SHA256"
        AuthHeaderPrefix     = "X-DaniOs-"
        RequiredHeaders      = @("X-DaniOs-Fingerprint", "X-DaniOs-Timestamp", "X-DaniOs-Body-SHA256", "X-DaniOs-Signature")
    }
}
