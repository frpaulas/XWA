#!/usr/bin/env bash
# Install NLI service dependencies and pre-download the model.
# Run once from the project root or from this directory.
set -e

echo "==> Installing PyTorch (CUDA 11.8)..."
pip install torch --index-url https://download.pytorch.org/whl/cu118 --user

echo "==> Installing Python deps..."
pip install -r "$(dirname "$0")/requirements.txt" --user

echo "==> Pre-downloading NLI model (cross-encoder/nli-deberta-v3-small)..."
python3 -c "
from sentence_transformers import CrossEncoder
CrossEncoder('cross-encoder/nli-deberta-v3-small')
print('Model ready.')
"

echo "==> Done. Install the systemd service with:"
echo "    cp priv/nli_service/nli-gate.service ~/.config/systemd/user/"
echo "    systemctl --user daemon-reload"
echo "    systemctl --user enable --now nli-gate.service"
