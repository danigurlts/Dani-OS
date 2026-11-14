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
