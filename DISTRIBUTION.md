# Distribution and rebuilding

Mandel's own code is MIT licensed; see LICENSE. NanoUI is MIT licensed with additional notices in vendor/nanoui/THIRD_PARTY_NOTICES.md. The app bundle contains these notices and license texts under Contents/Resources/Licenses.

The application statically links unmodified GMP 6.3.0 and MPFR 4.2.2 under LGPLv3. The same GitHub Release provides Mandel-source.tar.gz, containing the corresponding application source, build scripts, and the complete upstream library source archives in dependencies/. The library archives include their copyright notices and licenses. You may modify these libraries and rebuild/relink Mandel; reverse engineering for debugging such modifications is permitted. No signing keys or activation credentials are required to run your rebuilt, ad-hoc-signed app.

## Build the release sources

On an Apple Silicon Mac with Xcode Command Line Tools installed, extract Mandel-source.tar.gz, enter Mandel/, then run:

```sh
./tools/bootstrap.sh
./tools/package.sh
```

The pinned compiler is downloaded and verified by SHA-256. The bootstrap also downloads and verifies library sources; identical copies are provided in dependencies/ so you can inspect and modify them.

## Relink with modified libraries

After bootstrap, extract the provided archives into a temporary path without spaces, for example /tmp/mandel-libraries. Make your changes in the extracted sources. Build GMP first and then MPFR, using a shared installation prefix:

```sh
# Run within your modified gmp-6.3.0 source directory:
./configure --prefix=/tmp/mandel-libraries/native --disable-shared --enable-static
make -j4
make install

# Run within your modified mpfr-4.2.2 source directory:
./configure --prefix=/tmp/mandel-libraries/native --with-gmp=/tmp/mandel-libraries/native --disable-shared --enable-static
make -j4
make install

# Run from the Mandel source directory:
cp /tmp/mandel-libraries/native/lib/libgmp.a /tmp/mandel-libraries/native/lib/libmpfr.a .tools/native/lib/
cp /tmp/mandel-libraries/native/include/gmp.h /tmp/mandel-libraries/native/include/mpfr.h .tools/native/include/
./tools/package.sh
```

The resulting app is zig-out/Mandel.app. The packaging script applies a new ad-hoc signature. Modified binaries will naturally not match the original GitHub attestation.
