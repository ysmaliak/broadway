import Foundation

enum Completions {
    static let fish = """
    # broadway completions, written by broadway setup
    complete -c broadway -f -a '(broadway __complete (commandline -opc)[2..-1] -- (commandline -ct))'

    """

    static let zsh = """
    # broadway completions, written by broadway setup
    _broadway() {
      local line
      local -a items
      for line in ${(f)"$(broadway __complete ${words[2,CURRENT-1]} -- ${words[CURRENT]} 2>/dev/null)"}; do
        items+=("${${line%%$'\\t'*}//:/\\\\:}:${line#*$'\\t'}")
      done
      _describe 'broadway' items
    }
    compdef _broadway broadway

    """

    static let bash = """
    # broadway completions, written by broadway setup
    _broadway() {
      local IFS=$'\\n'
      local current="${COMP_WORDS[COMP_CWORD]}"
      COMPREPLY=($(compgen -W "$(broadway __complete "${COMP_WORDS[@]:1:COMP_CWORD-1}" -- "$current" 2>/dev/null | cut -f1)" -- "$current"))
    }
    complete -o default -F _broadway broadway

    """

    static func candidates(_ typed: [String], current: String, catalog: Catalog) -> [(String, String)] {
        var found: [(String, String)] = []
        if let first = typed.first, let noun = Nouns.noun(first) ?? Nouns.aliases[first].flatMap({ Nouns.noun($0.noun) }) {
            found = nounWords(noun, typed: typed)
        } else if let first = typed.first {
            if first == "help" {
                found = typed.count == 2 ? (Nouns.noun(typed[1]).map { noun in noun.shown.map { ($0.name, $0.summary) } } ?? []) : commands(catalog)
            }
            if let command = catalog.find(first), Builtins.find(first) == nil {
                found = command.listed.map { ("--\($0.name)", $0.description) }
                if CommandLineInput.takesTarget(command) {
                    let named = Set(command.listed.map(\.name))
                    found += Help.targetOptions.filter { option in !named.contains(Help.flagName(option.0)) }.map { option in ("--" + Help.flagName(option.0), option.1) }
                    if !command.reads { found += Help.expectOptions.map { option in ("--" + Help.flagName(option.0), option.1) } }
                }
                if command.tabbed { found.append(("--tab", "the tab to work in")) }
            }
            if first == "batch" { found = [("--from", "run step N and on"), ("--keep-going", "go on after a failure"), ("--tab", "the tab to start in")] }
            if first == "run" { found = [("--timeout", "seconds the script may run"), ("--output-limit", "printed characters"), ("--tab", "the tab to start in")] }
            if first == "guide" { found = [("mcp", "how MCP clients connect")] }
            if first == "completions" { found = [("fish", ""), ("zsh", ""), ("bash", "")] }
            if first == "watch" { found = [("--only", "any of \(Watch.kinds.joined(separator: ","))"), ("--count", "stop after this many"), ("--seconds", "stop after this long")] }
            if ["setup", "remove"].contains(first) { found = Setup.parts.map { ($0, "") } }
        } else {
            found = commands(catalog)
        }
        found += [("--json", "one JSON envelope"), ("--help", "how to use this")]
        return found.filter { $0.0.hasPrefix(current) }
    }

    private static func commands(_ catalog: Catalog) -> [(String, String)] {
        Nouns.all.map { ($0.name, $0.summary) }
            + catalog.commands.filter { Nouns.noun($0.name) == nil && Builtins.find($0.name) == nil }.map { ($0.name, $0.summary) }
            + Builtins.all.filter { !$0.hidden }.map { ($0.name, $0.summary) }
    }

    private static func verb(_ noun: Noun, _ typed: [String]) -> Verb? {
        if let alias = Nouns.aliases[typed[0]] { return noun.verb(alias.verb) }
        if typed.count > 1, let named = noun.verb(typed[1]) { return named }
        return nil
    }

    private static func nounWords(_ noun: Noun, typed: [String]) -> [(String, String)] {
        guard let verb = verb(noun, typed) else {
            guard typed.count == 1 else { return [] }
            return noun.shown.map { ($0.name, $0.summary) }
        }
        let command = verb.command
        let named = Set(command.positional.map(\.name))
        var found = command.listed.filter { !named.contains($0.name) }.map { ("--\($0.name)", $0.description) }
        if command.tabbed { found.append(("--tab", "the tab to work in")) }
        return found
    }

    static let dynamic: [String: String] = ["space": "space", "tab": "tab", "setting": "setting", "shortcut": "shortcut", "folder": "folder"]

    static func wants(_ typed: [String]) -> String? {
        guard let first = typed.first else { return nil }
        if typed.last == "--tab" { return "tab" }
        if first == "tab", typed.count == 1 { return "tab" }
        guard let noun = Nouns.noun(first) ?? Nouns.aliases[first].flatMap({ Nouns.noun($0.noun) }), let verb = verb(noun, typed) else { return nil }
        let command = verb.command
        if let last = typed.last, last.hasPrefix("--") {
            let flag = String(last.dropFirst(2))
            return command.flags.contains { $0.name == flag && $0.type != "boolean" } ? dynamic[flag] : nil
        }
        let given = typed.dropFirst(Nouns.aliases[first] == nil ? 2 : 1).filter { !$0.hasPrefix("-") }.count
        let index = min(given, max(command.positional.count - 1, 0))
        guard index < command.positional.count, given < command.positional.count || command.positional[index].many else { return nil }
        return dynamic[command.positional[index].name]
    }

    private static func values(_ kind: String, context: Context) -> [(String, String)] {
        guard let link = context.place.connect() else { return [] }
        link.patience(0.2)
        guard link.send(["op": "do", "noun": "complete", "verb": "values", "arguments": ["of": kind], "wait": 0]), let reply = link.object(),
              let rows = (reply["data"] as? [String: Any])?["values"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in (row["value"] as? String).map { ($0, row["about"] as? String ?? "") } }
    }

    static func answer(_ words: [String], context: Context) -> Exit {
        let split = words.firstIndex(of: "--") ?? words.count
        let current = split + 1 < words.count ? words[split + 1] : ""
        let typed = Array(words[..<split])
        var found = candidates(typed, current: current, catalog: context.catalog())
        if let kind = wants(typed) { found = values(kind, context: context).filter { $0.0.hasPrefix(current) } + found }
        for (name, what) in found {
            context.console.line(what.isEmpty ? name : "\(name)\t\(Plain.cell(what))")
        }
        return .done
    }
}
