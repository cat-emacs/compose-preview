# Temporary device and size overrides

Start from a successful `compose-preview list` result for the exact source and
target. Each `previews[]` entry has `previewId` and `configuration`. Copy both
without recomputing the ID or omitting baseline null values:

```json
{
  "example.HomeKt.Home_HASH_FROM_DISCOVERY": {
    "baseline": {"device": null, "widthDp": null, "heightDp": null, "showSystemUi": null},
    "values": {"widthDp": 360, "heightDp": 640, "showSystemUi": false}
  }
}
```

The key above is illustrative; replace it with the returned ID and replace
`baseline` with that entry's exact `configuration`. Allowed value fields are
`device`, `widthDp`, `heightDp`, `showSystemUi`. Device uses Studio `id:`/`spec:`
syntax. Disable system decorations for size overrides to take effect.

```sh
compose-preview render --project "$ROOT" --module "$MODULE" --variant "$VARIANT" \
  --file "$SOURCE" --preview-id "$PREVIEW_ID" --overrides "$WORK/overrides.json" \
  --reuse --json > "$WORK/configured.json" 2> "$WORK/configured.log"
```

Keep composite identity, input roots, cache directory and JDK options consistent
with the original request. `--no-build` may replace `--reuse` only when a fresh
compiled model already exists; otherwise it fails. A source baseline change makes
an override inapplicable: rediscover and review it instead of forcing the old
configuration onto new source. Output `configuration` identifies the source
baseline, not proof that an override took effect. View the PNG and check its
actual dimensions/content to verify the intended device/size was applied.
