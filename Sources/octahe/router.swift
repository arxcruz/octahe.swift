//
//  mixin.swift
//
//
//  Created by Kevin Carter on 6/4/20.
//

import Foundation

import Spinner

let taskQueue = TaskOperations()

let targetQueue = TargetOperations()

let inspectionQueue = InspectionOperations()

enum RouterError: Error {
    case notImplemented(message: String)
    case failedExecution(message: String)
    case failedUnknown
}

final class Router {
    let parsedOptions: OctaheCLI.Options
    let function: ExecutionStates
    let octaheArgs: ConfigParse
    let tempSshConfigFile: URL
    var octaheSteps: Int = 0

    init(parsedOptions: OctaheCLI.Options, function: ExecutionStates) throws {
        self.parsedOptions = parsedOptions
        self.function = function

        let configFileURL = URL(fileURLWithPath: self.parsedOptions.configurationFiles.first!)
        self.octaheArgs = try ConfigParse(
            parsedOptions: self.parsedOptions,
            configDirURL: configFileURL.deletingLastPathComponent()
        )
        self.tempSshConfigFile = try localTempFile(content: self.parsedOptions.configurationFiles.first!)
        self.octaheArgs.octaheSshConfigFile = self.tempSshConfigFile
    }

    private func cliFinish() -> Int32 {
        let failedTargets = targetQueue.targetRecords.values.filter {$0.state == .failed}
        var exitCode: Int32 = 0
        var message: TypeLogString
        switch failedTargets.count {
        case self.octaheArgs.octaheTargetsCount:
            message = "Execution Failed."
            logger.critical("\(message)")
            exitCode = 2
        case _ where failedTargets.count > 0:
            message = "Execution Degraded."
            logger.warning("\(message)")
            exitCode = 1
        default:
            message = "Success."
            logger.info("\(message)")
        }
        print("\n\(message)\n")

        for degradedTarget in failedTargets {
            message = "\(degradedTarget.target.name) - failed step \(degradedTarget.failedStep!)/\(self.octaheSteps)"
            defer {
                print(
                    """
                    [-] \(message)
                        \(degradedTarget.failedTask!)
                    """
                )
            }
            logger.error("\(message) -- \(degradedTarget.failedTask!)")
        }
        let successTargets = targetQueue.targetRecords.values.filter {$0.state == .available}.count
        if successTargets > 0 {
            print("[+] Successful operation on \(successTargets) targets")
        }
        return exitCode
    }

    private func processFrom() throws {
        throw RouterError.notImplemented(message: "FROM is not implemented yet.")
        logger.info("Found FROM information, pulling in instructions from external Targetfiles")
        for from in self.octaheArgs.octaheFrom {
            logger.info("Parsing \(from)")
            let fromComponents = from.components(separatedBy: ":")
            let image = fromComponents.first
            var tag: String = "latest"
            if fromComponents.last != image {
                tag = fromComponents.last!
            }
            // inspectionQueue.inspectionQueue.addOperation(
            //     InspectionOperationQuay(
            //         containerImage: image!,
            //         tag: tag,
            //         debug: parsedOptions.debug
            //     )
            // )
        }
        inspectionQueue.inspectionQueue.waitUntilAllOperationsAreFinished()
        for (_, value) in inspectionQueue.inspectionInComplete {
            let deployOptions = value.filter {key, _ in
                return ["RUN", "SHELL", "ARG", "ENV", "USER", "INTERFACE", "EXPOSE", "WORKDIR", "LABEL"].contains(key)
            }
            for deployOption in deployOptions.reversed() {
                self.octaheArgs.octaheDeploy.insert(try self.octaheArgs.deploymentCases(deployOption), at: 0)
            }
            logger.info("Adding \(deployOptions.count) instructions into the deployment")
        }
    }

