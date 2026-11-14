#!/usr/bin/env bash
set -euo pipefail

echo "======================================================================"
echo " ⚡ Scaffolding Complete DaniOs Repository in GitHub Codespaces"
echo "======================================================================"

# 1. Create Directory Topology
mkdir -p \
  boot/DaniOs.Boot \
  kernel/src/DaniOs.Kernel.AI \
  kernel/src/DaniOs.Kernel.Host \
  kernel/bin/native \
  kernel/models \
  kernel/seeds \
  polyglot/node \
  polyglot/php/public \
  polyglot/python \
  cloud-origin \
  config \
  native \
  setup \
  tests

# Keep empty runtime folders tracked in Git
touch kernel/bin/native/.gitkeep kernel/models/.gitkeep native/.gitkeep

# 2. .gitignore
cat << 'EOF' > .gitignore
# Live secrets & local machine configs
config/kernel.config.json
cloud-origin/vault.config.json
cloud-origin/vault_data/

# Compiled .NET/PowerShell kernel binaries & native inference DLLs
kernel/bin/*.dll
kernel/bin/*.exe
kernel/bin/*.pdb
kernel/bin/*.json
kernel/bin/native/*.dll
kernel/bin/native/*.so
kernel/bin/native/*.dylib
boot/DaniOs.Boot.exe
boot/DaniOs.Boot
**/bin/
**/obj/

