import Foundation
import xcproj
import PathKit
import Yams
import SourceryRuntime

struct Project {
    let file: XcodeProj
    let root: Path
    let targets: [Target]
    let exclude: [Path]

    let name: String
    private(set) var output: Output?
    private(set) var dependencies: [Project] = []

    struct Target {
        let name: String
        let module: String

        init(dict: [String: String]) throws {
            guard let name = dict["name"] else {
                throw Configuration.Error.invalidSources(message: "Target name is not provided. Expected string.")
            }
            self.name = name
            self.module = dict["module"] ?? name
        }
    }

    init(dict: [String: Any], relativePath: Path) throws {
        guard let file = dict["file"] as? String else {
            throw Configuration.Error.invalidSources(message: "Project file path is not provided. Expected string.")
        }

        let targetsArray: [Target]
        if let targets = dict["target"] as? [[String: String]] {
            targetsArray = try targets.map({ try Target(dict: $0) })
        } else if let target = dict["target"] as? [String: String] {
            targetsArray = try [Target(dict: target)]
        } else {
            throw Configuration.Error.invalidSources(message: "'target' key is missing. Expected object or array of objects.")
        }
        guard !targetsArray.isEmpty else {
            throw Configuration.Error.invalidSources(message: "No targets provided.")
        }
        self.targets = targetsArray

        let exclude = (dict["exclude"] as? [String])?.map({ Path($0, relativeTo: relativePath) }) ?? []
        self.exclude = exclude.flatMap { $0.allPaths }

        let path = Path(file, relativeTo: relativePath)
        self.file = try XcodeProj(path: path)
        self.root = path.parent()

        self.name = dict["name"] as? String ?? ""
    }

    mutating func update(withDependencies dependencies: [Project]) {
        self.dependencies.append(contentsOf: dependencies)
    }

    mutating func update(withOutput output: Output) {
        self.output = output
    }
}

struct Paths {
    let include: [Path]
    let exclude: [Path]
    let allPaths: [Path]

    var isEmpty: Bool {
        return allPaths.isEmpty
    }

    init(dict: Any, relativePath: Path) throws {
        if let sources = dict as? [String: [String]],
            let include = sources["include"]?.map({ Path($0, relativeTo: relativePath) }) {

            let exclude = sources["exclude"]?.map({ Path($0, relativeTo: relativePath) }) ?? []
            self.init(include: include, exclude: exclude)
        } else if let sources = dict as? [String] {

            let sources = sources.map({ Path($0, relativeTo: relativePath) })
            guard !sources.isEmpty else {
                throw Configuration.Error.invalidPaths(message: "No paths provided.")
            }
            self.init(include: sources)
        } else {
            throw Configuration.Error.invalidPaths(message: "No paths provided. Expected list of strings or object with 'include' and optional 'exclude' keys.")
        }
    }

    init(include: [Path], exclude: [Path] = []) {
        self.include = include
        self.exclude = exclude

        let include = self.include.flatMap { $0.allPaths }
        let exclude = self.exclude.flatMap { $0.allPaths }

        self.allPaths = Array(Set(include).subtracting(Set(exclude))).sorted()
    }

}

enum Source {
    case projects([Project])
    case sources(Paths)

    var isEmpty: Bool {
        switch self {
        case let .sources(paths):
            return paths.allPaths.isEmpty
        case let .projects(projects):
            return projects.isEmpty
        }
    }

    static func create(with dict: [String: Any], relativePath: Path) throws -> Source {
        if let projects = (dict["project"] as? [[String: Any]]) ?? (dict["project"] as? [String: Any]).map({ [$0] }) {
            return try self.create(withProjects: projects, relativePath: relativePath)
        } else if let sources = dict["sources"] {
            return try self.create(withSources: sources, relativePath: relativePath)
        } else {
            throw Configuration.Error.invalidSources(message: "'sources' or 'project' key are missing.")
        }
    }

