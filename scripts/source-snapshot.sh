# Copy an explicit source list without flattening its architecture directories.
yullo_snapshot_sources() {
  local destination="$1"
  shift
  local source
  for source in "$@"; do
    mkdir -p "$destination/$(dirname "$source")"
    cp "$source" "$destination/$source"
    if [ "$source" = "App/Services/KeyStore.swift" ]; then
      cp App/Services/KeychainInteraction.h "$destination/App/Services/KeychainInteraction.h"
    fi
  done
}
