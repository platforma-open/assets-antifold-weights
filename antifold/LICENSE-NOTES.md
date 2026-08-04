# License notes — AntiFold model checkpoint

**The license of these weights is unresolved. It needs legal review before this asset ships.**
This file records what is known and what is not. It does not state a license, and the weights do
**not** inherit AntiFold's code license by default.

## What is known

- The AntiFold **source repository** carries a `LICENSE` file with BSD 3-Clause text,
  `Copyright 2023 Magnus Haraldson Hoie and Alissa M Hummer`. That file covers the **code**.
- The repository ships **no weights** — `models/.gitkeep` is the only thing in its weights directory.
  The checkpoint in this asset comes from a separate download host,
  `https://opig.stats.ox.ac.uk/data/downloads/AntiFold/models/model.pt`.
- The checkpoint is 566,838,063 bytes. Verified from the live `content-length` response header.

## What is not known

- No license statement accompanies the checkpoint at its download URL, and none is stated for the
  weights inside the source repository.
- The repository `README.md` claims BSD 3-Clause and points at a URL for the terms. That URL was
  never fetched, so the claim is unverified here and is not repeated as fact.
- The vendored `esm/*.py` files carry MIT headers referring to "the LICENSE file in the root
  directory", but the only license file present in the repository is the BSD 3-Clause one. Which
  terms govern the ESM-IF1 lineage that this checkpoint is fine-tuned from is therefore unclear.

## Consequence for this asset

The asset is published for internal use by the Antibody Variant Designer. Redistribution terms are
an open question. Resolve them with the upstream authors, or with legal review, before the asset is
published anywhere public.
