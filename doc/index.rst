PrismaGPU
=========

PrismaGPU combines a Geometry Engine (GE) with a Raster Engine (RE). GE
prepares triangles, and RE draws them into a framebuffer. This guide follows
the data from input vertices through rasterization and explains software
control in command and direct-stream modes.

The guide explains the internal architecture, data formats, and programming
interface. It assumes familiarity with basic 3D geometry, but no knowledge
of hardware description languages. The diagrams show how the stages work
together and where data is buffered.

.. toctree::
   :maxdepth: 2
   :caption: Integration

   integration
   simulation

.. toctree::
   :maxdepth: 2
   :caption: Geometry Engine

   ge/index

.. toctree::
   :maxdepth: 2
   :caption: Raster Engine

   re/registers
   re/commands
   re/command_processor
   re/pixel_raster_pipeline
   re/memory_unit
   re/pixel_interpolator
   re/z_test
   re/texturizer
   re/pixel_blender
