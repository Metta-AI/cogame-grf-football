# Metta post-training data

The native simulator and published `zonal` policy can export supervised
examples for both certified variants:

```sh
nimby sync nimby.lock
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/grf-match 10 1 match
nim r -d:release --path:src tools/export_posttrain.nim \
  /tmp/grf-half 10 1 half
```

Each run reads its exact manifest config and plays complete seeded, eight-seat
matches. The exporter records the hosted system prompt, each seat's match view,
and a `zonal` action accepted by the game's reply parser. Parsed actions drive
the simulator. Splits are by match seed. The manifest records source revision,
variant, goals, end reason, and row counts. Existing output directories are
never overwritten.

Train either output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/grf-match \
  --output /tmp/grf-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

The local 10-match export contained 1,536 training and 384 validation
examples; half contained 768 and 192. All 2,880 examples fit a 4096-token
model context. A one-step CPU optimizer smoke reduced held-out loss from
5.5581 to 5.4847 (match) and 5.5068 to 5.4427 (half). This distills the
scripted teacher; it does not establish stronger league play.
