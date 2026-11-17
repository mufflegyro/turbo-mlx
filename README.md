# Turbo MLX — a fork with a render-Mac backend

This is a personal fork of **[rinste/turbo-mlx](https://github.com/rinste/turbo-mlx)**, the native
macOS front end to an MLX Swift image and video engine. What the app is — the native model
catalog, the interface, the engine, the keyboard shortcuts — is upstream's, and
**[upstream's README](https://github.com/rinste/turbo-mlx#readme)** describes it: read that first.
This file documents only what the fork changes.

**[⬇ Download the fork's latest build](https://github.com/mufflegyro/turbo-mlx-network/releases/latest)** —
a disk image built from this fork (Apple silicon, macOS 15 or later). It is **not notarized**:
macOS will refuse the app on first launch until you allow it, once — right-click the app and choose
*Open*, or, after copying it to Applications,
`xattr -dr com.apple.quarantine "/Applications/Turbo MLX.app"`. These builds do not update
themselves; download the next one from the releases page.

## What is different from upstream

- **Generation on another Mac.** A render-Mac backend (TurboRelay) runs the models and the
  downloads, and this app stays the GUI.
- **Two model families the native engine does not have** — Krea 2 and Qwen-Image 2.1 (base and
  Turbo) — served by the relay's mflux engine, with the picker saying which engine a model needs.
- **LoRA work**: MOSS-Image adapters in the native engine, few-step adapters that set their own
  steps, imports from the render Mac, per-model tunings, and the adapter's name and strength under
  the picture.
- **Upscaling that starts where SeedVR2 wants it**: *Softness* preset to ComfyUI's 0.35-megapixel
  base, with a *Detail* read-out.
- **History and browsing**: a strip that folds, slides and resizes, a private history behind a
  padlock, a gallery with filters and search, and a prompt library beside a 314-style browser.
- **Clips**: longer LTX runs, 720p and 1080p presets, 8-step Quality, distilled LoRAs, and memory
  guards around the reference encode and the decode.

## A render Mac: remote rendering (TurboRelay)

Generation can run on a more powerful Mac on the same network, the way moss-image-mac drives a
ComfyUI server: the GUI stays here, and a menu bar app on that Mac — **TurboRelay**, a separate
project and not part of this repository — owns the models, the downloads and the renders.

- **Settings → Remote Render** takes the address and the **pairing token** the menu bar app shows,
  with a status row and a log. *Apply* switches without a restart. A failed connection returns to
  this Mac's engine rather than leaving the app without one.
- **What travels**: the request; reference and last-frame images, content-addressed; the LoRA files
  the relay does not have yet; previews inline as the picture forms; results by file id, fetched
  when they land. The client reconnects on its own and delivers the results by job id.
- **What comes back**: model list, download state and progress, the render Mac's memory (so the
  memory gate and its warnings judge that Mac, not this one), and the engine a result ran on.
- **Model downloads** happen on the render Mac from its own Hugging Face cache; *Download and
  Generate* asks the server, and Quality files (LTX's full transformer) are requested through the
  relay's own route with their own progress.
- **Models added by hand** on the relay appear in this app's picker while connected, marked
  built-in (they cannot be removed from here) and hidden again when this Mac runs its own engine.
- **Jobs made remotely carry a `relay` tag**, so the time estimate's local fit is not skewed by
  the other Mac's speed.
- The transport seam is `EngineTransport` (`TurboMLX/Services/`): `RemoteBackend` is the HTTP +
  WebSocket client, the local engine is the other side.

## Models this fork adds

They appear in the picker and in Settings only in remote mode; selecting one locally falls back to
a native model. Their memory and time figures are estimates from the relay.

| Model | Minimum RAM | Download | Steps | Licence |
|---|---|---|---|---|
| Krea 2 Turbo (mflux q4) | 32 GB | 15.8 GB | 8, no guidance | Krea 2 Community License |
| Qwen-Image 2.1 (mflux q4) | 24 GB | 10.6 GB | 40 | Qwen Research License |
| Qwen-Image 2.1 Turbo (mflux q4) | 24 GB | 10.6 GB | 8, no guidance | Qwen Research License |

The relay pins mflux 0.24.0 for them; a model whose family only mflux serves is tagged **mflux** in
the picker and on the history thumbnails, the rest **native**. *Add Model* recognises both families
and says they need a render Mac, and LoRA files that name them are recognised too.

## LoRAs

- **MOSS-Image adapters run in the native engine.** The engine gained a mapping for MOSS-Image's
  DiT (`layers.{block}.proj.{q,k,v,o,ffn_up_gate,ffn_down}`), so its published adapters — the
  8-step DMD distillation among them — apply instead of being turned away as "made for Z-Image".
- **A few-step adapter sets its own steps.** The count is read from the file's name or the
  trainer's note ("8-step", "4 steps", "distilled"), and choosing it sets the steps and guidance Off,
  clamped to the model's range. It applies again at launch or when switching back to the model, but
  only while the steps are still the model's default, so a tuned count is never overwritten.
- **MOSS-Image's step range starts at 2**, for the 2-, 3- and 4-step distillations.
- **Save memory** releases MOSS-Image's transformer mid-job; the LoRAs are applied again when it is
  loaded back rather than silently dropped.
- **Import from the render Mac**: a sheet lists the relay's LoRA library (name, family, size, date),
  marks the files already here, and downloads the chosen one to disk.
- **The preview shows the LoRA**: a chip beside the model names the adapter and its strength
  ("StyleX ×0.8"), one per adapter, with the full filename in its tooltip. Items made before this
  build show it too — the LoRA was always recorded in the saved request.

## Upscaling

SeedVR2's *Softness* now starts at the reduction that reads the picture as about **0.35
megapixels** first — what ComfyUI's SeedVR2 workflows do with `ImageScaleToTotalPixels` before they
upscale, so the model adds detail from a small base instead of sharpening an already-large picture.
The slider is set when the picture or the scale changes and stays free from there, and a *Detail*
row says what the upscale starts from. A history item keeps the softness it was made with.

## History, gallery, prompts

- **The strip** folds down to its header and slides away (the stage takes the room back), the
  header doubles as a grip that resizes the thumbnails from 64 to 200 pixels, a double-click folds
  it, and the scroll place survives a fold. An upscaled thumbnail carries its factor, a remote one
  the engine that made it.
- **Private history**: a padlock in the strip switches to the pictures kept privately; everything
  generated while it is on joins them, existing pictures can be moved either way from their menu,
  *Clear History* clears the list being shown, and the gallery and the *From History…* picker follow
  the same lock.
- **The gallery** (⇧⌘G): the history as a grid, filtered by model, by kind (image, clip, 3D object,
  song) or by a search of the prompts, with counts that follow the other filters. The filter and the
  place are remembered between opens.
- **The prompt library** (⇧⌘P): save the prompt blocks and the negative prompt, use them again, or
  delete them. *Use* changes nothing else — not the model, size, steps, seed or LoRA.
- **Styles & Prompts** (⇧⌘P): the MOSS-Image Character & Style Catalog, bundled (314 styles in eight
  categories, MIT, attribution in *Acknowledgements*), searchable, appended to the prompt's Style
  block in one click.
- **Missing clip posters are rebuilt** from the first frame at launch, so a clip whose still was
  lost stops showing as a blank thumbnail.

## Clips (LTX)

- Up to **20 s** at 24/25 fps (LTX-2.3 and 2.5, their long configurations); 30 fps and the other
  families keep 10 s, and switching to 30 clamps back.
- Resolution presets gain **720p and 1080p** (the long side: 1280 × 704 and 1920 × 1088 at 16:9,
  sides kept multiples of 64).
- **Quality opens at 8 steps**, for the distilled LoRA trained on that schedule, and a LoRA whose
  name or note says "distilled" carries the 8-step hint.
- **Memory guards**: the resident transformer is released before a large reference picture is
  encoded (where the crash reports faulted), MLX errors during the reference encode, the decode or
  the generation become readable failures instead of an engine that dies, and the decode's tiling
  plan is checked before it allocates.
- The mode text says what the step count means: Fast's 8 steps show as 11 in progress because the
  two-stage pipeline adds three fixed full-resolution refinement steps.

## Custom models

- **A precision choice** where the family takes one (as stored, or 8-bit), for example the
  full-precision MOSS-Image repository.
- **Diffusers-layout checkpoints are turned away with the reason**, for the families whose loader
  reads mflux's saved packs — BFL's own FLUX.2 Klein 9B among them.
- **The descriptor travels** with a remote download, so a model added by hand here can be fetched
  to the render Mac.
- **Steps, guidance and the negative prompt are remembered per model** and restored when you switch
  back, instead of resetting to the family's defaults.

## Fixes

- Transport events hop to the main actor before touching the app's state: model downloads used to
  crash the app from a background queue (four crash reports, one stack).
- An MLX error fails the job with a message instead of taking the engine down mid-generation.
- MOSS-Image no longer quantizes a checkpoint whose packed weights are already quantized.
- The guidance experiment on Z-Image Turbo was reverted: the turbo checkpoint is distilled to
  imitate a guided model in one pass, so CFG is off in the fork's builds.

## Building and releasing this fork

Requirements are upstream's: an Apple silicon Mac with macOS 15 or later and Xcode 26. Open
`TurboMLX.xcodeproj` and press ⌘R; the build also builds and embeds the native engine
(`scripts/embed-engine.sh`, a few minutes the first time).

- `scripts/dev-release.sh` — a development disk image in one command: bumps
  `CURRENT_PROJECT_VERSION`, builds Release signed with the Apple Development identity in
  `Signing.local.xcconfig` (or the keychain), verifies the app and the mounted image, and writes
  `build/release-apple-development/Turbo-MLX-<version>-<build>-apple-development.dmg`. `--build N`
  takes an exact number, `--copy-to-desktop` also puts a copy on the Desktop.
- `scripts/release.sh` — upstream's notarized release, for a Developer ID certificate and the
  update feed. This fork has no update feed; releases here are the development images.
- The fork numbers its own builds (`MARKETING_VERSION` 1.12, its own `CURRENT_PROJECT_VERSION`) and
  turns automatic updates off, so upstream's appcast never replaces it with the stock app.

## Every commit since the fork

```
c7816f1 Engine: LoRA support for MOSS-Image's DiT
c204a42 Client: remote render backend (TurboRelay)
2beb047 Client: recognise MOSS-Image LoRAs; 8-step minimum for moss
9a0235f Client: send a custom model's descriptor when downloading remotely
e5e3d9a Engine: do not quantize an already-quantized MOSS checkpoint
1cdf563 Client: precision picker in Add Model
b5140b0 MOSS-Image: reapply LoRAs when Save memory reloads the transformer
170aeba Client: prompt library (save, use, delete)
99da00f Client: Styles & Prompts browser, as in the app it comes from
aef901c Release 1.12 (13): this build's own version, and no automatic updates
c8c9db7 Client: deliver transport events on the main actor (crash fix)
94fbb39 MOSS-Image: steps from 2, for the few-step adapters
d5cfe53 Client: private history, behind a padlock in the strip
c7a875e Build 18: Z-Image stays guidance-off
2c3c158 Client: turn away diffusers-layout checkpoints when adding a model
11e6670 Client: Krea 2 and Qwen-Image 2.1, engine badges
0edc349 Client: remember steps and guidance per model
02d0889 Client: list the relay's models added by hand
8ebe74d History: upscale tags, a collapsible strip
86ab7a9 History: slide the strip, double-click it, resize the thumbnails
8c55fea History: resize cursor and a steady thumbnail resize
ea43323 History: keep the scroll place; drag only the bar
10d7943 Remote Quality: download LTX's dev transformer on the render Mac
0292061 Clips: 20 s for LTX at 24/25 fps, and 720p/1080p presets
850b0a5 LoRAs: import the ones the render Mac already has
afc8640 Clips: repair missing posters; guard the decode's memory plan
3917496 LTX: catch MLX errors at the reference image; free the swapped transformer
cafa535 LTX: free the transformer for a large reference encode
005c216 LTX: free the transformer from 720p's full-size reference encode
c4c00f2 LoRAs: a few-step adapter sets its own steps and guidance
a35ffb1 LoRAs: also fix a half-default tuning for a few-step adapter
5a7ac27 Reference picker: private images only while private history is shown
9bf420b Gallery: the history as a grid, filtered by model, kind and prompt
632a506 LTX Quality: allow 8 steps, and recognise a distilled LoRA
fb9aeef Clips: say that LTX's step count is stage 1 (plus 3 refinement)
7661505 Upscaler: softness starts at the reduction ComfyUI's SeedVR2 workflows use
84674d3 Preview: the LoRA and its strength beside the model
878300a Build: scripts/dev-release.sh, a development disk image in one command
500e403 README: this fork's features, and the two settings that changed
```

## Licence and credits

The fork keeps upstream's **MIT** licence and copyright notice (`LICENSE`). The bundled style
catalog is the MOSS-Image Character & Style Catalog (MIT), credited in
`TurboMLX/Resources/Acknowledgements.txt` with the models and libraries the app uses. TurboRelay,
the render-Mac server, is a separate project of this fork and is not covered by this repository.
