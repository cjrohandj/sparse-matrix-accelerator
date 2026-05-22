# Manim Sparse Accelerator Demo

Render the animation with:

```bash
manim -pqh manim_demo/sparse_accelerator_scene.py SparseAcceleratorScene
```

Use `-pql` for a faster low-quality preview or `-p` to open the rendered video when complete.

The scene shows:

- dense weight matrix values
- 2:4 sparse conversion
- resultant sparse matrix
- stored values and indices
- sparse multiplication unit with muxes and fixed weights
- dense input values selected by indices
- multiply-add outputs streamed into the result matrix
