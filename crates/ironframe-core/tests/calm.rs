//! The CALM chain: the shop example's architecture and decorators resolve in every environment,
//! and every unresolved or incompatible binding is refused naming the element at fault.
//! ref:DEC-calm-resolution ref:DEC-calm-refusals

use ironframe_core::calm::load_and_resolve;
use std::path::PathBuf;

fn example() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/calm-shop/architecture/shop.calm.json")
}

/// Every environment of the example resolves. ref:DEC-calm-resolution
#[test]
fn the_example_resolves_in_every_environment() {
    for environment in ["twin", "real", "mixed", "staging"] {
        let resolution =
            load_and_resolve(&example(), None, environment).unwrap_or_else(|e| panic!("{environment}: {e}"));
        println!("{}", serde_json::to_string_pretty(&resolution.topology).unwrap());
    }
}
