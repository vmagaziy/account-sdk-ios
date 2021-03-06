//
// Copyright 2011 - 2020 Schibsted Products & Technology AS.
// Licensed under the terms of the MIT license. See LICENSE in the project root.
//

import Foundation

private extension DispatchTime {
    var elapsed: Double {
        let nanoTime = DispatchTime.now().uptimeNanoseconds - uptimeNanoseconds
        return Double(nanoTime) / 1_000_000
    }
}

/**
 A logging class that can be told where to log to via transports.

 Features include:
 - Asynchronous, ordered output to transports
 - All log messages can be tagged and filtered
 - `LogLevel`s are provided as well
 - Force logging enables output via `print` even if no transports available

 ## Filtering

 Two methods exist to allow for filtering of the log stream.

 - `Logger.filterUnless(tag:)`
 - `Logger.filterIf(tag:)`

 */
public class Logger {
    /// Shared logger object
    public static let shared = Logger(label: "# SchAccount: ")

    private let startTime = DispatchTime.now()
    private let queue = DispatchQueue(label: "com.schibsted.identity.Logger", qos: .utility)
    private let dispatchGroup = DispatchGroup()

    private var _enabled: Bool = true
    private var _outputTags: Bool = false
    private var transports: [(String) -> Void] = []
    private var allowedTags = Set<String>()
    private var ignoredTags = Set<String>()
    private let label: String

    /**
     Initializes a Logger object
     */
    public init(label: String? = nil) {
        self.label = label ?? ""
    }

    /**
     Transports are called asynchronously, if you need to wait till all logging output has been sent to
     all transports then this function blocks until that happens
     */
    public func waitTillAllLogsTransported() {
        dispatchGroup.wait()
    }

    /// Set to true if you want the tags to be printed as well
    public var outputTags: Bool {
        get {
            return queue.sync {
                self._outputTags
            }
        }
        set {
            queue.async { [weak self] in
                self?._outputTags = newValue
            }
        }
    }

    /// If this is false then it ignores all logs
    public var enabled: Bool {
        get {
            return queue.sync {
                self._enabled
            }
        }
        set {
            queue.async { [weak self] in
                self?._enabled = newValue
            }
        }
    }

    /**
     Adding a transport allows you to tell the logger where the output goes to. You may add as
     many as you like.

     - parameter transport: function that is called with each log invocaton
     */
    public func addTransport(_ transport: @escaping (String) -> Void) {
        queue.async { [weak self] in
            self?.transports.append(transport)
        }
    }

    /// Removes all transports
    public func removeTransports() {
        queue.async { [weak self] in
            self?.transports.removeAll()
        }
    }

    /// Filters log messages unless they are tagged with `tag`
    public func filterUnless(tag: String) {
        queue.async { [weak self] in
            self?.allowedTags.insert(tag)
        }
    }

    /// Filters log messages unless they are tagged with any of `tags`
    public func filterUnless(tags: [String]) {
        queue.async { [weak self] in
            if let union = self?.allowedTags.union(tags) {
                self?.allowedTags = union
            }
        }
    }

    /// Filters log messages if they are tagged with `tag`
    public func filterIf(tag: String) {
        queue.async { [weak self] in
            self?.ignoredTags.insert(tag)
        }
    }

    /// Filters log messages if they are tagged with any of `tags`
    public func filterIf(tags: [String]) {
        queue.async { [weak self] in
            if let union = self?.ignoredTags.union(tags) {
                self?.ignoredTags = union
            }
        }
    }

    func log<T>(
        level: LogLevel = .info,
        _ object: @autoclosure () -> T,
        tag: String,
        force: Bool = false,
        _ file: String = #file,
        _ function: String = #function,
        _ line: Int = #line
    ) {
        log(level: level, object, tags: [tag], force: force, file, function, line)
    }

    func log<T, S>(
        level: LogLevel = .info,
        from _: S?,
        _ object: @autoclosure () -> T,
        tags: [String] = [],
        force: Bool = false,
        _ file: String = #file,
        _ function: String = #function,
        _ line: Int = #line
    ) {
        log(
            level: level,
            object: object,
            tags: tags,
            force: force,
            context: String(describing: S.self),
            file: file,
            function: function,
            line: line
        )
    }

    func log<T>(
        level: LogLevel = .info,
        _ object: @autoclosure () -> T,
        tags: [String] = [],
        force: Bool = false,
        _ file: String = #file,
        _ function: String = #function,
        _ line: Int = #line
    ) {
        log(
            level: level,
            object: object,
            tags: tags,
            force: force,
            context: nil,
            file: file,
            function: function,
            line: line
        )
    }

    private func log<T>(
        level: LogLevel = .info,
        object: @autoclosure () -> T,
        tags explicitTags: [String] = [],
        force: Bool,
        context: String?,
        file: String,
        function: String,
        line: Int
    ) {
        #if !DEBUG
            guard level != .debug else {
                return
            }
        #endif

        let thread = Thread.isMainThread ? "UI" : "BG"
        let threadID = pthread_mach_thread_np(pthread_self())
        let timestamp = startTime.elapsed
        let string = "\(object())"

        dispatchGroup.enter()
        queue.async {
            self.synclog(
                thread: thread,
                threadID: threadID,
                timestamp: timestamp,
                level: level,
                string: string,
                tags: explicitTags,
                force: force,
                file: file,
                function: function,
                line: line,
                context: context
            )
            self.dispatchGroup.leave()
        }
    }

    private func synclog(
        thread: String,
        threadID: mach_port_t,
        timestamp: Double,
        level: LogLevel = .info,
        string: String,
        tags explicitTags: [String] = [],
        force: Bool = false,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        context: String?
    ) {
        guard (_enabled && transports.count > 0) || force else {
            return
        }

        let functionName = function.components(separatedBy: "(").first ?? ""
        let fileName: String = {
            let name = URL(fileURLWithPath: file)
                .deletingPathExtension().lastPathComponent
            let value = name.isEmpty ? "Unknown file" : name
            return value
        }()

        var allTags = [functionName, thread, fileName, level.rawValue]
        allTags.append(contentsOf: explicitTags)
        if let context = context {
            allTags.append(context)
        }

        var shouldOutputToTransports = true
        if ignoredTags.count > 0 && ignoredTags.intersection(allTags).count > 0 {
            shouldOutputToTransports = false
        }

        if allowedTags.count > 0 && allowedTags.intersection(allTags).count == 0 {
            shouldOutputToTransports = false
        }

        guard shouldOutputToTransports || force else {
            return
        }

        var tagsString = ""
        if explicitTags.count > 0, _outputTags {
            tagsString = ",\(explicitTags.joined(separator: ","))"
        }

        let output = "\(label)[\(level.rawValue):\(String(format: "%.2f", timestamp))]"
            + "[\(thread):\(threadID),\(fileName):\(line),\(functionName)\(tagsString)]"
            + " => \(string)"

        if shouldOutputToTransports {
            for transport in transports {
                transport(output)
            }
        }

        if force {
            print(output)
        }
    }
}
