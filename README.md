# 🧪 Fault
Fault is an automatic test pattern generator for netlists that includes scan chain stitching, synthesis scripts and a number of other convenience features.

# Quick Setup/Walkthrough
You may refer to the [wiki](https://github.com/Cloud-V/Fault/wiki) for quick setup instructions (and a small walkthrough!) if you're into that.

# Running
## Subcommands
### synth
Synth is a synthesis script included with Fault that generates both a netlist and a cut-away version.

To run it, `fault synth --top <your-top-module> --liberty <your-liberty-file> <your-file>`. You can optionally omit` --liberty` where osu035 will be used.

For more options, you can invoke `fault synth --help`.

### cut
`fault cut <your-netlist>`

This exposes the D-flipflops as ports for use with the main script.

For more options, you can invoke `fault cut --help`.

### main
`fault --cellModel <your-cell-models> <your-file>`, `--cellModel` behaving similar to `--liberty` in synth.

A set of assumptions are made about the input file:
* It is a netlist
* It is flattened (there is only one module with no submodules)
* The flipflops have been cut away and replaced with outputs and inputs.

Generated test vectors are printed to stdout by default, but you can use `-o <file>` (or simply redirect the output).

For more options, you can invoke `fault --help`.

## chain
`fault chain --liberty <your-liberty-file> --clock <clockName> --reset <resetName> <--activeLow> <your-file>`, `--liberty` behaving identical to Synth.

Chain is another synthesis script that links registers together for scan insertion. It takes all the assumptions made in the main program but the last, and one more:
* All instantiated D flipflops start with "DFF".

A note about the liberty file in use in this step is that we recommend a modified liberty file that keeps only a buffer, an and gate, and a multiplexer (and an inverter if necessary), as abc tends to overthink multiplexers.

Chain will output information about the scan chain embedded in the output netlist as `/* FAULT METADATA: '<json>' */` after the boilerplate. This metadata includes things like port names, the DFF count and the order of the registers in the scan chain.

You can have Chain automagically verify its generated scanchain-- see the help for more options, but the gist of it is `-v <your-cell-model>`.

For more options, you can invoke `fault chain --help`.

## asm
`fault asm <test vector json> <chained netlist>`, in any order, will assemble a .bin file for use with `$readmemb`.

For more options, you can invoke `fault asm --help`.

## compact
`fault compact <test vector json>`

This performs static compaction on the generated test vectors by reducing the test vectors count while keeping the same coverage.

For more options, you can invoke `fault compact --help`.

# License
The GNU General Public License v3 (or later, at your option). See 'License'.

# References
- Z. Navabi, Digital System Test and Testable Design : Using Hdl Models and Architectures. 2010;2011;. DOI: 10.1007/978-1-4419-7548-5.
[Book](https://ieeexplore.ieee.org/book/5266057)
- Shinya Takamaeda-Yamazaki: Pyverilog: A Python-based Hardware Design Processing Toolkit for Verilog HDL, 11th International Symposium on Applied Reconfigurable Computing (ARC 2015) (Poster), Lecture Notes in Computer Science, Vol.9040/2015, pp.451-460, April 2015.
[Paper](http://link.springer.com/chapter/10.1007/978-3-319-16214-0_42)

# Detailed installation instructions
You can try [INSTALLING.md](INSTALLING.md) for full installation instructions.