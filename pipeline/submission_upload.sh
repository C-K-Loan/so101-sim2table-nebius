#!/bin/bash
# Package + upload submission bundle to Nebius Object Storage.
# Target: s3://ckl-solo-hackathon/<timestamp>/
#
# DO NOT RUN YET. Needs: (1) hackathon tenant active, (2) bucket created,
# (3) S3-compatible access key + secret from `nebius storage access-key create`.
#
# Usage after prereqs:
#   ./submission_upload.sh [bundle_name]
set -euo pipefail

BUNDLE_NAME="${1:-sim-to-table-$(date +%Y%m%d-%H%M%S)}"
BUCKET="${BUCKET:-ckl-solo-hackathon}"
REGION="${REGION:-eu-north1}"
ENDPOINT="https://storage.${REGION}.nebius.cloud"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGING="$PROJECT_DIR/_submission/$BUNDLE_NAME"
TARBALL="$PROJECT_DIR/_submission/$BUNDLE_NAME.tar.gz"

echo "=== staging $BUNDLE_NAME ==="
rm -rf "$STAGING" && mkdir -p "$STAGING"

# Required artifacts per challenge rules
for required in dataset_manifest.json SUBMISSION_README_TEMPLATE.md; do
  if [[ ! -f "$PROJECT_DIR/$required" ]]; then
    echo "ERROR: missing required artifact $required" >&2
    exit 1
  fi
done

cp "$PROJECT_DIR/dataset_manifest.json" "$STAGING/dataset_manifest.json" 2>/dev/null || \
  cp "$PROJECT_DIR/dataset_manifest_template.json" "$STAGING/dataset_manifest.json"
cp "$PROJECT_DIR/SUBMISSION_README_TEMPLATE.md" "$STAGING/README.md"

# Cosmos artifacts (challenge rule: Reason JSON mandatory for 10 pts)
[[ -f "$PROJECT_DIR/cosmos_reason_scores.json" ]] && cp "$PROJECT_DIR/cosmos_reason_scores.json" "$STAGING/" || echo "WARN: no cosmos_reason_scores.json yet"
[[ -d "$PROJECT_DIR/dummy_dataset.cosmos/transfer_manifest.json" ]] || [[ -f "$PROJECT_DIR/transfer_manifest.json" ]] && cp "$PROJECT_DIR"/transfer_manifest*.json "$STAGING/" 2>/dev/null || true

# Checkpoints (main + ablation per challenge rule, needs both)
if [[ -d "$PROJECT_DIR/checkpoints" ]]; then
  cp -r "$PROJECT_DIR/checkpoints" "$STAGING/checkpoints"
else
  echo "WARN: no checkpoints dir yet (will skip, re-run after training)"
fi

# Videos (eval runs + real arm trial)
if [[ -d "$PROJECT_DIR/eval_videos" ]]; then
  cp -r "$PROJECT_DIR/eval_videos" "$STAGING/videos"
else
  mkdir -p "$STAGING/videos" && echo "placeholder" > "$STAGING/videos/.empty"
fi

echo ""
echo "=== staging contents ==="
find "$STAGING" -type f | head -30
echo ""

echo "=== tarring ==="
tar -czf "$TARBALL" -C "$PROJECT_DIR/_submission" "$BUNDLE_NAME"
echo "tarball: $TARBALL ($(du -h "$TARBALL" | cut -f1))"

# TODO(bucket): if bucket does not exist, create it:
#   nebius storage bucket create --name "$BUCKET" --max-size-bytes 10737418240 --versioning-policy ENABLED
# Then create an access key pair:
#   nebius storage access-key create --name hackathon-upload --scope read_write
# Export the returned keypair as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.

if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]] || [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  echo ""
  echo "SKIPPING upload: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY not set."
  echo "To upload, run:"
  echo "  nebius storage access-key create --name hackathon-upload --scope read_write"
  echo "  export AWS_ACCESS_KEY_ID=<returned-id>"
  echo "  export AWS_SECRET_ACCESS_KEY=<returned-secret>"
  echo "  AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... $0 $BUNDLE_NAME"
  exit 0
fi

echo ""
echo "=== uploading to s3://$BUCKET/$BUNDLE_NAME/ at $ENDPOINT ==="
command -v aws >/dev/null || { echo "install awscli: pip install awscli" >&2; exit 2; }

# Upload tarball
aws s3 cp "$TARBALL" "s3://$BUCKET/$BUNDLE_NAME.tar.gz" \
  --endpoint-url "$ENDPOINT"

# Also upload unpacked tree for direct browsing (judges may want this)
aws s3 sync "$STAGING/" "s3://$BUCKET/$BUNDLE_NAME/" \
  --endpoint-url "$ENDPOINT"

echo ""
echo "=== DONE ==="
echo "Submission URL: $ENDPOINT/$BUCKET/$BUNDLE_NAME.tar.gz"
echo "Browse:         $ENDPOINT/$BUCKET/$BUNDLE_NAME/"
