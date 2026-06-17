import Foundation

struct RuntimeContext {
    let rootDirectory: URL
    let presetsDirectory: URL
    let appRulesDirectory: URL
    let binaryURL: URL
    let prefURL: URL
}

struct RuntimeInstaller {
    func installIfNeeded() throws -> RuntimeContext {
        try AppPaths.ensureDirectories()

        let runtimeRoot = AppPaths.runtimeDirectory
        // The packaged (release) .app vendors subconverter's Homebrew dylibs into
        // Contents/Frameworks and rewrites the engine to load them via the rpath
        // `@loader_path/../Frameworks`. Because the engine is copied out to
        // <root>/runtime/subconverter, that rpath resolves to <root>/Frameworks, so
        // the dylibs must live there too. Debug builds instead link the engine
        // against absolute Homebrew paths and ship no Frameworks at all.
        //
        // These two layouts are mutually incompatible. The previous behaviour
        // decided what to refresh by file modification date, which let a stale
        // release engine survive next to a missing Frameworks dir — dyld then
        // failed to load libyaml-cpp and the engine exited before becoming ready.
        // To make drift impossible we stamp the runtime with a signature of the
        // current bundle's engine payload and rebuild the whole runtime from
        // scratch whenever it changes (app upgrade, engine rebuild, or a
        // Debug<->release switch).
        let frameworksDestination = AppPaths.rootDirectory.appendingPathComponent("Frameworks", isDirectory: true)
        let markerURL = runtimeRoot.appendingPathComponent(".payload-signature")
        let signature = currentPayloadSignature()

        if installedSignature(at: markerURL) != signature || !isRuntimeIntact(frameworksDestination: frameworksDestination) {
            AppLogger.log("Runtime payload changed or incomplete; rebuilding runtime from bundle.")
            try rebuildRuntime(runtimeRoot: runtimeRoot, frameworksDestination: frameworksDestination)
            try signature.write(to: markerURL, atomically: true, encoding: .utf8)
        }

        return RuntimeContext(
            rootDirectory: runtimeRoot,
            presetsDirectory: AppPaths.presetsDirectory,
            appRulesDirectory: runtimeRoot.appendingPathComponent("AppRules", isDirectory: true),
            binaryURL: runtimeRoot.appendingPathComponent("subconverter"),
            prefURL: runtimeRoot.appendingPathComponent("pref.toml")
        )
    }

    /// Identifies the engine payload shipped in the current app bundle. Includes the
    /// engine binary's size and modification date so a rebuilt engine — even one with
    /// an unchanged bundle version — forces a fresh install, and records whether this
    /// bundle vendors its dylibs (release) or relies on Homebrew (Debug).
    private func currentPayloadSignature() -> String {
        let version = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        var parts = ["v\(version)"]
        if let engine = Bundle.main.resourceURL?.appendingPathComponent("subconverter"),
           let attributes = try? FileManager.default.attributesOfItem(atPath: engine.path) {
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            parts.append("engine:\(size):\(Int(mtime))")
        }
        parts.append(bundleHasVendoredFrameworks() ? "vendored" : "homebrew")
        return parts.joined(separator: "|")
    }

