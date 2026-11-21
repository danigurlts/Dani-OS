using System.Collections;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace DaniOs.Kernel;

public sealed class AiRuntimeOptions
{
    public string NativeLibraryDirectory { get; set; } = "native";
    public int ContextTokens { get; set; } = 4096;
    public int BatchSize { get; set; } = 128;
    public int Threads { get; set; } = 3;
    public int GpuLayers { get; set; }
    public int ModelLoadTimeoutMs { get; set; } = 120_000;
    public int InferenceTimeoutMs { get; set; } = 30_000;
    public int MaxTokens { get; set; } = 96;
    public int MaxOutputCharacters { get; set; } = 4096;
    public float Temperature { get; set; }
    public float TopP { get; set; } = 0.9f;
    public float RepeatPenalty { get; set; } = 1.05f;
    public bool FallbackToDeterministicRules { get; set; } = true;
}

public static unsafe class AI
{
    private static readonly object SyncLock = new();
    private static IntPtr _modelPtr = IntPtr.Zero;
    private static IntPtr _vocabPtr = IntPtr.Zero;
    private static int _contextTokens = 4096;
    private static int _batchSize = 128;
    private static int _threads = Math.Max(1, Environment.ProcessorCount - 1);
    private static int _gpuLayers;
    private static int _modelLoadTimeoutMs = 120_000;
    private static int _inferenceTimeoutMs = 30_000;
    private static int _maxTokens = 96;
    private static int _maxOutputCharacters = 4096;
    private static float _temperature;
    private static float _topP = 0.9f;
    private static float _repeatPenalty = 1.05f;
    private static bool _fallbackToDeterministicRules = true;
    private static bool _nativeReady;
    private static string _loadedModelPath = string.Empty;

    public static bool IsNativeLoaded => _nativeReady;

    public static bool Initialize(string modelPath, int contextTokens = 4096)
        => Initialize(modelPath, new AiRuntimeOptions { ContextTokens = contextTokens });

    public static bool Initialize(string modelPath, AiRuntimeOptions options)
    {
        lock (SyncLock)
        {
            ArgumentNullException.ThrowIfNull(options);
            _contextTokens = Math.Clamp(options.ContextTokens, 512, 32768);
            _batchSize = Math.Clamp(options.BatchSize, 32, Math.Min(2048, _contextTokens));
            _threads = Math.Clamp(options.Threads <= 0 ? Math.Max(1, Environment.ProcessorCount - 1) : options.Threads, 1, Environment.ProcessorCount);
            _gpuLayers = Math.Clamp(options.GpuLayers, 0, 999);
            _modelLoadTimeoutMs = Math.Clamp(options.ModelLoadTimeoutMs, 1000, 600_000);
            _inferenceTimeoutMs = Math.Clamp(options.InferenceTimeoutMs, 250, 300_000);
            _maxTokens = Math.Clamp(options.MaxTokens, 1, 2048);
            _maxOutputCharacters = Math.Clamp(options.MaxOutputCharacters, 64, 65_536);
            _temperature = float.IsFinite(options.Temperature) ? Math.Clamp(options.Temperature, 0f, 2f) : 0f;
            _topP = float.IsFinite(options.TopP) ? Math.Clamp(options.TopP, 0.05f, 1f) : 0.9f;
            _repeatPenalty = float.IsFinite(options.RepeatPenalty) ? Math.Clamp(options.RepeatPenalty, 0.5f, 2f) : 1.05f;
            _fallbackToDeterministicRules = options.FallbackToDeterministicRules;

            if (_nativeReady && string.Equals(_loadedModelPath, modelPath, StringComparison.OrdinalIgnoreCase))
                return true;

            ShutdownInternal();

            if (string.IsNullOrWhiteSpace(modelPath) || !File.Exists(modelPath))
                return false;

            string binDir = Path.GetDirectoryName(typeof(AI).Assembly.Location) ?? AppContext.BaseDirectory;
            NativeLlamaInterop.EnsureNativeResolver(binDir, options.NativeLibraryDirectory);

            bool backendInitialized = false;
            try
            {
                NativeLlamaInterop.llama_backend_init();
                backendInitialized = true;

                var modelParams = NativeLlamaInterop.llama_model_default_params();
                modelParams.NGpuLayers = _gpuLayers;
                modelParams.LoadMode = NativeLlamaInterop.LoadModeMmap;
                long loadStarted = Environment.TickCount64;
                NativeLlamaInterop.LlamaProgressCallback progressCallback = (_, _) =>
                    Environment.TickCount64 - loadStarted < _modelLoadTimeoutMs;
                modelParams.ProgressCallback = Marshal.GetFunctionPointerForDelegate(progressCallback);

                _modelPtr = NativeLlamaInterop.llama_model_load_from_file(modelPath, modelParams);
                GC.KeepAlive(progressCallback);
                if (_modelPtr == IntPtr.Zero)
                {
                    NativeLlamaInterop.llama_backend_free();
                    backendInitialized = false;
                    return false;
                }

                _vocabPtr = NativeLlamaInterop.llama_model_get_vocab(_modelPtr);
                _loadedModelPath = modelPath;
                _nativeReady = true;
                return true;
            }
            catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException or MarshalDirectiveException)
            {
                if (_modelPtr != IntPtr.Zero)
                {
                    NativeLlamaInterop.llama_model_free(_modelPtr);
                    _modelPtr = IntPtr.Zero;
                }
                if (backendInitialized)
                    NativeLlamaInterop.llama_backend_free();
                _nativeReady = false;
                _vocabPtr = IntPtr.Zero;
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
            string result = InferRaw(sysPrompt, serialized, maxTokens: _maxTokens);
            if (!string.IsNullOrWhiteSpace(result))
                return result.Trim();
        }

        return _fallbackToDeterministicRules ? DeterministicFallbackDiagnosis(serialized) : string.Empty;
    }

