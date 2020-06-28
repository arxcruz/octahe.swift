//
//  File.swift
//  
//
//  Created by Kevin Carter on 6/25/20.
//

import Foundation

import Shout

class ExecuteSSH: Execution {
    var ssh: SSH?
    var server: String = "localhost"
    var port: String = "22"

    override init(cliParameters: OctaheCLI.Options, processParams: ConfigParse) {
        super.init(cliParameters: cliParameters, processParams: processParams)
    }

    override func connect() throws {
        let cssh = try SSH(host: self.server, port: self.port.toInt)
        cssh.ptyType = .vanilla
        if let privatekey = self.cliParams.connectionKey {
            try cssh.authenticate(username: self.user, privateKey: privatekey)
        } else {
            try cssh.authenticateByAgent(username: self.user)
        }

        self.ssh = cssh
    }

    private func outputStrip(output: String) -> String {
        return output.lowercased().strip
    }

    override func probe() throws {
        //    TARGETPLATFORM - platform of the build result. Eg linux/amd64, linux/arm/v7, windows/amd64.
        //    TARGETOS - OS component of TARGETPLATFORM
        //    TARGETARCH - architecture component of TARGETPLATFORM
        let unameLookup = ["x86_64": "amd64", "armv7l": "arm/v7", "armv8l": "arm/v8"]
        let output = try self.runReturn(execute: "uname -ms; systemctl --version; echo ${PATH}")
        let lowerOutput = outputStrip(output: output).components(separatedBy: "\n")
        let targetVars = lowerOutput.first!.components(separatedBy: " ")
        let kernel = self.outputStrip(output: targetVars.first!)
        let archRaw = self.outputStrip(output: targetVars.last!)
        let arch = unameLookup[archRaw] ?? "unknown"
        let systemd = lowerOutput[1].components(separatedBy: " ")
        self.environment["TARGETOS"] = kernel
        self.environment["TARGETARCH"] = arch
        self.environment["TARGETPLATFORM"] = "\(kernel)/\(arch)"
        self.environment["SYSTEMD_VERSION"] = self.outputStrip(output: systemd.last!)
        self.environment["PATH"] = outputStrip(output: lowerOutput.last!)
    }

    override func copyRun(toUrl: URL, fromUrl: URL, toFile: URL) throws -> String {
        do {
            try self.ssh!.sendFile(localURL: fromUrl, remotePath: toUrl.path)
            return toUrl.path
        } catch {
            try self.ssh!.sendFile(localURL: fromUrl, remotePath: toFile.path)
            return toFile.path
        }
    }

    override func chown(perms: String?, path: String) throws {
        if let chownSettings = perms {
            try run(execute: "chown \(chownSettings) \(path)")
        }
    }

    override func run(execute: String) throws {
        _ = try self.runReturn(execute: execute)
    }

    override func runReturn(execute: String) throws -> String {
        // NOTE This is not ideal, I wishthere was a better way to leverage an
        // environment setup prior to executing a command which didn't require
        // server side configuration, however, it does so here we are.
        let preparedExec = self.execString(command: execute)
        var envVars: [String] = []
        for (key, value) in self.environment {
            envVars.append("export \(key)=\(value);")
        }
        let preparedCommand = "\(envVars.joined(separator: " ")) \(preparedExec)"
        let (status, output) = try self.ssh!.capture(preparedCommand)
        if status != 0 {
            throw RouterError.failedExecution(message: "FAILED execution: \(output)")
        }
        return output
    }

    override func mkdir(workdirURL: URL) throws {
        try run(execute: "mkdir -p \(workdirURL.path)")
    }

    override func serviceTemplate(entrypoint: String) throws {
        if self.environment.keys.contains("SYSTEMD_VERSION") {
            try super.serviceTemplate(entrypoint: entrypoint)
        } else {
            throw RouterError.notImplemented(
                message: """
                         Service templating is not currently supported on non-linux operating systems without systemd.
                         """
            )
        }
    }
}