    private func nonLocalHosts() throws {
        var sshViaData: [[String: Any]] = []
        var controlPathSockets: URL = URL(fileURLWithPath: NSHomeDirectory())
        controlPathSockets = controlPathSockets.appendingPathComponent(".ssh/octahe", isDirectory: true)
        do {
            try localMkdir(workdirURL: controlPathSockets)
        } catch {
            controlPathSockets = URL(fileURLWithPath: NSTemporaryDirectory())
            controlPathSockets = controlPathSockets.appendingPathComponent("octahe", isDirectory: true)
            try localMkdir(workdirURL: controlPathSockets)
        }

        for item in self.octaheArgs.octaheTargetHash.values {
            logger.info("Parsing \(item.name)")
            var itemData: [String: Any] = [:]
            itemData["name"] = item.name.sha1
            itemData["server"] = item.domain
            itemData["port"] = item.port ?? 22
            itemData["user"] = item.user ?? "root"
            itemData["key"] = item.key?.path ?? parsedOptions.connectionKey
            if let keyFile = itemData["key"] {
                logger.debug("User defined key-file: \(keyFile)")
            }
            itemData["socketPath"] = controlPathSockets.appendingPathComponent(item.name.sha1, isDirectory: false).path
            if let via = item.viaName {
                itemData["config"] = self.tempSshConfigFile.path
                itemData["via"] = via.sha1
            }
            sshViaData.append(itemData)
        }
        try sshRender(data: ["targets": sshViaData]).write(
            to: self.tempSshConfigFile,
            atomically: true,
            encoding: String.Encoding.utf8
        )
    }

    private func queueTasks() {
        // Modify the default quota set using our CLI args.
        targetQueue.maxConcurrentOperationCount = parsedOptions.connectionQuota
        var allTaskOperations: [TaskOperation] = []
        for (index, deployItem) in self.octaheArgs.octaheDeploy.enumerated() {
            logger.info("Queuing task: \(index) - \(deployItem.value.original)")
            let taskOperation = TaskOperation(
                deployItem: deployItem,
                steps: self.octaheSteps,
                stepIndex: index,
                args: self.octaheArgs,
                options: parsedOptions,
                function: function,
                printStatus: !parsedOptions.debug
            )
            allTaskOperations.append(taskOperation)
        }
        taskQueue.taskQueue.addOperations(allTaskOperations, waitUntilFinished: true)
        logger.info("All queued tasks have been completed.")
    }

    private func taskRouter() throws -> Int32 {
        defer {
            logger.debug("Removing ssh temp file: \(self.tempSshConfigFile.path)")
            try? FileManager.default.removeItem(at: self.tempSshConfigFile)
        }

        switch parsedOptions.debug {
        case true:
            logger.logLevel = .trace
        default:
            logger.logLevel = .critical
        }
        logger.debug("Running function: \(function)")

        if self.octaheArgs.octaheFrom.count > 0 {
            try self.processFrom()
        }

        if self.octaheArgs.octaheTargetHash.values.filter({$0.name != "localhost"}).count > 0 {
            try self.nonLocalHosts()
        }

        guard self.octaheArgs.octaheDeploy.count > 0 else {
            let configFiles = parsedOptions.configurationFiles.joined(separator: " ")
            let message = "No steps found within provided Containerfiles: \(configFiles)"
            logger.error("\(message)")
            throw RouterError.failedExecution(message: String(describing: message))
        }

        switch function {
        case .undeploy:
            logger.info("Undeployment mode engaged.")
            let deployOptions =  self.octaheArgs.octaheDeploy.filter {key, _ in
                return ["ENTRYPOINT", "EXPOSE", "INTERFACE"].contains(key)
            }
            var undeploy: [(key: String, value: TypeDeploy)] = []
            for deployItem in deployOptions {
                undeploy.append(deployItem)
            }
            self.octaheArgs.octaheDeploy = undeploy
        default:
            logger.info("Deployment mode engaged.")
        }

        // The total calculated steps start at 0, so we take the total and subtract 1.
        self.octaheSteps = self.octaheArgs.octaheDeploy.count - 1
        self.queueTasks()
        return cliFinish()
    }

    public func main() throws {
        let exitCode = try self.taskRouter()
        exit(exitCode)
    }
}
