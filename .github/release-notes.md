Native Mandelbrot explorer for Apple Silicon, built with Zig, NanoUI and Metal.

Download **Mandel-macos-arm64.zip**, extract it, and move Mandel.app to Applications. Built on macOS 15 for arm64.

The app is ad-hoc signed, **not Apple Developer ID signed or notarized**. GitHub's provenance attestation does not bypass Gatekeeper. After verifying the download, macOS may require **System Settings → Privacy & Security → Open Anyway**.

Verify the exact downloaded ZIP with GitHub CLI:

```sh
gh attestation verify Mandel-macos-arm64.zip --repo valland/Mandel
```

`Mandel-source.tar.gz` contains the corresponding application source plus GMP 6.3.0 and MPFR 4.2.2 sources. See `DISTRIBUTION.md` for licenses and rebuilding with modified libraries. Both archives are attested; `SHA256SUMS` supplies checksums for convenience.

CI runs CPU numerics and persistence tests and compiles the full Metal/UI test suite. GPU/UI execution is validated separately on a physical Mac; it is not claimed as part of the hosted CI test results.
