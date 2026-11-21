# Native llama.cpp runtime

The local Windows bundle is the official `llama.cpp` `b12602` Windows x64 CPU build. Keep `llama.dll`, the matching `ggml*.dll` files, and `libomp.dll` together in this directory so dependent DLLs load from the same location.

The files are runtime artifacts and remain untracked by Git. Download the matching bundle from the [llama.cpp b12602 release](https://github.com/ggml-org/llama.cpp/releases/tag/b12602); do not mix DLLs from different builds or architectures.
