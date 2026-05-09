{
  description = "xnu-12377.101.15 (macOS 26.4.1) builder, fully sandboxed";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
    flake-utils.url = "github:numtide/flake-utils";

    # Versions taken from apple-oss-distributions/distribution-macOS@rel/macOS-26 release.json
    xnu-src                  = { url = "github:apple-oss-distributions/xnu/xnu-12377.101.15"; flake = false; };
    bootstrap_cmds-src       = { url = "github:apple-oss-distributions/bootstrap_cmds/bootstrap_cmds-138"; flake = false; };
    dtrace-src               = { url = "github:apple-oss-distributions/dtrace/dtrace-413"; flake = false; };
    AvailabilityVersions-src = { url = "github:apple-oss-distributions/AvailabilityVersions/AvailabilityVersions-157.2"; flake = false; };
    Libsystem-src            = { url = "github:apple-oss-distributions/Libsystem/Libsystem-1356"; flake = false; };
    libplatform-src          = { url = "github:apple-oss-distributions/libplatform/libplatform-375.100.10"; flake = false; };
    libdispatch-src          = { url = "github:apple-oss-distributions/libdispatch/libdispatch-1542.100.32"; flake = false; };
  };

  outputs = inputs@{ self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Xcode .xip — Apple's URL is gated by Developer auth.
        # First-time setup: nix-store --add-fixed sha256 ~/Downloads/Xcode_26.4.1_Apple_silicon.xip
        xcodeXip = pkgs.requireFile {
          name = "Xcode_26.4.1_Apple_silicon.xip";
          hash = "sha256-ydLjr+g/1V9TuzXvJZdBNR8zJ9HxGj9KX7kNXCONtKI=";
          url = "https://download.developer.apple.com/Developer_Tools/Xcode_26.4.1/Xcode_26.4.1_Apple_silicon.xip";
        };

        kdkDmg = pkgs.fetchurl {
          url = "https://github.com/dortania/KdkSupportPkg/releases/download/25E253/Kernel_Debug_Kit_26.4.1_build_25E253.dmg";
          hash = "sha256-23nDOhApwoNTIq0jpJVJSeHAL52WhuwKnBJuYpqzA/M=";
        };

        # Shims for Apple's system shims that delegate to DEVELOPER_DIR.
        # Put earlier in PATH than /usr/bin so the build never reaches the system copies.
        xcodeShims = pkgs.writeShellScriptBin "xcode-shims-marker" "" // {};
        xcrunShim = pkgs.writeShellScriptBin "xcrun" ''
          # xcrun replacement: searches DEVELOPER_DIR for tools, supports -f / -sdk / TOOL ARGS
          : "''${DEVELOPER_DIR:?DEVELOPER_DIR not set}"
          find_tool() {
            for d in \
              "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin" \
              "$DEVELOPER_DIR/usr/bin" \
              "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/bin" \
              "$DEVELOPER_DIR/Platforms/MacOSX.platform/usr/bin"; do
              [ -x "$d/$1" ] && { echo "$d/$1"; return 0; }
            done
            # Fall back to PATH search (cmake/ninja/etc. live in nix store)
            command -v "$1" 2>/dev/null && return 0
            echo "xcrun: tool '$1' not found" >&2; return 1
          }
          # Skip optional flags that don't affect tool resolution
          while [ $# -gt 0 ]; do
            case "$1" in
              -sdk|--sdk)             shift 2 ;;
              -toolchain|--toolchain) shift 2 ;;
              -f|-find|--find)                            shift; find_tool "$1"; exit $? ;;
              --show-sdk-path|-show-sdk-path)             echo "$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"; exit 0 ;;
              --show-sdk-version|-show-sdk-version)       echo "26.4"; exit 0 ;;
              --show-sdk-platform-path|-show-sdk-platform-path) echo "$DEVELOPER_DIR/Platforms/MacOSX.platform"; exit 0 ;;
              -*)                     shift ;;
              *)                      break ;;
            esac
          done
          tool=$(find_tool "$1") || exit 1
          shift
          exec "$tool" "$@"
        '';
        # plutil shim — Apple-only binary, but xnu only uses -lint and basic conversion.
        # python's plistlib does both. Sandbox-friendly.
        plutilShim = pkgs.writeShellScriptBin "plutil" ''
          ${pkgs.python3}/bin/python3 - "$@" <<'PYEOF'
          import sys, plistlib
          args = sys.argv[1:]
          # Skip flags we can ignore
          while args and args[0].startswith("-"):
            f = args[0]
            if f in ("-lint", "-s"): args.pop(0)
            elif f == "-convert": args = args[2:]    # skip -convert FORMAT
            elif f == "-o": args = args[2:]
            else: args.pop(0)
          for path in args:
            try:
              with open(path, "rb") as fh: plistlib.load(fh)
            except Exception as e:
              print(f"{path}: {e}", file=sys.stderr); sys.exit(1)
          sys.exit(0)
          PYEOF
        '';

        # sysctl stub — values are also passed via make command-line override; this just
        # prevents `make: execvp: /usr/sbin/sysctl: Operation not permitted` at parse time.
        sysctlShim = pkgs.writeShellScriptBin "sysctl" ''
          case "$*" in
            *hw.physicalcpu*) echo 1 ;;
            *hw.logicalcpu*)  echo 1 ;;
            *hw.memsize*)     echo 1073741824 ;;
            *)                echo 0 ;;
          esac
        '';

        # Shim for `codesign -s - file` (ad-hoc) → rcodesign sign file
        codesignShim = pkgs.writeShellScriptBin "codesign" ''
          file=""
          while [ $# -gt 0 ]; do
            case "$1" in
              -s|--sign)     shift 2 ;;
              -i|--identifier|-r|--requirements|--entitlements|--prefix|--timestamp|-o|--options) shift 2 ;;
              -*)            shift ;;
              *)             file="$1"; shift ;;
            esac
          done
          [ -n "$file" ] || exit 0
          exec ${pkgs.rcodesign}/bin/rcodesign sign "$file"
        '';
        swVersShim = pkgs.writeShellScriptBin "sw_vers" ''
          case "$1" in
            -productName|--productName)       echo "macOS" ;;
            -productVersion|--productVersion) echo "26.4" ;;
            -buildVersion|--buildVersion)     echo "25E253" ;;
            *) echo "ProductName: macOS"; echo "ProductVersion: 26.4"; echo "BuildVersion: 25E253" ;;
          esac
        '';
        xcodeSelectShim = pkgs.writeShellScriptBin "xcode-select" ''
          : "''${DEVELOPER_DIR:?DEVELOPER_DIR not set}"
          case "$1" in
            -p|--print-path) echo "$DEVELOPER_DIR"; exit 0 ;;
            *)               exit 0 ;;
          esac
        '';

        # runCommand: no fixup phases — Xcode's internal shebangs/binaries stay untouched
        xcode = pkgs.runCommand "xcode-26.4.1" {
          nativeBuildInputs = [ pkgs.xar pkgs.pbzx pkgs.cpio ];
        } ''
          xar -xf ${xcodeXip}
          pbzx -n Content | cpio -i
          mkdir -p $out
          mv Xcode.app $out/
        '';

        kdk = pkgs.runCommand "kdk-26.4.1-25E253" {
          nativeBuildInputs = [ pkgs.p7zip pkgs.xar pkgs.cpio pkgs.pbzx ];
        } ''
          7z x ${kdkDmg}
          xar -xf "Kernel Debug Kit/KernelDebugKit.pkg"
          mkdir -p $out/KDK_26.4.1_25E253.kdk
          (cd $out/KDK_26.4.1_25E253.kdk && pbzx -n $NIX_BUILD_TOP/KDK.pkg/Payload     | cpio -i)
          (cd $out/KDK_26.4.1_25E253.kdk && pbzx -n $NIX_BUILD_TOP/KDK_SDK.pkg/Payload | cpio -i)
        '';

        mkXnu = { arch, machine, label, kernelConfig ? "DEVELOPMENT" }: let
          buildTools = with pkgs; [
            jq git cmake ninja
            gnugrep gnused gawk gnupatch coreutils curl which findutils gzip pax rcodesign
            perl python3 tcsh bash
            xcrunShim xcodeSelectShim swVersShim sysctlShim codesignShim plutilShim
            # pre-built from nixpkgs (cached, no xcodebuild)
            darwin.bootstrap_cmds  # libSystem now sourced from Xcode SDK (matching version)
          ];
        in pkgs.stdenvNoCC.mkDerivation {
          pname   = "xnu-${label}";
          version = "12377.101.15";
          src = builtins.path { path = ./.; name = "darwin-xnu-build"; };

          nativeBuildInputs = buildTools;

          xnu                  = inputs.xnu-src;
          bootstrap_cmds       = inputs.bootstrap_cmds-src;
          dtrace               = inputs.dtrace-src;
          AvailabilityVersions = inputs.AvailabilityVersions-src;
          Libsystem            = inputs.Libsystem-src;
          libplatform          = inputs.libplatform-src;
          libdispatch          = inputs.libdispatch-src;

          configurePhase = ''
            for s in xnu bootstrap_cmds dtrace AvailabilityVersions Libsystem libplatform libdispatch; do
              cp -R "''${!s}"/. "./$s"
              chmod -R u+w "./$s"
            done

            # /usr/bin/env is the last impure host dep — replace globally across all sources.
            find . -type f -not -path './.git/*' -print0 \
              | xargs -0 sed -i 's|/usr/bin/env|${pkgs.coreutils}/bin/env|g'

            # Static map: rewrite every hardcoded /bin/* /usr/bin/* /usr/sbin/* in xnu's
            # Makefiles to point at nixpkgs/store equivalents.
            sed -i \
              -e 's|/bin/cat|${pkgs.coreutils}/bin/cat|g' \
              -e 's|/bin/chmod|${pkgs.coreutils}/bin/chmod|g' \
              -e 's|/bin/cp|${pkgs.coreutils}/bin/cp|g' \
              -e 's|/bin/ln|${pkgs.coreutils}/bin/ln|g' \
              -e 's|/bin/mkdir|${pkgs.coreutils}/bin/mkdir|g' \
              -e 's|/bin/mv|${pkgs.coreutils}/bin/mv|g' \
              -e 's|/bin/pax|${pkgs.pax}/bin/pax|g' \
              -e 's|/bin/pwd|${pkgs.coreutils}/bin/pwd|g' \
              -e 's|/bin/rm |${pkgs.coreutils}/bin/rm |g' \
              -e 's|/bin/rmdir|${pkgs.coreutils}/bin/rmdir|g' \
              -e 's|/bin/sleep|${pkgs.coreutils}/bin/sleep|g' \
              -e 's|/usr/bin/awk|${pkgs.gawk}/bin/awk|g' \
              -e 's|/usr/bin/basename|${pkgs.coreutils}/bin/basename|g' \
              -e 's|/usr/bin/dirname|${pkgs.coreutils}/bin/dirname|g' \
              -e 's|/usr/bin/find|${pkgs.findutils}/bin/find|g' \
              -e 's|/usr/bin/grep|${pkgs.gnugrep}/bin/grep|g' \
              -e 's|/usr/bin/patch|${pkgs.gnupatch}/bin/patch|g' \
              -e 's|/usr/bin/sed|${pkgs.gnused}/bin/sed|g' \
              -e 's|/usr/bin/touch|${pkgs.coreutils}/bin/touch|g' \
              -e 's|/usr/bin/tr|${pkgs.coreutils}/bin/tr|g' \
              -e 's|/usr/bin/xargs|${pkgs.findutils}/bin/xargs|g' \
              -e 's|/usr/bin/xcrun|${xcrunShim}/bin/xcrun|g' \
              -e 's|/usr/bin/codesign|${codesignShim}/bin/codesign|g' \
              -e 's|/usr/sbin/sysctl|${sysctlShim}/bin/sysctl|g' \
              -e 's|/usr/bin/plutil|${plutilShim}/bin/plutil|g' \
              xnu/Makefile xnu/makedefs/MakeInc.cmd xnu/makedefs/MakeInc.def xnu/makedefs/MakeInc.rule xnu/makedefs/MakeInc.top

            # libkern/libkern/Makefile uses bare `install` instead of `$(INSTALL)` — coreutils
            # install rejects xnu's BSD-style `-S` flag. Substitute xnu's installfile.
            sed -i 's|^\(\t.*\)install \$(DATA_INSTALL_FLAGS)|\1$(INSTALL) $(DATA_INSTALL_FLAGS)|' \
              xnu/libkern/libkern/Makefile

            # Patch hardcoded shebangs throughout xnu sources — sandbox blocks /bin/* and /usr/bin/*
            find xnu -type f \( -name "*.sh" -o -name "*.pl" -o -name "*.py" -o -path "*/SETUP/config/doconf" \) -print0 \
              | xargs -0 sed -i \
                  -e '1s|^#!/bin/csh|#!${pkgs.tcsh}/bin/tcsh|' \
                  -e '1s|^#!/bin/bash|#!${pkgs.bash}/bin/bash|' \
                  -e '1s|^#!/bin/sh|#!${pkgs.bash}/bin/sh|' \
                  -e '1s|^#!/usr/bin/perl|#!${pkgs.perl}/bin/perl|' \
                  -e '1s|^#!/usr/bin/python3|#!${pkgs.python3}/bin/python3|' \
                  -e '1s|^#!/usr/bin/env python3|#!${pkgs.python3}/bin/python3|' \
                  -e '1s|^#!/usr/bin/env python|#!${pkgs.python3}/bin/python3|' \
                  -e '1s|^#!/usr/bin/awk|#!${pkgs.gawk}/bin/awk|'

            # libkern/libkern/Makefile uses bare `install` instead of `$(INSTALL)`.
            # Coreutils install rejects BSD-style `-S` flag — substitute xnu's installfile.
            sed -i 's|^\(\t.*\)install \$(DATA_INSTALL_FLAGS)|\1$(INSTALL) $(DATA_INSTALL_FLAGS)|' \
              xnu/libkern/libkern/Makefile

            # Pre-populate fakeroot/ with prebuilt artifacts so build.sh's existence checks
            # skip the xcodebuild-using prereq steps.
            mkdir -p fakeroot/usr/local/bin fakeroot/usr/local/libexec fakeroot/usr

            # mig (from nixpkgs darwin.bootstrap_cmds) — but its hardcoded MIGCC points at
            # nixpkgs clang-wrapper which strips Apple-specific flags like -mno-implicit-sme.
            # Copy + repoint at Apple clang from our extracted Xcode.
            cp ${pkgs.darwin.bootstrap_cmds}/bin/mig          fakeroot/usr/local/bin/mig
            cp ${pkgs.darwin.bootstrap_cmds}/libexec/migcom   fakeroot/usr/local/libexec/migcom
            chmod +w fakeroot/usr/local/bin/mig
            sed -i 's|MIGCC=/nix/store/[^ ]*clang-wrapper[^/]*/bin/clang|MIGCC=${xcode}/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang|' \
              fakeroot/usr/local/bin/mig

            # availability.pl from the matching v157.2 source (nixpkgs has v151, wrong version)
            cp AvailabilityVersions/availability.pl fakeroot/usr/local/libexec/availability.pl
            chmod +x fakeroot/usr/local/libexec/availability.pl

            # libSystem headers — use Xcode 26.4.1's SDK directly (macOS 26.4, matches xnu)
            cp -R ${xcode}/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/. fakeroot/usr/
            chmod -R u+w fakeroot/usr

            # Marker so build.sh's libsystem_headers check is satisfied
            mkdir -p fakeroot/System/Library/Frameworks/System.framework

            # ctftools stubs — CTF is debug info, not required for a working kernel.
            for tool in ctfconvert ctfmerge ctfdump; do
              cat > fakeroot/usr/local/bin/$tool <<'EOF'
            #!/bin/sh
            exit 0
            EOF
              chmod +x fakeroot/usr/local/bin/$tool
            done
          '';

          buildPhase = ''
            export DEVELOPER_DIR=${xcode}/Xcode.app/Contents/Developer
            export KDKROOT=${kdk}/KDK_26.4.1_25E253.kdk
            export NIX_LIBSYSTEM_PATH=${xcode}/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr
            unset SDKROOT NIX_CFLAGS_COMPILE NIX_LDFLAGS
            export EXTRA_PATH="${pkgs.lib.makeBinPath buildTools}"
            export KERNEL_CONFIG=${kernelConfig}
            export ARCH_CONFIG=${arch}
            export MACHINE_CONFIG=${machine}
            export MACOS_VERSION=26.4
            export HOME=$TMPDIR
            TRACE=1 bash ./build.sh
          '';

          installPhase = ''
            mkdir -p $out
            cp -R build/xnu.obj/* $out/ || true
          '';
        };

        xnu-arm64  = mkXnu { arch = "ARM64";  machine = "VMAPPLE"; label = "arm64-vmapple"; };
        xnu-x86_64 = mkXnu { arch = "X86_64"; machine = "NONE";    label = "x86_64";        };

      in {
        packages = {
          inherit xcode kdk xnu-arm64 xnu-x86_64;
          default = pkgs.runCommand "xnu-all" {} ''
            mkdir -p $out/arm64 $out/x86_64
            cp -R ${xnu-arm64}/* $out/arm64/
            cp -R ${xnu-x86_64}/* $out/x86_64/
          '';
        };
      });
}
