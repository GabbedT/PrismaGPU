# PrismaGPU documentation

This English guide describes the Geometry Engine architecture, triangle
formats, and software register interface. The Sphinx setup and Read the
Docs theme are adapted from `ZenithSoC/docs/`.

```bash
python3 -m pip install -r doc/requirements.txt
make -C doc html
make -C doc SPHINXOPTS="-W --keep-going -n" html
```

Open `doc/_build/html/index.html`. On Windows, use `doc/make.bat html`.
The SVG diagrams in `doc/img/` explain the functional architecture and can
be replaced by schematic images. RST editorial comments mark the insertion
points without displaying editing instructions to readers.

Keep changes focused on behavior, architectural concepts, and the programming
contract. Hardware file names, internal signals, and source-code commentary
do not belong in the reader-facing chapters. Build with warnings as errors
after updating pages or navigation.
