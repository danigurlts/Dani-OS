using System.Runtime.InteropServices;

namespace DaniOs.Kernel;

internal static unsafe class NativeLlamaInterop
{
    private const string LibName = "llama";
    private static bool _resolverRegistered;

    public static void EnsureNativeResolver(string kernelBinDir, string? configuredNativeDirectory = null)
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

            for (DirectoryInfo? current = new(Path.GetFullPath(kernelBinDir)); current is not null; current = current.Parent)
            {
                var candidateDirectories = new List<string>();
                if (!string.IsNullOrWhiteSpace(configuredNativeDirectory))
                {
                    candidateDirectories.Add(Path.IsPathRooted(configuredNativeDirectory)
                        ? configuredNativeDirectory
                        : Path.Combine(current.FullName, configuredNativeDirectory));
                }
                candidateDirectories.Add(Path.Combine(current.FullName, "native"));

                foreach (string directory in candidateDirectories.Distinct(StringComparer.OrdinalIgnoreCase))
                {
                    string nativeCandidate = Path.Combine(directory, fileName);
                    if (File.Exists(nativeCandidate) && NativeLibrary.TryLoad(nativeCandidate, out IntPtr handle))
                        return handle;
                }
            }

            return IntPtr.Zero;
        });
    }

    public const int LoadModeMmap = 1;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public delegate bool LlamaProgressCallback(float progress, IntPtr userData);

    [StructLayout(LayoutKind.Sequential)]
    public struct LlamaModelParams
    {
        public IntPtr Devices;
        public IntPtr TensorBuftOverrides;
        public int NGpuLayers;
        public int SplitMode;
        public int LoadMode;
        public int LazyMode;
        public int MainGpu;
        public IntPtr TensorSplit;
        public IntPtr ProgressCallback;
        public IntPtr ProgressCallbackUserData;
        public IntPtr KvOverrides;
        [MarshalAs(UnmanagedType.I1)] public bool VocabOnly;
        [MarshalAs(UnmanagedType.I1)] public bool CheckTensors;
        [MarshalAs(UnmanagedType.I1)] public bool UseExtraBufts;
        [MarshalAs(UnmanagedType.I1)] public bool NoHost;
        [MarshalAs(UnmanagedType.I1)] public bool NoAlloc;
        [MarshalAs(UnmanagedType.I1)] public bool LoadMtp;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LlamaContextParams
    {
        public uint NCtx;
        public uint NBatch;
        public uint NUbatch;
        public uint NSeqMax;
        public uint NRsSeq;
        public uint NOutputsMax;
        public uint NOutputsMaxPerSeq;
        public int NThreads;
        public int NThreadsBatch;
        public int CtxType;
        public int RopeScalingType;
        public int PoolingType;
        public int AttentionType;
        public int FlashAttnType;
        public float RopeFreqBase;
        public float RopeFreqScale;
        public float YarnExtFactor;
        public float YarnAttnFactor;
        public float YarnBetaFast;
        public float YarnBetaSlow;
        public uint YarnOrigCtx;
        public IntPtr CbEval;
        public IntPtr CbEvalUserData;
        public int TypeK;
        public int TypeV;
        public nuint MoeCacheSize;
        public float MoeCacheCpuShare;
        public IntPtr AbortCallback;
        public IntPtr AbortCallbackData;
        [MarshalAs(UnmanagedType.I1)] public bool Embeddings;
        [MarshalAs(UnmanagedType.I1)] public bool OffloadKqv;
        [MarshalAs(UnmanagedType.I1)] public bool NoPerf;
        [MarshalAs(UnmanagedType.I1)] public bool OpOffload;
        [MarshalAs(UnmanagedType.I1)] public bool SwaFull;
        [MarshalAs(UnmanagedType.I1)] public bool KvUnified;
        public IntPtr Samplers;
        public nuint NSamplers;
        public IntPtr CtxOther;
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
    public static extern int llama_vocab_n_tokens(IntPtr vocab);

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
    public static extern IntPtr llama_sampler_init_top_p(float p, nuint minKeep);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_sampler_init_penalties(int vocabSize, int penaltyLastN, float repeat, float frequency, float presence);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_sampler_init_temp(float temperature);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr llama_sampler_init_dist(uint seed);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern int llama_sampler_sample(IntPtr smpl, IntPtr ctx, int idx);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_sampler_accept(IntPtr smpl, int token);

    [DllImport(LibName, CallingConvention = CallingConvention.Cdecl)]
    public static extern void llama_sampler_free(IntPtr smpl);
}
