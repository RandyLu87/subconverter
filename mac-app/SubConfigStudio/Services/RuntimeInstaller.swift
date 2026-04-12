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
        try copyBundleResource(named: "subconverter", to: runtimeRoot.appendingPathComponent("subconverter"), executable: true)
        try copyBundleFolder(named: "base", to: runtimeRoot.appendingPathComponent("base"))
        try copyBundleFolder(named: "rules", to: runtimeRoot.appendingPathComponent("rules"))
        try copyBundleFolder(named: "snippets", to: runtimeRoot.appendingPathComponent("snippets"))
        try copyBundleFolder(named: "AppRules", to: runtimeRoot.appendingPathComponent("AppRules"))

        let prefURL = runtimeRoot.appendingPathComponent("pref.toml")
        try writePrefTemplate(to: prefURL)

        return RuntimeContext(
            rootDirectory: runtimeRoot,
            presetsDirectory: AppPaths.presetsDirectory,
            appRulesDirectory: runtimeRoot.appendingPathComponent("AppRules", isDirectory: true),
            binaryURL: runtimeRoot.appendingPathComponent("subconverter"),
            prefURL: prefURL
        )
    }

    private func copyBundleFolder(named name: String, to destination: URL) throws {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent(name, isDirectory: true) else {
            throw RuntimeInstallerError.missingBundleResource(name)
        }

        try replaceItemIfNeeded(source: source, destination: destination, isDirectory: true)
    }

    private func copyBundleResource(named name: String, to destination: URL, executable: Bool) throws {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent(name) else {
            throw RuntimeInstallerError.missingBundleResource(name)
        }

        try replaceItemIfNeeded(source: source, destination: destination, isDirectory: false)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
    }

    private func replaceItemIfNeeded(source: URL, destination: URL, isDirectory: Bool) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            let sourceDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let destinationDate = (try? destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if destinationDate >= sourceDate {
                return
            }

            try manager.removeItem(at: destination)
        }

        if isDirectory {
            try manager.copyItem(at: source, to: destination)
        } else {
            try manager.copyItem(at: source, to: destination)
        }
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
