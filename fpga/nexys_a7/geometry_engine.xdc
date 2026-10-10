# Geometry Engine internal clock: 100 MHz.
# Interface delays belong to the eventual GPU integration and are intentionally
# left unconstrained here. This constraint measures internal register paths.
create_clock -name ge_clk -period 10.000 [get_ports clk_i]
