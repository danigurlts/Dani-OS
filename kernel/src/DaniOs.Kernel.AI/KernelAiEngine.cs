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
