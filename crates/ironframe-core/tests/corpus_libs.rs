//! Captures the corpus of the libraries the Rust implementation leaned on, so each Haskell
//! counterpart has an oracle of its own: serde_json reading and writing, serde_yaml reading and
//! writing, jsonschema's errors, semver, RFC 3339 times, Rust's Debug quoting of text and serde's
//! typed-decoding errors. Written to corpus/libs-*.json. Run with
//! `cargo test -p ironframe-core --test corpus_libs -- --ignored`. ref:DEC-haskell-wasm-core

use ironframe_core::calm::model::{CALM_META, CALM_SCHEMAS, DECORATOR_SCHEMAS};
use ironframe_core::manifest::{Admin, Fault, Real, SCHEMA, Twin};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

fn repo() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..").canonicalize().unwrap()
}

fn write(name: &str, cases: Vec<Value>) {
    let text = serde_json::to_string_pretty(&Value::Array(cases)).unwrap() + "\n";
    std::fs::write(repo().join("corpus").join(format!("libs-{name}.json")), text).unwrap();
}

fn json_cases() -> Vec<Value> {
    let texts = [
        "", " ", "null", "true", "false", "nul", "tru", "0", "-0", "01", "-", "1.", "1.5", "1e3", "1E+3", "1e-3", "1.5e", "-1.25e-7",
        "12345678901234567890", "18446744073709551615", "18446744073709551616", "-9223372036854775808",
        "-9223372036854775809", "1e400", "-1e400", "0.1", "123456789012345678901234567890.0", "2.5e-324", "1e-400",
        "3.141592653589793238462643383279", "5e-324", "1.7976931348623157e308", "100000000000000000000", "1e16", "1e15",
        "123456.789e3", "0.000001", "0.0000001", "\"\"", "\"a\\\"b\"", "\"\\u00e9\\u2603\\ud83d\\ude00\"", "\"\\ud800\"",
        "\"\\udc00\"", "\"\\ud800\\u0041\"", "\"\\x\"", "\"\\u12\"", "\"\\u12g4\"", "\"a\nb\"", "\"\\/\"", "\"tab\there\"", "\"unterminated",
        "[]", "[1,]", "[1 2]", "[", "[1", "{}", "{\"a\":1,}", "{\"a\" 1}", "{a:1}", "{\"a\":1 \"b\":2}", "{\"a\":", "{\"a\"", "{",
        "{\"a\":1,\"a\":2,\"b\":3}", "{\"z\":1,\"a\":[1,{\"y\":null}],\"m\":{}}", "[1] x", "1 2", "\n\n  [\n 1,\n x]",
        "{\"k\": [true, false, null, 1.0, -2, \"s\"]}", "  {\"nested\": {\"deep\": {\"deeper\": [[[]]]}}}  ", "\u{feff}{}",
        "[\"\u{7f}\", \"\u{1f}\"]", "{\"a\":\"\\u0000\\u001f\\b\\f\\n\\r\\t\\\\\\\"\"}", "nan", "Infinity", "[-]", "[--1]", "[+1]",
        "[.5]", "[1.e3]", "[0x10]", "\"\\uD83D\\uDE00\"", "{\"\\u0041\":1}", "[1e]", "[1e+]", "[1.5e-]",
    ];
    let mut cases = Vec::new();
    let deep = format!("{}{}", "[".repeat(130), "]".repeat(130));
    let mut all: Vec<String> = texts.iter().map(|t| t.to_string()).collect();
    all.push(deep);
    all.push(format!("{}{}", "[".repeat(127), "]".repeat(127)));
    for text in all {
        let expected = match serde_json::from_str::<Value>(&text) {
            Ok(value) => json!({"compact": serde_json::to_string(&value).unwrap(), "pretty": serde_json::to_string_pretty(&value).unwrap()}),
            Err(error) => json!({"error": error.to_string()}),
        };
        cases.push(json!({"method": "json.decode", "input": {"text": text}, "expected": expected}));
    }
    for f in [0.0, -0.0, 1.0, 0.5, 1000.0, 1e15, 1e16, 1e17, 1e21, 1e22, 1e-5, 1e-6, 1e-7, 123.456, 1.0 / 3.0, f64::MAX, f64::MIN_POSITIVE, 5e-324, 2.5, 9007199254740993.0, 0.1 + 0.2, 100.0, 12340000000.0, -7.25e-12] {
        cases.push(json!({"method": "json.formatDouble", "input": {"bits": f.to_bits().to_string()}, "expected": serde_json::to_string(&json!(f)).unwrap()}));
    }
    cases
}