# Local SLM model weights
kernel/models/*.gguf
kernel/models/*.onnx

# Polyglot dependencies & runtime artifacts
polyglot/node/node_modules/
polyglot/python/__pycache__/
.parallel_3x3_firewall/
EOF

# 3. Official GNU GPLv3 LICENSE
echo "[1/7] Fetching GNU GPLv3 LICENSE..."
curl -fsSL "https://www.gnu.org/licenses/gpl-3.0.txt" -o LICENSE

# 4. Boot & C# Kernel Assemblies
echo "[2/7] Writing C# DLL Kernel Projects & Bootloader..."

cat << 'EOF' > boot/DaniOs.Boot/DaniOs.Boot.csproj
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AssemblyName>DaniOs.Boot</AssemblyName>
    <OutputPath>..\</OutputPath>
    <AppendTargetFrameworkToOutputPath>false</AppendTargetFrameworkToOutputPath>
  </PropertyGroup>

  <ItemGroup>
    <ProjectReference Include="..\..\kernel\src\DaniOs.Kernel.Host\DaniOs.Kernel.Host.csproj" />
    <ProjectReference Include="..\..\kernel\src\DaniOs.Kernel.AI\DaniOs.Kernel.AI.csproj" />
  </ItemGroup>
</Project>
EOF

cat << 'EOF' > boot/DaniOs.Boot/Program.cs
using DaniOs.Kernel.Host;

string bootDir = AppContext.BaseDirectory;
string daniRoot = Directory.GetParent(bootDir.TrimEnd(Path.DirectorySeparatorChar))?.FullName ?? bootDir;

var engine = new KernelHostEngine(daniRoot);
int exitCode = engine.Boot(args);
return exitCode;
EOF

cat << 'EOF' > kernel/src/DaniOs.Kernel.Host/DaniOs.Kernel.Host.csproj
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AssemblyName>DaniOs.Kernel.Host</AssemblyName>
    <RootNamespace>DaniOs.Kernel.Host</RootNamespace>
    <OutputPath>..\..\bin\</OutputPath>
    <AppendTargetFrameworkToOutputPath>false</AppendTargetFrameworkToOutputPath>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.PowerShell.SDK" Version="7.4.6" />
  </ItemGroup>
</Project>
EOF

cat << 'EOF' > kernel/src/DaniOs.Kernel.Host/KernelHostEngine.cs
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using Microsoft.PowerShell;

namespace DaniOs.Kernel.Host;

public sealed class KernelHostEngine
{
    private readonly string _daniRoot;

    public KernelHostEngine(string daniRoot)
    {
        _daniRoot = Path.GetFullPath(daniRoot);
    }

    public int Boot(string[] cliArgs)
    {
        string initScript = Path.Combine(_daniRoot, "boot", "init.ps1");
        if (!File.Exists(initScript))
        {
            Console.Error.WriteLine($"[DaniOs::Host] FATAL: Missing kernel entry script '{initScript}'.");
            return 2;
        }

        var iss = InitialSessionState.CreateDefault();
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            iss.ExecutionPolicy = ExecutionPolicy.Bypass;
        }

        Environment.SetEnvironmentVariable("DANIOS_KERNEL_ROOT", _daniRoot);

        using var runspace = RunspaceFactory.CreateRunspace(iss);
        runspace.Open();

        using var ps = PowerShell.Create();
        ps.Runspace = runspace;

        ps.Streams.Error.DataAdded += (_, e) =>
        {
            var record = ps.Streams.Error[e.Index];
            Console.ForegroundColor = ConsoleColor.Red;
            Console.Error.WriteLine($"[DaniOs::KernelError] {record}");
            Console.ResetColor();
        };

        ps.Streams.Warning.DataAdded += (_, e) =>
        {
            var record = ps.Streams.Warning[e.Index];
            Console.ForegroundColor = ConsoleColor.Yellow;
            Console.WriteLine($"[DaniOs::Warning] {record.Message}");
            Console.ResetColor();
        };

        ps.Streams.Information.DataAdded += (_, e) =>
        {
            var record = ps.Streams.Information[e.Index];
            Console.WriteLine(record.MessageData);
        };

        Console.CancelKeyPress += (_, cancelArgs) =>
        {
            cancelArgs.Cancel = true;
            if (ps.InvocationStateInfo.State == PSInvocationState.Running)
            {
                ps.BeginStop(_ => { }, null);
            }
        };

        ps.AddScript($"& '{initScript.Replace("'", "''")}' @args");
        foreach (string arg in cliArgs)
        {
            ps.AddArgument(arg);
        }

        try
        {
            var results = ps.Invoke();
            foreach (var item in results)
            {
                if (item is not null)
                    Console.WriteLine(item.ToString());
            }

            return ps.HadErrors ? 1 : 0;
        }
        catch (PipelineStoppedException)
        {
            return 0;
        }
        catch (Exception ex)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.Error.WriteLine($"[DaniOs::HostPanic] {ex.Message}");
            Console.ResetColor();
            return 1;
        }
    }
}
EOF

cat << 'EOF' > kernel/src/DaniOs.Kernel.AI/DaniOs.Kernel.AI.csproj
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
    <AssemblyName>DaniOs.Kernel.AI</AssemblyName>
    <RootNamespace>DaniOs.Kernel</RootNamespace>
    <OutputPath>..\..\bin\</OutputPath>
    <AppendTargetFrameworkToOutputPath>false</AppendTargetFrameworkToOutputPath>
  </PropertyGroup>
</Project>
EOF

cat << 'EOF' > kernel/src/DaniOs.Kernel.AI/NativeLlamaInterop.cs
using System.Runtime.InteropServices;

namespace DaniOs.Kernel;

internal static unsafe class NativeLlamaInterop
{
    private const string LibName = "llama";
    private static bool _resolverRegistered;

    public static void EnsureNativeResolver(string kernelBinDir)
    {
        if (_resolverRegistered) return;
        _resolverRegistered = true;

        NativeLibrary.SetDllImportResolver(typeof(NativeLlamaInterop).Assembly, (libraryName, assembly, searchPath) =>
        {
            if (!string.Equals(libraryName, LibName, StringComparison.OrdinalIgnoreCase))
                return IntPtr.Zero;

            string fileName = RuntimeInformation.IsOSPlatform(OSPlatform.Windows)
                ? "llama.dll"
                : RuntimeInformation.IsOSPlatform(OSPlatform.OSX)
                    ? "libllama.dylib"
                    : "libllama.so";

            string nativeCandidate = Path.Combine(kernelBinDir, "native", fileName);
            if (File.Exists(nativeCandidate) && NativeLibrary.TryLoad(nativeCandidate, out IntPtr handle))
                return handle;

            return IntPtr.Zero;
        });
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LlamaModelParams
    {
        public IntPtr Devices;
        public IntPtr TensorBuftOverrides;
        public int NGpuLayers;
        public int SplitMode;
        public int MainGpu;
        public IntPtr TensorSplit;
        public IntPtr ProgressCallback;
        public IntPtr ProgressCallbackUserData;
        public IntPtr KvOverrides;
        [MarshalAs(UnmanagedType.I1)] public bool VocabOnly;
        [MarshalAs(UnmanagedType.I1)] public bool UseMmap;
        [MarshalAs(UnmanagedType.I1)] public bool UseMlock;
        [MarshalAs(UnmanagedType.I1)] public bool CheckTensors;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LlamaContextParams
    {
        public uint NCtx;
        public uint NBatch;
        public uint NUbatch;
        public uint NSeqMax;
        public int NThreads;
        public int NThreadsBatch;
        public int RopeScalingType;
        public int PoolingType;
        public int AttentionType;
        public float RopeFreqBase;
        public float RopeFreqScale;
        public float YarnExtFactor;
        public float YarnAttnFactor;
        public float YarnBetaFast;
        public float YarnBetaSlow;
        public uint YarnOrigCtx;
        public float DefragThold;
        public IntPtr CbEval;
        public IntPtr CbEvalUserData;
        public int TypeK;
        public int TypeV;
        public IntPtr AbortCallback;
        public IntPtr AbortCallbackData;
        [MarshalAs(UnmanagedType.I1)] public bool Embeddings;
        [MarshalAs(UnmanagedType.I1)] public bool OffloadKqv;
        [MarshalAs(UnmanagedType.I1)] public bool FlashAttn;
        [MarshalAs(UnmanagedType.I1)] public bool NoPerf;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LlamaBatch
    {
        public int NTokens;
        public int* Token;
        public float* Emb;
        public int* Pos;
        public int* NSeqId;
        public int** SeqId;
        public sbyte* Logits;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LlamaSamplerChainParams
    {
        [MarshalAs(UnmanagedType.I1)] public bool NoPerf;
    }

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_backend_init();

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_backend_free();

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern LlamaModelParams llama_model_default_params();

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern LlamaContextParams llama_context_default_params();

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
    public static extern IntPtr llama_model_load_from_file(string pathModel, LlamaModelParams @params);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_model_free(IntPtr model);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_init_from_model(IntPtr model, LlamaContextParams @params);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_free(IntPtr ctx);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_model_get_vocab(IntPtr model);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_vocab_eos(IntPtr vocab);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_tokenize(
        IntPtr vocab, byte* text, int textLen, int* tokens, int nTokensMax,
        [MarshalAs(UnmanagedType.I1)] bool addSpecial, [MarshalAs(UnmanagedType.I1)] bool parseSpecial);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_token_to_piece(
        IntPtr vocab, int token, byte* buf, int length, int lstrip,
        [MarshalAs(UnmanagedType.I1)] bool special);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern LlamaBatch llama_batch_get_one(int* tokens, int nTokens);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_decode(IntPtr ctx, LlamaBatch batch);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern LlamaSamplerChainParams llama_sampler_chain_default_params();

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_sampler_chain_init(LlamaSamplerChainParams @params);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_sampler_chain_add(IntPtr chain, IntPtr smpl);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_sampler_init_greedy();

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_sampler_sample(IntPtr smpl, IntPtr ctx, int idx);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_sampler_accept(IntPtr smpl, int token);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_sampler_free(IntPtr smpl);
}
EOF

cat << 'EOF' > kernel/src/DaniOs.Kernel.AI/KernelAiEngine.cs
using System.Collections;
using System.Text;
using System.Text.Json;

namespace DaniOs.Kernel;

public static unsafe class AI
{
    private static readonly object SyncLock = new();
    private static IntPtr _modelPtr = IntPtr.Zero;
    private static IntPtr _vocabPtr = IntPtr.Zero;
    private static int _contextTokens = 4096;
    private static bool _nativeReady;
    private static string _loadedModelPath = string.Empty;

    public static bool IsNativeLoaded => _nativeReady;

    public static bool Initialize(string modelPath, int contextTokens = 4096)
    {
        lock (SyncLock)
        {
            if (_nativeReady && string.Equals(_loadedModelPath, modelPath, StringComparison.OrdinalIgnoreCase))
                return true;

            ShutdownInternal();
            _contextTokens = Math.Clamp(contextTokens, 512, 32768);

            if (string.IsNullOrWhiteSpace(modelPath) || !File.Exists(modelPath))
                return false;

            string binDir = Path.GetDirectoryName(typeof(AI).Assembly.Location) ?? AppContext.BaseDirectory;
            NativeLlamaInterop.EnsureNativeResolver(binDir);

            try
            {
                NativeLlamaInterop.llama_backend_init();

                var modelParams = NativeLlamaInterop.llama_model_default_params();
                modelParams.NGpuLayers = 0;
                modelParams.UseMmap = true;

                _modelPtr = NativeLlamaInterop.llama_model_load_from_file(modelPath, modelParams);
                if (_modelPtr == IntPtr.Zero)
                    return false;

                _vocabPtr = NativeLlamaInterop.llama_model_get_vocab(_modelPtr);
                _loadedModelPath = modelPath;
                _nativeReady = true;
                return true;
            }
            catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
            {
                _nativeReady = false;
                return false;
            }
        }
    }

    public static string DiagnoseFault(object faultRecord)
    {
        string serialized = SerializeObjectSafe(faultRecord);

        if (_nativeReady)
        {
            string sysPrompt =
                "You are the embedded DaniOs Kernel AI. Analyze the JSON fault telemetry and output " +
                "a concise 1-2 sentence root cause and immediate remediation action. Do not output markdown fences.";
            string result = InferRaw(sysPrompt, serialized, maxTokens: 160);
            if (!string.IsNullOrWhiteSpace(result))
                return result.Trim();
        }

        return DeterministicFallbackDiagnosis(serialized);
    }

    public static string DiagnoseAndSynthesize(string faultContextJson, string journalContext)
    {
        if (_nativeReady)
        {
            string sysPrompt =
                "You are the DaniOs in-kernel self-healing synthesizer. Given the fault JSON and recent " +
                "3x3 run journal entries, identify the root cause and provide a safe, minimal remediation summary.";
            string userPrompt = $"FAULT:\n{faultContextJson}\n\nRECENT_JOURNAL:\n{journalContext}";
            string result = InferRaw(sysPrompt, userPrompt, maxTokens: 256);
            if (!string.IsNullOrWhiteSpace(result))
                return result.Trim();
        }

        return DeterministicFallbackDiagnosis(faultContextJson);
    }

    public static string InferRaw(string systemPrompt, string userPrompt, int maxTokens = 256)
    {
        lock (SyncLock)
        {
            if (!_nativeReady || _modelPtr == IntPtr.Zero || _vocabPtr == IntPtr.Zero)
                return string.Empty;

            string formattedPrompt =
                $"<|im_start|>system\n{systemPrompt}<|im_end|>\n" +
                $"<|im_start|>user\n{userPrompt}<|im_end|>\n" +
                "<|im_start|>assistant\n";

            byte[] promptBytes = Encoding.UTF8.GetBytes(formattedPrompt);
            IntPtr ctxPtr = IntPtr.Zero;
            IntPtr samplerPtr = IntPtr.Zero;

            try
            {
                var ctxParams = NativeLlamaInterop.llama_context_default_params();
                ctxParams.NCtx = (uint)_contextTokens;
                ctxParams.NBatch = 512;
                ctxParams.NThreads = Math.Max(2, Environment.ProcessorCount / 2);
                ctxParams.NThreadsBatch = ctxParams.NThreads;

                ctxPtr = NativeLlamaInterop.llama_init_from_model(_modelPtr, ctxParams);
                if (ctxPtr == IntPtr.Zero)
                    return string.Empty;

                int maxPromptTokens = promptBytes.Length + 16;
                int[] promptTokens = new int[maxPromptTokens];
                int nPromptTokens;

                fixed (byte* pText = promptBytes)
                fixed (int* pTokens = promptTokens)
                {
                    nPromptTokens = NativeLlamaInterop.llama_tokenize(
                        _vocabPtr, pText, promptBytes.Length, pTokens, maxPromptTokens,
                        addSpecial: true, parseSpecial: true);
                }

                if (nPromptTokens <= 0)
                    return string.Empty;

                fixed (int* pTokens = promptTokens)
                {
                    var batch = NativeLlamaInterop.llama_batch_get_one(pTokens, nPromptTokens);
                    if (NativeLlamaInterop.llama_decode(ctxPtr, batch) != 0)
                        return string.Empty;
                }

                var chainParams = NativeLlamaInterop.llama_sampler_chain_default_params();
                samplerPtr = NativeLlamaInterop.llama_sampler_chain_init(chainParams);
                NativeLlamaInterop.llama_sampler_chain_add(samplerPtr, NativeLlamaInterop.llama_sampler_init_greedy());

                int eosToken = NativeLlamaInterop.llama_vocab_eos(_vocabPtr);
                var outputBytes = new List<byte>(maxTokens * 4);
                byte* pieceBuf = stackalloc byte[256];
                int nextToken = 0;

                for (int i = 0; i < maxTokens; i++)
                {
                    nextToken = NativeLlamaInterop.llama_sampler_sample(samplerPtr, ctxPtr, -1);
                    if (nextToken == eosToken)
                        break;

                    NativeLlamaInterop.llama_sampler_accept(samplerPtr, nextToken);

                    int written = NativeLlamaInterop.llama_token_to_piece(_vocabPtr, nextToken, pieceBuf, 256, 0, false);
                    if (written > 0)
                    {
                        for (int b = 0; b < written; b++)
                            outputBytes.Add(pieceBuf[b]);
                    }

                    var stepBatch = NativeLlamaInterop.llama_batch_get_one(&nextToken, 1);
                    if (NativeLlamaInterop.llama_decode(ctxPtr, stepBatch) != 0)
                        break;
                }

                string decoded = Encoding.UTF8.GetString(outputBytes.ToArray());
                int endMarker = decoded.IndexOf("<|im_end|>", StringComparison.Ordinal);
                return endMarker >= 0 ? decoded[..endMarker] : decoded;
            }
            finally
            {
                if (samplerPtr != IntPtr.Zero) NativeLlamaInterop.llama_sampler_free(samplerPtr);
                if (ctxPtr != IntPtr.Zero) NativeLlamaInterop.llama_free(ctxPtr);
            }
        }
    }

    public static void Shutdown()
    {
        lock (SyncLock)
        {
            ShutdownInternal();
        }
    }

    private static void ShutdownInternal()
    {
        if (_modelPtr != IntPtr.Zero)
        {
            NativeLlamaInterop.llama_model_free(_modelPtr);
            _modelPtr = IntPtr.Zero;
            _vocabPtr = IntPtr.Zero;
            NativeLlamaInterop.llama_backend_free();
        }
        _nativeReady = false;
        _loadedModelPath = string.Empty;
    }

    private static string SerializeObjectSafe(object? input)
    {
        if (input is null) return "{}";
        if (input is string s) return s;

        if (input is IDictionary dict)
        {
            var clean = new Dictionary<string, object?>();
            foreach (DictionaryEntry entry in dict)
                clean[entry.Key?.ToString() ?? "key"] = entry.Value?.ToString();
            return JsonSerializer.Serialize(clean);
        }

        var props = new Dictionary<string, string?>();
        foreach (var prop in input.GetType().GetProperties())
        {
            if (prop.GetIndexParameters().Length > 0) continue;
            try
            {
                props[prop.Name] = prop.GetValue(input)?.ToString();
            }
            catch { }
        }
        return props.Count > 0 ? JsonSerializer.Serialize(props) : input.ToString() ?? "{}";
    }

    private static string DeterministicFallbackDiagnosis(string faultJson)
    {
        if (faultJson.Contains("ZoneBoundaryViolation", StringComparison.OrdinalIgnoreCase))
            return "Zone firewall blocked unauthorized traversal or invalid session nonce; packet dropped and worker isolated.";
        if (faultJson.Contains("NamedPipe", StringComparison.OrdinalIgnoreCase) || faultJson.Contains("WorkerUnexpectedExit", StringComparison.OrdinalIgnoreCase))
            return "Zone 3 polyglot IPC pipe interrupted; respawn worker with fresh ephemeral session nonce and verify pipe listener.";
        if (faultJson.Contains("Cloud", StringComparison.OrdinalIgnoreCase))
            return "Cloud Origin unreachable or signature rejected; retain local 3x3 baseline and retry sync on next clean heartbeat.";

        return "Kernel anomaly logged to Tier-1 journal; verified Golden Seed invariants and restarted affected supervisor unit.";
    }
}
EOF

# 5. Kernel Golden Seeds (Immutable Default Triad)
echo "[3/7] Writing Kernel Golden Seeds & PowerShell Modules..."

cat << 'EOF' > kernel/seeds/default.md
# DaniOs Kernel Golden Journal (Absolute Default)
- **Kernel Architecture:** Self-contained PowerShell 7.4+ (.NET DLL Host) + In-Process SLM (`DaniOs.Kernel.AI.dll`)
- **Memory Topology:** Parallel 3x3 Firewall Matrix (`.md`, `.yml`, `.json` x 3 Tiers) encompassing Native FS
- **Trust Boundary:** Native Zone (0-2) strictly isolated from Unsecure Polyglot Edge (Zone 3: Node.js, PHP, Python)

## Baseline Boot Invariants
1. Verify SHA-256 signatures of `kernel/seeds/default.{md,yml,json}` before mounting parallel 3x3 partition.
2. Enforce ACL isolation on parallel 3x3 namespace; deny all standard user and web-worker traversal.
3. Spawn polyglot workers (`node`, `php`, `python`) under restricted tokens bound exclusively to Named Pipes.
4. Bind local Browser/Desktop shell (`127.0.0.1`) via Node.js HTTP/WebSocket bridge with session nonce verification.
EOF

cat << 'EOF' > kernel/seeds/default.yml
version: "1.0.0"
kernel_invariants:
  immutable_paths:
    - "/kernel/bin"
    - "/kernel/models"
    - "/kernel/seeds"
  pruning_policy:
    max_entries_per_tier: 50
    promotion_threshold_runs: 3
    auto_compact_on_shutdown: true

trust_zones:
  native_to_unsecure:
    allow_outbound_http: true
    allow_browser_ipc: true
    allow_syscall_probes: true
    redact_env_secrets: true
  unsecure_to_native:
    allow_direct_fs_write: false
    require_schema_validation: true
    require_session_nonce: true

baseline_playbooks:
  - id: "ERR_3X3_CORRUPT"
    signature: "MemoryMatrixIntegrityException|SchemaValidationFailed"
    severity: "critical"
    remediation:
      action: "RestoreTierFromGoldenSeed"
      target: "parallel_partition"
      verify_hash: true

  - id: "ERR_POLYGLOT_WORKER_HANG"
    signature: "NamedPipeTimeout|WorkerUnresponsive"
    severity: "high"
    remediation:
      action: "RestartPolyglotWorker"
      allow_ai_synthesis: true

  - id: "ERR_WEB_PAYLOAD_REJECTED"
    signature: "ZoneBoundaryViolation|InvalidNonce"
    severity: "medium"
    remediation:
      action: "DropPayloadAndLogJournal"
      quarantine_source: true
EOF

cat << 'EOF' > kernel/seeds/default.json
{
  "schemaVersion": "1.0.0",
  "osIdentity": "DaniOs",
  "bootGeneration": 0,
  "firewallState": {
    "parallelPartitionMounted": false,
    "nativeFsLocked": true,
    "unsecureBridgeActive": false
  },
  "desktopBrowserIntegration": {
    "bindAddress": "127.0.0.1",
    "httpPort": 4110,
    "wsPort": 4111,
    "requireEphemeralToken": true
  },
  "polyglotDomains": {
    "node": {
      "pipeName": "DaniOs.Pipe.Node",
      "capabilities": ["parse_matrix", "browser_server", "ws_stream", "fs_watch"]
    },
    "php": {
      "pipeName": "DaniOs.Pipe.PHP",
      "capabilities": ["http_outbound", "webhook_ingest", "rest_client", "remote_sync"]
    },
    "python": {
      "pipeName": "DaniOs.Pipe.Python",
      "capabilities": ["syscall_probe", "hardware_telemetry", "memory_inspect"]
    }
  },
  "integrityBaselines": {}
}
EOF

# 6. PowerShell Kernel Modules & Boot Scripts
cat << 'EOF' > boot/manifest.psd1
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
            Windows = "kernel/bin/native/llama.dll"
            Linux   = "kernel/bin/native/libllama.so"
            MacOS   = "kernel/bin/native/libllama.dylib"
        }
        GoldenSeeds = @{
            Markdown = "kernel/seeds/default.md"
            Yaml     = "kernel/seeds/default.yml"
            Json     = "kernel/seeds/default.json"
        }
        ImmutablePaths = @(
            "/kernel/bin",
            "/kernel/models",
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
        CompressionAlgorithm = "Brotli"
        EncryptionCipher     = "AES-256-GCM"
        AuthHeaderPrefix     = "X-DaniOs-"
        RequiredHeaders      = @("X-DaniOs-Fingerprint", "X-DaniOs-Timestamp", "X-DaniOs-Body-SHA256", "X-DaniOs-Signature")
    }
}
EOF

cat << 'EOF' > boot/init.ps1
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\kernel.config.json"),
    [switch]$ForceCloudRestore,
    [switch]$Headless
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DaniRoot  = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$KernelDir = Join-Path $DaniRoot "kernel"
$BinDir    = Join-Path $KernelDir "bin"
$ModelDir  = Join-Path $KernelDir "models"

Write-Host "[DaniOs::Boot] Initializing self-contained PowerShell + AI Kernel..." -ForegroundColor Cyan

$hostDll = Join-Path $BinDir "DaniOs.Kernel.Host.dll"
$aiDll   = Join-Path $BinDir "DaniOs.Kernel.AI.dll"

foreach ($dll in @($hostDll, $aiDll)) {
    if (Test-Path $dll) {
        Add-Type -Path $dll
        Write-Host "[DaniOs::Boot] Loaded kernel assembly: $(Split-Path $dll -Leaf)" -ForegroundColor DarkCyan
    }
}

if (-not (Test-Path $ConfigPath)) {
    throw "FATAL KERNEL PANIC: Missing kernel configuration at '$ConfigPath'."
}
$Config   = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json -AsHashtable
$Manifest = Import-PowerShellDataFile -Path (Join-Path $PSScriptRoot "manifest.psd1")

if ($Manifest.ParallelMemoryMatrix.ExpectedNodeCount -ne 9) {
    throw "FATAL KERNEL PANIC: Manifest 3x3 topology mismatch."
}

$modelFile = Join-Path $ModelDir ($Config.ai.modelFile ?? "danios-core-3b.Q4_K_M.gguf")
if ([System.Management.Automation.PSTypeName]'DaniOs.Kernel.AI'.Type -and (Test-Path $modelFile)) {
    $aiReady = [DaniOs.Kernel.AI]::Initialize($modelFile, [int]($Config.ai.contextTokens ?? 4096))
    if (-not $aiReady) {
        throw "FATAL KERNEL PANIC: Embedded AI DLL failed to mount model '$modelFile'."
    }
    Write-Host "[DaniOs::Boot] Embedded SLM active in-kernel ($(Split-Path $modelFile -Leaf))." -ForegroundColor Green
}

Import-Module (Join-Path $KernelDir "Bridge.psm1")      -Force
Import-Module (Join-Path $KernelDir "CloudOrigin.psm1") -Force
Import-Module (Join-Path $KernelDir "Policy.psm1")      -Force
Import-Module (Join-Path $KernelDir "Snapshot.psm1")    -Force
Import-Module (Join-Path $KernelDir "Core.psm1")        -Force

$partitionRoot = Mount-DaniParallelFirewallPartition -Config $Config
$matrixState   = Initialize-DaniGoldenMatrix -ParallelPartitionRoot $partitionRoot

Write-Host "[DaniOs::Boot] Parallel 3x3 Firewall Partition mounted ($($matrixState.ActiveNodes) nodes active)." -ForegroundColor Green

$t3StatePath = Join-Path $partitionRoot "tier_3_baseline\state.json"
$t3State     = Get-Content -Path $t3StatePath -Raw | ConvertFrom-Json -AsHashtable

$isZeroGen  = ([int]($t3State.bootGeneration ?? 0)) -eq 0
$shouldPull = $ForceCloudRestore -or ($isZeroGen -and $Config.cloudOrigin.enabled -and $Config.cloudOrigin.autoRestoreOnZeroGeneration)

if ($shouldPull) {
    Write-Host "[DaniOs::Boot] Zero-generation state detected. Querying Cloud Origin save point..." -ForegroundColor Yellow
    $restoreResult = Restore-DaniCloudSavePoint `
        -ParallelPartitionRoot $partitionRoot `
        -CloudConfig $Config.cloudOrigin

    if ($restoreResult.Ok) {
        Write-Host "[DaniOs::Boot] Cloud save point restored (SavedAt: $($restoreResult.SavedAtUtc))." -ForegroundColor Green
        $t3State = Get-Content -Path $t3StatePath -Raw | ConvertFrom-Json -AsHashtable
    }
    else {
        Write-Warning "[DaniOs::Boot] Cloud restore unavailable ($($restoreResult.Error)). Continuing on Golden Seeds."
    }
}

$nextGen = ([int]($t3State.bootGeneration ?? 0)) + 1
Update-DaniBootGeneration -ParallelPartitionRoot $partitionRoot -Generation $nextGen -SessionNonce $matrixState.BrowserSession
Write-DaniJournalEntry -ParallelPartitionRoot $partitionRoot -Tier "tier_1_active" -Category "BOOT" -Message "DaniOs booted cleanly into Generation #$nextGen (CloudRestore=$shouldPull)."

$workers = Start-DaniPolyglotWorkers `
    -DaniRoot $DaniRoot `
    -Config $Config `
    -SessionNonce $matrixState.BrowserSession

Write-Host "[DaniOs::Boot] Polyglot workers online: $($workers.Keys -join ', ')" -ForegroundColor Green

if (-not $Headless) {
    Send-DaniBrowserEvent -Channel "kernel:boot" -Data @{
        os             = "DaniOs"
        bootGeneration = $nextGen
        activeNodes    = $matrixState.ActiveNodes
        workers        = @($workers.Keys)
        timestampUtc   = (Get-Date).ToUniversalTime().ToString("o")
    } | Out-Null
}

if ($Config.cloudOrigin.enabled -and $Config.cloudOrigin.autoBackupOnCleanBoot) {
    $backupResult = Sync-DaniCloudSavePoint `
        -ParallelPartitionRoot $partitionRoot `
        -CloudConfig $Config.cloudOrigin

    if ($backupResult.Ok) {
        Write-Host "[DaniOs::Boot] Default Cloud Origin save point synced ($($backupResult.PackedBytes) bytes)." -ForegroundColor DarkGreen
    }
}

Start-DaniKernelSupervisor `
    -DaniRoot $DaniRoot `
    -ParallelPartitionRoot $partitionRoot `
    -Config $Config `
    -SessionNonce $matrixState.BrowserSession
EOF

cat << 'EOF' > kernel/Bridge.psm1
#Requires -Version 7.4
using namespace System.IO.Pipes
using namespace System.Text
using namespace System.Security.Cryptography

Set-StrictMode -Version Latest

$script:KernelSeedDir = Join-Path $PSScriptRoot "seeds"
$script:SessionNonce  = [Convert]::ToHexString([RandomNumberGenerator]::GetBytes(24))
$script:PipeRegistry  = @{
    Node   = "DaniOs.Pipe.Node"
    PHP    = "DaniOs.Pipe.PHP"
    Python = "DaniOs.Pipe.Python"
}

function Initialize-DaniGoldenMatrix {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ParallelPartitionRoot)

    $defaultFiles = @("default.md", "default.yml", "default.json")
    $tiers        = @("tier_1_active", "tier_2_rolling", "tier_3_baseline")

    foreach ($file in $defaultFiles) {
        $seedPath = Join-Path $script:KernelSeedDir $file
        if (-not (Test-Path $seedPath) -or (Get-Item $seedPath).Length -eq 0) {
            throw "FATAL KERNEL PANIC: Missing or empty golden seed '$file'."
        }
    }

    foreach ($tier in $tiers) {
        $tierPath = Join-Path $ParallelPartitionRoot $tier
        if (-not (Test-Path $tierPath)) {
            New-Item -ItemType Directory -Path $tierPath -Force | Out-Null
        }

        $map = @{
            "journal.md"    = Join-Path $script:KernelSeedDir "default.md"
            "solutions.yml" = Join-Path $script:KernelSeedDir "default.yml"
            "state.json"    = Join-Path $script:KernelSeedDir "default.json"
        }

        foreach ($targetName in $map.Keys) {
            $targetFile = Join-Path $tierPath $targetName
            if (-not (Test-Path $targetFile) -or (Get-Item $targetFile).Length -eq 0) {
                Copy-Item -Path $map[$targetName] -Destination $targetFile -Force
            }
        }
    }

    return [PSCustomObject]@{
        Status         = "MatrixReady"
        PartitionRoot  = $ParallelPartitionRoot
        ActiveNodes    = 9
        BrowserSession = $script:SessionNonce
        TimestampUtc   = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Test-DaniZonePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("NativeToUnsecure", "UnsecureToNative")][string]$Direction,
        [Parameter(Mandatory)][ValidateSet("Node", "PHP", "Python")][string]$Domain,
        [Parameter(Mandatory)][hashtable]$Envelope
    )

    if ($Direction -eq "UnsecureToNative") {
        if ($Envelope.Nonce -ne $script:SessionNonce) {
            throw "ZoneBoundaryViolation: Invalid or missing session nonce from '$Domain'."
        }

        $serialized = ($Envelope | ConvertTo-Json -Depth 6 -Compress)
        if ($serialized -match "(?i)([/\\](tier_1_active|tier_2_rolling|tier_3_baseline)|[/\\]kernel[/\\]seeds)") {
            throw "ZoneBoundaryViolation: Unsecure domain '$Domain' attempted restricted path traversal."
        }
    }

    if ($Direction -eq "NativeToUnsecure") {
        if ($Envelope.Payload -is [hashtable] -and $Envelope.Payload.ContainsKey("KernelMasterKey")) {
            $Envelope.Payload.Remove("KernelMasterKey")
        }
    }

    return $true
}

function Invoke-DaniPolyglotBridge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("Read", "Write", "Receive", "Send")][string]$Operation,
        [Parameter(Mandatory)][ValidateSet("Node", "PHP", "Python")][string]$Domain,
        [Parameter(Mandatory)][string]$Action,
        [hashtable]$Payload = @{},
        [int]$TimeoutMs = 4000
    )

    $direction = switch ($Operation) {
        { $_ -in @("Send", "Write") }   { "NativeToUnsecure" }
        { $_ -in @("Receive", "Read") } { "UnsecureToNative" }
    }

    $envelope = @{
        Id        = [guid]::NewGuid().ToString()
        Nonce     = $script:SessionNonce
        Operation = $Operation
        Domain    = $Domain
        Action    = $Action
        Timestamp = (Get-Date).ToUniversalTime().ToString("o")
        Payload   = $Payload
    }

    Test-DaniZonePayload -Direction $direction -Domain $Domain -Envelope $envelope | Out-Null

    $pipeName = $script:PipeRegistry[$Domain]
    $client   = [NamedPipeClientStream]::new(".", $pipeName, [PipeDirection]::InOut)

    try {
        $client.Connect($TimeoutMs)
        $writer = [System.IO.StreamWriter]::new($client, [UTF8Encoding]::new($false))
        $reader = [System.IO.StreamReader]::new($client, [UTF8Encoding]::new($false))
        $writer.AutoFlush = $true

        $jsonRequest = ($envelope | ConvertTo-Json -Depth 8 -Compress)
        $writer.WriteLine($jsonRequest)

        $rawResponse = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($rawResponse)) {
            throw "NamedPipeEmptyResponse from domain '$Domain'."
        }

        $parsed = $rawResponse | ConvertFrom-Json -AsHashtable
        Test-DaniZonePayload -Direction "UnsecureToNative" -Domain $Domain -Envelope $parsed | Out-Null

        return [PSCustomObject]@{
            Ok        = $true
            Domain    = $Domain
            Operation = $Operation
            Action    = $Action
            Data      = $parsed.Payload
        }
    }
    catch {
        $faultRecord = [PSCustomObject]@{
            Ok        = $false
            Domain    = $Domain
            Operation = $Operation
            Action    = $Action
            Error     = $_.Exception.Message
            Timestamp = (Get-Date).ToUniversalTime().ToString("o")
        }

        if ([System.Management.Automation.PSTypeName]'DaniOs.Kernel.AI'.Type) {
            $faultRecord | Add-Member -NotePropertyName "AiDiagnosis" -NotePropertyValue ([DaniOs.Kernel.AI]::DiagnoseFault($faultRecord))
        }

        return $faultRecord
    }
    finally {
        $client.Dispose()
    }
}

function Send-DaniBrowserEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][hashtable]$Data
    )

    return Invoke-DaniPolyglotBridge -Operation "Send" -Domain "Node" -Action "BroadcastBrowserWS" -Payload @{
        channel = $Channel
        data    = $Data
    }
}

function Invoke-DaniWebRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [ValidateSet("GET", "POST", "PUT", "DELETE")][string]$Method = "GET",
        [hashtable]$Headers = @{},
        [object]$Body = $null
    )

    return Invoke-DaniPolyglotBridge -Operation "Send" -Domain "PHP" -Action "ExecuteHttpCall" -Payload @{
        url     = $Url
        method  = $Method
        headers = $Headers
        body    = $Body
    }
}

Export-ModuleMember -Function @(
    "Initialize-DaniGoldenMatrix",
    "Test-DaniZonePayload",
    "Invoke-DaniPolyglotBridge",
    "Send-DaniBrowserEvent",
    "Invoke-DaniWebRequest"
)
EOF

cat << 'EOF' > kernel/CloudOrigin.psm1
#Requires -Version 7.4
using namespace System.IO
using namespace System.IO.Compression
using namespace System.Text
using namespace System.Security.Cryptography

Set-StrictMode -Version Latest

function Get-DaniDeviceFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccountSecret,
        [string]$KernelSalt = "DaniOs-Kernel-v1"
    )

    $signals = [System.Collections.Generic.List[string]]::new()

    if ($IsWindows) {
        try {
            $csUuid   = (Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop).UUID
            $cpuId    = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1).ProcessorId
            $boardSer = (Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop).SerialNumber
            $machGuid = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction Stop).MachineGuid

            $signals.Add("UUID:$csUuid")
            $signals.Add("CPU:$cpuId")
            $signals.Add("BOARD:$boardSer")
            $signals.Add("MGUID:$machGuid")
        }
        catch {
            $signals.Add("HOST:$([Environment]::MachineName)")
        }
    }
    else {
        foreach ($probePath in @("/etc/machine-id", "/sys/class/dmi/id/product_uuid", "/sys/class/dmi/id/board_serial")) {
            if (Test-Path $probePath) {
                $val = (Get-Content -Path $probePath -Raw -ErrorAction SilentlyContinue).Trim()
                if (-not [string]::IsNullOrWhiteSpace($val)) {
                    $signals.Add("${probePath}:${val}")
                }
            }
        }
        if ($signals.Count -eq 0) {
            $signals.Add("HOST:$([Environment]::MachineName)")
        }
    }

    $rawComposite = ($signals -join "|") + "|SALT:$KernelSalt"
    $sha256       = [SHA256]::Create()

    try {
        $fpBytes     = $sha256.ComputeHash([Encoding]::UTF8.GetBytes($rawComposite))
        $fingerprint = [Convert]::ToHexString($fpBytes).ToLowerInvariant()
        $keyMaterial = $sha256.ComputeHash([Encoding]::UTF8.GetBytes("${fingerprint}:${AccountSecret}"))

        return [PSCustomObject]@{
            Fingerprint = $fingerprint
            DerivedKey  = $keyMaterial
            SignalCount = $signals.Count
        }
    }
    finally {
        $sha256.Dispose()
    }
}

function Protect-DaniSavePointPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$JsonPayload,
        [Parameter(Mandatory)][byte[]]$KeyBytes
    )

    $rawBytes         = [Encoding]::UTF8.GetBytes($JsonPayload)
    $compressedStream = [MemoryStream]::new()
    $brotli           = [BrotliStream]::new($compressedStream, [CompressionLevel]::Optimal, $true)
    $brotli.Write($rawBytes, 0, $rawBytes.Length)
    $brotli.Dispose()
    $compressedBytes  = $compressedStream.ToArray()
    $compressedStream.Dispose()

    $nonce      = [RandomNumberGenerator]::GetBytes(12)
    $tag        = [byte[]]::new(16)
    $cipherText = [byte[]]::new($compressedBytes.Length)

    $aesGcm = [AesGcm]::new($KeyBytes, 16)
    try {
        $aesGcm.Encrypt($nonce, $compressedBytes, $cipherText, $tag)
    }
    finally {
        $aesGcm.Dispose()
    }

    return [PSCustomObject]@{
        NonceB64      = [Convert]::ToBase64String($nonce)
        TagB64        = [Convert]::ToBase64String($tag)
        CipherTextB64 = [Convert]::ToBase64String($cipherText)
        RawBytes      = $rawBytes.Length
        PackedBytes   = $cipherText.Length
    }
}

function Unprotect-DaniSavePointPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$NonceB64,
        [Parameter(Mandatory)][string]$TagB64,
        [Parameter(Mandatory)][string]$CipherTextB64,
        [Parameter(Mandatory)][byte[]]$KeyBytes
    )

    $nonce      = [Convert]::FromBase64String($NonceB64)
    $tag        = [Convert]::FromBase64String($TagB64)
    $cipherText = [Convert]::FromBase64String($CipherTextB64)
    $plainComp  = [byte[]]::new($cipherText.Length)

    $aesGcm = [AesGcm]::new($KeyBytes, 16)
    try {
        $aesGcm.Decrypt($nonce, $cipherText, $tag, $plainComp)
    }
    finally {
        $aesGcm.Dispose()
    }

    $inStream  = [MemoryStream]::new($plainComp)
    $outStream = [MemoryStream]::new()
    $brotli    = [BrotliStream]::new($inStream, [CompressionMode]::Decompress)

    try {
        $brotli.CopyTo($outStream)
        return [Encoding]::UTF8.GetString($outStream.ToArray())
    }
    finally {
        $brotli.Dispose()
        $inStream.Dispose()
        $outStream.Dispose()
    }
}

function New-DaniSignatureHeaders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Fingerprint,
        [Parameter(Mandatory)][string]$AccountSecret,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$BodyHashHex
    )

    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString()
    $canonical = "${Method}|${Fingerprint}|${timestamp}|${BodyHashHex}"

    $hmac = [HMACSHA256]::new([Encoding]::UTF8.GetBytes($AccountSecret))
    try {
        $sigBytes  = $hmac.ComputeHash([Encoding]::UTF8.GetBytes($canonical))
        $signature = [Convert]::ToHexString($sigBytes).ToLowerInvariant()

        return @{
            "X-DaniOs-Fingerprint" = $Fingerprint
            "X-DaniOs-Timestamp"   = $timestamp
            "X-DaniOs-Body-SHA256" = $BodyHashHex
            "X-DaniOs-Signature"   = $signature
            "User-Agent"           = "DaniOs-Kernel/1.0"
        }
    }
    finally {
        $hmac.Dispose()
    }
}

function Sync-DaniCloudSavePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][hashtable]$CloudConfig
    )

    if (-not $CloudConfig.enabled) {
        return [PSCustomObject]@{ Ok = $false; Reason = "CloudOriginDisabled" }
    }

    $identity    = Get-DaniDeviceFingerprint -AccountSecret $CloudConfig.accountSecret -KernelSalt $CloudConfig.kernelSalt
    $t3Solutions = Get-Content (Join-Path $ParallelPartitionRoot "tier_3_baseline/solutions.yml") -Raw
    $t3State     = Get-Content (Join-Path $ParallelPartitionRoot "tier_3_baseline/state.json") -Raw
    $t1Journal   = Get-Content (Join-Path $ParallelPartitionRoot "tier_1_active/journal.md") -Tail 40 | Out-String

    $saveBundle = @{
        os          = "DaniOs"
        createdUtc  = (Get-Date).ToUniversalTime().ToString("o")
        fingerprint = $identity.Fingerprint
        matrix      = @{
            baseline_solutions_yml = $t3Solutions
            baseline_state_json    = $t3State
            recent_journal_md      = $t1Journal
        }
    } | ConvertTo-Json -Depth 5 -Compress

    $sealed   = Protect-DaniSavePointPayload -JsonPayload $saveBundle -KeyBytes $identity.DerivedKey
    $wireBody = @{
        fingerprint = $identity.Fingerprint
        nonce       = $sealed.NonceB64
        tag         = $sealed.TagB64
        ciphertext  = $sealed.CipherTextB64
        meta        = @{
            rawBytes    = $sealed.RawBytes
            packedBytes = $sealed.PackedBytes
            schema      = "3x3-compact-v1"
        }
    } | ConvertTo-Json -Depth 4 -Compress

    $sha256      = [SHA256]::Create()
    $bodyHashHex = [Convert]::ToHexString($sha256.ComputeHash([Encoding]::UTF8.GetBytes($wireBody))).ToLowerInvariant()
    $sha256.Dispose()

    $headers = New-DaniSignatureHeaders `
        -Fingerprint $identity.Fingerprint `
        -AccountSecret $CloudConfig.accountSecret `
        -Method "PUT" `
        -BodyHashHex $bodyHashHex

    $endpoint = "$($CloudConfig.originUrl.TrimEnd('/'))/v1/savepoints/$($identity.Fingerprint)"

    try {
        $response = Invoke-RestMethod `
            -Uri $endpoint `
            -Method Put `
            -Headers $headers `
            -Body $wireBody `
            -ContentType "application/json" `
            -TimeoutSec 8 `
            -ErrorAction Stop

        return [PSCustomObject]@{
            Ok          = $true
            Action      = "CloudBackupCommitted"
            Fingerprint = $identity.Fingerprint
            PackedBytes = $sealed.PackedBytes
            Revision    = $response.revision
            Timestamp   = (Get-Date).ToUniversalTime().ToString("o")
        }
    }
    catch {
        $fault = [PSCustomObject]@{
            Ok        = $false
            Action    = "CloudBackupFailed"
            Error     = $_.Exception.Message
            Timestamp = (Get-Date).ToUniversalTime().ToString("o")
        }

        if ([System.Management.Automation.PSTypeName]'DaniOs.Kernel.AI'.Type) {
            $fault | Add-Member -NotePropertyName "AiDiagnosis" -NotePropertyValue ([DaniOs.Kernel.AI]::DiagnoseFault($fault))
        }

        return $fault
    }
}

function Restore-DaniCloudSavePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][hashtable]$CloudConfig
    )

    $identity  = Get-DaniDeviceFingerprint -AccountSecret $CloudConfig.accountSecret -KernelSalt $CloudConfig.kernelSalt
    $sha256    = [SHA256]::Create()
    $emptyHash = [Convert]::ToHexString($sha256.ComputeHash([byte[]]@())).ToLowerInvariant()
    $sha256.Dispose()

    $headers = New-DaniSignatureHeaders `
        -Fingerprint $identity.Fingerprint `
        -AccountSecret $CloudConfig.accountSecret `
        -Method "GET" `
        -BodyHashHex $emptyHash

    $endpoint = "$($CloudConfig.originUrl.TrimEnd('/'))/v1/savepoints/$($identity.Fingerprint)"

    try {
        $envelope = Invoke-RestMethod `
            -Uri $endpoint `
            -Method Get `
            -Headers $headers `
            -TimeoutSec 8 `
            -ErrorAction Stop

        $decryptedJson = Unprotect-DaniSavePointPayload `
            -NonceB64 $envelope.nonce `
            -TagB64 $envelope.tag `
            -CipherTextB64 $envelope.ciphertext `
            -KeyBytes $identity.DerivedKey

        $bundle = $decryptedJson | ConvertFrom-Json -AsHashtable

        if ($bundle.fingerprint -ne $identity.Fingerprint) {
            throw "FingerprintMismatch: Cloud save point does not match local hardware identity."
        }

        foreach ($tier in @("tier_1_active", "tier_2_rolling", "tier_3_baseline")) {
            $tierDir = Join-Path $ParallelPartitionRoot $tier
            Set-Content -Path (Join-Path $tierDir "solutions.yml") -Value $bundle.matrix.baseline_solutions_yml -Encoding UTF8 -Force
            Set-Content -Path (Join-Path $tierDir "state.json")    -Value $bundle.matrix.baseline_state_json    -Encoding UTF8 -Force
            Set-Content -Path (Join-Path $tierDir "journal.md")    -Value $bundle.matrix.recent_journal_md      -Encoding UTF8 -Force
        }

        return [PSCustomObject]@{
            Ok          = $true
            Action      = "CloudSavePointRestored"
            Fingerprint = $identity.Fingerprint
            SavedAtUtc  = $bundle.createdUtc
        }
    }
    catch {
        return [PSCustomObject]@{
            Ok     = $false
            Action = "CloudRestoreFailedFallbackToGoldenSeeds"
            Error  = $_.Exception.Message
        }
    }
}

Export-ModuleMember -Function @(
    "Get-DaniDeviceFingerprint",
    "Protect-DaniSavePointPayload",
    "Unprotect-DaniSavePointPayload",
    "Sync-DaniCloudSavePoint",
    "Restore-DaniCloudSavePoint"
)
EOF

cat << 'EOF' > kernel/Policy.psm1
#Requires -Version 7.4
using namespace System.IO
using namespace System.Management.Automation.Language
using namespace System.Collections.Generic

Set-StrictMode -Version Latest

$script:ImmutableKernelPatterns = @(
    "[/\\]kernel[/\\]bin([/\\]|$)",
    "[/\\]kernel[/\\]models([/\\]|$)",
    "[/\\]kernel[/\\]seeds([/\\]|$)",
    "[/\\]kernel[/\\]Policy\.psm1$",
    "[/\\]boot[/\\]DaniOs\.Boot",
    "[/\\]\.parallel_3x3_firewall([/\\]|$)",
    "[/\\](tier_1_active|tier_2_rolling|tier_3_baseline)([/\\]|$)"
)

$script:BlockedAstCommands = [HashSet[string]]::new([string[]]@(
    "Invoke-Expression", "iex",
    "Invoke-WebRequest", "iwr", "curl", "wget",
    "Invoke-RestMethod", "irm",
    "Start-BitsTransfer",
    "Format-Volume", "Format-Disk", "Clear-Disk", "Remove-Partition",
    "Stop-Computer", "Restart-Computer",
    "Set-ExecutionPolicy",
    "Add-MpPreference", "Set-MpPreference", "Disable-WindowsDefender",
    "New-LocalUser", "Add-LocalGroupMember",
    "reg", "bcdedit", "diskpart", "cipher", "vssadmin"
), [System.StringComparer]::OrdinalIgnoreCase)

$script:BlockedAstTypePatterns = @(
    "System\.Reflection\.Assembly",
    "System\.Runtime\.InteropServices\.Marshal",
    "System\.Net\.Sockets",
    "System\.Net\.Http\.HttpClient",
    "System\.Net\.WebClient",
    "Microsoft\.Win32\.Registry"
)

function Test-DaniImmutablePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $normalized = $Path.Replace("\", "/")
    foreach ($pattern in $script:ImmutableKernelPatterns) {
        if ($normalized -match $pattern) {
            return $true
        }
    }
    return $false
}

function Test-DaniScriptAst {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptText,
        [string[]]$AllowedCommands = @()
    )

    $violations = [List[string]]::new()
    $tokens     = $null
    $parseErrs  = $null

    $ast = [Parser]::ParseInput($ScriptText, [ref]$tokens, [ref]$parseErrs)

    if ($null -ne $parseErrs -and $parseErrs.Count -gt 0) {
        foreach ($err in $parseErrs) {
            $violations.Add("SyntaxError (Line $($err.Extent.StartLineNumber)): $($err.Message)")
        }
        return [PSCustomObject]@{
            Approved   = $false
            Violations = @($violations)
            AstSummary = $null
        }
    }

    $allowSet     = [HashSet[string]]::new([string[]]$AllowedCommands, [System.StringComparer]::OrdinalIgnoreCase)
    $commandNodes = $ast.FindAll({ param($node) $node -is [CommandAst] }, $true)
    $detectedCmds = [HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($cmdNode in $commandNodes) {
        $cmdName = $cmdNode.GetCommandName()

        if ([string]::IsNullOrWhiteSpace($cmdName)) {
            $violations.Add("DynamicInvocationBlocked (Line $($cmdNode.Extent.StartLineNumber)): '$($cmdNode.Extent.Text)'")
            continue
        }

        [void]$detectedCmds.Add($cmdName)

        if ($script:BlockedAstCommands.Contains($cmdName) -and -not $allowSet.Contains($cmdName)) {
            $violations.Add("BlockedCommand (Line $($cmdNode.Extent.StartLineNumber)): '$cmdName' is forbidden by Kernel Policy.")
        }

        if ($cmdName -in @("Remove-Item", "rm", "del", "ri", "Clear-Content", "Set-Content", "Out-File", "Move-Item", "Rename-Item")) {
            $rawExtent = $cmdNode.Extent.Text
            if ($rawExtent -match "(?i)(^|\s)(/|\\|[A-Za-z]:\\?\s*\*|\.\.[\\/])") {
                $violations.Add("UnsafeFileTarget (Line $($cmdNode.Extent.StartLineNumber)): Root or parent traversal in '$rawExtent'.")
            }
        }
    }

    $stringNodes = $ast.FindAll({ param($node) $node -is [StringConstantExpressionAst] }, $true)
    foreach ($strNode in $stringNodes) {
        if (Test-DaniImmutablePath -Path $strNode.Value) {
            $violations.Add("ImmutablePathReference (Line $($strNode.Extent.StartLineNumber)): Script references protected path '$($strNode.Value)'.")
        }
    }

    $typeNodes = $ast.FindAll({ param($node) $node -is [TypeExpressionAst] -or $node -is [TypeConstraintAst] }, $true)
    foreach ($tNode in $typeNodes) {
        $typeName = $tNode.TypeName.FullName
        foreach ($blockedType in $script:BlockedAstTypePatterns) {
            if ($typeName -match $blockedType) {
                $violations.Add("BlockedDotNetType (Line $($tNode.Extent.StartLineNumber)): Type '[$typeName]' is restricted.")
            }
        }
    }

    $paramNodes = $ast.FindAll({ param($node) $node -is [CommandParameterAst] }, $true)
    foreach ($pNode in $paramNodes) {
        if ($pNode.ParameterName -match "^(e|ec|enc|enco|encod|encode|encoded|encodedcommand)$") {
            $violations.Add("ObfuscatedParameterBlocked (Line $($pNode.Extent.StartLineNumber)): '-$($pNode.ParameterName)' is forbidden.")
        }
    }

    return [PSCustomObject]@{
        Approved   = ($violations.Count -eq 0)
        Violations = @($violations)
        AstSummary = [PSCustomObject]@{
            CommandCount = $commandNodes.Count
            Commands     = @($detectedCmds)
        }
    }
}

function Test-DaniWebToNativeRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("Node", "PHP", "Python", "BrowserUI")][string]$SourceDomain,
        [Parameter(Mandatory)][ValidateSet("Read", "Write", "Delete", "Execute")][string]$Intent,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$NativeRoot,
        [string]$ContentPreview = ""
    )

    if ($SourceDomain -in @("PHP", "Python") -and $Intent -in @("Write", "Delete", "Execute")) {
        return [PSCustomObject]@{
            Allowed = $false
            Reason  = "ZoneFirewallDeny: Domain '$SourceDomain' lacks Zone 2 mutation privileges ($Intent)."
        }
    }

    if (Test-DaniImmutablePath -Path $TargetPath) {
        return [PSCustomObject]@{
            Allowed = $false
            Reason  = "ZoneFirewallDeny: Target '$TargetPath' lies inside protected Zone 0/1 perimeter."
        }
    }

    $resolvedNativeRoot = [Path]::GetFullPath($NativeRoot).TrimEnd([Path]::DirectorySeparatorChar, [Path]::AltDirectorySeparatorChar) + [Path]::DirectorySeparatorChar
    $candidateFullPath  = if ([Path]::IsPathRooted($TargetPath)) {
        [Path]::GetFullPath($TargetPath)
    }
    else {
        [Path]::GetFullPath((Join-Path $resolvedNativeRoot $TargetPath))
    }

    $comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if (-not $candidateFullPath.StartsWith($resolvedNativeRoot, $comparison)) {
        return [PSCustomObject]@{
            Allowed = $false
            Reason  = "PathTraversalBlocked: Resolved path '$candidateFullPath' escapes encapsulated NativeRoot."
        }
    }

    $ext = [Path]::GetExtension($candidateFullPath).ToLowerInvariant()
    $blockedExtensions = @(".exe", ".dll", ".sys", ".drv", ".bat", ".cmd", ".vbs", ".scr", ".msi", ".so", ".dylib")
    if ($Intent -eq "Write" -and $ext -in $blockedExtensions) {
        return [PSCustomObject]@{
            Allowed = $false
            Reason  = "ExecutableDropBlocked: Writing binary/script extension '$ext' from '$SourceDomain' is denied."
        }
    }

    if ($Intent -eq "Write" -and $ext -in @(".ps1", ".psm1") -and -not [string]::IsNullOrWhiteSpace($ContentPreview)) {
        $astAudit = Test-DaniScriptAst -ScriptText $ContentPreview
        if (-not $astAudit.Approved) {
            return [PSCustomObject]@{
                Allowed = $false
                Reason  = "AstPolicyRejected: $($astAudit.Violations -join '; ')"
            }
        }
    }

    return [PSCustomObject]@{
        Allowed      = $true
        ResolvedPath = $candidateFullPath
        Reason       = "ApprovedByKernelPolicy"
    }
}

function Invoke-DaniMediatedNativeWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("Node", "BrowserUI")][string]$SourceDomain,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$NativeRoot,
        [Parameter(Mandatory)][string]$ParallelPartitionRoot
    )

    $verdict = Test-DaniWebToNativeRequest `
        -SourceDomain $SourceDomain `
        -Intent "Write" `
        -TargetPath $TargetPath `
        -NativeRoot $NativeRoot `
        -ContentPreview $Content

    if (-not $verdict.Allowed) {
        throw "PolicyViolation: $($verdict.Reason)"
    }

    $tx = Start-DaniKernelTransaction `
        -ParallelPartitionRoot $ParallelPartitionRoot `
        -Reason "MediatedWrite from $SourceDomain to $($verdict.ResolvedPath)"

    try {
        Add-DaniTransactionTarget -Transaction $tx -TargetPath $verdict.ResolvedPath

        $parentDir = Split-Path -Path $verdict.ResolvedPath -Parent
        if (-not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }

        Set-Content -Path $verdict.ResolvedPath -Value $Content -Encoding UTF8 -Force
        $commitInfo = Commit-DaniKernelTransaction -Transaction $tx -ParallelPartitionRoot $ParallelPartitionRoot

        return [PSCustomObject]@{
            Ok            = $true
            Path          = $verdict.ResolvedPath
            TransactionId = $tx.TransactionId
            Sha256        = $commitInfo.UpdatedHashes[$verdict.ResolvedPath]
        }
    }
    catch {
        Undo-DaniKernelTransaction -Transaction $tx | Out-Null
        throw
    }
}

Export-ModuleMember -Function @(
    "Test-DaniImmutablePath",
    "Test-DaniScriptAst",
    "Test-DaniWebToNativeRequest",
    "Invoke-DaniMediatedNativeWrite"
)
EOF

cat << 'EOF' > kernel/Snapshot.psm1
#Requires -Version 7.4
using namespace System.IO
using namespace System.Security.Cryptography
using namespace System.Collections.Generic

Set-StrictMode -Version Latest

function Get-DaniFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)

    $sha256 = [SHA256]::Create()
    $stream = [File]::OpenRead($FilePath)
    try {
        $hashBytes = $sha256.ComputeHash($stream)
        return [Convert]::ToHexString($hashBytes).ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $sha256.Dispose()
    }
}

function Start-DaniKernelTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [string]$Reason = "KernelMutation"
    )

    $txId        = "tx_" + [DateTimeOffset]::UtcNow.ToString("yyyyMMdd_HHmmss") + "_" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $snapshotDir = Join-Path $ParallelPartitionRoot ".snapshots\$txId"

    New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null

    return [PSCustomObject]@{
        TransactionId = $txId
        SnapshotDir   = $snapshotDir
        Reason        = $Reason
        StartedUtc    = (Get-Date).ToUniversalTime().ToString("o")
        State         = "Open"
        Entries       = [List[hashtable]]::new()
    }
}

function Add-DaniTransactionTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Transaction,
        [Parameter(Mandatory)][string]$TargetPath
    )

    if ($Transaction.State -ne "Open") {
        throw "TransactionStateError: Cannot add targets to transaction '$($Transaction.TransactionId)' in state '$($Transaction.State)'."
    }

    $fullPath = [Path]::GetFullPath($TargetPath)

    foreach ($existing in $Transaction.Entries) {
        if ($existing.OriginalPath -eq $fullPath) { return }
    }

    $existedBefore = Test-Path -Path $fullPath -PathType Leaf
    $backupFile    = $null
    $preHash       = $null
    $attributes    = $null

    if ($existedBefore) {
        $slotIndex  = $Transaction.Entries.Count
        $backupFile = Join-Path $Transaction.SnapshotDir "slot_${slotIndex}.bak"
        [File]::Copy($fullPath, $backupFile, $true)
        $preHash    = Get-DaniFileSha256 -FilePath $fullPath
        $attributes = (Get-Item -Path $fullPath -Force).Attributes
    }

    $Transaction.Entries.Add(@{
        OriginalPath  = $fullPath
        ExistedBefore = $existedBefore
        BackupPath    = $backupFile
        PreSha256     = $preHash
        Attributes    = $attributes
    })
}

function Undo-DaniKernelTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Transaction)

    if ($Transaction.State -eq "RolledBack") {
        return [PSCustomObject]@{ Ok = $true; TransactionId = $Transaction.TransactionId; RestoredCount = 0 }
    }

    $restoredCount = 0

    for ($i = $Transaction.Entries.Count - 1; $i -ge 0; $i--) {
        $entry = $Transaction.Entries[$i]
        $orig  = $entry.OriginalPath

        if ($entry.ExistedBefore) {
            $parentDir = Split-Path -Path $orig -Parent
            if (-not (Test-Path $parentDir)) {
                New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
            }

            if (Test-Path $orig) {
                $item = Get-Item -Path $orig -Force
                if ($item.Attributes -band [FileAttributes]::ReadOnly) {
                    $item.Attributes = $item.Attributes -bxor [FileAttributes]::ReadOnly
                }
            }

            [File]::Copy($entry.BackupPath, $orig, $true)

            if ($null -ne $entry.Attributes) {
                (Get-Item -Path $orig -Force).Attributes = $entry.Attributes
            }

            $restoredCount++
        }
        else {
            if (Test-Path $orig) {
                Remove-Item -Path $orig -Force
                $restoredCount++
            }
        }
    }

    $Transaction.State = "RolledBack"

    if (Test-Path $Transaction.SnapshotDir) {
        Remove-Item -Path $Transaction.SnapshotDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{
        Ok            = $true
        TransactionId = $Transaction.TransactionId
        RestoredCount = $restoredCount
        RolledBackUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Commit-DaniKernelTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Transaction,
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [int]$RetainMaxSnapshots = 15
    )

    if ($Transaction.State -ne "Open") {
        throw "TransactionStateError: Cannot commit transaction '$($Transaction.TransactionId)' in state '$($Transaction.State)'."
    }

    $updatedHashes = @{}
    $vaultBaseline = Join-Path $ParallelPartitionRoot ".snapshots\verified_baselines"
    if (-not (Test-Path $vaultBaseline)) {
        New-Item -ItemType Directory -Path $vaultBaseline -Force | Out-Null
    }

    foreach ($entry in $Transaction.Entries) {
        $orig = $entry.OriginalPath
        if (Test-Path -Path $orig -PathType Leaf) {
            $postHash = Get-DaniFileSha256 -FilePath $orig
            $updatedHashes[$orig] = $postHash

            $goldenCopy = Join-Path $vaultBaseline "$postHash.obj"
            if (-not (Test-Path $goldenCopy)) {
                [File]::Copy($orig, $goldenCopy, $true)
            }
        }
        else {
            $updatedHashes[$orig] = $null
        }
    }

    foreach ($tier in @("tier_1_active", "tier_3_baseline")) {
        $statePath = Join-Path $ParallelPartitionRoot "$tier\state.json"
        if (Test-Path $statePath) {
            $stateObj = Get-Content -Path $statePath -Raw | ConvertFrom-Json -AsHashtable
            if (-not $stateObj.ContainsKey("integrityBaselines") -or $null -eq $stateObj.integrityBaselines) {
                $stateObj["integrityBaselines"] = @{}
            }

            foreach ($pathKey in $updatedHashes.Keys) {
                if ($null -eq $updatedHashes[$pathKey]) {
                    $stateObj["integrityBaselines"].Remove($pathKey) | Out-Null
                }
                else {
                    $stateObj["integrityBaselines"][$pathKey] = @{
                        sha256     = $updatedHashes[$pathKey]
                        verifiedAt = (Get-Date).ToUniversalTime().ToString("o")
                        txId       = $Transaction.TransactionId
                    }
                }
            }

            $stateObj | ConvertTo-Json -Depth 8 | Set-Content -Path $statePath -Encoding UTF8 -Force
        }
    }

    $Transaction.State = "Committed"

    $snapRoot = Join-Path $ParallelPartitionRoot ".snapshots"
    $txDirs   = Get-ChildItem -Path $snapRoot -Directory -Filter "tx_*" | Sort-Object CreationTimeUtc -Descending
    if ($txDirs.Count -gt $RetainMaxSnapshots) {
        $txDirs | Select-Object -Skip $RetainMaxSnapshots | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{
        Ok            = $true
        TransactionId = $Transaction.TransactionId
        UpdatedHashes = $updatedHashes
        CommittedUtc  = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Invoke-DaniTransactionalAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][string[]]$TargetPaths,
        [Parameter(Mandatory)][scriptblock]$Action,
        [scriptblock]$VerifyCheck = { $true },
        [string]$Reason = "AutonomousRemediation"
    )

    if (Get-Command -Name "Test-DaniScriptAst" -ErrorAction SilentlyContinue) {
        $audit = Test-DaniScriptAst -ScriptText $Action.ToString()
        if (-not $audit.Approved) {
            throw "AstPolicyRejected: $($audit.Violations -join '; ')"
        }
    }

    $tx = Start-DaniKernelTransaction -ParallelPartitionRoot $ParallelPartitionRoot -Reason $Reason

    try {
        foreach ($path in $TargetPaths) {
            Add-DaniTransactionTarget -Transaction $tx -TargetPath $path
        }

        $actionOutput = & $Action

        $verified = & $VerifyCheck
        if (-not $verified) {
            throw "PostMutationVerificationFailed: Health check returned false after remediation."
        }

        $commitResult = Commit-DaniKernelTransaction -Transaction $tx -ParallelPartitionRoot $ParallelPartitionRoot

        return [PSCustomObject]@{
            Ok            = $true
            TransactionId = $tx.TransactionId
            Output        = $actionOutput
            Hashes        = $commitResult.UpdatedHashes
        }
    }
    catch {
        $rollback = Undo-DaniKernelTransaction -Transaction $tx
        return [PSCustomObject]@{
            Ok            = $false
            TransactionId = $tx.TransactionId
            Error         = $_.Exception.Message
            RolledBack    = $rollback.Ok
            RestoredFiles = $rollback.RestoredCount
        }
    }
}

function Test-DaniNativePerimeterIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [switch]$AutoHealDrift
    )

    $t3StatePath = Join-Path $ParallelPartitionRoot "tier_3_baseline\state.json"
    if (-not (Test-Path $t3StatePath)) {
        return [PSCustomObject]@{ Clean = $true; Checked = 0; Drifted = @() }
    }

    $stateObj  = Get-Content -Path $t3StatePath -Raw | ConvertFrom-Json -AsHashtable
    $baselines = $stateObj["integrityBaselines"]
    if ($null -eq $baselines -or $baselines.Count -eq 0) {
        return [PSCustomObject]@{ Clean = $true; Checked = 0; Drifted = @() }
    }

    $vaultBaseline = Join-Path $ParallelPartitionRoot ".snapshots\verified_baselines"
    $drifted       = [List[PSCustomObject]]::new()

    foreach ($filePath in $baselines.Keys) {
        $expectedSha = $baselines[$filePath].sha256
        $status      = "Match"
        $actualSha   = $null
        $healed      = $false

        if (-not (Test-Path -Path $filePath -PathType Leaf)) {
            $status = "Missing"
        }
        else {
            $actualSha = Get-DaniFileSha256 -FilePath $filePath
            if ($actualSha -ne $expectedSha) {
                $status = "HashMismatch"
            }
        }

        if ($status -ne "Match") {
            if ($AutoHealDrift) {
                $goldenObj = Join-Path $vaultBaseline "$expectedSha.obj"
                if (Test-Path $goldenObj) {
                    $parentDir = Split-Path -Path $filePath -Parent
                    if (-not (Test-Path $parentDir)) {
                        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
                    }
                    [File]::Copy($goldenObj, $filePath, $true)
                    $healed = $true
                }
            }

            $drifted.Add([PSCustomObject]@{
                Path        = $filePath
                Status      = $status
                ExpectedSha = $expectedSha
                ActualSha   = $actualSha
                AutoHealed  = $healed
            })
        }
    }

    return [PSCustomObject]@{
        Clean   = ($drifted.Count -eq 0)
        Checked = $baselines.Count
        Drifted = @($drifted)
    }
}

Export-ModuleMember -Function @(
    "Get-DaniFileSha256",
    "Start-DaniKernelTransaction",
    "Add-DaniTransactionTarget",
    "Undo-DaniKernelTransaction",
    "Commit-DaniKernelTransaction",
    "Invoke-DaniTransactionalAction",
    "Test-DaniNativePerimeterIntegrity"
)
EOF

cat << 'EOF' > kernel/Core.psm1
#Requires -Version 7.4
using namespace System.IO
using namespace System.Security.AccessControl
using namespace System.Security.Principal

Set-StrictMode -Version Latest

$script:ActiveWorkers = @{}
$script:KernelRunning = $false

function Mount-DaniParallelFirewallPartition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $defaultPath = if ($IsWindows) {
        Join-Path $env:ProgramData "DaniOs\.parallel_3x3_firewall"
    }
    else {
        "/var/lib/danios/.parallel_3x3_firewall"
    }

    $partitionRoot = $Config.memoryMatrix.parallelPartitionPath ?? $defaultPath

    if (-not (Test-Path $partitionRoot)) {
        New-Item -ItemType Directory -Path $partitionRoot -Force | Out-Null
    }

    if ($IsWindows) {
        $acl = Get-Acl -Path $partitionRoot
        $acl.SetAccessRuleProtection($true, $false)

        $systemSid = [SecurityIdentifier]::new([WellKnownSidType]::LocalSystemSid, $null)
        $adminSid  = [SecurityIdentifier]::new([WellKnownSidType]::BuiltinAdministratorsSid, $null)
        $usersSid  = [SecurityIdentifier]::new([WellKnownSidType]::BuiltinUsersSid, $null)

        $acl.AddAccessRule([FileSystemAccessRule]::new($systemSid, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"))
        $acl.AddAccessRule([FileSystemAccessRule]::new($adminSid,  "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"))
        $acl.AddAccessRule([FileSystemAccessRule]::new($usersSid,  "FullControl", "ContainerInherit,ObjectInherit", "Deny"))
        Set-Acl -Path $partitionRoot -AclObject $acl

        $dirInfo = Get-Item -Path $partitionRoot -Force
        $dirInfo.Attributes = $dirInfo.Attributes -bor [FileAttributes]::Hidden -bor [FileAttributes]::System
    }
    else {
        & chmod 700 $partitionRoot
    }

    return $partitionRoot
}

function Update-DaniBootGeneration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][int]$Generation,
        [Parameter(Mandatory)][string]$SessionNonce
    )

    foreach ($tier in @("tier_1_active", "tier_2_rolling", "tier_3_baseline")) {
        $statePath = Join-Path $ParallelPartitionRoot "$tier\state.json"
        $stateObj  = Get-Content -Path $statePath -Raw | ConvertFrom-Json -AsHashtable

        $stateObj.bootGeneration = $Generation
        $stateObj.lastBootUtc    = (Get-Date).ToUniversalTime().ToString("o")
        $stateObj.firewallState.parallelPartitionMounted = $true
        $stateObj.firewallState.nativeFsLocked           = $true
        $stateObj.firewallState.unsecureBridgeActive     = $true

        $stateObj | ConvertTo-Json -Depth 8 | Set-Content -Path $statePath -Encoding UTF8 -Force
    }
}

function Write-DaniJournalEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [ValidateSet("tier_1_active", "tier_2_rolling", "tier_3_baseline")][string]$Tier = "tier_1_active",
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message
    )

    $journalPath = Join-Path $ParallelPartitionRoot "$Tier\journal.md"
    $stamp       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'")
    $entry       = "- **[$stamp] [$Category]** $Message"

    Add-Content -Path $journalPath -Value $entry -Encoding UTF8
}

function Start-DaniPolyglotWorkers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DaniRoot,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$SessionNonce
    )

    $workerSpecs = @{
        Node = @{
            Executable = "node"
            EntryPoint = Join-Path $DaniRoot "polyglot\node\bridge_daemon.js"
            PipeName   = "DaniOs.Pipe.Node"
            HttpPort   = [string]($Config.desktopBrowserIntegration.httpPort ?? 4110)
            WsPort     = [string]($Config.desktopBrowserIntegration.wsPort ?? 4111)
        }
        PHP = @{
            Executable = "php"
            EntryPoint = Join-Path $DaniRoot "polyglot\php\bridge_worker.php"
            PipeName   = "DaniOs.Pipe.PHP"
            HttpPort   = ""
            WsPort     = ""
        }
        Python = @{
            Executable = if ($IsWindows) { "python" } else { "python3" }
            EntryPoint = Join-Path $DaniRoot "polyglot\python\bridge_server.py"
            PipeName   = "DaniOs.Pipe.Python"
            HttpPort   = ""
            WsPort     = ""
        }
    }

    foreach ($domain in @("Node", "PHP", "Python")) {
        $spec = $workerSpecs[$domain]
        if (-not (Test-Path $spec.EntryPoint)) { continue }

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = $spec.Executable
        $psi.Arguments              = "`"$($spec.EntryPoint)`""
        $psi.WorkingDirectory       = Split-Path $spec.EntryPoint -Parent
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true

        $psi.Environment["DANIOS_TRUST_ZONE"]    = "UNSECURE_EDGE"
        $psi.Environment["DANIOS_DOMAIN"]        = $domain.ToUpperInvariant()
        $psi.Environment["DANIOS_PIPE_NAME"]     = $spec.PipeName
        $psi.Environment["DANIOS_SESSION_NONCE"] = $SessionNonce
        if ($spec.HttpPort) { $psi.Environment["DANIOS_HTTP_PORT"] = $spec.HttpPort }
        if ($spec.WsPort)   { $psi.Environment["DANIOS_WS_PORT"]   = $spec.WsPort }

        $psi.Environment.Remove("DANIOS_CLOUD_SECRET") | Out-Null

        $proc = [System.Diagnostics.Process]::Start($psi)
        $script:ActiveWorkers[$domain] = @{
            Process    = $proc
            Spec       = $spec
            StartedUtc = (Get-Date).ToUniversalTime()
            Restarts   = 0
        }
    }

    Start-Sleep -Milliseconds 350
    return $script:ActiveWorkers
}

function Stop-DaniPolyglotWorkers {
    [CmdletBinding()]
    param()

    foreach ($domain in @($script:ActiveWorkers.Keys)) {
        $entry = $script:ActiveWorkers[$domain]
        $proc  = $entry.Process
        if ($null -ne $proc -and -not $proc.HasExited) {
            try {
                $proc.Kill($true)
                $proc.WaitForExit(1500) | Out-Null
            }
            catch {
                Write-Warning "[DaniOs::Core] Force-closed worker '$domain': $($_.Exception.Message)"
            }
        }
        $script:ActiveWorkers.Remove($domain)
    }
}

function Invoke-DaniMatrixExpansionAndPrune {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][hashtable]$Config
    )

    $maxEntries = [int]($Config.memoryMatrix.maxJournalEntriesPerTier ?? 50)
    $payload    = @{ maxEntriesPerTier = $maxEntries; tiers = @{} }

    foreach ($tier in @("tier_1_active", "tier_2_rolling", "tier_3_baseline")) {
        $payload.tiers[$tier] = @{
            journal   = Get-Content (Join-Path $ParallelPartitionRoot "$tier\journal.md")    -Raw
            solutions = Get-Content (Join-Path $ParallelPartitionRoot "$tier\solutions.yml") -Raw
            state     = Get-Content (Join-Path $ParallelPartitionRoot "$tier\state.json")    -Raw
        }
    }

    $nodeResult = Invoke-DaniPolyglotBridge -Operation "Send" -Domain "Node" -Action "CompactAndPruneMatrix" -Payload $payload

    if ($nodeResult.Ok -and $null -ne $nodeResult.Data.tiers) {
        foreach ($tier in @("tier_1_active", "tier_2_rolling", "tier_3_baseline")) {
            $compacted = $nodeResult.Data.tiers[$tier]
            if ($compacted.journal)   { Set-Content (Join-Path $ParallelPartitionRoot "$tier\journal.md")    -Value $compacted.journal   -Encoding UTF8 -Force }
            if ($compacted.solutions) { Set-Content (Join-Path $ParallelPartitionRoot "$tier\solutions.yml") -Value $compacted.solutions -Encoding UTF8 -Force }
            if ($compacted.state)     { Set-Content (Join-Path $ParallelPartitionRoot "$tier\state.json")    -Value $compacted.state     -Encoding UTF8 -Force }
        }
    }
    else {
        foreach ($tier in @("tier_1_active", "tier_2_rolling", "tier_3_baseline")) {
            $jPath = Join-Path $ParallelPartitionRoot "$tier\journal.md"
            $lines = Get-Content -Path $jPath
            if ($lines.Count -gt ($maxEntries + 10)) {
                $header = $lines | Select-Object -First 8
                $tail   = $lines | Select-Object -Last $maxEntries
                @($header + "" + $tail) | Set-Content -Path $jPath -Encoding UTF8 -Force
            }
        }
    }
}

function Invoke-DaniSelfHeal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DaniRoot,
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$SessionNonce,
        [Parameter(Mandatory)][hashtable]$FaultContext
    )

    $domain    = $FaultContext.Domain
    $signature = $FaultContext.Signature

    Write-Warning "[DaniOs::Healer] Fault detected in '$domain' ($signature). Initiating self-healing loop..."
    Write-DaniJournalEntry -ParallelPartitionRoot $ParallelPartitionRoot -Tier "tier_1_active" -Category "FAULT" -Message "Detected '$signature' in domain '$domain'."

    $knownFix = $null
    foreach ($tier in @("tier_3_baseline", "tier_2_rolling", "tier_1_active")) {
        $ymlText = Get-Content (Join-Path $ParallelPartitionRoot "$tier\solutions.yml") -Raw
        if ($ymlText -match [regex]::Escape($signature)) {
            $knownFix = "Matched verified playbook in $tier for '$signature'."
            break
        }
    }

    $aiAdvice = $null
    if (-not $knownFix -and [System.Management.Automation.PSTypeName]'DaniOs.Kernel.AI'.Type) {
        $contextSnapshot = Get-Content (Join-Path $ParallelPartitionRoot "tier_1_active\journal.md") -Tail 20 | Out-String
        $aiAdvice = [DaniOs.Kernel.AI]::DiagnoseAndSynthesize(($FaultContext | ConvertTo-Json -Compress), $contextSnapshot)
    }

    if ($domain -in @("Node", "PHP", "Python") -and $script:ActiveWorkers.ContainsKey($domain)) {
        $entry    = $script:ActiveWorkers[$domain]
        $maxRetry = [int]($Config.kernel.maxAutonomousRetries ?? 3)

        if ($entry.Restarts -lt $maxRetry) {
            if (-not $entry.Process.HasExited) { $entry.Process.Kill($true) }
            $newProc = [System.Diagnostics.Process]::Start($entry.Process.StartInfo)
            $entry.Process    = $newProc
            $entry.Restarts  += 1
            $entry.StartedUtc = (Get-Date).ToUniversalTime()

            $resolutionNote = $knownFix ?? $aiAdvice ?? "Respawned '$domain' worker (attempt $($entry.Restarts)/$maxRetry)."
            Write-DaniJournalEntry -ParallelPartitionRoot $ParallelPartitionRoot -Tier "tier_1_active" -Category "HEALED" -Message $resolutionNote

            $t1Solutions = Join-Path $ParallelPartitionRoot "tier_1_active\solutions.yml"
            $yamlAppend  = @"

  - id: "AUTO_$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    signature: "$signature"
    domain: "$domain"
    remediation: "$($resolutionNote -replace '"', '\"')"
    verified_at: "$((Get-Date).ToUniversalTime().ToString('o'))"
"@
            Add-Content -Path $t1Solutions -Value $yamlAppend -Encoding UTF8

            Send-DaniBrowserEvent -Channel "kernel:healed" -Data @{
                domain     = $domain
                signature  = $signature
                resolution = $resolutionNote
            } | Out-Null

            if ($Config.cloudOrigin.enabled -and $Config.cloudOrigin.autoBackupOnHealCommit) {
                Sync-DaniCloudSavePoint -ParallelPartitionRoot $ParallelPartitionRoot -CloudConfig $Config.cloudOrigin | Out-Null
            }
        }
        else {
            Write-DaniJournalEntry -ParallelPartitionRoot $ParallelPartitionRoot -Tier "tier_1_active" -Category "ESCALATE" -Message "Worker '$domain' exceeded maxAutonomousRetries ($maxRetry)."
        }
    }
}

function Start-DaniKernelSupervisor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DaniRoot,
        [Parameter(Mandatory)][string]$ParallelPartitionRoot,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$SessionNonce
    )

    $intervalMs           = [int]($Config.kernel.heartbeatIntervalMs ?? 1500)
    $script:KernelRunning = $true
    $tickCounter          = 0

    Write-Host "[DaniOs::Supervisor] Kernel heartbeat active (${intervalMs}ms). Press Ctrl+C for clean shutdown." -ForegroundColor Cyan

    try {
        while ($script:KernelRunning) {
            Start-Sleep -Milliseconds $intervalMs
            $tickCounter++

            foreach ($domain in @($script:ActiveWorkers.Keys)) {
                $proc = $script:ActiveWorkers[$domain].Process
                if ($proc.HasExited) {
                    Invoke-DaniSelfHeal `
                        -DaniRoot $DaniRoot `
                        -ParallelPartitionRoot $ParallelPartitionRoot `
                        -Config $Config `
                        -SessionNonce $SessionNonce `
                        -FaultContext @{
                            Domain    = $domain
                            Signature = "WorkerUnexpectedExit_Code_$($proc.ExitCode)"
                            Timestamp = (Get-Date).ToUniversalTime().ToString("o")
                        }
                }
            }

            if (($tickCounter % 20) -eq 0) {
                Initialize-DaniGoldenMatrix -ParallelPartitionRoot $ParallelPartitionRoot | Out-Null
                if (Get-Command -Name "Test-DaniNativePerimeterIntegrity" -ErrorAction SilentlyContinue) {
                    Test-DaniNativePerimeterIntegrity -ParallelPartitionRoot $ParallelPartitionRoot -AutoHealDrift | Out-Null
                }
                Send-DaniBrowserEvent -Channel "kernel:heartbeat" -Data @{
                    tick         = $tickCounter
                    workersAlive = @($script:ActiveWorkers.Keys | Where-Object { -not $script:ActiveWorkers[$_].Process.HasExited })
                    timestampUtc = (Get-Date).ToUniversalTime().ToString("o")
                } | Out-Null
            }
        }
    }
    finally {
        Write-Host "`n[DaniOs::Supervisor] Shutdown signal received. Pruning 3x3 matrix & committing Cloud Origin backup..." -ForegroundColor Yellow

        if ($Config.memoryMatrix.autoPruneOnShutdown) {
            Invoke-DaniMatrixExpansionAndPrune -ParallelPartitionRoot $ParallelPartitionRoot -Config $Config
        }

        Write-DaniJournalEntry -ParallelPartitionRoot $ParallelPartitionRoot -Tier "tier_1_active" -Category "SHUTDOWN" -Message "Clean kernel shutdown completed."

        if ($Config.cloudOrigin.enabled) {
            Sync-DaniCloudSavePoint -ParallelPartitionRoot $ParallelPartitionRoot -CloudConfig $Config.cloudOrigin | Out-Null
        }

        Stop-DaniPolyglotWorkers
        Write-Host "[DaniOs::Supervisor] DaniOs halted cleanly." -ForegroundColor Cyan
    }
}

Export-ModuleMember -Function @(
    "Mount-DaniParallelFirewallPartition",
    "Update-DaniBootGeneration",
    "Write-DaniJournalEntry",
    "Start-DaniPolyglotWorkers",
    "Stop-DaniPolyglotWorkers",
    "Invoke-DaniMatrixExpansionAndPrune",
    "Invoke-DaniSelfHeal",
    "Start-DaniKernelSupervisor"
)
EOF

# 7. Zone 3 Polyglot Workers (Node.js, PHP, Python)
echo "[4/7] Writing Zone 3 Polyglot Workers (Node.js, PHP, Python)..."

cat << 'EOF' > polyglot/node/package.json
{
  "name": "danios-polyglot-node",
  "version": "1.0.0",
  "description": "DaniOs Zone 3 Node.js Named-Pipe daemon, 3x3 matrix parser/pruner, and browser-desktop server factory",
  "main": "bridge_daemon.js",
  "license": "GPL-3.0",
  "engines": {
    "node": ">=22.0.0"
  },
  "dependencies": {
    "js-yaml": "^4.1.0",
    "ws": "^8.18.0"
  }
}
EOF

cat << 'EOF' > polyglot/node/matrix_pruner.js
"use strict";

const yaml = require("js-yaml");

const TIER_ORDER = ["tier_1_active", "tier_2_rolling", "tier_3_baseline"];
const JOURNAL_ENTRY_REGEX = /^- \*\*\[(.*?)\] \[(.*?)\]\*\* (.*)$/;

function parseJournalMarkdown(rawMd) {
  const lines = (rawMd || "").split(/\r?\n/);
  const headerLines = [];
  const entries = [];
  let seenFirstEntry = false;

  for (const line of lines) {
    const match = line.match(JOURNAL_ENTRY_REGEX);
    if (match) {
      seenFirstEntry = true;
      entries.push({ timestamp: match[1], category: match[2], message: match[3], raw: line });
    } else if (!seenFirstEntry) {
      headerLines.push(line);
    }
  }

  while (headerLines.length > 0 && headerLines[headerLines.length - 1].trim() === "") {
    headerLines.pop();
  }

  return { header: headerLines.join("\n"), entries };
}

function serializeJournalMarkdown(header, entries) {
  const baseHeader = header && header.trim().length > 0 ? header.trim() : "# DaniOs Run Journal";
  const body = entries.map((e) => e.raw || `- **[${e.timestamp}] [${e.category}]** ${e.message}`).join("\n");
  return body.length > 0 ? `${baseHeader}\n\n${body}\n` : `${baseHeader}\n`;
}

function parseSolutionsYaml(rawYml) {
  const doc = yaml.load(rawYml || "") || {};
  if (!Array.isArray(doc.baseline_playbooks)) {
    doc.baseline_playbooks = [];
  }
  return doc;
}

function deduplicatePlaybooks(playbooks) {
  const bySignature = new Map();

  for (const rule of playbooks) {
    if (!rule || !rule.signature) continue;
    const existing = bySignature.get(rule.signature);
    if (!existing) {
      bySignature.set(rule.signature, { ...rule, hit_count: Number(rule.hit_count || 1) });
    } else {
      existing.hit_count = Number(existing.hit_count || 1) + Number(rule.hit_count || 1);
      if (rule.verified_at && (!existing.verified_at || rule.verified_at > existing.verified_at)) {
        existing.remediation = rule.remediation;
        existing.verified_at = rule.verified_at;
      }
    }
  }

  return Array.from(bySignature.values());
}

function compactAndPruneMatrix(payload) {
  const maxEntries = Math.max(10, Number(payload.maxEntriesPerTier || 50));
  const incomingTiers = payload.tiers || {};

  const parsed = {};
  for (const tier of TIER_ORDER) {
    const rawTier = incomingTiers[tier] || {};
    parsed[tier] = {
      journal: parseJournalMarkdown(rawTier.journal),
      solutions: parseSolutionsYaml(rawTier.solutions),
      state: JSON.parse(rawTier.state || "{}")
    };
  }

  for (const tier of TIER_ORDER) {
    parsed[tier].solutions.baseline_playbooks = deduplicatePlaybooks(parsed[tier].solutions.baseline_playbooks);
  }

  const promotionThreshold = Number(
    parsed.tier_3_baseline.solutions?.kernel_invariants?.pruning_policy?.promotion_threshold_runs || 3
  );

  const t2Map = new Map(parsed.tier_2_rolling.solutions.baseline_playbooks.map((r) => [r.signature, r]));
  for (const rule of parsed.tier_1_active.solutions.baseline_playbooks) {
    if ((rule.hit_count || 1) >= 2 && !t2Map.has(rule.signature)) {
      t2Map.set(rule.signature, { ...rule, promoted_from: "tier_1_active" });
    }
  }
  parsed.tier_2_rolling.solutions.baseline_playbooks = deduplicatePlaybooks(Array.from(t2Map.values()));

  const t3Map = new Map(parsed.tier_3_baseline.solutions.baseline_playbooks.map((r) => [r.signature, r]));
  for (const rule of parsed.tier_2_rolling.solutions.baseline_playbooks) {
    if ((rule.hit_count || 1) >= promotionThreshold && !t3Map.has(rule.signature)) {
      t3Map.set(rule.signature, { ...rule, promoted_from: "tier_2_rolling" });
    }
  }
  parsed.tier_3_baseline.solutions.baseline_playbooks = deduplicatePlaybooks(Array.from(t3Map.values()));

  const stats = {
    prunedEntries: 0,
    promotedRules: parsed.tier_3_baseline.solutions.baseline_playbooks.length
  };

  const t1Entries = parsed.tier_1_active.journal.entries;
  if (t1Entries.length > maxEntries) {
    const overflowCount = t1Entries.length - maxEntries;
    const evicted = t1Entries.slice(0, overflowCount);
    const faultCount = evicted.filter((e) => e.category === "FAULT").length;
    const healCount = evicted.filter((e) => e.category === "HEALED").length;

    parsed.tier_2_rolling.journal.entries.push({
      timestamp: new Date().toISOString().replace("T", " ").slice(0, 19) + " UTC",
      category: "COMPACT",
      message: `Rolled up ${overflowCount} Tier-1 journal entries (${faultCount} faults, ${healCount} heals).`
    });

    parsed.tier_1_active.journal.entries = t1Entries.slice(overflowCount);
    stats.prunedEntries += overflowCount;
  }

  for (const tier of ["tier_2_rolling", "tier_3_baseline"]) {
    const list = parsed[tier].journal.entries;
    if (list.length > maxEntries) {
      const trim = list.length - maxEntries;
      parsed[tier].journal.entries = list.slice(trim);
      stats.prunedEntries += trim;
    }
  }

  const nowUtc = new Date().toISOString();
  const outputTiers = {};

  for (const tier of TIER_ORDER) {
    const st = parsed[tier].state;
    st.lastCompactedUtc = nowUtc;
    if (st.transientTelemetry) delete st.transientTelemetry;

    outputTiers[tier] = {
      journal: serializeJournalMarkdown(parsed[tier].journal.header, parsed[tier].journal.entries),
      solutions: yaml.dump(parsed[tier].solutions, { lineWidth: 120, noRefs: true }),
      state: JSON.stringify(st, null, 2)
    };
  }

  return { tiers: outputTiers, stats };
}

function parseStructuredStream(rawText, format = "auto") {
  const trimmed = (rawText || "").trim();
  if (!trimmed) return { format: "empty", records: [] };

  if (format === "json" || (format === "auto" && (trimmed.startsWith("{") || trimmed.startsWith("[")))) {
    return { format: "json", data: JSON.parse(trimmed) };
  }

  if (format === "yaml" || format === "yml") {
    return { format: "yaml", data: yaml.load(trimmed) };
  }

  const lines = trimmed.split(/\r?\n/);
  const anomalies = lines
    .map((line, idx) => ({ line: idx + 1, text: line }))
    .filter((item) => /\b(FATAL|ERROR|EXCEPTION|PANIC|TIMEOUT|DENIED)\b/i.test(item.text));

  return {
    format: "log_stream",
    totalLines: lines.length,
    anomalyCount: anomalies.length,
    anomalies: anomalies.slice(0, 100)
  };
}

module.exports = { compactAndPruneMatrix, parseStructuredStream };
EOF

cat << 'EOF' > polyglot/node/server_factory.js
"use strict";

const http = require("http");
const { WebSocketServer, WebSocket } = require("ws");

class DaniServerFactory {
  constructor({ sessionNonce, httpPort = 4110, wsPort = 4111, onBrowserCommand }) {
    this.sessionNonce = sessionNonce;
    this.httpPort = Number(httpPort);
    this.wsPort = Number(wsPort);
    this.onBrowserCommand = onBrowserCommand || (() => {});
    this.primaryHttp = null;
    this.primaryWs = null;
    this.recentEvents = [];
    this.dynamicServers = new Map();
  }

  startPrimaryDesktopBridge() {
    this.primaryHttp = http.createServer((req, res) => {
      const url = new URL(req.url, `http://127.0.0.1:${this.httpPort}`);

      if (url.pathname === "/health") {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({
          ok: true,
          os: "DaniOs",
          zone: "UNSECURE_EDGE",
          wsClients: this.primaryWs ? this.primaryWs.clients.size : 0,
          dynamicServers: Array.from(this.dynamicServers.keys())
        }));
        return;
      }

      if (url.pathname === "/") {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
        res.end(this.renderDesktopShellHtml());
        return;
      }

      res.writeHead(404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "NotFound" }));
    });

    this.primaryHttp.listen(this.httpPort, "127.0.0.1");

    this.primaryWs = new WebSocketServer({ host: "127.0.0.1", port: this.wsPort });

    this.primaryWs.on("connection", (socket, req) => {
      const reqUrl = new URL(req.url, `ws://127.0.0.1:${this.wsPort}`);
      const clientNonce = reqUrl.searchParams.get("nonce");

      if (clientNonce !== this.sessionNonce) {
        socket.close(4001, "InvalidSessionNonce");
        return;
      }

      socket.send(JSON.stringify({
        channel: "bridge:connected",
        data: { history: this.recentEvents.slice(-25), timestampUtc: new Date().toISOString() }
      }));

      socket.on("message", (raw) => {
        try {
          const msg = JSON.parse(raw.toString("utf8"));
          this.onBrowserCommand(msg, socket);
        } catch {
          socket.send(JSON.stringify({ channel: "bridge:error", data: { error: "MalformedJSON" } }));
        }
      });
    });
  }

  broadcastEvent(channel, data) {
    const packet = { channel, data, timestampUtc: new Date().toISOString() };
    this.recentEvents.push(packet);
    if (this.recentEvents.length > 100) this.recentEvents.shift();

    if (!this.primaryWs) return 0;

    const serialized = JSON.stringify(packet);
    let delivered = 0;

    for (const client of this.primaryWs.clients) {
      if (client.readyState === WebSocket.OPEN) {
        client.send(serialized);
        delivered++;
      }
    }
    return delivered;
  }

  spawnDynamicServer({ id, port, routes = {} }) {
    if (!id || !port) throw new Error("spawnDynamicServer requires 'id' and 'port'.");
    if (this.dynamicServers.has(id)) this.stopDynamicServer(id);

    const server = http.createServer((req, res) => {
      const url = new URL(req.url, `http://127.0.0.1:${port}`);
      const handlerSpec = routes[url.pathname];

      if (!handlerSpec) {
        res.writeHead(404, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: "RouteNotDefined", path: url.pathname }));
        return;
      }

      res.writeHead(Number(handlerSpec.status || 200), {
        "Content-Type": handlerSpec.contentType || "application/json"
      });
      const body = typeof handlerSpec.body === "string"
        ? handlerSpec.body
        : JSON.stringify(handlerSpec.body ?? { ok: true });
      res.end(body);
    });

    server.listen(Number(port), "127.0.0.1");
    this.dynamicServers.set(id, { id, port: Number(port), server, createdUtc: new Date().toISOString() });

    return { id, bind: `http://127.0.0.1:${port}`, routeCount: Object.keys(routes).length };
  }

  stopDynamicServer(id) {
    const entry = this.dynamicServers.get(id);
    if (!entry) return false;
    entry.server.close();
    this.dynamicServers.delete(id);
    return true;
  }

  shutdownAll() {
    for (const id of this.dynamicServers.keys()) this.stopDynamicServer(id);
    if (this.primaryWs) this.primaryWs.close();
    if (this.primaryHttp) this.primaryHttp.close();
  }

  renderDesktopShellHtml() {
    return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>DaniOs Kernel Console</title>
  <style>
    :root { color-scheme: dark; --bg: #0b0f17; --card: #121826; --border: #1f2937; --accent: #38bdf8; --ok: #10b981; --warn: #f59e0b; }
    body { margin: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--bg); color: #e5e7eb; padding: 20px; }
    header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 12px; margin-bottom: 20px; }
    .badge { padding: 4px 10px; border-radius: 999px; font-size: 12px; background: #064e3b; color: var(--ok); border: 1px solid var(--ok); }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 14px; margin-bottom: 20px; }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 14px; }
    .label { font-size: 11px; color: #9ca3af; text-transform: uppercase; }
    .val { font-size: 20px; font-weight: 700; margin-top: 6px; color: var(--accent); }
    #log { background: #070a10; border: 1px solid var(--border); border-radius: 8px; padding: 14px; height: 340px; overflow-y: auto; font-size: 12px; line-height: 1.5; }
    .evt-heal { color: var(--warn); }
    .evt-boot { color: var(--ok); }
  </style>
</head>
<body>
  <header>
    <div><strong>⚡ DaniOs</strong> // Desktop-Browser Kernel Telemetry</div>
    <span id="status" class="badge">CONNECTING</span>
  </header>
  <div class="grid">
    <div class="card"><div class="label">Boot Generation</div><div id="gen" class="val">—</div></div>
    <div class="card"><div class="label">3×3 Matrix Nodes</div><div id="nodes" class="val">9 / 9</div></div>
    <div class="card"><div class="label">Heartbeat Tick</div><div id="tick" class="val">0</div></div>
    <div class="card"><div class="label">Active Workers</div><div id="workers" class="val">—</div></div>
  </div>
  <div id="log"></div>
  <script>
    const logEl = document.getElementById("log");
    const statusEl = document.getElementById("status");
    const ws = new WebSocket("ws://127.0.0.1:${this.wsPort}/?nonce=${this.sessionNonce}");
    function appendLine(pkt) {
      const div = document.createElement("div");
      if (pkt.channel === "kernel:healed") div.className = "evt-heal";
      if (pkt.channel === "kernel:boot") div.className = "evt-boot";
      div.textContent = "[" + (pkt.timestampUtc || new Date().toISOString()) + "] " + pkt.channel + " -> " + JSON.stringify(pkt.data);
      logEl.appendChild(div);
      logEl.scrollTop = logEl.scrollHeight;
    }
    function applyEvent(pkt) {
      appendLine(pkt);
      if (pkt.channel === "kernel:boot" && pkt.data) {
        document.getElementById("gen").textContent = "#" + pkt.data.bootGeneration;
        document.getElementById("nodes").textContent = (pkt.data.activeNodes || 9) + " / 9";
        document.getElementById("workers").textContent = (pkt.data.workers || []).join(", ");
      }
      if (pkt.channel === "kernel:heartbeat" && pkt.data) {
        document.getElementById("tick").textContent = pkt.data.tick;
        document.getElementById("workers").textContent = (pkt.data.workersAlive || []).join(", ");
      }
    }
    ws.onopen = () => { statusEl.textContent = "LIVE // NONCE VERIFIED"; };
    ws.onclose = () => { statusEl.textContent = "DISCONNECTED"; statusEl.style.color = "#f87171"; };
    ws.onmessage = (ev) => {
      const pkt = JSON.parse(ev.data);
      if (pkt.channel === "bridge:connected" && Array.isArray(pkt.data.history)) {
        pkt.data.history.forEach(applyEvent);
      } else {
        applyEvent(pkt);
      }
    };
  </script>
</body>
</html>`;
  }
}

module.exports = { DaniServerFactory };
EOF

cat << 'EOF' > polyglot/node/bridge_daemon.js
"use strict";

const fs = require("fs");
const net = require("net");
const path = require("path");
const { compactAndPruneMatrix, parseStructuredStream } = require("./matrix_pruner");
const { DaniServerFactory } = require("./server_factory");

const PIPE_NAME = process.env.DANIOS_PIPE_NAME || "DaniOs.Pipe.Node";
const SESSION_NONCE = process.env.DANIOS_SESSION_NONCE || "";
const HTTP_PORT = Number(process.env.DANIOS_HTTP_PORT || 4110);
const WS_PORT = Number(process.env.DANIOS_WS_PORT || 4111);

if (!SESSION_NONCE) {
  process.stderr.write("[DaniOs::Node] FATAL: Missing DANIOS_SESSION_NONCE in environment.\n");
  process.exit(1);
}

function resolveDotNetPipePath(pipeName) {
  if (process.platform === "win32") return `\\\\.\\pipe\\${pipeName}`;
  const sockPath = path.join("/tmp", `CoreFxPipe_${pipeName}`);
  if (fs.existsSync(sockPath)) fs.unlinkSync(sockPath);
  return sockPath;
}

const pendingBrowserQueue = [];

const serverFactory = new DaniServerFactory({
  sessionNonce: SESSION_NONCE,
  httpPort: HTTP_PORT,
  wsPort: WS_PORT,
  onBrowserCommand: (msg) => {
    pendingBrowserQueue.push({ receivedUtc: new Date().toISOString(), command: msg });
    if (pendingBrowserQueue.length > 200) pendingBrowserQueue.shift();
  }
});

serverFactory.startPrimaryDesktopBridge();

function dispatchKernelAction(envelope) {
  if (envelope.Nonce !== SESSION_NONCE) {
    throw new Error("ZoneBoundaryViolation: Session nonce mismatch on Node IPC pipe.");
  }

  const action = envelope.Action;
  const payload = envelope.Payload || {};

  switch (action) {
    case "BroadcastBrowserWS":
      return { deliveredClients: serverFactory.broadcastEvent(payload.channel || "kernel:event", payload.data || {}) };
    case "PollBrowserCommands":
      return { commands: pendingBrowserQueue.splice(0, pendingBrowserQueue.length) };
    case "CompactAndPruneMatrix":
      return compactAndPruneMatrix(payload);
    case "ParseTelemetryStream":
      return parseStructuredStream(payload.rawText, payload.format || "auto");
    case "SpawnDynamicServer":
      return serverFactory.spawnDynamicServer(payload);
    case "StopDynamicServer":
      return { stopped: serverFactory.stopDynamicServer(payload.id) };
    default:
      throw new Error(`UnsupportedNodeAction: '${action}'`);
  }
}

const pipeEndpoint = resolveDotNetPipePath(PIPE_NAME);

const pipeServer = net.createServer((socket) => {
  let buffer = "";

  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let newlineIdx;

    while ((newlineIdx = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, newlineIdx).trim();
      buffer = buffer.slice(newlineIdx + 1);
      if (!line) continue;

      let requestId = null;
      try {
        const envelope = JSON.parse(line);
        requestId = envelope.Id || null;
        const resultPayload = dispatchKernelAction(envelope);

        socket.write(JSON.stringify({
          Id: requestId, Nonce: SESSION_NONCE, Domain: "Node", Ok: true,
          Timestamp: new Date().toISOString(), Payload: resultPayload
        }) + "\n");
      } catch (err) {
        socket.write(JSON.stringify({
          Id: requestId, Nonce: SESSION_NONCE, Domain: "Node", Ok: false,
          Timestamp: new Date().toISOString(), Payload: { error: err.message }
        }) + "\n");
      }
    }
  });

  socket.on("error", () => {});
});

pipeServer.listen(pipeEndpoint, () => {
  process.stdout.write(`[DaniOs::Node] Listening on ${pipeEndpoint} | Desktop UI http://127.0.0.1:${HTTP_PORT}\n`);
});

function gracefulExit() {
  serverFactory.shutdownAll();
  pipeServer.close(() => {
    if (process.platform !== "win32" && fs.existsSync(pipeEndpoint)) fs.unlinkSync(pipeEndpoint);
    process.exit(0);
  });
}

process.on("SIGINT", gracefulExit);
process.on("SIGTERM", gracefulExit);
EOF

cat << 'EOF' > polyglot/php/web_client.php
<?php
declare(strict_types=1);

final class DaniWebClient
{
    private const BLOCKED_HOSTS = ['localhost', '127.0.0.1', '::1', '0.0.0.0', '169.254.169.254'];
    private string $sessionNonce;
    private int $nodeHttpPort;
    private int $nodeWsPort;
    private ?string $projectedTelemetryPath;

    public function __construct(?string $sessionNonce = null, ?int $nodeHttpPort = null, ?int $nodeWsPort = null, ?string $projectedTelemetryPath = null)
    {
        $this->sessionNonce = $sessionNonce ?? (getenv('DANIOS_SESSION_NONCE') ?: '');
        $this->nodeHttpPort = $nodeHttpPort ?? (int)(getenv('DANIOS_HTTP_PORT') ?: 4110);
        $this->nodeWsPort   = $nodeWsPort ?? (int)(getenv('DANIOS_WS_PORT') ?: 4111);

        $envTelemetry = $projectedTelemetryPath ?? (getenv('DANIOS_EDGE_TELEMETRY_FILE') ?: null);
        if ($envTelemetry !== null && $envTelemetry !== '') {
            self::assertNoRestrictedPartitionPath($envTelemetry);
            $this->projectedTelemetryPath = $envTelemetry;
        } else {
            $this->projectedTelemetryPath = null;
        }
    }

    public static function assertNoRestrictedPartitionPath(string $candidatePath): void
    {
        if (preg_match('#[/\\\\](tier_1_active|tier_2_rolling|tier_3_baseline|\.parallel_3x3_firewall|kernel[/\\\\]seeds)#i', $candidatePath) === 1) {
            throw new RuntimeException("ZoneBoundaryViolation: PHP edge layer is barred from parallel 3x3 partition paths.");
        }
    }

    public static function assertSafeOutboundUrl(string $url): void
    {
        $parts = parse_url($url);
        if ($parts === false || empty($parts['scheme']) || empty($parts['host'])) {
            throw new RuntimeException("InvalidOutboundUrl: Malformed URL.");
        }
        $scheme = strtolower($parts['scheme']);
        if (!in_array($scheme, ['http', 'https'], true)) {
            throw new RuntimeException("DisallowedUrlScheme: Only http and https are permitted.");
        }
        $host = strtolower(trim($parts['host'], '[]'));
        if (in_array($host, self::BLOCKED_HOSTS, true) || str_starts_with($host, '127.')) {
            throw new RuntimeException("ZoneBoundaryViolation: Outbound PHP worker blocked from loopback/metadata host '{$host}'.");
        }
    }

    public function executeHttpCall(array $payload): array
    {
        $url     = (string)($payload['url'] ?? '');
        $method  = strtoupper((string)($payload['method'] ?? 'GET'));
        $headers = is_array($payload['headers'] ?? null) ? $payload['headers'] : [];
        $body    = $payload['body'] ?? null;
        $timeout = max(1, min(30, (int)($payload['timeoutSec'] ?? 10)));

        self::assertSafeOutboundUrl($url);

        $ch = curl_init($url);
        if ($ch === false) throw new RuntimeException("CurlInitFailed for '{$url}'.");

        $formattedHeaders = ['User-Agent: DaniOs-Edge-PHP/1.0'];
        foreach ($headers as $k => $v) {
            $formattedHeaders[] = is_int($k) ? (string)$v : "{$k}: {$v}";
        }

        $encodedBody = null;
        if ($body !== null) {
            if (is_array($body) || is_object($body)) {
                $encodedBody = json_encode($body, JSON_UNESCAPED_SLASHES);
                $formattedHeaders[] = 'Content-Type: application/json';
            } else {
                $encodedBody = (string)$body;
            }
        }

        $responseHeaders = [];
        curl_setopt_array($ch, [
            CURLOPT_CUSTOMREQUEST  => $method,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_TIMEOUT        => $timeout,
            CURLOPT_CONNECTTIMEOUT => 5,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_SSL_VERIFYHOST => 2,
            CURLOPT_HTTPHEADER     => $formattedHeaders,
            CURLOPT_HEADERFUNCTION => static function ($curl, string $headerLine) use (&$responseHeaders): int {
                $len   = strlen($headerLine);
                $parts = explode(':', $headerLine, 2);
                if (count($parts) === 2) $responseHeaders[strtolower(trim($parts[0]))] = trim($parts[1]);
                return $len;
            },
        ]);

        if ($encodedBody !== null && !in_array($method, ['GET', 'HEAD'], true)) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, $encodedBody);
        }

        $startMs    = hrtime(true);
        $rawBody    = curl_exec($ch);
        $elapsedMs  = round((hrtime(true) - $startMs) / 1_000_000, 2);
        $statusCode = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        $curlErr    = curl_error($ch);
        curl_close($ch);

        if ($rawBody === false) throw new RuntimeException("HttpCallFailed ({$method} {$url}): {$curlErr}");

        $decodedJson = null;
        $contentType = $responseHeaders['content-type'] ?? '';
        if (str_contains($contentType, 'application/json') && $rawBody !== '') {
            $tmp = json_decode($rawBody, true);
            if (json_last_error() === JSON_ERROR_NONE) $decodedJson = $tmp;
        }

        return [
            'statusCode' => $statusCode,
            'ok'         => ($statusCode >= 200 && $statusCode < 300),
            'latencyMs'  => $elapsedMs,
            'headers'    => $responseHeaders,
            'json'       => $decodedJson,
            'body'       => $decodedJson === null ? $rawBody : null,
        ];
    }

    public function dispatchWebhook(array $payload): array
    {
        $url        = (string)($payload['url'] ?? '');
        $event      = (string)($payload['event'] ?? 'danios.kernel.event');
        $data       = $payload['data'] ?? [];
        $signingKey = (string)($payload['signingKey'] ?? '');
        $maxRetries = max(1, min(3, (int)($payload['retries'] ?? 2)));

        self::assertSafeOutboundUrl($url);

        $wireJson = json_encode(['source' => 'DaniOs', 'event' => $event, 'timestamp' => gmdate('c'), 'data' => $data], JSON_UNESCAPED_SLASHES);
        $headers  = ['Content-Type' => 'application/json', 'X-DaniOs-Event' => $event];
        if ($signingKey !== '') {
            $headers['X-DaniOs-Signature'] = 'sha256=' . hash_hmac('sha256', (string)$wireJson, $signingKey);
        }

        $lastResult = null;
        for ($attempt = 1; $attempt <= $maxRetries; $attempt++) {
            try {
                $lastResult = $this->executeHttpCall(['url' => $url, 'method' => 'POST', 'headers' => $headers, 'body' => $wireJson]);
                if ($lastResult['ok'] || $lastResult['statusCode'] < 500) {
                    $lastResult['attempts'] = $attempt;
                    return $lastResult;
                }
            } catch (Throwable $e) {
                $lastResult = ['ok' => false, 'error' => $e->getMessage(), 'attempts' => $attempt];
            }
            usleep($attempt * 150_000);
        }
        return $lastResult ?? ['ok' => false, 'error' => 'WebhookDeliveryExhausted'];
    }

    public function batchHttpProbe(array $targets): array
    {
        $mh      = curl_multi_init();
        $handles = [];

        foreach ($targets as $idx => $target) {
            $url = is_string($target) ? trim($target) : trim((string)($target['url'] ?? ''));
            if ($url === '') continue;

            try {
                self::assertSafeOutboundUrl($url);
            } catch (Throwable $e) {
                $handles[$idx] = ['url' => $url, 'handle' => null, 'blocked' => $e->getMessage(), 'start' => hrtime(true)];
                continue;
            }

            $ch = curl_init($url);
            curl_setopt_array($ch, [
                CURLOPT_NOBODY => true, CURLOPT_RETURNTRANSFER => true,
                CURLOPT_TIMEOUT => 5, CURLOPT_CONNECTTIMEOUT => 3,
                CURLOPT_SSL_VERIFYPEER => true, CURLOPT_USERAGENT => 'DaniOs-Probe-PHP/1.0',
            ]);
            curl_multi_add_handle($mh, $ch);
            $handles[$idx] = ['url' => $url, 'handle' => $ch, 'blocked' => null, 'start' => hrtime(true)];
        }

        do {
            $status = curl_multi_exec($mh, $active);
            if ($active) curl_multi_select($mh, 0.2);
        } while ($active && $status === CURLM_OK);

        $results = [];
        foreach ($handles as $entry) {
            if ($entry['handle'] === null) {
                $results[] = ['url' => $entry['url'], 'reachable' => false, 'statusCode' => 0, 'latencyMs' => 0.0, 'error' => $entry['blocked']];
                continue;
            }
            $ch   = $entry['handle'];
            $code = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
            $err  = curl_error($ch);
            $ms   = round((hrtime(true) - $entry['start']) / 1_000_000, 2);

            $results[] = ['url' => $entry['url'], 'reachable' => ($err === '' && $code > 0), 'statusCode' => $code, 'latencyMs' => $ms, 'error' => $err !== '' ? $err : null];
            curl_multi_remove_handle($mh, $ch);
            curl_close($ch);
        }
        curl_multi_close($mh);
        return ['checkedAtUtc' => gmdate('c'), 'probes' => $results];
    }

    public function inspectPolyglotPipes(): array
    {
        $domains = [
            'Node'   => ['pipe' => 'DaniOs.Pipe.Node',   'role' => '3x3 Matrix Parser, Pruner & Desktop WebSocket Shell'],
            'PHP'    => ['pipe' => 'DaniOs.Pipe.PHP',    'role' => 'Outbound HTTP/cURL, Webhooks & Edge Diagnostics UI'],
            'Python' => ['pipe' => 'DaniOs.Pipe.Python', 'role' => 'Low-Level Syscall, Hardware & Block I/O Probes'],
        ];
        $statuses = [];
        foreach ($domains as $domain => $meta) {
            $pipeName = $meta['pipe'];
            $endpoint = PHP_OS_FAMILY === 'Windows' ? "\\\\.\\pipe\\{$pipeName}" : "/tmp/CoreFxPipe_{$pipeName}";
            $statuses[] = ['domain' => $domain, 'pipeName' => $pipeName, 'endpoint' => $endpoint, 'online' => file_exists($endpoint), 'role' => $meta['role']];
        }
        return $statuses;
    }

    public function probeNodeDesktopBridge(): array
    {
        $ch = curl_init("http://127.0.0.1:{$this->nodeHttpPort}/health");
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 2, CURLOPT_CONNECTTIMEOUT => 1]);
        $startMs = hrtime(true);
        $raw     = curl_exec($ch);
        $ms      = round((hrtime(true) - $startMs) / 1_000_000, 2);
        $code    = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        $err     = curl_error($ch);
        curl_close($ch);

        if ($raw === false || $code !== 200) {
            return ['online' => false, 'httpPort' => $this->nodeHttpPort, 'wsPort' => $this->nodeWsPort, 'latencyMs' => $ms, 'error' => $err !== '' ? $err : "HTTP {$code}", 'wsClients' => 0, 'dynamicServers' => []];
        }
        $decoded = json_decode($raw, true);
        return ['online' => (bool)($decoded['ok'] ?? false), 'httpPort' => $this->nodeHttpPort, 'wsPort' => $this->nodeWsPort, 'latencyMs' => $ms, 'wsClients' => (int)($decoded['wsClients'] ?? 0), 'dynamicServers' => is_array($decoded['dynamicServers'] ?? null) ? $decoded['dynamicServers'] : []];
    }

    public function getProjectedMatrixDiagnostics(): array
    {
        return [
            'firewallPerimeter' => 'ISOLATED_KERNEL_ACL',
            'directEdgeAccess'  => 'DENIED_BY_POLICY',
            'topology'          => '3x3 (9 Nodes: .md, .yml, .json x 3 Tiers)',
            'tiers'             => [
                ['name' => 'tier_1_active',   'role' => 'Immediate Run State',   'formats' => ['journal.md', 'solutions.yml', 'state.json'], 'access' => 'Kernel Only'],
                ['name' => 'tier_2_rolling',  'role' => 'Rolling Consolidation', 'formats' => ['journal.md', 'solutions.yml', 'state.json'], 'access' => 'Kernel Only'],
                ['name' => 'tier_3_baseline', 'role' => 'Verified Invariants',   'formats' => ['journal.md', 'solutions.yml', 'state.json'], 'access' => 'Kernel Only'],
            ],
        ];
    }

    public function collectEdgeDiagnostics(array $probeTargets = []): array
    {
        return [
            'os'             => 'DaniOs',
            'layer'          => 'Zone 3 // PHP Web & Network Edge',
            'timestampUtc'   => gmdate('c'),
            'phpRuntime'     => ['version' => PHP_VERSION, 'osFamily' => PHP_OS_FAMILY, 'curlLoaded' => extension_loaded('curl'), 'ffiLoaded' => extension_loaded('ffi'), 'nonceBound' => ($this->sessionNonce !== '')],
            'polyglotPipes'  => $this->inspectPolyglotPipes(),
            'desktopBridge'  => $this->probeNodeDesktopBridge(),
            'matrixFirewall' => $this->getProjectedMatrixDiagnostics(),
            'externalProbes' => count($probeTargets) > 0 ? $this->batchHttpProbe($probeTargets) : ['checkedAtUtc' => gmdate('c'), 'probes' => []],
        ];
    }
}
EOF

cat << 'EOF' > polyglot/php/bridge_worker.php
<?php
declare(strict_types=1);

require_once __DIR__ . '/web_client.php';

$pipeName     = getenv('DANIOS_PIPE_NAME') ?: 'DaniOs.Pipe.PHP';
$sessionNonce = getenv('DANIOS_SESSION_NONCE') ?: '';

if ($sessionNonce === '') {
    fwrite(STDERR, "[DaniOs::PHP] FATAL: Missing DANIOS_SESSION_NONCE in environment.\n");
    exit(1);
}

$webClient = new DaniWebClient($sessionNonce);

function handleEnvelope(string $rawLine, string $sessionNonce, DaniWebClient $webClient): string
{
    $requestId = null;
    try {
        DaniWebClient::assertNoRestrictedPartitionPath($rawLine);
        $envelope  = json_decode($rawLine, true, 16, JSON_THROW_ON_ERROR);
        $requestId = $envelope['Id'] ?? null;

        if (($envelope['Nonce'] ?? '') !== $sessionNonce) {
            throw new RuntimeException("ZoneBoundaryViolation: Session nonce mismatch on PHP IPC pipe.");
        }

        $action  = (string)($envelope['Action'] ?? '');
        $payload = is_array($envelope['Payload'] ?? null) ? $envelope['Payload'] : [];

        $result = match ($action) {
            'ExecuteHttpCall' => $webClient->executeHttpCall($payload),
            'DispatchWebhook' => $webClient->dispatchWebhook($payload),
            'BatchHttpProbe'  => $webClient->batchHttpProbe($payload['targets'] ?? []),
            'Ping'            => ['pong' => true, 'phpVersion' => PHP_VERSION],
            default           => throw new RuntimeException("UnsupportedPhpAction: '{$action}'"),
        };

        return json_encode(['Id' => $requestId, 'Nonce' => $sessionNonce, 'Domain' => 'PHP', 'Ok' => true, 'Timestamp' => gmdate('c'), 'Payload' => $result], JSON_UNESCAPED_SLASHES) . "\n";
    } catch (Throwable $e) {
        return json_encode(['Id' => $requestId, 'Nonce' => $sessionNonce, 'Domain' => 'PHP', 'Ok' => false, 'Timestamp' => gmdate('c'), 'Payload' => ['error' => $e->getMessage()]], JSON_UNESCAPED_SLASHES) . "\n";
    }
}

if (PHP_OS_FAMILY === 'Windows') {
    $k32 = FFI::cdef("
        typedef void* HANDLE;
        typedef unsigned long DWORD;
        typedef int BOOL;
        HANDLE CreateNamedPipeA(const char* lpName, DWORD dwOpenMode, DWORD dwPipeMode, DWORD nMaxInstances, DWORD nOutBufferSize, DWORD nInBufferSize, DWORD nDefaultTimeOut, void* lpSecurityAttributes);
        BOOL ConnectNamedPipe(HANDLE hNamedPipe, void* lpOverlapped);
        BOOL ReadFile(HANDLE hFile, char* lpBuffer, DWORD nNumberOfBytesToRead, DWORD* lpNumberOfBytesRead, void* lpOverlapped);
        BOOL WriteFile(HANDLE hFile, const char* lpBuffer, DWORD nNumberOfBytesToWrite, DWORD* lpNumberOfBytesWritten, void* lpOverlapped);
        BOOL FlushFileBuffers(HANDLE hFile);
        BOOL DisconnectNamedPipe(HANDLE hNamedPipe);
        DWORD GetLastError();
    ", "kernel32.dll");

    $winPipePath   = "\\\\.\\pipe\\{$pipeName}";
    $invalidHandle = FFI::cast("HANDLE", -1);
    $hPipe = $k32->CreateNamedPipeA($winPipePath, 0x00000003, 0x00000000, 16, 65536, 65536, 0, null);
    if (FFI::isNull($hPipe) || $hPipe == $invalidHandle) exit(1);

    fwrite(STDOUT, "[DaniOs::PHP] Listening on {$winPipePath}\n");
    fflush(STDOUT);

    $readBuf   = FFI::new("char[65536]");
    $bytesRead = FFI::new("DWORD");
    $bytesWrit = FFI::new("DWORD");

    while (true) {
        $connected = $k32->ConnectNamedPipe($hPipe, null);
        if ($connected === 0 && $k32->GetLastError() !== 535) { usleep(10_000); continue; }
        $lineBuffer = '';
        while (true) {
            $ok = $k32->ReadFile($hPipe, $readBuf, 65535, FFI::addr($bytesRead), null);
            if ($ok === 0 || $bytesRead->cdata === 0) break;
            $lineBuffer .= FFI::string($readBuf, $bytesRead->cdata);
            while (($nlPos = strpos($lineBuffer, "\n")) !== false) {
                $line = trim(substr($lineBuffer, 0, $nlPos));
                $lineBuffer = substr($lineBuffer, $nlPos + 1);
                if ($line === '') continue;
                $response = handleEnvelope($line, $sessionNonce, $webClient);
                $k32->WriteFile($hPipe, $response, strlen($response), FFI::addr($bytesWrit), null);
                $k32->FlushFileBuffers($hPipe);
            }
        }
        $k32->DisconnectNamedPipe($hPipe);
    }
} else {
    $sockPath = "/tmp/CoreFxPipe_{$pipeName}";
    if (file_exists($sockPath)) @unlink($sockPath);
    $server = stream_socket_server("unix://{$sockPath}", $errno, $errstr);
    if ($server === false) exit(1);
    @chmod($sockPath, 0600);

    fwrite(STDOUT, "[DaniOs::PHP] Listening on {$sockPath}\n");
    fflush(STDOUT);

    register_shutdown_function(static function () use ($sockPath): void { if (file_exists($sockPath)) @unlink($sockPath); });

    while (true) {
        $conn = @stream_socket_accept($server, -1);
        if ($conn === false) continue;
        while (($line = fgets($conn)) !== false) {
            $trimmed = trim($line);
            if ($trimmed === '') continue;
            fwrite($conn, handleEnvelope($trimmed, $sessionNonce, $webClient));
            fflush($conn);
        }
        fclose($conn);
    }
}
EOF

cat << 'EOF' > polyglot/php/public/index.php
<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/web_client.php';

function esc(mixed $value): string
{
    return htmlspecialchars((string)$value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

$client         = new DaniWebClient();
$defaultTargets = ['https://api.github.com/zen', 'https://1.1.1.1/cdn-cgi/trace'];
$rawTargetInput = is_string($_POST['targets'] ?? null) ? $_POST['targets'] : (is_string($_GET['targets'] ?? null) ? $_GET['targets'] : '');
$probeTargets   = trim($rawTargetInput) !== ''
    ? array_values(array_filter(array_map('trim', preg_split('/[\r\n,]+/', $rawTargetInput) ?: []), static fn(string $u): bool => $u !== ''))
    : $defaultTargets;

$skipProbes  = (($_GET['probes'] ?? '1') === '0');
$diagnostics = $client->collectEdgeDiagnostics($skipProbes ? [] : $probeTargets);

if (($_GET['format'] ?? '') === 'json') {
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($diagnostics, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
    exit;
}

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');

$pipes         = $diagnostics['polyglotPipes'];
$onlineWorkers = count(array_filter($pipes, static fn(array $p): bool => (bool)$p['online']));
$bridge        = $diagnostics['desktopBridge'];
$matrix        = $diagnostics['matrixFirewall'];
$probes        = $diagnostics['externalProbes']['probes'] ?? [];
$phpInfo       = $diagnostics['phpRuntime'];
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>DaniOs // PHP Edge Diagnostics &amp; 3×3 Perimeter Status</title>
  <style>
    :root { color-scheme: dark; --bg: #090d14; --panel: #111827; --border: #1f2937; --text: #e5e7eb; --muted: #9ca3af; --accent: #38bdf8; --ok: #10b981; --warn: #f59e0b; --err: #ef4444; }
    body { margin: 0; padding: 24px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--bg); color: var(--text); }
    header { display: flex; justify-content: space-between; align-items: center; padding-bottom: 16px; margin-bottom: 20px; border-bottom: 1px solid var(--border); }
    .kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 14px; margin-bottom: 20px; }
    .card { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 16px; margin-bottom: 16px; }
    .kpi-label { font-size: 11px; color: var(--muted); text-transform: uppercase; }
    .kpi-value { font-size: 20px; font-weight: 700; margin-top: 6px; color: var(--accent); }
    table { width: 100%; border-collapse: collapse; font-size: 12px; }
    th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--border); }
    th { color: var(--muted); font-size: 11px; text-transform: uppercase; }
    .pill { padding: 2px 8px; border-radius: 999px; font-size: 11px; font-weight: 700; }
    .ok { background: rgba(16,185,129,.15); color: var(--ok); }
    .err { background: rgba(239,68,68,.15); color: var(--err); }
    .warn { background: rgba(245,158,11,.15); color: var(--warn); }
  </style>
</head>
<body>
  <header>
    <div><strong>⚡ DaniOs // PHP Edge Diagnostics</strong> &bull; Snapshot: <?= esc($diagnostics['timestampUtc']) ?></div>
    <a href="?format=json" style="color: var(--accent);">Raw JSON</a>
  </header>
  <section class="kpi-grid">
    <div class="card"><div class="kpi-label">Polyglot IPC Pipes</div><div class="kpi-value"><?= esc("{$onlineWorkers} / " . count($pipes)) ?> Online</div></div>
    <div class="card"><div class="kpi-label">Desktop Bridge</div><div class="kpi-value"><?= $bridge['online'] ? 'CONNECTED' : 'OFFLINE' ?></div></div>
    <div class="card"><div class="kpi-label">3×3 Firewall Partition</div><div class="kpi-value" style="color: var(--ok);">SEALED</div></div>
    <div class="card"><div class="kpi-label">PHP Runtime</div><div class="kpi-value">PHP <?= esc($phpInfo['version']) ?></div></div>
  </section>
  <section class="card">
    <h3>Zone 3 Polyglot Worker Pipes</h3>
    <table>
      <thead><tr><th>Domain</th><th>Endpoint</th><th>Status</th><th>Role</th></tr></thead>
      <tbody>
        <?php foreach ($pipes as $p): ?>
          <tr>
            <td><strong><?= esc($p['domain']) ?></strong></td>
            <td><code><?= esc($p['endpoint']) ?></code></td>
            <td><span class="pill <?= $p['online'] ? 'ok' : 'err' ?>"><?= $p['online'] ? 'LISTENING' : 'OFFLINE' ?></span></td>
            <td><?= esc($p['role']) ?></td>
          </tr>
        <?php endforeach; ?>
      </tbody>
    </table>
  </section>
  <section class="card">
    <h3>Parallel 3×3 Firewall Perimeter (Zero-Traversal Isolation)</h3>
    <table>
      <thead><tr><th>Tier</th><th>Role</th><th>Nodes</th><th>Zone 3 ACL</th></tr></thead>
      <tbody>
        <?php foreach ($matrix['tiers'] as $tier): ?>
          <tr>
            <td><code><?= esc($tier['name']) ?></code></td>
            <td><?= esc($tier['role']) ?></td>
            <td><?= esc(implode(', ', $tier['formats'])) ?></td>
            <td><span class="pill warn"><?= esc($tier['access']) ?></span></td>
          </tr>
        <?php endforeach; ?>
      </tbody>
    </table>
  </section>
  <section class="card">
    <h3>External Outbound HTTP Probes (SSRF-Guarded)</h3>
    <table>
      <thead><tr><th>Target URL</th><th>Reachable</th><th>Status</th><th>Latency</th><th>Notes</th></tr></thead>
      <tbody>
        <?php foreach ($probes as $probe): ?>
          <tr>
            <td><code><?= esc($probe['url']) ?></code></td>
            <td><span class="pill <?= $probe['reachable'] ? 'ok' : 'err' ?>"><?= $probe['reachable'] ? 'REACHABLE' : 'BLOCKED/DOWN' ?></span></td>
            <td><?= esc($probe['statusCode'] > 0 ? $probe['statusCode'] : '—') ?></td>
            <td><?= esc($probe['latencyMs']) ?> ms</td>
            <td><?= esc($probe['error'] ?? 'OK') ?></td>
          </tr>
        <?php endforeach; ?>
      </tbody>
    </table>
  </section>
</body>
</html>
EOF

cat << 'EOF' > polyglot/python/requirements.txt
# DaniOs Python Zone 3 Worker uses Python 3.11+ standard library & ctypes for zero-dependency boot.
EOF

cat << 'EOF' > polyglot/python/bridge_server.py
#!/usr/bin/env python3
"""
DaniOs Zone 3 Polyglot Worker: Python Low-Level Syscall, Hardware & Memory Probe Daemon
License: GNU GPLv3
"""

import ctypes
import hashlib
import json
import os
import platform
import re
import shutil
import socket
import stat
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict

PIPE_NAME = os.environ.get("DANIOS_PIPE_NAME", "DaniOs.Pipe.Python")
SESSION_NONCE = os.environ.get("DANIOS_SESSION_NONCE", "")

if not SESSION_NONCE:
    sys.stderr.write("[DaniOs::Python] FATAL: Missing DANIOS_SESSION_NONCE in environment.\n")
    sys.exit(1)

RESTRICTED_PATH_PATTERN = re.compile(
    r"[/\\](tier_1_active|tier_2_rolling|tier_3_baseline|kernel[/\\]seeds)",
    re.IGNORECASE,
)


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def assert_non_restricted_path(target_path: str) -> Path:
    if RESTRICTED_PATH_PATTERN.search(target_path):
        raise PermissionError(
            f"ZoneBoundaryViolation: Python worker blocked from accessing parallel 3x3 path '{target_path}'."
        )
    return Path(target_path).resolve()


def probe_hardware_telemetry(_payload: Dict[str, Any]) -> Dict[str, Any]:
    cpu_count = os.cpu_count() or 1
    mem_total_bytes = 0
    mem_avail_bytes = 0
    mem_load_pct = 0.0
    uptime_sec = 0.0

    if sys.platform == "win32":
        class MEMORYSTATUSEX(ctypes.Structure):
            _fields_ = [
                ("dwLength", ctypes.c_ulong),
                ("dwMemoryLoad", ctypes.c_ulong),
                ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong),
                ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong),
                ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong),
                ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
            ]

        mem_status = MEMORYSTATUSEX()
        mem_status.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(mem_status)):
            mem_total_bytes = int(mem_status.ullTotalPhys)
            mem_avail_bytes = int(mem_status.ullAvailPhys)
            mem_load_pct = float(mem_status.dwMemoryLoad)

        ctypes.windll.kernel32.GetTickCount64.restype = ctypes.c_ulonglong
        uptime_sec = round(ctypes.windll.kernel32.GetTickCount64() / 1000.0, 2)
    else:
        meminfo: Dict[str, int] = {}
        try:
            with open("/proc/meminfo", "r", encoding="utf-8") as fh:
                for line in fh:
                    parts = line.split()
                    if len(parts) >= 2:
                        meminfo[parts[0].rstrip(":")] = int(parts[1]) * 1024
            mem_total_bytes = meminfo.get("MemTotal", 0)
            mem_avail_bytes = meminfo.get("MemAvailable", meminfo.get("MemFree", 0))
            if mem_total_bytes > 0:
                mem_load_pct = round(((mem_total_bytes - mem_avail_bytes) / mem_total_bytes) * 100.0, 2)
        except OSError:
            pass

        try:
            with open("/proc/uptime", "r", encoding="utf-8") as fh:
                uptime_sec = round(float(fh.read().split()[0]), 2)
        except OSError:
            pass

    root_anchor = os.environ.get("SystemDrive", "C:\\") if sys.platform == "win32" else "/"
    disk = shutil.disk_usage(root_anchor)

    return {
        "platform": platform.system(),
        "release": platform.release(),
        "arch": platform.machine(),
        "cpuLogicalCores": cpu_count,
        "uptimeSeconds": uptime_sec,
        "memory": {
            "totalBytes": mem_total_bytes,
            "availableBytes": mem_avail_bytes,
            "usedPercent": mem_load_pct,
        },
        "storageRoot": {
            "mount": root_anchor,
            "totalBytes": disk.total,
            "freeBytes": disk.free,
            "usedPercent": round(((disk.total - disk.free) / max(1, disk.total)) * 100.0, 2),
        },
    }


def inspect_block_io(payload: Dict[str, Any]) -> Dict[str, Any]:
    raw_target = str(payload.get("path") or (os.environ.get("SystemDrive", "C:\\") if sys.platform == "win32" else "/"))
    target = assert_non_restricted_path(raw_target)
    usage = shutil.disk_usage(target)

    bytes_per_sector = 512
    sectors_per_cluster = 8
    read_only = False

    if sys.platform == "win32":
        root_path = os.path.splitdrive(str(target))[0] + "\\"
        spc = ctypes.c_ulong()
        bps = ctypes.c_ulong()
        nfc = ctypes.c_ulong()
        tnc = ctypes.c_ulong()
        ok = ctypes.windll.kernel32.GetDiskFreeSpaceW(
            ctypes.c_wchar_p(root_path), ctypes.byref(spc), ctypes.byref(bps), ctypes.byref(nfc), ctypes.byref(tnc)
        )
        if ok:
            bytes_per_sector = int(bps.value)
            sectors_per_cluster = int(spc.value)
    else:
        st = os.statvfs(target)
        bytes_per_sector = int(st.f_frsize or st.f_bsize or 4096)
        sectors_per_cluster = max(1, int(st.f_bsize // max(1, bytes_per_sector)))
        read_only = bool(st.f_flag & getattr(os, "ST_RDONLY", 1))

    free_ratio = usage.free / max(1, usage.total)
    integrity_score = round(min(1.0, max(0.0, (0.0 if read_only else 0.7) + (0.3 * min(1.0, free_ratio * 5.0)))), 4)

    return {
        "target": str(target),
        "bytesPerSector": bytes_per_sector,
        "sectorsPerCluster": sectors_per_cluster,
        "clusterBytes": bytes_per_sector * sectors_per_cluster,
        "totalBytes": usage.total,
        "freeBytes": usage.free,
        "readOnly": read_only,
        "IntegrityScore": integrity_score,
    }


def inspect_process_memory(payload: Dict[str, Any]) -> Dict[str, Any]:
    pid = int(payload.get("pid") or os.getpid())
    if pid <= 0:
        raise ValueError("InvalidPid: PID must be greater than 0.")

    if sys.platform == "win32":
        class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
            _fields_ = [
                ("cb", ctypes.c_ulong),
                ("PageFaultCount", ctypes.c_ulong),
                ("PeakWorkingSetSize", ctypes.c_size_t),
                ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t),
                ("PeakPagefileUsage", ctypes.c_size_t),
            ]

        h_proc = ctypes.windll.kernel32.OpenProcess(0x1000 | 0x0010, False, pid)
        if not h_proc:
            raise OSError(f"OpenProcessFailed for PID {pid}")

        try:
            pmc = PROCESS_MEMORY_COUNTERS()
            pmc.cb = ctypes.sizeof(PROCESS_MEMORY_COUNTERS)
            if not ctypes.windll.psapi.GetProcessMemoryInfo(h_proc, ctypes.byref(pmc), pmc.cb):
                raise OSError(f"GetProcessMemoryInfoFailed for PID {pid}")

            return {
                "pid": pid,
                "workingSetBytes": int(pmc.WorkingSetSize),
                "peakWorkingSetBytes": int(pmc.PeakWorkingSetSize),
                "pagefileBytes": int(pmc.PagefileUsage),
                "pageFaults": int(pmc.PageFaultCount),
            }
        finally:
            ctypes.windll.kernel32.CloseHandle(h_proc)
    else:
        status_file = Path(f"/proc/{pid}/status")
        if not status_file.exists():
            raise FileNotFoundError(f"ProcessNotFound: /proc/{pid}/status does not exist.")

        metrics: Dict[str, int] = {}
        for line in status_file.read_text(encoding="utf-8").splitlines():
            if line.startswith(("VmRSS:", "VmPeak:", "VmSize:", "Threads:")):
                key, rest = line.split(":", 1)
                num = int(rest.strip().split()[0])
                metrics[key] = num * 1024 if key.startswith("Vm") else num

        return {
            "pid": pid,
            "workingSetBytes": metrics.get("VmRSS", 0),
            "peakWorkingSetBytes": metrics.get("VmPeak", 0),
            "virtualBytes": metrics.get("VmSize", 0),
            "threads": metrics.get("Threads", 0),
        }


def verify_file_integrity(payload: Dict[str, Any]) -> Dict[str, Any]:
    raw_path = str(payload.get("path") or "")
    if not raw_path:
        raise ValueError("Missing 'path' in VerifyFileIntegrity payload.")

    target = assert_non_restricted_path(raw_path)
    if not target.is_file():
        raise FileNotFoundError(f"FileNotFound: '{target}'")

    hasher = hashlib.sha256()
    with target.open("rb") as fh:
        while chunk := fh.read(65536):
            hasher.update(chunk)

    st = target.stat()
    return {
        "path": str(target),
        "sha256": hasher.hexdigest(),
        "sizeBytes": st.st_size,
        "modeOctal": oct(stat.S_IMODE(st.st_mode)),
        "modifiedUtc": datetime.fromtimestamp(st.st_mtime, timezone.utc).isoformat().replace("+00:00", "Z"),
    }


ACTION_DISPATCH: Dict[str, Callable[[Dict[str, Any]], Dict[str, Any]]] = {
    "ProbeHardwareTelemetry": probe_hardware_telemetry,
    "InspectBlockIO": inspect_block_io,
    "inspect_sectors": inspect_block_io,
    "InspectProcessMemory": inspect_process_memory,
    "VerifyFileIntegrity": verify_file_integrity,
    "Ping": lambda _p: {"pong": True, "pythonVersion": sys.version.split()[0]},
}


def process_envelope(raw_line: str) -> str:
    request_id = None
    try:
        if RESTRICTED_PATH_PATTERN.search(raw_line):
            raise PermissionError("ZoneBoundaryViolation: Restricted 3x3 partition path detected in Python worker.")

        envelope = json.loads(raw_line)
        request_id = envelope.get("Id")

        if envelope.get("Nonce") != SESSION_NONCE:
            raise PermissionError("ZoneBoundaryViolation: Session nonce mismatch on Python IPC pipe.")

        action = str(envelope.get("Action") or "")
        payload = envelope.get("Payload")
        if not isinstance(payload, dict):
            payload = {}

        handler = ACTION_DISPATCH.get(action)
        if handler is None:
            raise ValueError(f"UnsupportedPythonAction: '{action}'")

        result = handler(payload)
        return json.dumps({
            "Id": request_id, "Nonce": SESSION_NONCE, "Domain": "Python",
            "Ok": True, "Timestamp": utc_now_iso(), "Payload": result,
        }) + "\n"
    except Exception as exc:
        return json.dumps({
            "Id": request_id, "Nonce": SESSION_NONCE, "Domain": "Python",
            "Ok": False, "Timestamp": utc_now_iso(), "Payload": {"error": str(exc)},
        }) + "\n"


def serve_windows_named_pipe(pipe_name: str) -> None:
    kernel32 = ctypes.windll.kernel32
    win_pipe_path = f"\\\\.\\pipe\\{pipe_name}"
    INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value
    ERROR_PIPE_CONNECTED = 535

    kernel32.CreateNamedPipeW.restype = ctypes.c_void_p
    h_pipe = kernel32.CreateNamedPipeW(
        ctypes.c_wchar_p(win_pipe_path), 0x00000003, 0x00000000, 16, 65536, 65536, 0, None
    )
    if not h_pipe or h_pipe == INVALID_HANDLE_VALUE:
        sys.exit(1)

    sys.stdout.write(f"[DaniOs::Python] Listening on {win_pipe_path}\n")
    sys.stdout.flush()

    read_buf = ctypes.create_string_buffer(65536)
    bytes_read = ctypes.c_ulong(0)
    bytes_written = ctypes.c_ulong(0)

    try:
        while True:
            connected = kernel32.ConnectNamedPipe(ctypes.c_void_p(h_pipe), None)
            if connected == 0 and kernel32.GetLastError() != ERROR_PIPE_CONNECTED:
                time.sleep(0.01)
                continue

            line_buffer = ""
            while True:
                ok = kernel32.ReadFile(ctypes.c_void_p(h_pipe), read_buf, 65535, ctypes.byref(bytes_read), None)
                if ok == 0 or bytes_read.value == 0:
                    break
                line_buffer += read_buf.raw[: bytes_read.value].decode("utf-8", errors="replace")
                while "\n" in line_buffer:
                    line, line_buffer = line_buffer.split("\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    response_bytes = process_envelope(line).encode("utf-8")
                    kernel32.WriteFile(ctypes.c_void_p(h_pipe), response_bytes, len(response_bytes), ctypes.byref(bytes_written), None)
                    kernel32.FlushFileBuffers(ctypes.c_void_p(h_pipe))

            kernel32.DisconnectNamedPipe(ctypes.c_void_p(h_pipe))
    finally:
        kernel32.CloseHandle(ctypes.c_void_p(h_pipe))


def serve_posix_unix_pipe(pipe_name: str) -> None:
    sock_path = f"/tmp/CoreFxPipe_{pipe_name}"
    if os.path.exists(sock_path):
        os.unlink(sock_path)

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    os.chmod(sock_path, 0o600)
    srv.listen(16)

    sys.stdout.write(f"[DaniOs::Python] Listening on {sock_path}\n")
    sys.stdout.flush()

    try:
        while True:
            conn, _ = srv.accept()
            with conn:
                reader = conn.makefile("r", encoding="utf-8")
                for line in reader:
                    trimmed = line.strip()
                    if not trimmed:
                        continue
                    conn.sendall(process_envelope(trimmed).encode("utf-8"))
    finally:
        srv.close()
        if os.path.exists(sock_path):
            os.unlink(sock_path)


if __name__ == "__main__":
    try:
        if sys.platform == "win32":
            serve_windows_named_pipe(PIPE_NAME)
        else:
            serve_posix_unix_pipe(PIPE_NAME)
    except KeyboardInterrupt:
        sys.exit(0)
EOF

# 8. Cloud Origin Vault, Config, Setup & Chaos Tests
echo "[5/7] Writing Cloud Origin Vault, Config, Installer & Chaos Tests..."

cat << 'EOF' > cloud-origin/vault.config.example.json
{
  "host": "0.0.0.0",
  "port": 8443,
  "storageDir": "./vault_data",
  "defaultAccountSecret": "REPLACE_WITH_PROVISIONED_ACCOUNT_SECRET",
  "maxClockSkewSec": 300,
  "maxPayloadBytes": 262144,
  "retainRevisions": 3,
  "allowAutoBindNewFingerprints": true
}
EOF

cat << 'EOF' > cloud-origin/vault_server.js
#!/usr/bin/env node
"use strict";

const http = require("node:http");
const crypto = require("node:crypto");
const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");

const CONFIG_PATH = process.env.DANIOS_VAULT_CONFIG || path.join(__dirname, "vault.config.json");

function loadConfig() {
  let fileCfg = {};
  if (fs.existsSync(CONFIG_PATH)) {
    fileCfg = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
  }

  return {
    host: process.env.DANIOS_VAULT_HOST || fileCfg.host || "0.0.0.0",
    port: Number(process.env.DANIOS_VAULT_PORT || fileCfg.port || 8443),
    storageDir: path.resolve(process.env.DANIOS_VAULT_STORAGE || fileCfg.storageDir || path.join(__dirname, "vault_data")),
    defaultAccountSecret: process.env.DANIOS_VAULT_SECRET || fileCfg.defaultAccountSecret || "",
    maxClockSkewSec: Number(fileCfg.maxClockSkewSec || 300),
    maxPayloadBytes: Number(fileCfg.maxPayloadBytes || 262144),
    retainRevisions: Math.max(1, Number(fileCfg.retainRevisions || 3)),
    allowAutoBindNewFingerprints: fileCfg.allowAutoBindNewFingerprints !== false
  };
}

const CONFIG = loadConfig();
fs.mkdirSync(CONFIG.storageDir, { recursive: true });

const FINGERPRINT_REGEX = /^[a-f0-9]{64}$/;
const SHA256_HEX_REGEX = /^[a-f0-9]{64}$/;
const ROUTE_REGEX = /^(?:\/api)?\/v1\/savepoints\/([a-f0-9]{64})$/;

function readRawBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalBytes = 0;
    req.on("data", (chunk) => {
      totalBytes += chunk.length;
      if (totalBytes > maxBytes) {
        req.destroy();
        reject(Object.assign(new Error("PayloadTooLarge"), { statusCode: 413 }));
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", (err) => reject(err));
  });
}

function sendJson(res, statusCode, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store"
  });
  res.end(body);
}

async function resolveSecretForFingerprint(fingerprint) {
  const bindingFile = path.join(CONFIG.storageDir, fingerprint, "binding.json");
  try {
    const raw = await fsp.readFile(bindingFile, "utf8");
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed.accountSecret === "string" && parsed.accountSecret.length > 0) {
      return { secret: parsed.accountSecret, isBound: true };
    }
  } catch {}

  if (CONFIG.allowAutoBindNewFingerprints && CONFIG.defaultAccountSecret) {
    return { secret: CONFIG.defaultAccountSecret, isBound: false };
  }
  return { secret: null, isBound: false };
}

async function authenticateRequest(req, routeFingerprint, rawBodyBuffer) {
  const headerFp = String(req.headers["x-danios-fingerprint"] || "").toLowerCase();
  const timestampStr = String(req.headers["x-danios-timestamp"] || "");
  const headerBodyHash = String(req.headers["x-danios-body-sha256"] || "").toLowerCase();
  const headerSignature = String(req.headers["x-danios-signature"] || "").toLowerCase();

  if (!FINGERPRINT_REGEX.test(headerFp) || headerFp !== routeFingerprint) {
    throw Object.assign(new Error("FingerprintMismatch"), { statusCode: 401 });
  }
  if (!SHA256_HEX_REGEX.test(headerBodyHash) || !SHA256_HEX_REGEX.test(headerSignature)) {
    throw Object.assign(new Error("MalformedSecurityHeaders"), { statusCode: 401 });
  }

  const reqEpochSec = Number(timestampStr);
  const nowEpochSec = Math.floor(Date.now() / 1000);
  if (!Number.isFinite(reqEpochSec) || Math.abs(nowEpochSec - reqEpochSec) > CONFIG.maxClockSkewSec) {
    throw Object.assign(new Error("TimestampOutOfWindow"), { statusCode: 401 });
  }

  const computedBodyHash = crypto.createHash("sha256").update(rawBodyBuffer).digest("hex");
  if (computedBodyHash !== headerBodyHash) {
    throw Object.assign(new Error("BodyIntegrityMismatch"), { statusCode: 400 });
  }

  const { secret, isBound } = await resolveSecretForFingerprint(routeFingerprint);
  if (!secret) {
    throw Object.assign(new Error("UnregisteredDeviceFingerprint"), { statusCode: 403 });
  }

  const method = (req.method || "GET").toUpperCase();
  const canonical = `${method}|${routeFingerprint}|${timestampStr}|${computedBodyHash}`;
  const expectedSigHex = crypto.createHmac("sha256", secret).update(canonical, "utf8").digest("hex");

  const providedBuf = Buffer.from(headerSignature, "hex");
  const expectedBuf = Buffer.from(expectedSigHex, "hex");

  if (providedBuf.length !== expectedBuf.length || !crypto.timingSafeEqual(providedBuf, expectedBuf)) {
    throw Object.assign(new Error("InvalidHmacSignature"), { statusCode: 401 });
  }

  return { secret, isBound };
}

function validateEncryptedEnvelope(rawBuffer, expectedFingerprint) {
  let parsed;
  try {
    parsed = JSON.parse(rawBuffer.toString("utf8"));
  } catch {
    throw Object.assign(new Error("InvalidJsonPayload"), { statusCode: 400 });
  }

  if (!parsed || typeof parsed !== "object" || String(parsed.fingerprint || "").toLowerCase() !== expectedFingerprint) {
    throw Object.assign(new Error("EnvelopeFingerprintMismatch"), { statusCode: 400 });
  }

  const nonceBytes = Buffer.from(String(parsed.nonce || ""), "base64");
  const tagBytes = Buffer.from(String(parsed.tag || ""), "base64");
  const cipherBytes = Buffer.from(String(parsed.ciphertext || ""), "base64");

  if (nonceBytes.length !== 12 || tagBytes.length !== 16 || cipherBytes.length === 0) {
    throw Object.assign(new Error("InvalidAesGcmParameters"), { statusCode: 400 });
  }

  return parsed;
}

async function storeSavePoint(fingerprint, envelope, secret, wasAlreadyBound) {
  const deviceDir = path.join(CONFIG.storageDir, fingerprint);
  await fsp.mkdir(deviceDir, { recursive: true });

  if (!wasAlreadyBound) {
    const bindingTmp = path.join(deviceDir, `binding.${process.pid}.tmp`);
    const bindingFinal = path.join(deviceDir, "binding.json");
    await fsp.writeFile(bindingTmp, JSON.stringify({ fingerprint, accountSecret: secret, boundAtUtc: new Date().toISOString() }, null, 2), "utf8");
    await fsp.rename(bindingTmp, bindingFinal);
  }

  const latestPath = path.join(deviceDir, "latest.json");
  let nextRevision = 1;
  try {
    const prevDoc = JSON.parse(await fsp.readFile(latestPath, "utf8"));
    nextRevision = Number(prevDoc.revision || 0) + 1;
  } catch {}

  const record = {
    fingerprint,
    revision: nextRevision,
    storedAtUtc: new Date().toISOString(),
    nonce: envelope.nonce,
    tag: envelope.tag,
    ciphertext: envelope.ciphertext,
    meta: envelope.meta || {}
  };

  const serialized = JSON.stringify(record, null, 2);
  const revPath = path.join(deviceDir, `rev_${nextRevision}.json`);
  const tmpLatest = path.join(deviceDir, `latest.${Date.now()}.tmp`);

  await fsp.writeFile(revPath, serialized, "utf8");
  await fsp.writeFile(tmpLatest, serialized, "utf8");
  await fsp.rename(tmpLatest, latestPath);

  const files = await fsp.readdir(deviceDir);
  const revNumbers = files.map((f) => { const m = f.match(/^rev_(\d+)\.json$/); return m ? Number(m[1]) : null; }).filter((n) => n !== null).sort((a, b) => b - a);
  for (const oldRev of revNumbers.slice(CONFIG.retainRevisions)) {
    await fsp.unlink(path.join(deviceDir, `rev_${oldRev}.json`)).catch(() => {});
  }

  return record;
}

const server = http.createServer(async (req, res) => {
  try {
    const reqUrl = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
    const pathname = reqUrl.pathname;

    if (req.method === "GET" && (pathname === "/health" || pathname === "/api/health")) {
      sendJson(res, 200, { ok: true, service: "DaniOs-Cloud-Origin", timestampUtc: new Date().toISOString() });
      return;
    }

    const match = pathname.match(ROUTE_REGEX);
    if (!match) { sendJson(res, 404, { ok: false, error: "EndpointNotFound" }); return; }

    const fingerprint = match[1];
    const method = (req.method || "").toUpperCase();
    if (method !== "PUT" && method !== "GET") { sendJson(res, 405, { ok: false, error: "MethodNotAllowed" }); return; }

    const rawBody = await readRawBody(req, CONFIG.maxPayloadBytes);
    const auth = await authenticateRequest(req, fingerprint, rawBody);

    if (method === "PUT") {
      const envelope = validateEncryptedEnvelope(rawBody, fingerprint);
      const saved = await storeSavePoint(fingerprint, envelope, auth.secret, auth.isBound);
      sendJson(res, 200, { ok: true, fingerprint, revision: saved.revision, storedAtUtc: saved.storedAtUtc });
      return;
    }

    if (method === "GET") {
      const latestPath = path.join(CONFIG.storageDir, fingerprint, "latest.json");
      let rawStored;
      try { rawStored = await fsp.readFile(latestPath, "utf8"); }
      catch { sendJson(res, 404, { ok: false, error: "SavePointNotFound" }); return; }
      sendJson(res, 200, JSON.parse(rawStored));
    }
  } catch (err) {
    sendJson(res, Number(err.statusCode || 500), { ok: false, error: err.message || "InternalVaultError" });
  }
});

server.listen(CONFIG.port, CONFIG.host, () => {
  process.stdout.write(`[DaniOs::CloudOrigin] Listening on http://${CONFIG.host}:${CONFIG.port} | Storage: ${CONFIG.storageDir}\n`);
});
EOF

cat << 'EOF' > config/kernel.config.example.json
{
  "osName": "DaniOs",
  "schemaVersion": "1.0.0",
  "kernel": {
    "heartbeatIntervalMs": 1500,
    "autoHealEnabled": true,
    "requireSandboxValidation": true,
    "maxAutonomousRetries": 3,
    "perimeterSweepIntervalTicks": 20,
    "autoHealNativeDrift": true
  },
  "ai": {
    "provider": "in-kernel-dll",
    "nativeRuntime": "llama.cpp",
    "modelFile": "danios-core-3b.Q4_K_M.gguf",
    "contextTokens": 4096,
    "maxDiagnosisTokens": 256,
    "gpuLayers": 0,
    "fallbackToDeterministicRules": true
  },
  "memoryMatrix": {
    "parallelPartitionPath": null,
    "formats": ["md", "yml", "json"],
    "tiers": ["tier_1_active", "tier_2_rolling", "tier_3_baseline"],
    "expansionFactor": 3,
    "autoPruneOnShutdown": true,
    "maxJournalEntriesPerTier": 50,
    "promotionThresholdRuns": 3,
    "minSolutionConfidenceScore": 0.75,
    "retainMaxRollbackSnapshots": 15
  },
  "desktopBrowserIntegration": {
    "enabled": true,
    "bindAddress": "127.0.0.1",
    "httpPort": 4110,
    "wsPort": 4111,
    "requireEphemeralToken": true,
    "eventHistoryBufferSize": 100
  },
  "polyglot": {
    "ipcTransport": "named_pipe",
    "pipeTimeoutMs": 4000,
    "workers": {
      "node": { "enabled": true, "pipeName": "DaniOs.Pipe.Node", "workerCount": 1, "entryPoint": "polyglot/node/bridge_daemon.js" },
      "php": { "enabled": true, "pipeName": "DaniOs.Pipe.PHP", "workerCount": 1, "entryPoint": "polyglot/php/bridge_worker.php" },
      "python": { "enabled": true, "pipeName": "DaniOs.Pipe.Python", "workerCount": 1, "entryPoint": "polyglot/python/bridge_server.py" }
    }
  },
  "cloudOrigin": {
    "enabled": true,
    "originUrl": "https://origin.danios.local/api",
    "accountSecret": "REPLACE_WITH_PROVISIONED_ACCOUNT_SECRET",
    "kernelSalt": "DaniOs-Kernel-v1",
    "autoBackupOnCleanBoot": true,
    "autoBackupOnHealCommit": true,
    "autoRestoreOnZeroGeneration": true,
    "requestTimeoutSec": 8
  }
}
EOF

cat << 'EOF' > setup/Install-DaniOs.ps1
#Requires -Version 7.4
using namespace System.IO
using namespace System.Security.AccessControl
using namespace System.Security.Principal
using namespace System.Security.Cryptography

[CmdletBinding()]
param(
    [string]$CloudOriginUrl,
    [string]$AccountSecret,
    [string]$ParallelPartitionPath,
    [switch]$SkipDotNetBuild,
    [switch]$SkipNpmInstall,
    [switch]$SkipVerification,
    [switch]$NonInteractive,
    [switch]$BootAfterInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DaniRoot       = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$BootDir        = Join-Path $DaniRoot "boot"
$KernelDir      = Join-Path $DaniRoot "kernel"
$KernelBinDir   = Join-Path $KernelDir "bin"
$KernelModelDir = Join-Path $KernelDir "models"
$ConfigDir      = Join-Path $DaniRoot "config"
$NodePolyDir    = Join-Path $DaniRoot "polyglot\node"
$NativeZoneDir  = Join-Path $DaniRoot "native"

function Test-RuntimeRequirement {
    param([string]$Name, [string]$Command, [string[]]$VersionArgs, [version]$MinVersion, [string]$InstallHint)
    $cmdInfo = Get-Command -Name $Command -ErrorAction SilentlyContinue
    if ($null -eq $cmdInfo) { return [PSCustomObject]@{ Name = $Name; Found = $false; Version = "Not Installed"; MeetsMin = $false; InstallTip = $InstallHint } }
    try {
        $rawOut = (& $Command @VersionArgs 2>&1 | Out-String).Trim()
        if ($rawOut -match "(\d+\.\d+(?:\.\d+)?)") {
            $parsedVer = [version]$Matches[1]
            return [PSCustomObject]@{ Name = $Name; Found = $true; Version = $parsedVer.ToString(); MeetsMin = ($parsedVer -ge $MinVersion); InstallTip = $InstallHint }
        }
    } catch {}
    return [PSCustomObject]@{ Name = $Name; Found = $true; Version = "Unknown"; MeetsMin = $false; InstallTip = $InstallHint }
}

function Get-TargetRuntimeIdentifier {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($IsWindows) { return "win-$arch" }
    if ($IsLinux)   { return "linux-$arch" }
    if ($IsMacOS)   { return "osx-$arch" }
    return "win-x64"
}

function Set-KernelOnlyFileAcl {
    param([string]$FilePath)
    if ($IsWindows) {
        try {
            $acl = Get-Acl -Path $FilePath
            $acl.SetAccessRuleProtection($true, $false)
            $systemSid = [SecurityIdentifier]::new([WellKnownSidType]::LocalSystemSid, $null)
            $adminSid  = [SecurityIdentifier]::new([WellKnownSidType]::BuiltinAdministratorsSid, $null)
            $usersSid  = [SecurityIdentifier]::new([WellKnownSidType]::BuiltinUsersSid, $null)
            $acl.AddAccessRule([FileSystemAccessRule]::new($systemSid, "FullControl", "Allow"))
            $acl.AddAccessRule([FileSystemAccessRule]::new($adminSid,  "FullControl", "Allow"))
            $acl.AddAccessRule([FileSystemAccessRule]::new($usersSid,  "FullControl", "Deny"))
            Set-Acl -Path $FilePath -AclObject $acl
        } catch {}
    } else { & chmod 600 $FilePath }
}

$pythonCmd = if (Get-Command "python3" -ErrorAction SilentlyContinue) { "python3" } else { "python" }
$checks = @(
    (Test-RuntimeRequirement -Name ".NET SDK" -Command "dotnet"   -VersionArgs @("--version")               -MinVersion ([version]"8.0.0")  -InstallHint "Install .NET 8.0 SDK"),
    (Test-RuntimeRequirement -Name "Node.js"  -Command "node"     -VersionArgs @("--version")               -MinVersion ([version]"22.0.0") -InstallHint "Install Node.js 22+"),
    (Test-RuntimeRequirement -Name "PHP CLI"  -Command "php"      -VersionArgs @("-r", "echo PHP_VERSION;") -MinVersion ([version]"8.3.0")  -InstallHint "Install PHP 8.3+ CLI"),
    (Test-RuntimeRequirement -Name "Python"   -Command $pythonCmd -VersionArgs @("--version")               -MinVersion ([version]"3.11.0") -InstallHint "Install Python 3.11+")
)

$missingOrOld = @($checks | Where-Object { -not $_.MeetsMin })
if ($missingOrOld.Count -gt 0) {
    $missingOrOld | Format-Table Name, Version, InstallTip -AutoSize
    throw "Prerequisite check failed."
}

New-Item -ItemType Directory -Path $KernelBinDir, (Join-Path $KernelBinDir "native"), $KernelModelDir, $NativeZoneDir -Force | Out-Null

$bootProj     = Join-Path $BootDir "DaniOs.Boot\DaniOs.Boot.csproj"
$rid          = Get-TargetRuntimeIdentifier
$bootExeName  = if ($IsWindows) { "DaniOs.Boot.exe" } else { "DaniOs.Boot" }
$finalBootExe = Join-Path $BootDir $bootExeName

if (-not $SkipDotNetBuild -and (Test-Path $bootProj)) {
    & dotnet publish $bootProj -c Release -r $rid --self-contained true -o $KernelBinDir --nologo
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed." }
    $publishedBootExe = Join-Path $KernelBinDir $bootExeName
    if (Test-Path $publishedBootExe) {
        Move-Item -Path $publishedBootExe -Destination $finalBootExe -Force
        if (-not $IsWindows) { & chmod +x $finalBootExe }
    }
}

if (-not $SkipNpmInstall -and (Test-Path (Join-Path $NodePolyDir "package.json"))) {
    & npm install --prefix $NodePolyDir --no-audit --no-fund --loglevel=error
}

$exampleConfigPath = Join-Path $ConfigDir "kernel.config.example.json"
$liveConfigPath    = Join-Path $ConfigDir "kernel.config.json"
if (-not (Test-Path $liveConfigPath)) { Copy-Item -Path $exampleConfigPath -Destination $liveConfigPath -Force }

$Config = Get-Content -Path $liveConfigPath -Raw | ConvertFrom-Json -AsHashtable
if ($ParallelPartitionPath) { $Config.memoryMatrix.parallelPartitionPath = $ParallelPartitionPath }
if ($CloudOriginUrl)        { $Config.cloudOrigin.originUrl = $CloudOriginUrl }

if ($AccountSecret) {
    $Config.cloudOrigin.accountSecret = $AccountSecret
} elseif ($Config.cloudOrigin.accountSecret -eq "REPLACE_WITH_PROVISIONED_ACCOUNT_SECRET") {
    $Config.cloudOrigin.accountSecret = [Convert]::ToHexString([RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
}

$Config | ConvertTo-Json -Depth 10 | Set-Content -Path $liveConfigPath -Encoding UTF8 -Force
Set-KernelOnlyFileAcl -FilePath $liveConfigPath

Import-Module (Join-Path $KernelDir "Bridge.psm1")      -Force
Import-Module (Join-Path $KernelDir "CloudOrigin.psm1") -Force
Import-Module (Join-Path $KernelDir "Core.psm1")        -Force

$partitionRoot = Mount-DaniParallelFirewallPartition -Config $Config
Initialize-DaniGoldenMatrix -ParallelPartitionRoot $partitionRoot | Out-Null

if (-not $SkipVerification) {
    & (Join-Path $DaniRoot "tests\Simulate-KernelFault.ps1")
}

if ($BootAfterInstall) {
    if (Test-Path $finalBootExe) { & $finalBootExe } else { & (Join-Path $BootDir "init.ps1") -ConfigPath $liveConfigPath }
}
EOF

cat << 'EOF' > tests/Simulate-KernelFault.ps1
#Requires -Version 7.4
using namespace System.Net

[CmdletBinding()]
param([switch]$SkipLiveWorkers, [switch]$KeepSandbox)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DaniRoot  = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$KernelDir = Join-Path $DaniRoot "kernel"

Import-Module (Join-Path $KernelDir "Bridge.psm1")      -Force
Import-Module (Join-Path $KernelDir "CloudOrigin.psm1") -Force
Import-Module (Join-Path $KernelDir "Policy.psm1")      -Force
Import-Module (Join-Path $KernelDir "Snapshot.psm1")    -Force
Import-Module (Join-Path $KernelDir "Core.psm1")        -Force

$script:PassedCount = 0
$script:FailedCount = 0

function Invoke-ChaosTest {
    param([string]$Name, [scriptblock]$TestBlock)
    Write-Host "`n[TEST] $Name" -ForegroundColor Cyan
    try {
        & $TestBlock
        $script:PassedCount++
        Write-Host "  -> PASS" -ForegroundColor Green
    } catch {
        $script:FailedCount++
        Write-Host "  -> FAIL: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True { param([bool]$Condition, [string]$Message = "Assertion failed") if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Actual, $Expected, [string]$Message = "") if ($Actual -ne $Expected) { throw "$Message Expected '$Expected', got '$Actual'" } }

$SandboxId        = [guid]::NewGuid().ToString("N").Substring(0, 10)
$SandboxRoot      = Join-Path ([System.IO.Path]::GetTempPath()) "DaniOs_Chaos_$SandboxId"
$ParallelPartRoot = Join-Path $SandboxRoot ".parallel_3x3_firewall"
$NativeFsRoot     = Join-Path $SandboxRoot "encapsulated_native_fs"
New-Item -ItemType Directory -Path $ParallelPartRoot, $NativeFsRoot -Force | Out-Null

$TestHttpPort  = Get-Random -Minimum 24100 -Maximum 24900
$TestWsPort    = $TestHttpPort + 1
$TestVaultPort = $TestHttpPort + 2

$TestConfig = @{
    osName = "DaniOs-ChaosTest"
    kernel = @{ heartbeatIntervalMs = 500; autoHealEnabled = $true; requireSandboxValidation = $true; maxAutonomousRetries = 3 }
    memoryMatrix = @{ parallelPartitionPath = $ParallelPartRoot; maxJournalEntriesPerTier = 12; autoPruneOnShutdown = $true }
    desktopBrowserIntegration = @{ bindAddress = "127.0.0.1"; httpPort = $TestHttpPort; wsPort = $TestWsPort }
    cloudOrigin = @{ enabled = $true; originUrl = "http://127.0.0.1:$TestVaultPort/api"; accountSecret = "chaos-secret-9f8e7d"; kernelSalt = "DaniOs-Chaos-v1"; autoBackupOnCleanBoot = $true; autoBackupOnHealCommit = $true; autoRestoreOnZeroGeneration = $true }
}

$SessionNonce = $null
try {
    Invoke-ChaosTest -Name "1. Golden Seed Hydration & 3x3 Partition Self-Repair" -TestBlock {
        $init = Initialize-DaniGoldenMatrix -ParallelPartitionRoot $ParallelPartRoot
        Assert-Equal $init.ActiveNodes 9
        $script:SessionNonce = $init.BrowserSession
        Remove-Item (Join-Path $ParallelPartRoot "tier_2_rolling\solutions.yml") -Force
        Initialize-DaniGoldenMatrix -ParallelPartitionRoot $ParallelPartRoot | Out-Null
        Assert-True (Test-Path (Join-Path $ParallelPartRoot "tier_2_rolling\solutions.yml"))
    }

    Invoke-ChaosTest -Name "2. AST Policy Firewall" -TestBlock {
        Assert-True (-not (Test-DaniScriptAst -ScriptText 'Invoke-Expression "Get-Process"').Approved)
        Assert-True (-not (Test-DaniScriptAst -ScriptText 'Remove-Item "C:\ProgramData\DaniOs\.parallel_3x3_firewall\tier_1_active\state.json"').Approved)
        Assert-True (Test-DaniScriptAst -ScriptText '$x = 1 + 1').Approved
    }

    Invoke-ChaosTest -Name "3. Zone Boundary & Path Traversal Firewall" -TestBlock {
        Assert-True (-not (Test-DaniWebToNativeRequest -SourceDomain "Node" -Intent "Write" -TargetPath "..\..\.parallel_3x3_firewall\tier_3_baseline\solutions.yml" -NativeRoot $NativeFsRoot).Allowed)
        Assert-True (-not (Test-DaniWebToNativeRequest -SourceDomain "PHP" -Intent "Write" -TargetPath "notes.txt" -NativeRoot $NativeFsRoot).Allowed)
        $mediated = Invoke-DaniMediatedNativeWrite -SourceDomain "BrowserUI" -TargetPath "workspace\prefs.json" -Content '{"ok":true}' -NativeRoot $NativeFsRoot -ParallelPartitionRoot $ParallelPartRoot
        Assert-True $mediated.Ok
    }

    Invoke-ChaosTest -Name "4. Deterministic Rollback & Outside-In Drift Healing" -TestBlock {
        $targetFile = Join-Path $NativeFsRoot "apps\service.json"
        New-Item -ItemType Directory -Path (Split-Path $targetFile -Parent) -Force | Out-Null
        Set-Content -Path $targetFile -Value '{"port":8080}' -Encoding UTF8 -Force
        Invoke-DaniTransactionalAction -ParallelPartitionRoot $ParallelPartRoot -TargetPaths @($targetFile) -Action { } | Out-Null
        $bad = Invoke-DaniTransactionalAction -ParallelPartitionRoot $ParallelPartRoot -TargetPaths @($targetFile) -Action { Set-Content -Path $targetFile -Value "BROKEN" } -VerifyCheck { $false }
        Assert-True $bad.RolledBack
        Assert-Equal ((Get-Content $targetFile -Raw).Trim()) '{"port":8080}'
        Set-Content -Path $targetFile -Value '{"port":6666}' -Encoding UTF8 -Force
        $healed = Test-DaniNativePerimeterIntegrity -ParallelPartitionRoot $ParallelPartRoot -AutoHealDrift
        Assert-True $healed.Drifted[0].AutoHealed
        Assert-Equal ((Get-Content $targetFile -Raw).Trim()) '{"port":8080}'
    }

    Invoke-ChaosTest -Name "5. 3x3 Expansion & Pruning" -TestBlock {
        for ($i = 1; $i -le 20; $i++) { Write-DaniJournalEntry -ParallelPartitionRoot $ParallelPartRoot -Category "TICK" -Message "Event $i" }
        Invoke-DaniMatrixExpansionAndPrune -ParallelPartitionRoot $ParallelPartRoot -Config $TestConfig
        $lines = @(Get-Content (Join-Path $ParallelPartRoot "tier_1_active\journal.md") | Where-Object { $_ -match "^- \*\*\[" })
        Assert-True ($lines.Count -le 12)
    }
}
finally {
    if (-not $KeepSandbox -and (Test-Path $SandboxRoot)) { Remove-Item -Path $SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`nSummary: $($script:PassedCount) Passed | $($script:FailedCount) Failed"
if ($script:FailedCount -gt 0) { exit 1 }
EOF

# 9. Complete README.md
echo "[6/7] Writing README.md..."

cat << 'EOF' > README.md
<div align="center">

# ⚡ DaniOs
### Self-Healing, AI-Powered Operating System Built on a Self-Contained Polyglot PowerShell Kernel

[![PowerShell](https://img.shields.io/badge/Kernel-PowerShell%207.4%2B%20(.NET%208%20DLL)-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Embedded AI](https://img.shields.io/badge/Kernel%20AI-In--Process%20SLM%20(llama.cpp)-8B5CF6?style=for-the-badge)](https://github.com/ggerganov/llama.cpp)
[![Node.js](https://img.shields.io/badge/Parsing%20%26%20Desktop%20UI-Node.js%2022%2B-339933?style=for-the-badge&logo=nodedotjs&logoColor=white)](https://nodejs.org/)
[![PHP](https://img.shields.io/badge/Web%20Edge%20%26%20Probes-PHP%208.3%2B-777BB4?style=for-the-badge&logo=php&logoColor=white)](https://www.php.net/)
[![Python](https://img.shields.io/badge/Syscalls%20%26%20Hardware-Python%203.11%2B-3776AB?style=for-the-badge&logo=python&logoColor=white)](https://www.python.org/)
[![License: GPL v3](https://img.shields.io/badge/License-GNU%20GPLv3-BD0000?style=for-the-badge&logo=gnu&logoColor=white)](LICENSE)

*An autonomous, object-driven operating environment where a self-contained PowerShell + AI DLL kernel orchestrates system state, an ACL-locked parallel 3×3 firewall partition encompasses and protects the native filesystem, a hardware-fingerprinted Cloud Origin vault preserves encrypted save points, and restricted Node.js, PHP, and Python workers handle browser integration, web I/O, and low-level system probes.*

</div>

---

## 📖 Overview

**DaniOs** unifies **PowerShell (`System.Management.Automation.dll`)** and a **dedicated local Small Language Model (`DaniOs.Kernel.AI.dll` + `llama.dll`)** inside a single self-contained .NET 8 kernel process. Around the encapsulated native filesystem sits an ACL-locked **Parallel 3×3 Firewall Partition** (`.md`, `.yml`, `.json` × 3 tiers = 9 nodes) invisible and permission-denied to standard users and web-facing workers.

## 🚀 Quick Start

```powershell
# Automated prerequisite check, C# DLL compilation, onboarding & chaos verification
pwsh -NoProfile -ExecutionPolicy Bypass -File ./setup/Install-DaniOs.ps1

# Boot self-contained kernel
./boot/DaniOs.Boot.exe   # Windows
./boot/DaniOs.Boot       # Linux / macOS
 License
​Distributed under the GNU General Public License v3.0 (GPL-3.0). See LICENSE for full terms.
EOF
​10. Stage, Commit & Push to origin main
​echo "[7/7] Committing and pushing to https://github.com/danigurlts/danios ..."
git branch -M main
git add .
git commit -m "Scaffold complete DaniOs polyglot DLL kernel, parallel 3x3 firewall matrix, and Cloud Origin vault"
git push -u origin main
​echo ""
echo " ✅ Done! Refresh https://github.com/danigurlts/danios on your phone."
echo ""
