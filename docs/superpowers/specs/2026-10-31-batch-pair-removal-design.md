# One RAW cleanup confirmation per export batch

The user requests that multi-RAW exports finish creating their pairs before
asking once to remove the old assets, and that waiting at the iOS confirmation
must not pause unfinished exports. Existing Photos safeguards remain required.

Use the existing sequential rendering worker to create/verify pairs, retaining
durable pending saves and pinned JPEGs. After conversions finish, reverify the
pending pairs and originals and submit one guarded PhotoKit deletion containing
all eligible old assets. Passive recovery never deletes; explicit cleanup uses
the same batch path without camera work. Cancellation/backgrounding before
submission retains originals, and an already submitted transaction is drained.

Per-photo deletion causes repeated prompts; a separate user cleanup action for
every normal batch adds an unnecessary step. Deferred deletion in one existing
job is the approach requested by the user. Track each pair's job and insertion
order so album positions can account for other pairs added by that batch before
removal. All deletion preconditions are checked before requesting any deletion.

Keep the idle timer disabled through transient scene inactivity while export
owns work. Restore it on real backgrounding and after the worker ends. A real
background transition still suspends camera admission safely.
