struct InputSourceRule: Equatable {
    var bundleID: String
    var name: String
    var defaultSourceID: String?
    var rememberLast: Bool
    var forceEnglishPunctuation: Bool
}

struct InputSourceSettings: Equatable {
    var rules: [String: InputSourceRule] = [:]

    init(rules: [String: InputSourceRule] = [:]) {
        self.rules = rules
    }

    init(config: [String: Any]) {
        for value in config["inputSourceRules"] as? [[String: Any]] ?? [] {
            guard let bundleID = value["bundleID"] as? String, !bundleID.isEmpty,
                  let name = value["name"] as? String,
                  let remember = value["rememberLast"] as? Bool,
                  let punctuation = value["forceEnglishPunctuation"] as? Bool else { continue }
            rules[bundleID] = InputSourceRule(bundleID: bundleID, name: name,
                                              defaultSourceID: value["defaultSourceID"] as? String,
                                              rememberLast: remember, forceEnglishPunctuation: punctuation)
        }
    }

    var punctuationApps: Set<String> {
        Set(rules.values.filter(\.forceEnglishPunctuation).map(\.bundleID))
    }
}
