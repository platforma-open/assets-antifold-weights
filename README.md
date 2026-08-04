# assets-antifold-weights

The AntiFold inverse-folding model checkpoint, distributed as a Platforma asset. Consumed by the
`antibody-variant-designer` block, and by nothing else.

AntiFold downloads a 540.6 MiB checkpoint from `opig.stats.ox.ac.uk` the first time it loads a model,
and its `--model_path` flag does not redirect where it looks. A sealed run has no network, so that
download must never fire. This repo removes it: the checkpoint is fetched once at package-build time,
published as an asset, and mounted into the exec workdir.

## The contract with the Variant Designer

These are requirements, not examples. The Variant Designer's design script calls
`load_IF1_checkpoint(model, "models/model.pt")`, so:

| The asset | The consumer |
| --------- | ------------ |
| `indexed_model/antifold/model.pt` — the checkpoint at the asset root's top level | mounts the asset as `models`, giving exactly `models/model.pt` |
| entrypoint `antifold` in the catalogue package | `assets.importAsset("@platforma-open/milaboratories.antifold-weights-assets:antifold")` |

If the mount name moves, both sides move.

## Variants

| Variant    | Source                                                              | Size      |
| ---------- | ------------------------------------------------------------------- | --------- |
| `antifold` | `https://opig.stats.ox.ac.uk/data/downloads/AntiFold/models/model.pt` | 540.6 MiB |

## Building locally

```bash
pnpm install
pnpm build      # downloads the checkpoint, then builds the asset tarball
```

`build` shells out to `scripts/download-weights.sh`, which reads `antifold/modelInfo.json` and
`curl`s each listed file into `indexed_model/<target_dir>/`. The only network dependency is at build
time, never at block run time.

Two things in the manifest are load-bearing:

- `"url_suffix": ""` — the script defaults it to `"?download=1"`, which is a Zenodo convention. The
  OPIG URL is a direct path and 404s with that suffix appended.
- `"expected_bytes"` — the download is accepted only at exactly this byte count. A truncated fetch
  fails the build instead of shipping an asset whose consumer would fall back to the runtime
  download. The file is written to `<name>.part` and renamed only after the size check, so a partial
  file never occupies the final path.

## Testing

```bash
pnpm test       # or: ./scripts/download-weights.test.sh
```

The suite covers the download script against a local `python3 -m http.server` fixture, so it never
fetches the real checkpoint. It is wired directly rather than through `turbo run test`, because a
turbo `test` task that depends on `build` would trigger the 540.6 MiB download on every test run.

## License

**Unresolved.** The AntiFold source repository is BSD 3-Clause, but that covers the code; no license
accompanies the checkpoint at its download URL. `antifold/LICENSE-NOTES.md` records what is and is
not known, and the build copies it into `indexed_model/antifold/` so it ships inside the asset next
to the weights. Resolve the terms before publishing this asset anywhere public.