    private func installedSignature(at markerURL: URL) -> String? {
        guard let value = try? String(contentsOf: markerURL, encoding: .utf8) else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A matching signature normally means the runtime is good, but this guards the
    /// exact dyld failure directly: a vendored (release) engine is useless without its
    /// `<root>/Frameworks` dylibs, and the engine binary must exist at all.
    private func isRuntimeIntact(frameworksDestination: URL) -> Bool {
        let manager = FileManager.default
        let engine = AppPaths.runtimeDirectory.appendingPathComponent("subconverter")
        guard manager.fileExists(atPath: engine.path) else {
            return false
        }
        if bundleHasVendoredFrameworks(), !manager.fileExists(atPath: frameworksDestination.path) {
            return false
        }
        return true
    }

    private func bundleHasVendoredFrameworks() -> Bool {
        guard let source = Bundle.main.privateFrameworksURL,
              FileManager.default.fileExists(atPath: source.path) else {
            return false
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
        return !contents.isEmpty
    }

    /// Wipes and recreates the runtime (and vendored Frameworks) so the engine and its
    /// dylibs are always a faithful copy of the current bundle. Sibling state
    /// (imports/, logs/, state.json) is left untouched.
    private func rebuildRuntime(runtimeRoot: URL, frameworksDestination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: runtimeRoot.path) {
            try manager.removeItem(at: runtimeRoot)
        }
        if manager.fileExists(atPath: frameworksDestination.path) {
            try manager.removeItem(at: frameworksDestination)
        }
        try manager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try manager.createDirectory(at: AppPaths.presetsDirectory, withIntermediateDirectories: true)

        try copyFrameworksIfPresent(to: frameworksDestination)
        try copyBundleResource(named: "subconverter", to: runtimeRoot.appendingPathComponent("subconverter"), executable: true)
        try copyBundleFolder(named: "base", to: runtimeRoot.appendingPathComponent("base"))
        try copyBundleFolder(named: "rules", to: runtimeRoot.appendingPathComponent("rules"))
        try copyBundleFolder(named: "snippets", to: runtimeRoot.appendingPathComponent("snippets"))
        try copyBundleFolder(named: "AppRules", to: runtimeRoot.appendingPathComponent("AppRules"))
        try writePrefTemplate(to: runtimeRoot.appendingPathComponent("pref.toml"))
    }

    private func copyFrameworksIfPresent(to destination: URL) throws {
        // Debug builds run against Homebrew dylibs on the dev machine and ship no
        // vendored Frameworks directory, so this is a no-op when absent.
        guard let source = Bundle.main.privateFrameworksURL,
              FileManager.default.fileExists(atPath: source.path) else {
            return
        }

        try forceCopy(source: source, destination: destination)
    }

    private func copyBundleFolder(named name: String, to destination: URL) throws {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent(name, isDirectory: true) else {
            throw RuntimeInstallerError.missingBundleResource(name)
        }

        try forceCopy(source: source, destination: destination)
    }

    private func copyBundleResource(named name: String, to destination: URL, executable: Bool) throws {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent(name) else {
            throw RuntimeInstallerError.missingBundleResource(name)
        }

        try forceCopy(source: source, destination: destination)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
    }

    /// Copies `source` onto `destination`, replacing any existing item. Unlike the old
    /// modification-date heuristic this never leaves a stale copy in place — callers
    /// rebuild onto a freshly wiped runtime, so the result is always current.
    private func forceCopy(source: URL, destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
    }

    private func writePrefTemplate(to destination: URL) throws {
        let content = """
        version = 1
        [common]
        api_mode = false
        reload_conf_on_request = false
        default_url = []
        enable_insert = false
        insert_url = [""]
        prepend_insert_url = true
        base_path = "base"
        clash_rule_base = "base/all_base.tpl"
        surge_rule_base = "base/all_base.tpl"
        surfboard_rule_base = "base/all_base.tpl"
        mellow_rule_base = "base/all_base.tpl"
        quan_rule_base = "base/all_base.tpl"
        quanx_rule_base = "base/all_base.tpl"
        loon_rule_base = "base/all_base.tpl"
        sssub_rule_base = "base/all_base.tpl"
        singbox_rule_base = "base/all_base.tpl"
        proxy_config = "NONE"
        proxy_ruleset = "NONE"
        proxy_subscription = "NONE"
        append_proxy_type = false

        [node_pref]
        append_sub_userinfo = false
        filter_deprecated_nodes = false
        clash_use_new_field_name = true
        clash_proxies_style = "flow"
        clash_proxy_groups_style = "block"
        singbox_add_clash_modes = true

        [managed_config]
        write_managed_config = false
        managed_config_prefix = "http://127.0.0.1:25500"
        config_update_interval = 0
        config_update_strict = false
        quanx_device_id = ""

        [surge_external_proxy]
        resolve_hostname = true

        [emojis]
        add_emoji = false
        remove_old_emoji = false

        [ruleset]
        enabled = true
        overwrite_original_rules = false
        update_ruleset_on_request = false

        [template]
        template_path = ""

        [server]
        listen = "127.0.0.1"
        port = 25500

        [advanced]
        log_level = "info"
        print_debug_info = false
        max_pending_connections = 10
        max_concurrent_threads = 4
        max_allowed_rulesets = 64
        max_allowed_rules = 32768
        max_allowed_download_size = 1048576
        enable_cache = false
        cache_subscription = 0
        cache_config = 0
        cache_ruleset = 0
        script_clean_context = false
        async_fetch_ruleset = false
        skip_failed_links = false
        """

        try content.write(to: destination, atomically: true, encoding: .utf8)
    }
}

enum RuntimeInstallerError: LocalizedError {
    case missingBundleResource(String)

    var errorDescription: String? {
        switch self {
        case .missingBundleResource(let name):
            return "Missing bundled runtime resource: \(name)."
        }
    }
}
