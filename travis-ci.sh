#!/bin/bash

set -ex
BASEDIR=${PWD}

git clone git://github.com/jedisct1/libsodium.git
pushd libsodium
    git checkout 1.0.12
    ./autogen.sh
    ./configure --prefix=/usr
    make
    sudo make install
popd

git clone https://github.com/rweather/noise-c.git
pushd noise-c
    patch -p1 -i ${BASEDIR}/noise-c.patch
    ./autogen.sh
    ./configure --with-libsodium --prefix=/usr
    make
    sudo make install
popd

dub test -b unittest-cov --combined
dub test ":noise" -b unittest-cov --combined
rm src-noise.lst
chmod +x ./doveralls
./doveralls
