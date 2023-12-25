#!/bin/bash

if [ -z "$1" ] || [ ! -d "$1" ]
then
    echo "Usage: $0 <project_path>"
    exit 1
fi

cache_dir="${PWD}/build_cache"
output_dir="$PWD"
if [ ! -d "$cache_dir" ]
then
    mkdir "$cache_dir" || exit 1
fi

function clean {
    rm -rf "$cache_dir"
    echo "Done"
}

trap clean SIGINT SIGTERM ERR EXIT

PROJ_PATH="$1"
cd "$PROJ_PATH" || exit 1
branch=$(git rev-parse --abbrev-ref HEAD) || exit 1

if [ "$branch" != "stable" ] && [ -z "$DEBUG" ]
then
    echo "Please checkout stable branch or set DEBUG=1"
    exit 1
fi

CONFIGURE_FLAGS="--enable-static --enable-pic --disable-cli"

function build_bin {
    target="$1"
    ARCH="-arch ${target%-*}"
    HOST="--host=${target%-*}-apple-darwin"
    ASFLAGS=""
    LDFLAGS=""

    dst_dir="${cache_dir}/${target}"
    if [ ! -d "$dst_dir" ]
    then
        mkdir "$dst_dir"
    fi

    CC="xcrun -sdk iphoneos clang"
    CFLAGS="-miphoneos-version-min=11.0"
    if [[ "$target" == "arm64-sim" ]] || [[ "$target" == "x86_64" ]]
    then
        CC="xcrun -sdk iphonesimulator clang"
        CFLAGS="-miphonesimulator-version-min=11.0" 
    fi

    if [[ "$target" =~ ^arm64.* ]]
    then
        export AS="./tools/gas-preprocessor.pl ${ARCH} -- ${CC}"
        ASFLAGS="$CFLAGS"
    else
        unset AS
    fi
    LDFLAGS="$CFLAGS"

    # shellcheck disable=SC2086
    CC="${CC}" ./configure $CONFIGURE_FLAGS \
        $HOST \
        --extra-cflags="$CFLAGS" \
        --extra-asflags="$ASFLAGS" \
        --extra-ldflags="$LDFLAGS" \
        --prefix="$dst_dir" || exit 1
    ncpu=$(sysctl -n hw.logicalcpu) || 8
    make install -j "$ncpu" || exit 1
    gen_header "$dst_dir" || exit 1
}

function gen_header {
    dst_dir="$1"

    # Just for Swift, x264.h depends on stdint.h
    packed_header="${dst_dir}/include/x264_mod.h"
    echo "#pragma once" > "$packed_header"
    echo "#include <stdint.h>" >> "$packed_header"
    echo "#include \"x264.h\"" >> "$packed_header"

    module_file="${dst_dir}/include/module.modulemap"
    echo "module X264 {" > "$module_file"
    # shellcheck disable=SC2129
    echo "  header \"x264_mod.h\"" >> "$module_file"
    echo "" >> "$module_file"
    echo "  export *" >> "$module_file"
    echo "}" >> "$module_file"
}

targets="arm64 arm64-sim x86_64"

for target in $targets
do
    build_bin "$target"
done

sim_dir="${cache_dir}/sim"
if [ ! -d "$sim_dir" ]
then
    mkdir "$sim_dir" || exit 1
fi
sim_lib_dir="${sim_dir}/lib"
if [ ! -d "$sim_lib_dir" ]
then
    mkdir "$sim_lib_dir" || exit 1
fi

lipo_args=""
for target in ${targets#* }
do
    lipo_args="${lipo_args} ${cache_dir}/${target}/lib/libx264.a"
done

cp -a "${cache_dir}/arm64-sim/include" "${sim_dir}/include" || exit 1
# shellcheck disable=SC2086
lipo -create $lipo_args -output "${sim_lib_dir}/libx264.a" || exit 1

cf_args=""
dirs="arm64 sim"
for dir in $dirs
do
    cf_args="${cf_args} -library ${cache_dir}/${dir}/lib/libx264.a -headers ${cache_dir}/${dir}/include"
done

# shellcheck disable=SC2086
xcodebuild -create-xcframework $cf_args -output "${output_dir}/X264.xcframework" || exit 1