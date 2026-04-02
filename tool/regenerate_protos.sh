#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="$ROOT_DIR/proto"
OUT_DIR="$ROOT_DIR/lib/hoosat/grpc"

if ! command -v protoc >/dev/null 2>&1; then
  echo "error: protoc not found in PATH" >&2
  exit 1
fi

PROTOC_GEN_DART="${PROTOC_GEN_DART:-$HOME/.pub-cache/bin/protoc-gen-dart}"
if [[ ! -x "$PROTOC_GEN_DART" ]]; then
  echo "error: protoc-gen-dart not found (expected at $PROTOC_GEN_DART)" >&2
  echo "hint: run: dart pub global activate protoc_plugin 20.0.1" >&2
  exit 1
fi

if [[ ! -d "$PROTO_DIR" ]]; then
  echo "error: proto directory not found: $PROTO_DIR" >&2
  exit 1
fi

mapfile -t PROTO_FILES < <(find "$PROTO_DIR" -maxdepth 1 -type f -name '*.proto' -print | sort)
if [[ ${#PROTO_FILES[@]} -eq 0 ]]; then
  echo "error: no .proto files found in $PROTO_DIR" >&2
  exit 1
fi

missing=0
while IFS= read -r -d '' file; do
  while IFS= read -r imp; do
    # We only support imports relative to the proto root directory.
    if [[ ! -f "$PROTO_DIR/$imp" ]]; then
      echo "error: missing import '$imp' (referenced by $(basename "$file"))" >&2
      missing=1
    fi
  done < <(sed -nE 's/^import\s+"([^"]+)"\s*;\s*$/\1/p' "$file" | tr -d '\r')

done < <(find "$PROTO_DIR" -maxdepth 1 -type f -name '*.proto' -print0)

if [[ $missing -ne 0 ]]; then
  echo "\nFix: add the missing .proto files into $PROTO_DIR (keeping import paths the same), then re-run." >&2
  exit 2
fi

mkdir -p "$OUT_DIR"

# Regenerate Dart + gRPC stubs.
protoc \
  --plugin=protoc-gen-dart="$PROTOC_GEN_DART" \
  -I"$PROTO_DIR" \
  --dart_out=grpc:"$OUT_DIR" \
  "${PROTO_FILES[@]}"

# This app only uses the gRPC client; server stubs are unused and some versions
# of the Dart protoc plugin generate pbserver files with missing JSON symbols.
rm -f "$OUT_DIR"/*.pbserver.dart

echo "ok: generated Dart protos into $OUT_DIR"