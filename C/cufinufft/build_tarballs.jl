# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg
using BinaryBuilderBase
include(joinpath(@__DIR__, "..", "..", "fancy_toys.jl"))
include(joinpath(@__DIR__, "..", "..", "platforms", "cuda.jl"))

# Build script for the CUDA part of FINUFFT

# Builds for all compatible CUDA platforms, but without microarchitecture expansion (not
# needed for CUDA cuda, and would produce a giant amount of artifacts)
name = "cufinufft"
version = v"2.4.1"
commit_hash = "7919db50853f9933004d7c61e54b5782f7d8b00e" # current master
preferred_gcc_version=v"11"

# Collection of sources required to complete build
sources = [
    GitSource("https://github.com/flatironinstitute/finufft.git", commit_hash)
]

# Build script: cufinufft, all possible archs available for each CUDA version
# - CMake toolchain looks for compiler in CUDA_PATH/bin/nvcc
#   and libs in CUDA_PATH/lib64, so create link.
# - Need higher version of CMake, so remove existing
script = raw"""
cd $WORKSPACE/srcdir/finufft*/
apk del cmake

export CUDA_PATH="$prefix/cuda"
ln -s $prefix/cuda/lib $prefix/cuda/lib64

mkdir build && cd build
cmake .. \
    -DCMAKE_PREFIX_PATH="${prefix}" \
    -DCMAKE_INSTALL_PREFIX="${prefix}" \
    -DCMAKE_TOOLCHAIN_FILE="${CMAKE_TARGET_TOOLCHAIN}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DFINUFFT_FFTW_SUFFIX="" \
    -DFINUFFT_USE_CPU=OFF \
    -DFINUFFT_USE_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHS}" \
    -DFINUFFT_STATIC_LINKING="OFF"
cmake --build . --parallel $nproc
cmake --install .

unlink $prefix/cuda/lib64
"""

# Build for all supported CUDA >= v11.6 (highest that builds)
platforms = expand_cxxstring_abis(CUDA.supported_platforms(min_version=v"11.6"))

# Cmake toolchain breaks on aarch64, so only x86_64 for now
filter!(p -> arch(p)=="x86_64", platforms)

# cuFINUFFT does not compile with CUDA 12.5, so exclude
filter!(p -> VersionNumber(p["cuda"]) != v"12.5", platforms)

# Build process fails (why??) when specifying minor versions of CUDA 13, so don't
for platform in platforms
    cuda_version = VersionNumber(platform["cuda"])
    if cuda_version.major==13
        platform["cuda"] = "13"
    end
end
unique!(platforms) # Remove duplicates if there were multiple 13.x

# The products that we will ensure are always built
products = [
    LibraryProduct("libcufinufft", :libcufinufft)
]

# Dependencies that must be installed before this package can be built
# NVTX_jll is needed for nvToolsExt. (tested with v3.1.0+2)
# CMake needs higher version than what is bundled
dependencies = [Dependency("NVTX_jll"),
                HostBuildDependency(PackageSpec(; name="CMake_jll", version = v"3.24.3"))]

for platform in platforms
    should_build_platform(triplet(platform)) || continue

    # Static SDK is used in CMake toolchain
    cuda_deps = CUDA.required_dependencies(platform; static_sdk=true)

    # Build for all major archs supported by SDK
    # See https://en.wikipedia.org/wiki/CUDA
    cuda_ver = VersionNumber(platform["cuda"])
    if cuda_ver >= v"13" # 13.0+
        # Skip 110,121 to not run out of space
        cuda_archs = "75;80;90;100;120"
    elseif cuda_ver >= v"12.1" # 12.1-12.9
        # sm_90 works for CUDA v12.1 and up, due to use of atomic operations
        cuda_archs = "60;70;80;90"
    elseif cuda_ver >= v"12.0" # 12.0
        # sm_52 required for alloca from CUDA v12.0 and up
        cuda_archs = "60;70;80"
    else # < 12.0
        cuda_archs = "50;60;70;80"
    end
    arch_line = "export CUDA_ARCHS=\"$cuda_archs\"\n"
    platform_script = arch_line * script

    build_tarballs(ARGS, name, version, sources, platform_script, [platform],
                   products, [dependencies; cuda_deps];
                   preferred_gcc_version=preferred_gcc_version,
                   julia_compat="1.6",
                   augment_platform_block=CUDA.augment,
                   lazy_artifacts=true
                   )
end
