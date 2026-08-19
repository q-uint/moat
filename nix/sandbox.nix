{ pkgs, wrapper }:

{
  wrap = { name, paths }:
    pkgs.runCommand "moat-${name}" { inherit paths; } ''
      mkdir -p $out/bin $out/share/moat
      # Always present: a wrapper with no manifest fails with "cannot read
      # manifest" instead of the accurate "not in manifest".
      touch $out/share/moat/manifest

      for p in $paths; do
        for exe in $(find "$p" -maxdepth 1 -type f -perm -111 2>/dev/null); do
          exe_name=$(basename "$exe")
          # First path wins, matching lookupManifest's first-line-wins. Without
          # this the manifest keeps both while ln -sf keeps one.
          if grep -q "^$exe_name	" $out/share/moat/manifest; then
            continue
          fi
          printf '%s\t%s\n' "$exe_name" "$exe" >> $out/share/moat/manifest
          ln -s ${wrapper}/bin/moat-wrapper $out/bin/$exe_name
        done
      done
    '';
}