    public static string DiagnoseAndSynthesize(string faultContextJson, string journalContext)
    {
        if (_nativeReady)
        {
            string sysPrompt =
                "You are the DaniOs in-kernel self-healing synthesizer. Given the fault JSON and recent " +
                "3x3 run journal entries, identify the root cause and provide a safe, minimal remediation summary.";
            string userPrompt = $"FAULT:\n{faultContextJson}\n\nRECENT_JOURNAL:\n{journalContext}";
            string result = InferRaw(sysPrompt, userPrompt, maxTokens: _maxTokens);
            if (!string.IsNullOrWhiteSpace(result))
                return result.Trim();
        }

        return _fallbackToDeterministicRules ? DeterministicFallbackDiagnosis(faultContextJson) : string.Empty;
    }

    public static string InferRaw(string systemPrompt, string userPrompt, int maxTokens = 256)
    {
        lock (SyncLock)
        {
            if (!_nativeReady || _modelPtr == IntPtr.Zero || _vocabPtr == IntPtr.Zero)
                return string.Empty;
            maxTokens = Math.Clamp(maxTokens, 1, _maxTokens);
            long inferenceStarted = Stopwatch.GetTimestamp();
            bool TimedOut() => Stopwatch.GetElapsedTime(inferenceStarted).TotalMilliseconds >= _inferenceTimeoutMs;

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
                ctxParams.NBatch = (uint)_contextTokens;
                ctxParams.NUbatch = (uint)Math.Min(_batchSize, 128);
                ctxParams.NThreads = _threads;
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

                if (nPromptTokens <= 0 || nPromptTokens > _contextTokens || TimedOut())
                    return string.Empty;

                fixed (int* pTokens = promptTokens)
                {
                    var batch = NativeLlamaInterop.llama_batch_get_one(pTokens, nPromptTokens);
                    if (NativeLlamaInterop.llama_decode(ctxPtr, batch) != 0)
                        return string.Empty;
                }

                var chainParams = NativeLlamaInterop.llama_sampler_chain_default_params();
                samplerPtr = NativeLlamaInterop.llama_sampler_chain_init(chainParams);
                if (_topP < 1f)
                    NativeLlamaInterop.llama_sampler_chain_add(samplerPtr, NativeLlamaInterop.llama_sampler_init_top_p(_topP, 1));
                if (_repeatPenalty != 1f)
                    NativeLlamaInterop.llama_sampler_chain_add(samplerPtr, NativeLlamaInterop.llama_sampler_init_penalties(
                        NativeLlamaInterop.llama_vocab_n_tokens(_vocabPtr), 64, _repeatPenalty, 0f, 0f));
                if (_temperature <= 0f)
                {
                    NativeLlamaInterop.llama_sampler_chain_add(samplerPtr, NativeLlamaInterop.llama_sampler_init_greedy());
                }
                else
                {
                    NativeLlamaInterop.llama_sampler_chain_add(samplerPtr, NativeLlamaInterop.llama_sampler_init_temp(_temperature));
                    NativeLlamaInterop.llama_sampler_chain_add(samplerPtr, NativeLlamaInterop.llama_sampler_init_dist(42));
                }

                int eosToken = NativeLlamaInterop.llama_vocab_eos(_vocabPtr);
                var outputBytes = new List<byte>(maxTokens * 4);
                byte* pieceBuf = stackalloc byte[256];
                int nextToken = 0;

                for (int i = 0; i < maxTokens; i++)
                {
                    if (TimedOut())
                        return string.Empty;
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
                string answer = endMarker >= 0 ? decoded[..endMarker] : decoded;
                return answer.Length <= _maxOutputCharacters && !TimedOut() ? answer : string.Empty;
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