fn yaml_cases() -> Vec<Value> {
    let mut texts: Vec<String> = vec![
        "", "~", "null", "Null", "NULL", "true", "True", "TRUE", "yes", "no", "on", "off", "y", "n", "1", "-1", "+1", "0x1F", "0o17",
        "017", "1_000", "1.5", "1.", ".5", "-.5", "1e3", "1E3", "1.0e+3", ".inf", "-.Inf", ".NaN", "0.1", "18446744073709551615",
        "18446744073709551616", "-9223372036854775809", "'1'", "\"1\"", "abc", "a: 1", "a: [1, 'b', \"c\", d]", "{a: {b: c}}",
        "- 1\n- 2\n", "a:\n  - x\n  - y\nb: z\n", "a: &x 1\nb: *x\n", "a: &m {k: v}\nb:\n  <<: *m\n  j: w\n", "a: 1\na: 2\n",
        "? [1, 2]\n: x\n", "1: one\n2: two\n", "true: t\n", "null: n\n", "1.5: f\n", "a: !!str 1\n", "a: !!int '1'\n", "a: !custom x\n",
        "--- 1\n--- 2\n", "---\na: 1\n...\n", "a: |\n  line one\n  line two\n", "a: >\n  folded\n  text\n", "a: 'it''s'\n",
        "a: \"tab\\there\\u00e9\"\n", "a: b: c\n", "a: [1, 2\n", "\tindented: tab\n", "a:\n  b: 1\n c: 2\n", "key with spaces: v\n",
        "a: \"x${endpoint}y\"\n", "a: ${endpoint}\n", "ports: [9092, 9644]\n", "x: 2001-12-14\n", "x: 12:30\n", "x: 0b101\n",
        "x: -0\n", "x: 00\n", "x: 1e400\n", "x: +.5\n", "x: 1__0\n", "x: 0x\n", "x: 0xg\n", "empty:\n", "list:\n- \n- a\n",
        "s: 'single \"q\"'\n", "u: caf\u{e9}\n", "n: -0.0\n", "x: 9223372036854775807\n", "x: -9223372036854775808\n",
        "x: 123456789012345678901234567890\n", "x: 1.7976931348623157e309\n", "x: 6.02e23\n", "x: 1e-10\n", "x: .1e2\n",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    for entry in std::fs::read_dir(repo().join("examples")).unwrap() {
        let manifest = entry.unwrap().path().join("ironframe.yaml");
        if manifest.exists() {
            texts.push(std::fs::read_to_string(manifest).unwrap());
        }
    }
    let manifest_cases: Value = serde_json::from_str(&std::fs::read_to_string(repo().join("corpus/manifest.json")).unwrap()).unwrap();
    for case in manifest_cases.as_array().unwrap() {
        if let Some(text) = case["input"]["text"].as_str() {
            texts.push(text.to_string());
        }
    }
    texts.dedup();
    let mut cases = Vec::new();
    for text in texts {
        let expected = match serde_yaml::from_str::<Value>(&text) {
            Ok(value) => json!({"ok": serde_json::to_string(&value).unwrap()}),
            Err(error) => json!({"error": error.to_string()}),
        };
        cases.push(json!({"method": "yaml.decode", "input": {"text": text}, "expected": expected}));
    }
    let strings = [
        "plain", "", " lead", "trail ", "a: b", "a #b", "#x", "- x", "-x", "x-", "1", "1.5", "true", "yes", "no", "null", "~", "0x1F",
        "1e3", "9092:9092", "8700:8700", "localhost:9092", "{\"seed\":42}", "{}", "[]", "[a]", "a,b", "a'b", "a\"b", "line\nbreak",
        "tab\there", "caf\u{e9}", "@x", "`x", "%x", "&x", "*x", "!x", "|x", ">x", "?x", "? x", ":x", "x:", "x: ", "a\\b",
        "/work/.ironframe/local/settings.json:/etc/ironframe/settings.json:ro,Z", "0.0.0.0:8700", "docker.io/lawtwin/kafka:0.1.0",
        "${endpoint}", "y", "n", "on", "off", "Yes", "NO", "True", "FALSE", "Null", ".inf", "-.inf", ".nan", "0o17", "017", "+1", "-1",
        "1_000", "12:30", "2001-12-14", "x\u{7}y", "\u{feff}x", "x\r\ny", "very long string with many words that goes on and on and on past eighty columns of text to see folding",
        "=", "<<", "'", "\"", "1.", ".5", "0b101", "  ", "\n", "x\n", "a  b", "ends with colon:", "{x}", "x}", "x]", "x,", "a# b",
    ];
    for s in strings {
        let mut map = serde_json::Map::new();
        map.insert("k".into(), json!(s));
        map.insert(s.to_string(), json!("v"));
        map.insert("list".into(), json!([s]));
        let value = Value::Object(map);
        cases.push(json!({"method": "yaml.encode", "input": {"value": value}, "expected": serde_yaml::to_string(&value).unwrap()}));
    }
    let compose_like = json!({"name": "ironframe-x-local", "services": {"a": {"image": "i", "ports": ["1:1"], "environment": {"TWIN_CONFIG": "{}", "E": ""}, "labels": {"io.ironframe.kind": "twin"}}, "b": {"image": "j", "volumes": ["/a:/b:ro,Z"], "nested": {"deep": [1, 2.5, true, null, "s"]}, "empty_map": {}, "empty_list": []}}});
    cases.push(json!({"method": "yaml.encode", "input": {"value": compose_like}, "expected": serde_yaml::to_string(&compose_like).unwrap()}));
    cases
}

fn schema_instances() -> Vec<(String, Value)> {
    // Every YAML manifest of the corpus, as a JSON value, for the manifest schema.
    let mut found = Vec::new();
    let manifest_cases: Value = serde_json::from_str(&std::fs::read_to_string(repo().join("corpus/manifest.json")).unwrap()).unwrap();
    for case in manifest_cases.as_array().unwrap() {
        if let Some(text) = case["input"]["text"].as_str()
            && let Ok(value) = serde_yaml::from_str::<Value>(text)
        {
            found.push(("manifest".to_string(), value));
        }
    }
    found
}

fn schema_cases() -> Vec<Value> {
    let mut cases = Vec::new();
    let manifest_schema: Value = serde_json::from_str(SCHEMA).unwrap();
    let validator = jsonschema::validator_for(&manifest_schema).unwrap();
    let errors = |validator: &jsonschema::Validator, value: &Value| -> Vec<Value> {
        validator
            .iter_errors(value)
            .map(|e| json!({"path": e.instance_path.to_string(), "schemaPath": e.schema_path.to_string(), "message": e.to_string()}))
            .collect()
    };
    for (_, value) in schema_instances() {
        cases.push(json!({"method": "schema.validate", "input": {"schema": "manifest", "instance": value}, "expected": errors(&validator, &value)}));
    }
    // CALM core, with every embedded meta schema registered.
    let mut options = jsonschema::options();
    for (name, text) in CALM_SCHEMAS {
        let value: Value = serde_json::from_str(text).unwrap();
        options = options.with_resource(format!("{CALM_META}{name}"), jsonschema::Resource::from_contents(value).unwrap());
    }
    let core: Value = serde_json::from_str(CALM_SCHEMAS[0].1).unwrap();
    let calm = options.build(&core).unwrap();
    let architecture: Value =
        serde_json::from_str(&std::fs::read_to_string(repo().join("examples/calm-shop/architecture/shop.calm.json")).unwrap()).unwrap();
    let mut architectures = vec![architecture.clone()];
    let edits: Vec<Box<dyn Fn(&mut Value)>> = vec![
        Box::new(|a| { a["nodes"][1].as_object_mut().unwrap().remove("node-type"); }),
        Box::new(|a| { a["nodes"][2]["unique-id"] = json!(5); a["relationships"][0]["relationship-type"] = json!({"teleports": {}}); a["extra"] = json!(true); }),
        Box::new(|a| { a["nodes"] = json!([]); }),
        Box::new(|a| { a["nodes"] = json!("x"); a["relationships"] = json!({}); }),
        Box::new(|a| { a["nodes"][0]["interfaces"] = json!([{"host": "x"}]); a["nodes"][0]["controls"] = json!({"c": {"description": "d"}}); }),
        Box::new(|a| { a["relationships"][0]["relationship-type"] = json!({"connects": {"source": {}, "destination": {"node": 1}}}); }),
        Box::new(|a| { a["relationships"][0]["relationship-type"] = json!({"interacts": {"actor": "a", "nodes": []}}); }),
        Box::new(|a| { a["relationships"][0]["relationship-type"] = json!({"composed-of": {"container": "a", "nodes": ["b"]}, "deployed-in": {"container": "a", "nodes": ["b"]}}); }),
        Box::new(|a| { a["relationships"][0]["relationship-type"] = json!({"options": [{"description": "d", "nodes": [], "relationships": []}]}); }),
        Box::new(|a| { a["flows"] = json!([{"unique-id": "f", "name": "n", "description": "d", "transitions": [{"relationship-unique-id": "r", "sequence-number": 1, "description": "d", "direction": "sideways"}]}]); }),
        Box::new(|a| { a["adrs"] = json!([1]); a["metadata"] = json!(5); a["controls"] = json!([]); }),
        Box::new(|a| { a["nodes"][3]["details"] = json!({"detailed-architecture": 1, "required-pattern": "p"}); a["nodes"][3]["data-classification"] = json!("Secret"); }),
        Box::new(|a| { a["relationships"][1]["protocol"] = json!("Telepathy"); a["relationships"][1]["authentication"] = json!("magic"); }),
    ];
    for edit in edits {
        let mut a = architecture.clone();
        edit(&mut a);
        architectures.push(a);
    }
    architectures.push(json!({}));
    architectures.push(json!([]));
    for value in architectures {
        cases.push(json!({"method": "schema.validate", "input": {"schema": "calm-core", "instance": value}, "expected": errors(&calm, &value)}));
    }
    // CALM's base decorator and Ironframe's decorator schemas.
    let decorators_schema: Value = serde_json::from_str(CALM_SCHEMAS[4].1).unwrap();
    let base = jsonschema::validator_for(&decorators_schema["defs"]["decorator"]).unwrap();
    let typed: Vec<(&str, jsonschema::Validator)> = DECORATOR_SCHEMAS
        .iter()
        .map(|(kind, text)| (*kind, jsonschema::validator_for(&serde_json::from_str::<Value>(text).unwrap()).unwrap()))
        .collect();
    let decorators: Value =
        serde_json::from_str(&std::fs::read_to_string(repo().join("examples/calm-shop/architecture/shop.decorators.json")).unwrap()).unwrap();
    let mut items: Vec<Value> = decorators["decorators"].as_array().unwrap().clone();
    let first = items[0].clone();
    let binding = items.iter().find(|d| d["unique-id"] == "adoptions-log-twin").unwrap().clone();
    let environment = items.iter().find(|d| d["unique-id"] == "staging-environment").unwrap().clone();
    let contract = items.iter().find(|d| d["unique-id"] == "adoptions-log-contract").unwrap().clone();
    let variants: Vec<Value> = vec![
        json!({}),
        json!({"unique-id": "", "type": 1, "target": [], "applies-to": [1], "data": {}, "extra": 1}),
        { let mut d = first.clone(); d["$schema"] = json!("x"); d },
        { let mut d = binding.clone(); d["data"]["environment"] = json!("Twin"); d["data"]["real"] = json!({"endpoint": ""}); d },
        { let mut d = binding.clone(); d["data"] = json!({"environment": "x"}); d },
        { let mut d = binding.clone(); d["data"]["twin"]["stands-in-for"] = json!({"package": "Bad", "version": "1", "abilities": [], "x": 1}); d },
        { let mut d = binding.clone(); d["data"] = json!({"environment": "x", "application": {"managed": {"process": {"command": []}, "image": {"image": ""}}, "implementation": {"version": 1}}}); d },
        { let mut d = binding.clone(); d["data"] = json!({"environment": "x", "application": {"managed": {"image": {"image": "i", "build": {}}}, "other": 1}}); d },
        { let mut d = binding.clone(); d["type"] = json!("ironframe-contract"); d },
        { let mut d = binding.clone(); d["data"]["twin"] = json!({}); d },
        { let mut d = binding.clone(); d["data"]["real"] = json!({"endpoint": "x", "provider": {"name": "", "version": 1, "x": 0}}); d.as_object_mut().unwrap().remove("twin"); d["data"].as_object_mut().unwrap().remove("twin"); d },
        { let mut d = environment.clone(); d["data"]["project"] = json!(""); d["data"]["sync"] = json!("x"); d["data"]["runtime"] = json!("k8s"); d },
        { let mut d = environment.clone(); d["data"] = json!({"environment": "e"}); d },
        { let mut d = contract.clone(); d["data"]["dependency"]["package"] = json!("Bad"); d["data"]["dependency"].as_object_mut().unwrap().remove("abilities"); d },
        { let mut d = contract.clone(); d["data"] = json!({"application": {"package": "p", "version": "1.0.0"}, "dependency": {}}); d },
        { let mut d = contract.clone(); d["data"] = json!({"connection": {"consumes": [], "settings": {}}}); d },
        { let mut d = contract.clone(); d["data"] = json!({"connection": {"consumes": ["a::ability::B"], "settings": {"bad key": "x", "OK": 1}}}); d },
        { let mut d = contract.clone(); d["data"]["dependency"]["conformance"] = json!({"accept": []}); d["data"]["dependency"]["version"] = json!(""); d },
        json!(5),
        json!([]),
    ];
    items.extend(variants);
    for item in items {
        let mut bare = item.clone();
        if let Some(map) = bare.as_object_mut() {
            map.remove("$schema");
        }
        cases.push(json!({"method": "schema.validate", "input": {"schema": "calm-decorator", "instance": bare}, "expected": errors(&base, &bare)}));
        for (kind, validator) in &typed {
            cases.push(json!({"method": "schema.validate", "input": {"schema": kind, "instance": item}, "expected": errors(validator, &item)}));
        }
    }
    // The attestation schema.
    let attestation_schema: Value = serde_json::from_str(ironframe_attestation::SCHEMA_V1).unwrap();
    let attestation = jsonschema::validator_for(&attestation_schema).unwrap();
    let attestation_cases: Value = serde_json::from_str(&std::fs::read_to_string(repo().join("corpus/attestation.json")).unwrap()).unwrap();
    for case in attestation_cases.as_array().unwrap() {
        if let Some(text) = case["input"]["text"].as_str()
            && let Ok(value) = serde_json::from_str::<Value>(text)
        {
            cases.push(json!({"method": "schema.validate", "input": {"schema": "attestation", "instance": value}, "expected": errors(&attestation, &value)}));
        }
    }
    cases
}

fn semver_cases() -> Vec<Value> {
    let versions = [
        "0.1.0", "1.2.3", "1.2.3-alpha.1", "1.2.3+build.5", "1.2.3-rc.1+b", "01.2.3", "1.2", "1", "v1.2.3", "1.2.3-", "1.2.3-01", "1.2.3-a..b",
        "", " 1.2.3", "1.2.3 ", "18446744073709551615.0.0", "18446744073709551616.0.0", "1.2.3-alpha.01", "0.0.0", "1.2.3+", "1.2.3-x-y",
        "0.1.5-beta.1", "0.2.0", "0.9.0", "1.0", "1.a.0",
    ];
    let requirements = [
        ">=0.1.0, <0.2.0", "^0.1.0", "~0.1", "0.1", "0.1.0", "=0.1.0", "*", "1.*", "1.x", ">1", "<=1.2", ">=x", "", ">= 0.1.0", "^1.2.3-alpha",
        ">=1.0.0-alpha, <1.0.0", "0.*.1", "1.2.3, 1.2.4", "^0", "^0.0", "^0.0.3", "~1.2.3", "~1", "=1.2", "<1.2.3-beta", ">1.2.3-beta",
        "*, <2", "1.2.3,", ",", ">=0.1.0,<0.2.0", "^ 1.2", "!1", "1 2",
    ];
    let mut cases = Vec::new();
    for v in versions {
        let result = match semver::Version::parse(v) {
            Ok(version) => json!({"ok": version.to_string()}),
            Err(error) => json!({"error": error.to_string()}),
        };
        cases.push(json!({"method": "semver.version", "input": {"text": v}, "expected": result}));
    }
    for r in requirements {
        let result = match semver::VersionReq::parse(r) {
            Ok(req) => {
                let matches: Vec<Value> = versions
                    .iter()
                    .filter_map(|v| semver::Version::parse(v).ok().map(|version| json!([v, req.matches(&version)])))
                    .collect();
                json!({"ok": req.to_string(), "matches": matches})
            }
            Err(error) => json!({"error": error.to_string()}),
        };
        cases.push(json!({"method": "semver.requirement", "input": {"text": r}, "expected": result}));
    }
    cases
}

fn time_cases() -> Vec<Value> {
    use time::OffsetDateTime;
    use time::format_description::well_known::Rfc3339;
    let texts = [
        "2026-10-09T12:00:00Z", "2026-10-09T12:00:00.5Z", "2026-10-09T12:00:00.100Z", "2026-10-09T12:00:00.123456789Z",
        "2026-10-09T12:00:00.1234567891Z", "2026-10-09T13:00:00+01:00", "2026-10-09T12:00:00-00:30", "2026-10-09t12:00:00z",
        "2026-10-09 12:00:00Z", "2026-10-09T12:00:00", "2026-02-30T00:00:00Z", "2026-10-09T24:00:00Z", "2026-10-09T23:59:60Z",
        "yesterday", "", "2026-10-09T12:00:00+0100", "2026-10-09T12:00:00+24:00", "0001-01-01T00:00:00Z", "9999-12-31T23:59:59.999999999Z",
        "2024-02-29T12:00:00Z", "2023-02-29T12:00:00Z", "2026-10-09T12:00:00.Z", "2026-1-09T12:00:00Z", "2026-10-09T12:00:00-00:00",
    ];
    let mut cases = Vec::new();
    for text in texts {
        let result = match OffsetDateTime::parse(text, &Rfc3339) {
            Ok(t) => json!({"ok": t.format(&Rfc3339).unwrap(), "unixNanos": t.unix_timestamp_nanos().to_string()}),
            Err(error) => json!({"error": error.to_string()}),
        };
        cases.push(json!({"method": "time.rfc3339", "input": {"text": text}, "expected": result}));
    }
    // Formatting from a UTC instant, as `now` gives one.
    for (seconds, nanos) in [(0i64, 0u32), (1_791_633_600, 0), (1_791_633_600, 500_000_000), (1_791_633_600, 123_456_789), (1_791_633_600, 1_000), (4_070_908_800, 999_000_000)] {
        let t = OffsetDateTime::from_unix_timestamp(seconds).unwrap() + time::Duration::nanoseconds(i64::from(nanos));
        cases.push(json!({"method": "time.format", "input": {"seconds": seconds, "nanos": nanos}, "expected": t.format(&Rfc3339).unwrap()}));
    }
    cases
}

fn debug_cases() -> Vec<Value> {
    let texts = [
        "plain", "", "with \"quotes\"", "back\\slash", "new\nline", "tab\t", "cr\r", "nul\0", "bell\u{7}", "del\u{7f}", "caf\u{e9}",
        "snow\u{2603}", "emoji\u{1f600}", "zw\u{200b}j", "combining e\u{301}", "\u{301}lead", "nbsp\u{a0}", "bom\u{feff}", "single'quote",
        "line\u{2028}sep", "\u{e000}private", "\u{10ffff}", "esc\u{1b}[0m", "soft\u{ad}hyphen",
    ];
    texts.iter().map(|t| json!({"method": "rust.debugStr", "input": {"text": t}, "expected": format!("{t:?}")})).collect()
}

fn serde_cases() -> Vec<Value> {
    let twins = vec![
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [1], "colour": "blue"}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [1], "seed": "seven"}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [1], "seed": -1}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [1], "seed": 1.5}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [70000]}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": "x"}),
        json!({"image": "i", "version": "1", "conformance": "c"}),
        json!({"image": 1, "version": "1", "conformance": "c", "ports": [1]}),
        json!({"image": "i", "version": "1", "conformance": 5, "ports": [1]}),
        json!({"image": "i", "version": "1", "conformance": {"level": "a", "x": 1}, "ports": [1]}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [1], "protocol": "udp"}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [1], "faults": [{"params": {}}]}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [1], "faults": [{"name": "f", "x": 1}]}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [1], "admin": {"port": "x"}}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [1], "env": {"A": 1}}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [1], "admin": null}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [1], "seed": null}),
        json!({"image": "i", "version": "1", "conformance": "c", "ports": [-1]}),
        json!([1]),
        json!("twin"),
        json!(null),
    ];
    let mut cases = Vec::new();
    for value in twins {
        let result = match serde_json::from_value::<Twin>(value.clone()) {
            Ok(twin) => json!({"ok": serde_json::to_string(&twin).unwrap()}),
            Err(error) => json!({"error": error.to_string()}),
        };
        cases.push(json!({"method": "serde.twin", "input": {"value": value}, "expected": result}));
    }
    for value in [json!({"endpoint": "x", "colour": 1}), json!({}), json!({"endpoint": 5}), json!({"endpoint": "x", "ports": [1, "a"]}), json!({"endpoint": "x", "image": null})] {
        let result = match serde_json::from_value::<Real>(value.clone()) {
            Ok(real) => json!({"ok": serde_json::to_string(&real).unwrap()}),
            Err(error) => json!({"error": error.to_string()}),
        };
        cases.push(json!({"method": "serde.real", "input": {"value": value}, "expected": result}));
    }
    for value in [json!({"name": "f", "params": {"a": [1]}}), json!({"name": 1})] {
        let result = match serde_json::from_value::<Fault>(value.clone()) {
            Ok(f) => json!({"ok": serde_json::to_string(&f).unwrap()}),
            Err(error) => json!({"error": error.to_string()}),
        };
        cases.push(json!({"method": "serde.fault", "input": {"value": value}, "expected": result}));
    }
    for value in [json!({}), json!({"port": 1, "container_port": 2, "url": "u"}), json!({"port": 0}), json!({"port": 65536})] {
        let result = match serde_json::from_value::<Admin>(value.clone()) {
            Ok(a) => json!({"ok": serde_json::to_string(&a).unwrap()}),
            Err(error) => json!({"error": error.to_string()}),
        };
        cases.push(json!({"method": "serde.admin", "input": {"value": value}, "expected": result}));
    }
    cases
}

#[test]
#[ignore = "writes corpus/libs-*.json; run with --ignored"]
fn capture() {
    write("json", json_cases());
    write("yaml", yaml_cases());
    write("schema", schema_cases());
    write("semver", semver_cases());
    write("time", time_cases());
    write("debug", debug_cases());
    write("serde", serde_cases());
}
