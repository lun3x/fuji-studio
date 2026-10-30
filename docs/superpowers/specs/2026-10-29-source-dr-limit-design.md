# Per-photo conversion dynamic range

The user chose `conversion DR = min(capture DR, recipe DR)`. A recipe must
remain applicable when its requested DR exceeds the source RAW's capture DR.
Saved camera and phone recipes, recipe identity and settings digests stay intact.

Read capture DR from the RAF's embedded original JPEG FujiFilm
DevelopmentDynamicRange. Apply the same rule in both X-E3 and X-T5 working
profiles, covering preview and export through the shared camera service.
Validate returned JPEG metadata against the effective DR while retaining the
original requested settings and recording the effective DR in render provenance.

The selected approach limits conversion settings, rather than changing saved
recipes or rejecting the photo/recipe combination. Those alternatives contradict
the requested behavior. DR Auto keeps its existing support rules; explicit
DR100/200/400 follow the minimum rule.

If capture DR is missing, malformed or outside 100/200/400, use DR100 for the
conversion. This conservative fallback keeps the recipe applicable and stays
within every supported capture's DR limit. It is an implementation choice;
it can reduce DR for an original whose capture value cannot be established.

Version conversion support so previously cached invalid renders cannot be
reused. Invalidate metadata caches created before capture DR was recorded; preserve the newer metadata-only camera-filtering path. Validate decoded capture DR at use as well as construction. Keep the native camera recipe format identifier stable. Requeue old
unsubmitted exports for conversion; keep already submitted/unknown Photos saves
in their existing reconciliation flow. Explicit DR200 becomes convertible on
X-T5 and appears in the existing editor picker. The selected recipe stays
available, and DR is resolved for each original at conversion time. The full
test suite remains deferred by the user; run focused regression tests and build
the signed phone app.
