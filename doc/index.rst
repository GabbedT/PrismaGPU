PrismaGPU
=========

PrismaGPU includes a Geometry Engine (GE) that prepares triangles for the
later steps of rendering. This guide follows the data from the input format
to the processed primitives and explains how software controls the engine.

The guide explains the internal architecture, data formats, and programming
interface. It assumes familiarity with basic 3D geometry, but no knowledge
of hardware description languages. The diagrams show how the stages work
together and where data is buffered.

.. toctree::
   :maxdepth: 2
   :caption: Geometry Engine

   ge/index
