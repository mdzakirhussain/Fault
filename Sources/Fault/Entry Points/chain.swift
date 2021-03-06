import Foundation
import CommandLineKit
import PythonKit
import Defile

func scanChainCreate(arguments: [String]) -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let defaultLiberty = env["FAULT_INSTALL_PATH"] != nil

    let cli = CommandLineKit.CommandLine(arguments: arguments)

    let help = BoolOption(
        shortFlag: "h",
        longFlag: "help",
        helpMessage: "Prints this message and exits."
    )
    cli.addOptions(help)

    let filePath = StringOption(
        shortFlag: "o",
        longFlag: "output",
        helpMessage: "Path to the output file. (Default: input + .chained.v)"
    )
    cli.addOptions(filePath)

    let ignored = StringOption(
        shortFlag: "i",
        longFlag: "ignoring",
        helpMessage: "Inputs,to,ignore,separated,by,commas."
    )
    cli.addOptions(ignored)

    let verifyOpt = StringOption(
        shortFlag: "c",
        longFlag: "cellModel",
        helpMessage: "Verify scan chain using given cell model."
    )
    cli.addOptions(verifyOpt)

    let clockOpt = StringOption(
        longFlag: "clock",
        required: true,
        helpMessage: "Clock signal to add to --ignoring and use in simulation."
    )
    cli.addOptions(clockOpt)

    let resetOpt = StringOption(
        longFlag: "reset",
        required: true,
        helpMessage: "Reset signal to add to --ignoring and use in simulation."
    )
    cli.addOptions(resetOpt)

    let resetActiveLow = BoolOption(
        longFlag: "activeLow",
        helpMessage: "Reset signal is active low instead of active high."
    )
    cli.addOptions(resetActiveLow)

    let liberty = StringOption(
        shortFlag: "l",
        longFlag: "liberty",
        required: !defaultLiberty,
        helpMessage:
            "Liberty file. \(defaultLiberty ? "(Default: osu035)" : "(Required.)")"
    )
    cli.addOptions(liberty)

    var names: [String: (default: String, option: StringOption)] = [:]

    for (name, value) in [
        ("sin", "serial data in"),
        ("sout", "serial data out"),
        ("shift", "serial shifting enable"),
        ("capture", "JTAG capture signal"),
        ("update", "JTAG update signal")
    ] {
        let option = StringOption(
            longFlag: name,
            helpMessage: "Name for \(value) signal. (Default: \(name).)"
        )
        cli.addOptions(option)
        names[name] = (default: name, option: option)
    }


    do {
        try cli.parse()
    } catch {
        cli.printUsage()
        return EX_USAGE
    }

    if help.value {
        cli.printUsage()
        return EX_OK
    }

    let args = cli.unparsedArguments
    if args.count != 1 {
        cli.printUsage()
        return EX_USAGE
    }

    let fileManager = FileManager()
    let file = args[0]
    if !fileManager.fileExists(atPath: file) {
        fputs("File '\(file)' not found.\n", stderr)
        return EX_NOINPUT
    }

    if let libertyTest = liberty.value {
        if !fileManager.fileExists(atPath: libertyTest) {
            fputs("Liberty file '\(libertyTest)' not found.\n", stderr)
            return EX_NOINPUT
        }
        if !libertyTest.hasSuffix(".lib") {
            fputs(
                "Warning: Liberty file provided does not end with .lib.",
                stderr
            )
        }
    }

    if let modelTest = verifyOpt.value {
        if !fileManager.fileExists(atPath: modelTest) {
            fputs("Cell model file '\(modelTest)' not found.\n", stderr)
            return EX_NOINPUT
        }
        if !modelTest.hasSuffix(".v") && !modelTest.hasSuffix(".sv") {
            fputs(
                "Warning: Cell model file provided does not end with .v or .sv.\n",
                stderr
            )
        }
    }

    let output = filePath.value ?? "\(file).chained.v"
    let intermediate = output + ".intermediate.v"
    let bsrLocation = output + ".bsr.v"

    var ignoredInputs: Set<String>
        = Set<String>(ignored.value?.components(separatedBy: ",") ?? [])
    if let clock = clockOpt.value {
        ignoredInputs.insert(clock)
    }
    if let reset = resetOpt.value {
        ignoredInputs.insert(reset)
    }

    let libertyFile = defaultLiberty ?
        liberty.value ??
        "\(env["FAULT_INSTALL_PATH"]!)/FaultInstall/Tech/osu035/osu035_muxonly.lib" :
        liberty.value!


    // MARK: Importing Python and Pyverilog
    let parse = Python.import("pyverilog.vparser.parser").parse

    let Node = Python.import("pyverilog.vparser.ast")

    let Generator =
        Python.import("pyverilog.ast_code_generator.codegen").ASTCodeGenerator()
    
    // MARK: Parse
    let ast = parse([args[0]])[0]
    let description = ast[dynamicMember: "description"]
    var definitionOptional: PythonObject?
    for definition in description.definitions {
        let type = Python.type(definition).__name__
        if type == "ModuleDef" {
            definitionOptional = definition
            break
        }
    }

    guard let definition = definitionOptional else {
        fputs("No module found.\n", stderr)
        return EX_DATAERR
    }

    // MARK: Internal signals
    print("Chaining internal flip-flops…")
    let definitionName = String(describing: definition.name)
    let alteredName = "__UNIT__UNDER__FINANGLING__"

    var internalOrder: [ChainRegister] = []

    do {
        let (_, inputs, outputs) = try Port.extract(from: definition)

        let testingName = names["shift"]!.option.value
            ?? names["shift"]!.default
        let testingIdentifier = Node.Identifier(testingName)
        let inputName = names["sin"]!.option.value ?? names["sin"]!.default
        let inputIdentifier = Node.Identifier(inputName)
        let outputName = names["sout"]!.option.value ?? names["sout"]!.default
        let outputIdentifier = Node.Identifier(outputName)
        let captureName = names["capture"]!.option.value ?? names["capture"]!.default
        let updateName = names["update"]!.option.value ?? names["update"]!.default

        // MARK: Register chaining original module
        let internalCount: Int = {
            var previousOutput = inputIdentifier

            let ports = Python.list(definition.portlist.ports)
            ports.append(Node.Port(testingName, Python.None, Python.None, Python.None))
            ports.append(Node.Port(inputName, Python.None, Python.None, Python.None))
            ports.append(Node.Port(outputName, Python.None, Python.None, Python.None))
            definition.portlist.ports = Python.tuple(ports)

            var counter = 0

            for itemDeclaration in definition.items {
                let type = Python.type(itemDeclaration).__name__

                // Process gates
                if type == "InstanceList" {
                    let instance = itemDeclaration.instances[0]
                    if String(describing: instance.module).starts(with: "DFF") {
                        counter += 1
                        internalOrder.append(
                            ChainRegister(
                                name: String(describing: instance.name),
                                kind: .dff
                            )
                        )
                        for hook in instance.portlist {
                            if hook.portname == "D" {
                                let ternary = Node.Cond(
                                    testingIdentifier,
                                    previousOutput,
                                    hook.argname
                                )
                                hook.argname = ternary
                            }
                            if hook.portname == "Q" {
                                previousOutput = hook.argname
                            }
                        }
                    }
                }
            }

            let statements = Python.list()
            statements.append(Node.Input(inputName))
            statements.append(Node.Output(outputName))
            statements.append(Node.Input(testingName))

            statements.extend(Python.list(definition.items))

            let finalAssignment = Node.Assign(
                Node.Lvalue(outputIdentifier),
                Node.Rvalue(previousOutput)
            )
            statements.append(finalAssignment)
            definition.items = Python.tuple(statements)
            definition.name = Python.str(alteredName)

            return counter
        }()

        // MARK: Chaining boundary registers
        print("Creating and chaining boundary flip-flops…")
        var order: [ChainRegister] = []
        let boundaryCount: Int = try {
            let ports = Python.list(definition.portlist.ports)
            ports.append(Node.Port(captureName, Python.None, Python.None, Python.None))
            ports.append(Node.Port(updateName, Python.None, Python.None, Python.None))

            var statements: [PythonObject] = []
            statements.append(Node.Input(inputName))
            statements.append(Node.Output(outputName))
            statements.append(Node.Input(testingName))
            statements.append(Node.Input(clockOpt.value!))
            statements.append(Node.Input(resetOpt.value!))
            statements.append(Node.Input(captureName))
            statements.append(Node.Input(updateName))

            let portArguments = Python.list()
            let bsrCreator = BoundaryScanRegisterCreator(
                name: "BoundaryScanRegister",
                clock: clockOpt.value!,
                reset: resetOpt.value!,
                resetActive: resetActiveLow.value ? .low : .high,
                capture: captureName,
                update: updateName,
                shift: testingName,
                using: Node
            )

            var counter = 0
            
            let initialAssignment = Node.Assign(
                Node.Lvalue(Node.Identifier(inputName.uniqueName(0))),
                Node.Rvalue(inputIdentifier)
            )
            statements.append(initialAssignment)

            for input in inputs {
                let inputStatement = Node.Input(input.name)

                if (input.name != clockOpt.value! && input.name != resetOpt.value!){
                    statements.append(inputStatement)
                }
                if ignoredInputs.contains(input.name) {
                    portArguments.append(Node.PortArg(
                        input.name,
                        Node.Identifier(input.name)
                    ))
                    continue
                }
                
                let doutName = String(describing: input.name) + "__dout"
                let doutStatement = Node.Wire(doutName)
                if input.width > 1 {
                    let width = Node.Width(
                        Node.Constant(input.from),
                        Node.Constant(input.to)
                    )
                    inputStatement.width = width
                    doutStatement.width = width
                }
                statements.append(doutStatement)

                portArguments.append(Node.PortArg(
                    input.name,
                    Node.Identifier(doutName)
                ))

                let minimum = min(input.from, input.to)
                let maximum = max(input.from, input.to)

                for i in (minimum)...(maximum) {
                    statements.append(
                        bsrCreator.create(
                            ordinal: i,
                            din: input.name,
                            dout: doutName,
                            sin: inputName.uniqueName(counter),
                            sout: inputName.uniqueName(counter + 1),
                            input: true
                        )
                    )
                    counter += 1
                }

                order.append(
                    ChainRegister(
                        name: String(describing: input.name),
                        kind: .input,
                        width: input.width
                    )
                )
            }

            portArguments.append(Node.PortArg(
                testingName,
                testingIdentifier
            ))

            portArguments.append(Node.PortArg(
                inputName,
                Node.Identifier(inputName.uniqueName(counter))
            ))

            counter += 1 // as a skip
            order += internalOrder

            portArguments.append(Node.PortArg(
                outputName,
                Node.Identifier(inputName.uniqueName(counter))
            ))

            for output in outputs {
                let outputStatement = Node.Output(output.name)
                let dinName = String(describing: output.name) + "_din"
                let dinStatement = Node.Wire(dinName)
                if output.width > 1 {
                    let width = Node.Width(
                        Node.Constant(output.from),
                        Node.Constant(output.to)
                    )
                    outputStatement.width = width
                    dinStatement.width = width
                }
                statements.append(outputStatement)
                statements.append(dinStatement)

                portArguments.append(Node.PortArg(
                    output.name,
                    Node.Identifier(dinName)
                ))
                
                let minimum = min(output.from, output.to)
                let maximum = max(output.from, output.to)

                for i in (minimum)...(maximum) {
                    statements.append(
                        bsrCreator.create(
                            ordinal: i,
                            din: dinName,
                            dout: output.name,
                            sin:  inputName.uniqueName(counter),
                            sout: inputName.uniqueName(counter + 1),
                            input: false
                        )
                    )
                    counter += 1
                }

                order.append(
                    ChainRegister(
                        name: String(describing: output.name),
                        kind: .output,
                        width: output.width
                    )
                )
            }

            let submoduleInstance = Node.Instance(
                alteredName,
                "__uuf__",
                Python.tuple(portArguments),
                Python.tuple()
            )

            statements.append(Node.InstanceList(
                alteredName,
                Python.tuple(),
                Python.tuple([submoduleInstance])
            ))

            let finalAssignment = Node.Assign(
                Node.Lvalue(outputIdentifier),
                Node.Rvalue(Node.Identifier(inputName.uniqueName(counter)))
            )
            statements.append(finalAssignment)

            var wireDeclarations: [PythonObject] = []
            for i in 0...counter {
                wireDeclarations.append(Node.Wire(inputName.uniqueName(i)))
            }

            let supermodel = Node.ModuleDef(
                definitionName,
                Python.None,
                Node.Portlist(Python.tuple(ports)),
                Python.tuple(wireDeclarations + statements)
            )

            try File.open(bsrLocation, mode: .write) {
                try $0.print(bsrCreator.inputDefinition)
                try $0.print(bsrCreator.outputDefinition)
            }

            let boundaryScanRegisters =
                parse([bsrLocation])[0][dynamicMember: "description"].definitions
            
            let definitions = Python.list(description.definitions)
            definitions.extend(boundaryScanRegisters)
            definitions.append(supermodel)
            description.definitions = Python.tuple(definitions)

            return counter - 1 // Accounting for skip
        }()

        let dffCount = internalCount + boundaryCount
        let metadata = Metadata(
            dffCount: dffCount,
            order: order,
            shift: testingName, 
            sin: inputName,
            sout: outputName
        )
        
        guard let metadataString = metadata.toJSON() else {
            fputs("Could not generate metadata string.", stderr)
            return EX_SOFTWARE
        }
    
        try File.open(intermediate, mode: .write) {
            try $0.print(Generator.visit(ast))
        }

        let script = Synthesis.script(
            for: definitionName,
            in: intermediate,
            checkHierarchy: false,
            liberty: libertyFile,
            output: output
        )

        // MARK: Yosys
        print("Resynthesizing with yosys…")
        let result = "echo '\(script)' | '\(yosysExecutable)' > /dev/null".sh()

        if result != EX_OK {
            fputs("A yosys error has occurred.\n", stderr)
            // let log = "fault_yosys_\(Int(Date().timeIntervalSince1970 * 1000)).log"
            // try File.open(log, mode: .write) {
            //     try $0.print(result.output)
            // }
            // fputs("Wrote yosys output to \(log)\n", stderr)
            return Int32(result)
        }

        guard let content = File.read(output) else {
            throw "Could not re-read created file."
        }

        try File.open(output, mode: .write) {
            try $0.print(String.boilerplate)
            try $0.print("/* FAULT METADATA: '\(metadataString)' END FAULT METADATA */")
            try $0.print(content)
        }

        // MARK: Verification
        if let model = verifyOpt.value {
            print("Verifying scan chain integrity…")
            let ast = parse([output])[0]
            let description = ast[dynamicMember: "description"]
            var definitionOptional: PythonObject?
            for definition in description.definitions {
                let type = Python.type(definition).__name__
                if type == "ModuleDef" {
                    definitionOptional = definition
                    break
                }
            }
            guard let definition = definitionOptional else {
                fputs("No module found.\n", stderr)
                return EX_DATAERR
            }
            let (ports, inputs, outputs) = try Port.extract(from: definition)

            let verified = try Simulator.simulate(
                verifying: definitionName,
                in: output, 
                with: model,
                ports: ports,
                inputs: inputs,
                outputs: outputs,
                dffCount: dffCount,
                clock: clockOpt.value!,
                reset: resetOpt.value!,
                resetActive: resetActiveLow.value ? .low : .high,
                testing: testingName,
                using: iverilogExecutable,
                with: vvpExecutable
            )
            print("done")
            if (verified) {
                print("Scan chain verified successfully.")
            } else {
                print("Scan chain verification failed.")
                print("・Ensure that clock and reset signals, if they exist are passed as such to the program.")
                if !resetActiveLow.value {
                    print("・Ensure that the reset is active high- pass --activeLow for activeLow.")
                }
                print("・Ensure that there are no other asynchronous resets anywhere in the circuit.")
            }
        }
        print("Done.")
    } catch {
        fputs("Internal software error: \(error)", stderr)
        return EX_SOFTWARE
    }

    return EX_OK
}