    private static func create(withProjects projects: [[String: Any]], relativePath: Path) throws -> Source {
        guard !projects.isEmpty else { throw Configuration.Error.invalidSources(message: "No projects provided.") }
        let useDependencies = projects.contains(where: { $0["dependencies"] != nil })
        let useSeparatedOutputs = projects.contains(where: { $0["output"] != nil })
        let projectsObjects: [Project]
        if useDependencies {
            let names = projects.compactMap({ $0["name"] as? String })
            guard names.count == projects.count else {
                throw Configuration.Error.invalidSources(message: "In order to use dependencies all project configurations should contain name property.")
            }
            guard Set(names).count == projects.count else {
                throw Configuration.Error.invalidSources(message: "In order to use dependencies all project configurations should use unique name.")
            }
            let dependencies = projects.map({ ($0["dependencies"] as? [String]) ?? [] })
            let dependenciesMap = Dictionary(uniqueKeysWithValues: zip(names, dependencies))
            let projectsMap = try projects.reduce([:], { (res, project) -> [String: Project] in
                let project = try Project(dict: project, relativePath: relativePath)
                return res.merging([project.name: project]) { (current, _) in current }
            })
            try names.forEach { (projectName) in
                var unresolved = Set<String>()
                var resolved = Set<String>()
                try checkCircularDependencies(for: projectName, projectsMap: projectsMap, dependenciesMap: dependenciesMap, unresolved: &unresolved, resolved: &resolved)
            }
            names.forEach { (projectName) in
                let dependencies = dependenciesMap[projectName]
                var project = projectsMap[projectName]
                project?.update(withDependencies: dependencies?.compactMap({ projectsMap[$0] }) ?? [])
            }
            if useSeparatedOutputs {
                // TODO: update outputs per each project
            }
            projectsObjects = Array(projectsMap.values)
        } else {
            projectsObjects = try projects.map({ try Project(dict: $0, relativePath: relativePath) })
        }
        return .projects(projectsObjects)
    }

    private static func checkCircularDependencies(for projectName: String, projectsMap: [String: Project], dependenciesMap: [String: [String]], unresolved: inout Set<String>, resolved: inout Set<String>) throws {
        unresolved.insert(projectName)
        try dependenciesMap[projectName]?.forEach({ (dependency) in
            if !resolved.contains(dependency) {
                if unresolved.contains(dependency) {
                    throw Configuration.Error.invalidSources(message: "Circular dependencies found for the \(projectName).")
                }
                try checkCircularDependencies(for: dependency, projectsMap: projectsMap, dependenciesMap: dependenciesMap, unresolved: &unresolved, resolved: &resolved)
            }
        })
        resolved.insert(projectName)
        unresolved.remove(projectName)
    }

    private static func create(withSources sources: Any, relativePath: Path) throws -> Source {
        do {
            return try .sources(Paths(dict: sources, relativePath: relativePath))
        } catch {
            throw Configuration.Error.invalidSources(message: "\(error)")
        }
    }
}

struct Output {
    struct LinkTo {
        let project: XcodeProj
        let projectPath: Path
        let target: String
        let group: String?

        init(dict: [String: Any], relativePath: Path) throws {
            guard let project = dict["project"] as? String else {
                throw Configuration.Error.invalidOutput(message: "No project file path provided.")
            }
            guard let target = dict["target"] as? String else {
                throw Configuration.Error.invalidOutput(message: "No target name provided.")
            }
            let projectPath = Path(project, relativeTo: relativePath)
            self.projectPath = projectPath
            self.project = try XcodeProj(path: projectPath)
            self.target = target
            self.group = dict["group"] as? String
        }

        init(project: Project, dict: [String: Any], relativePath: Path) throws {
            guard let target = dict["target"] as? String else {
                throw Configuration.Error.invalidOutput(message: "No target name provided.")
            }
            self.projectPath = project.root
            self.project = project.file
            self.target = target
            self.group = dict["group"] as? String
        }
    }

    let path: Path
    let linkTo: LinkTo?

