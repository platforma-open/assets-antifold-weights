# assets-antifold-weights

The AntiFold inverse-folding model checkpoint, distributed as a [Platforma](https://platforma.bio)
asset. Consumed by the `antibody-variant-designer` block, and by nothing else. SDK docs:
[docs.platforma.bio](https://docs.platforma.bio).

AntiFold downloads a 540.6 MiB checkpoint from `opig.stats.ox.ac.uk` the first time it loads a model,
and its `--model_path` flag does not redirect where it looks. A sealed run has no network, so that
download must never fire. This repo removes it: the checkpoint is fetched once at package-build time,
published as an asset, and mounted into the exec workdir.

## Upstream

- Source repo: <https://github.com/oxpig/AntiFold> — BSD 3-Clause, which covers the **code**; the
  repo ships no weights (`models/.gitkeep` is the only thing in its weights directory)
- Checkpoint URL: `https://opig.stats.ox.ac.uk/data/downloads/AntiFold/models/model.pt`
- Article: _Improved antibody structure-based design using inverse folding_, Bioinformatics Advances
  (2024) — [10.1093/bioadv/vbae202](https://doi.org/10.1093/bioadv/vbae202)

The checkpoint URL carries no version. Upstream can replace the file in place, so `expected_bytes` in
the manifest is the only version pin this repo has.

## Variants

| Variant    | Source                                                                            | Size                      |
| ---------- | --------------------------------------------------------------------------------- | ------------------------- |
| `antifold` | [`model.pt`](https://opig.stats.ox.ac.uk/data/downloads/AntiFold/models/model.pt) | 566,838,063 B (540.6 MiB) |

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

## How a block consumes it

```go
antifoldAsset := assets.importAsset("@platforma-open/milaboratories.antifold-weights-assets:antifold")

exec.builder().
    addAsset(antifoldAsset, "models").
    …
```

These are requirements, not examples. The Variant Designer's design script calls
`load_IF1_checkpoint(model, "models/model.pt")`, so:

| The asset                                                                        | The consumer                                                                            |
| -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `indexed_model/antifold/model.pt` — the checkpoint at the asset root's top level | mounts the asset as `models`, giving exactly `models/model.pt`                           |
| entrypoint `antifold` in the catalogue package                                   | `assets.importAsset("@platforma-open/milaboratories.antifold-weights-assets:antifold")` |

If the mount name moves, both sides move. Nothing in this repo can prove the mount — there is no
block, no workflow, no UI here — so a wrong mount name or a wrong entrypoint leaves every test in
this repo green. A real run of the Variant Designer is the coverage claim.

## Testing

```bash
pnpm test       # or: ./scripts/download-weights.test.sh
```

The suite covers the download script against a local `python3 -m http.server` fixture, so it never
fetches the real checkpoint. It is wired directly rather than through `turbo run test`, because a
turbo `test` task that depends on `build` would trigger the 540.6 MiB download on every test run.

## Updating the checkpoint

1. Re-read the live size: `curl -sI <checkpoint url> | grep -i content-length`.
2. A different size means upstream replaced the file. Confirm that is intended, then update
   `expected_bytes` in `antifold/modelInfo.json` and the size in this README.
3. `pnpm changeset` — bump the `antifold` variant package **and** the `catalogue` package. CI does not
   overwrite an existing version; without a bump the registry keeps serving the old archive under the
   same version string.
4. Merge to `main`. CI builds, uploads the archive, publishes the catalogue, and tags. Publishing is
   never manual — `postbuild` gates `pl-pkg publish` on `CI`, so a local `pnpm build` uploads nothing.

Verify the upload:

```bash
curl -sI "https://bin.pl-open.science/assets/platforma-open/milaboratories.antifold-weights-assets.antifold/main/<version>.zip" | head -2
```

200 = published, 404 = not yet.

## License

Packaging in this repo: MIT — see [LICENSE](LICENSE).

**The checkpoint's license is unresolved.** The AntiFold source repository is BSD 3-Clause
(`Copyright 2023 Magnus Haraldson Hoie and Alissa M Hummer`), but that covers the code; no license
accompanies the checkpoint at its download URL, and weights do not inherit a code license by default.
`antifold/LICENSE-NOTES.md` records what is and is not known, and the build copies it into
`indexed_model/antifold/` so it ships inside the asset next to the weights.

`bin.pl-open.science` is a public registry. Resolve the terms before this asset is published there.
