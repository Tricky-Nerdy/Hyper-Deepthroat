# Public reference register

Scope: sources supplied for loader and optional visual-asset research. This is not an inventory of private
computer files, repositories or Obsidian notes. "Unpublished work" is not being labeled as a zero-day
security vulnerability. Availability and claims below reflect public page inspection, not executed packages.

| Source | Evidence | Known unknowns |
|---|---|---|
| [ExtraMod core/template](https://www.undertow.club/downloads/extramod-core-and-mod-template.8227/) | Page lists core v1.51/template v1.5, TemplateExtension dependency and recommended immediate load order | Source downloads require registration on the inspected page; runtime/API/rendering compatibility unverified |
| [sby alternate template](https://www.undertow.club/downloads/sby-alternate-loader-template.4762/) | Page lists V3_6_1 and additional dialogue/audio registration APIs | Complete signatures/source and compatibility fixtures unavailable in this review |
| [TemplateExtension](https://www.undertow.club/downloads/templateextension.3679/) | Public resource link located | Exact source/version corpus and adapter verification pending |
| [Character creator reference](https://civitai.red/models/1084936/sdt-character-creator) | Request returned HTTP 403 | Contents, license, requirements, and compatibility unverified |
| [Joy AI workflow](https://civitai.com/models/2532826/joy-ai-image-edit-workflow) | Public page lists v1.0 workflow and claims object movement, rotation and camera control | Actual graph, custom nodes, model files, license and quality not inspected; "Other" base-model label does not establish Qwen |
| [Wan 2.2 rotation LoRA](https://civitai.com/models/2216277/wan22-360-rotation-redmond-i2v-14b) | Page lists high-/low-noise variants, Wan 2.2 I2V-A14B, `360 Rotation` trigger and Apache 2.0 resource license | Workflow routing, weights, base-model terms, hardware requirements and output consistency unverified |

## Optional asset-production extension (not implemented)

Non-explicit asset jobs could use a pinned ComfyUI API graph, model checksums, source-image provenance,
generation parameters and seeds. Stages would be proposed → validated → queued → running → review required
→ approved → packaged, with failure/cancellation states. No graph, model or custom node is installed or
executed by this change.

Turntable video and true geometry are separate products. Generated unseen surfaces and prompted view angles
are estimates, not measured 3D truth. Record requested and reviewed angles separately. Review asymmetric
details, identity, silhouette, temporal consistency, loop seam and alpha edges before making discrete views.
Flattened frames do not establish layered costume attachments, masks or independently animated parts.

Keep inference on an explicitly configured authoring worker; portable clients should consume approved assets.
Future checks should cover workflow reproducibility, licenses, job cancellation, resource limits and import
behavior. These are known unknowns, not working integrations.

## Discovery gaps

Missing upstream source versions, unavailable fixtures, runtime-specific rendering differences, untested
device paths and undocumented package dependencies are gaps to investigate. They are not evidence of
undiscovered capabilities or confirmed security defects. New evidence should update the versioned matrix
in [loader-compatibility.md](loader-compatibility.md).