    var isDirectory: Bool {
        guard path.exists else {
            return path.lastComponentWithoutExtension == path.lastComponent || path.string.hasSuffix("/")
        }
        return path.isDirectory
    }

    init(dict: [String: Any], relativePath: Path) throws {
        guard let path = dict["path"] as? String else {
            throw Configuration.Error.invalidOutput(message: "No path provided.")
        }

        self.path = Path(path, relativeTo: relativePath)

        if let linkToDict = dict["link"] as? [String: Any] {
            self.linkTo = try? LinkTo(dict: linkToDict, relativePath: relativePath)
        } else {
            self.linkTo = nil
        }
    }

    init(_ path: Path, linkTo: LinkTo? = nil) {
        self.path = path
        self.linkTo = linkTo
    }

}

struct Configuration {

    enum Error: Swift.Error, CustomStringConvertible {
        case invalidFormat(message: String)
        case invalidSources(message: String)
        case invalidTemplates(message: String)
        case invalidOutput(message: String)
        case invalidCacheBasePath(message: String)
        case invalidPaths(message: String)

        var description: String {
            switch self {
            case .invalidFormat(let message):
                return "Invalid config file format. \(message)"
            case .invalidSources(let message):
                return "Invalid sources. \(message)"
            case .invalidTemplates(let message):
                return "Invalid templates. \(message)"
            case .invalidOutput(let message):
                return "Invalid output. \(message)"
            case .invalidCacheBasePath(let message):
                return "Invalid cacheBasePath. \(message)"
            case .invalidPaths(let message):
                return "\(message)"
            }
        }
    }

    let source: Source
    let templates: Paths
    let output: Output
    let cacheBasePath: Path
    let forceParse: [String]
    let args: [String: NSObject]

    init(path: Path, relativePath: Path) throws {
        guard let dict = try Yams.load(yaml: path.read()) as? [String: Any] else {
            throw Configuration.Error.invalidFormat(message: "Expected dictionary.")
        }

        try self.init(dict: dict, relativePath: relativePath)
    }

    init(dict: [String: Any], relativePath: Path) throws {
        let source = try Source.create(with: dict, relativePath: relativePath)
        guard !source.isEmpty else {
            throw Configuration.Error.invalidSources(message: "No sources provided.")
        }
        self.source = source

        let templates: Paths
        guard let templatesDict = dict["templates"] else {
            throw Configuration.Error.invalidTemplates(message: "'templates' key is missing.")
        }
        do {
            templates = try Paths(dict: templatesDict, relativePath: relativePath)
        } catch {
            throw Configuration.Error.invalidTemplates(message: "\(error)")
        }
        guard !templates.isEmpty else {
            throw Configuration.Error.invalidTemplates(message: "No templates provided.")
        }
        self.templates = templates

        self.forceParse = dict["force-parse"] as? [String] ?? []

        if let output = dict["output"] as? String {
            self.output = Output(Path(output, relativeTo: relativePath))
        } else if let output = dict["output"] as? [String: Any] {
            self.output = try Output(dict: output, relativePath: relativePath)
        } else {
            throw Configuration.Error.invalidOutput(message: "'output' key is missing or is not a string or object.")
        }

        if let cacheBasePath = dict["cacheBasePath"] as? String {
            self.cacheBasePath = Path(cacheBasePath, relativeTo: relativePath)
        } else if dict["cacheBasePath"] != nil {
            throw Configuration.Error.invalidCacheBasePath(message: "'cacheBasePath' key is not a string.")
        } else {
            self.cacheBasePath = Path.defaultBaseCachePath
        }

        self.args = dict["args"] as? [String: NSObject] ?? [:]
    }

    init(sources: Paths, templates: Paths, output: Path, cacheBasePath: Path, forceParse: [String], args: [String: NSObject]) {
        self.source = .sources(sources)
        self.templates = templates
        self.output = Output(output, linkTo: nil)
        self.cacheBasePath = cacheBasePath
        self.forceParse = forceParse
        self.args = args
    }

}
