# Red Fox asset provenance

The three fox atlases were generated with OpenAI image generation for this project and are distributed under the repository's MIT license.

- `fox-atlas.png`: 4 columns x 8 behavior rows; generated from the project's puppy atlas as a style and layout reference.
- `fox-directional-atlas.png`: 4 columns x 4 rows for front/back walk and run cycles; generated from the fox and puppy directional references.
- `fox-diagonal-atlas.png`: 4 columns x 4 rows for front/down-right and rear/up-right walk and run cycles; generated from the shipped fox atlases and the puppy diagonal movement reference.

The generated source images were resized to exact 224 x 224 cells without manual redrawing. The diagonal atlas checkerboard and neutral edge halo were removed with the deterministic macOS maintenance script in `scripts/remove-generated-checkerboard.m`, leaving real PNG alpha transparency.
