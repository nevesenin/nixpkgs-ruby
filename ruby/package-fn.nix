{ version
, versionSource
, libDir ? "${(import ./parse-version.nix version).majMin}.0"
, rubygems ? null
, stdenv
, buildPackages
, lib
, fetchurl
, fetchpatch
, fetchFromSavannah
, fetchFromGitHub
, zlib
, openssl
, gdbm
, ncurses
, readline
, groff
, libyaml
, libffi
, bison
, autoconf
, darwin ? null
, buildEnv
, bundler
, bundix
, useRailsExpress ? true
, zlibSupport ? true
, opensslSupport ? true
, gdbmSupport ? true
, cursesSupport ? true
, docSupport ? false
, yamlSupport ? true
, fiddleSupport ? true
, yjitSupport ? true
, rustc
, removeReferencesTo
}:
let
  op = lib.optional;
  ops = lib.optionals;
  opString = lib.optionalString;
  config = import ./config.nix { inherit fetchFromSavannah; };
  railsExpressPatches =
    if useRailsExpress
    then
      (import ./railsexpress.nix {
        inherit fetchFromGitHub lib version;
      })
    else [ ];

  useBaseRuby = (stdenv.buildPlatform != stdenv.hostPlatform) || useRailsExpress;

  # Needed during postInstall
  buildRuby =
    if useBaseRuby
    then
      buildPackages."ruby-${version}".override
        {
          useRailsExpress = false;
          docSupport = false;
          rubygems = null;
        }
    else self;

  self =
    stdenv.mkDerivation {
      pname = "ruby";
      inherit version;

      patches = railsExpressPatches;

      src = fetchurl versionSource;

      # Have `configure' avoid `/usr/bin/nroff' in non-chroot builds.
      NROFF =
        if docSupport
        then "${groff}/bin/nroff"
        else null;

      nativeBuildInputs =
        [ bison ]
        ++ ops useBaseRuby [ buildRuby removeReferencesTo ];
      buildInputs =
        (op fiddleSupport libffi)
        ++ (ops cursesSupport [ ncurses readline ])
        ++ (op docSupport groff)
        ++ (op zlibSupport zlib)
        ++ (op opensslSupport openssl)
        ++ (op gdbmSupport gdbm)
        ++ (op yamlSupport libyaml)
        ++ (op yjitSupport rustc)
        # Looks like ruby fails to build on darwin without readline even if curses
        # support is not enabled, so add readline to the build inputs if curses
        # support is disabled (if it's enabled, we already have it) and we're
        # running on darwin
        ++ (op (!cursesSupport && stdenv.isDarwin) readline)
        ++ (op stdenv.isDarwin darwin.apple_sdk.frameworks.Foundation)
        ++ (ops stdenv.isDarwin
          (with darwin; [ libiconv libobjc libunwind ]));

      enableParallelBuilding = true;

      postPatch = ''
        ${opString (rubygems != null) ''
          cp -rL --no-preserve=mode,ownership ${rubygems} ./rubygems
        ''}

        sed -i 's/\(:env_shebang *=> *\)false/\1true/' lib/rubygems/dependency_installer.rb
        sed -i 's/\(@home *=.* || \)Gem.default_dir/\1Gem.user_dir/' lib/rubygems/path_support.rb

        if [ -f configure.ac ]
        then
          sed -i configure.ac -e '/config.guess/d'
          cp ${config}/config.guess tool/
          cp ${config}/config.sub tool/
        fi
      '';

      preConfigure = ''
        sed -i configure -e 's/;; #(/\n;;/g'
      '';

      configureFlags =
        [ "--enable-shared" "--enable-pthread" ]
        ++ op (!docSupport) "--disable-install-doc"
        ++ ops stdenv.isDarwin [
          # on darwin, we have /usr/include/tk.h -- so the configure script detects
          # that tk is installed
          "--with-out-ext=tk"
          # on yosemite, "generating encdb.h" will hang for a very long time without this flag
          "--with-setjmp-type=setjmp"
        ]
        ++ op useBaseRuby "--with-baseruby=${buildRuby}/bin/ruby";

      preInstall = ''
        # Ruby installs gems here itself now.
        mkdir -pv "$out/${self.passthru.gemPath}"
        export GEM_HOME="$out/${self.passthru.gemPath}"
      '';

      installFlags = lib.optionalString docSupport "install-doc";

      postInstall = ''
        rbConfig=$out/lib/ruby/*/*/rbconfig.rb
        # Remove references to the build environment from the closure
        sed -i '/^  CONFIG\["\(BASERUBY\|SHELL\|GREP\|EGREP\|MKDIR_P\|MAKEDIRS\|INSTALL\)"\]/d' $rbConfig
        # Remove unnecessary groff reference from runtime closure, since it's big
        sed -i '/NROFF/d' $rbConfig

        ${opString (rubygems != null) ''
          # Update rubygems
          pushd rubygems
          ${buildRuby}/bin/ruby setup.rb
          popd
        ''}

        # Bundler tries to create this directory
        mkdir -p $out/nix-support
        cat > $out/nix-support/setup-hook <<EOF
        addGemPath() {
          addToSearchPath GEM_PATH \$1/${self.passthru.gemPath}
        }

        addEnvHooks "$hostOffset" addGemPath
        EOF
      '';

      preFixup = ''
          ${opString ((with import ../lib/version-comparison.nix version; greaterOrEqualTo "3.1.3") && useBaseRuby) ''
          echo "Removing references to base ruby:"
          # Build fails otherwise with "forbidden reference" error during postFixup phase.

          for so in $out/lib/ruby/*/*/enc/*.so $out/lib/ruby/*/*/enc/trans/*.so; do
            echo "patching $so"
            echo "  set RPATH to $out:${buildPackages.glibc}/lib"
            patchelf --set-rpath "$out:${buildPackages.glibc}/lib" $so
          done
        ''}
      '';

      meta = with lib; {
        description = "An object-oriented language for quick and easy programming";
        homepage = "http://www.ruby-lang.org/";
        license = licenses.ruby;
        maintainers = with maintainers; [ bobvanderlinden ];
        platforms = platforms.all;
      };

      passthru = {
        version = {
          inherit libDir;
        } // (import ./parse-version.nix version);
        rubyEngine = "ruby";
        libPath = "lib/${self.passthru.rubyEngine}/${libDir}";
        gemPath = "lib/${self.passthru.rubyEngine}/gems/${libDir}";
        devEnv = import ./dev.nix {
          inherit buildEnv bundler bundix;
          ruby = self;
        };
      };
    };
in
self
